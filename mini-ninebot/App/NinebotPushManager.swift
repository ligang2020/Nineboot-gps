import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    static let ninebotVehicleAlarm = Notification.Name("ninebot.vehicle.alarm")
}

enum NinebotPushError: LocalizedError {
    case denied
    case missingToken
    case missingBundleID
    case missingServer

    var errorDescription: String? {
        switch self {
        case .denied:
            return "系统通知权限未开启"
        case .missingToken:
            return "还没有拿到 APNs 设备 Token，请稍后再试"
        case .missingBundleID:
            return "无法读取 App Bundle ID"
        case .missingServer:
            return "请先填写 NinePlus 平台地址和 Token"
        }
    }
}

/// Registers the device for APNs and turns both server-delivered and locally
/// detected vehicle alarms into actionable system notifications.
final class NinebotPushManager: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let shared = NinebotPushManager()

    static let vehicleAlarmCategoryIdentifier = "NINEBOT_VEHICLE_ALARM"
    static let openVehicleActionIdentifier = "NINEBOT_OPEN_VEHICLE"

    private static let activeAlarmSignaturesKey = "ninebot.vehicle.alarm.active.signatures"
    private static let alarmKeywords = [
        "alarm", "alert", "warn", "warning", "fault", "theft", "security", "vibration", "exception"
    ]
    private static let inactiveAlarmValues: Set<String> = [
        "", "0", "false", "no", "off", "none", "normal", "inactive", "clear", "cleared", "safe", "ok", "noalarm", "no_alarm"
    ]

    private let store = NinebotSharedStore()
    private let alarmDefaults = UserDefaults(suiteName: NinebotAppGroup.identifier) ?? .standard

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NinebotNotificationManager.shared.configure()
        Task { await requestAuthorizationOnLaunchAndRegister() }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        store.savePushDeviceToken(token)
        Task {
            try? await registerStoredTokenWithServer()
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Registration can fail on simulator or when signing lacks Push Notifications.
    }

    /// Shows an alarm received while the app is foregrounded instead of
    /// silently swallowing it. Background alerts are presented by iOS.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        if content.categoryIdentifier == Self.vehicleAlarmCategoryIdentifier {
            NotificationCenter.default.post(
                name: .ninebotVehicleAlarm,
                object: nil,
                userInfo: content.userInfo
            )
        }
        completionHandler()
    }

    /// Converts a silent vehicle-alarm APNs payload to a visible local alert.
    /// Visible APNs alerts are intentionally left to the system so they are not
    /// delivered twice.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard Self.isVehicleAlarmPayload(userInfo) else {
            completionHandler(.noData)
            return
        }

        if Self.hasVisibleAlert(userInfo) {
            completionHandler(.newData)
            return
        }

        let vehicleName = Self.payloadText(for: ["vehicle_name", "vehicleName", "name", "sn"], in: userInfo)
        let event = Self.payloadText(for: ["alarm_type", "alert_type", "event", "type", "message"], in: userInfo)
        let title = "\(vehicleName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "车辆") 报警"
        let body = event?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "检测到车辆安全异常，请及时确认车辆状态。"
        let identifier = Self.payloadText(for: ["alarm_id", "event_id", "id"], in: userInfo)
            ?? "remote.\(vehicleName ?? "vehicle").\(event ?? "alarm")"

        scheduleVehicleAlarmNotification(
            title: title,
            body: body,
            identifier: "ninebot.remote.alarm.\(identifier)"
        ) {
            completionHandler(.newData)
        }
    }

    /// Evaluates raw vehicle status returned during normal dashboard refreshes.
    /// A notification is sent only when an alarm signature newly becomes active;
    /// when the raw alarm clears, the signature is removed so a later alarm can
    /// notify the owner again.
    func syncVehicleAlarmNotifications(with dashboard: NinebotDashboard) {
        let activeSignals = dashboard.vehicles.flatMap { alarmSignals(for: $0) }
        let currentSignatures = Set(activeSignals.map(\.signature))
        let previousSignatures = Set(alarmDefaults.stringArray(forKey: Self.activeAlarmSignaturesKey) ?? [])
        let newlyActive = currentSignatures.subtracting(previousSignatures)

        alarmDefaults.set(Array(currentSignatures).sorted(), forKey: Self.activeAlarmSignaturesKey)

        for signal in activeSignals where newlyActive.contains(signal.signature) {
            scheduleVehicleAlarmNotification(
                title: "\(signal.vehicleName) 车辆报警",
                body: "检测到\(signal.fieldDescription)：\(signal.valueDescription)。请及时确认车辆状态。",
                identifier: "ninebot.vehicle.alarm.\(signal.signature)"
            )
        }
    }

    func requestAuthorizationAndRegister() async throws {
        let granted = try await requestAuthorization()
        guard granted else { throw NinebotPushError.denied }
        await registerForRemoteNotifications()
    }

    func requestAuthorizationRegisterAndWaitForToken() async throws -> String? {
        let granted = try await requestAuthorization()
        guard granted else { throw NinebotPushError.denied }
        await registerForRemoteNotifications()
        return await waitForStoredToken()
    }

    func registerStoredTokenWithServer() async throws {
        guard let token = store.loadPushDeviceToken() else {
            throw NinebotPushError.missingToken
        }
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            throw NinebotPushError.missingBundleID
        }
        guard let configuration = store.loadConfiguration(), configuration.isUsable else {
            throw NinebotPushError.missingServer
        }
        try await NinebotProxyClient(configuration: configuration).registerPushDevice(
            token: token,
            bundleID: bundleID,
            environment: Self.apnsEnvironment
        )
    }

    private func configureVehicleAlarmCategory() {
        let openVehicle = UNNotificationAction(
            identifier: Self.openVehicleActionIdentifier,
            title: "查看车辆",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.vehicleAlarmCategoryIdentifier,
            actions: [openVehicle],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func scheduleVehicleAlarmNotification(
        title: String,
        body: String,
        identifier: String,
        completion: (() -> Void)? = nil
    ) {
        Task { @MainActor in
            NinebotNotificationManager.shared.send(
                category: .vehicleAlarm,
                title: title,
                body: body,
                vehicleSN: identifier,
                destination: .location,
                dedupeInterval: 60
            )
            completion?()
        }
    }

    private func alarmSignals(for snapshot: NinebotVehicleSnapshot) -> [VehicleAlarmSignal] {
        let sources: [(String, [String: JSONValue]?)] = [
            ("车辆状态", snapshot.state.rawStatus),
            ("电池状态", snapshot.state.rawBattery),
            ("行程状态", snapshot.state.rawTravel)
        ]
        var signals: [VehicleAlarmSignal] = []

        for (sourceName, fields) in sources {
            guard let fields, !fields.isEmpty else { continue }
            collectAlarmSignals(
                in: .object(fields),
                vehicleSN: snapshot.vehicle.sn,
                vehicleName: snapshot.vehicle.displayName,
                path: sourceName,
                into: &signals
            )
        }

        // Do not flood a single refresh if the server exposes the same alarm in
        // multiple raw payloads.
        var seen = Set<String>()
        return signals.filter { seen.insert($0.signature).inserted }.prefix(4).map { $0 }
    }

    private func collectAlarmSignals(
        in value: JSONValue,
        vehicleSN: String,
        vehicleName: String,
        path: String,
        into signals: inout [VehicleAlarmSignal]
    ) {
        switch value {
        case .object(let object):
            for (key, nestedValue) in object {
                let nestedPath = "\(path) · \(key)"
                if Self.isAlarmKey(key), let summary = Self.activeAlarmSummary(nestedValue) {
                    let signature = Self.signature(
                        vehicleSN: vehicleSN,
                        path: nestedPath,
                        summary: summary
                    )
                    signals.append(
                        VehicleAlarmSignal(
                            signature: signature,
                            vehicleName: vehicleName,
                            fieldDescription: key,
                            valueDescription: summary
                        )
                    )
                }
                collectAlarmSignals(
                    in: nestedValue,
                    vehicleSN: vehicleSN,
                    vehicleName: vehicleName,
                    path: nestedPath,
                    into: &signals
                )
            }
        case .array(let array):
            for (index, nestedValue) in array.enumerated() {
                collectAlarmSignals(
                    in: nestedValue,
                    vehicleSN: vehicleSN,
                    vehicleName: vehicleName,
                    path: "\(path)[\(index)]",
                    into: &signals
                )
            }
        default:
            break
        }
    }

    private static func activeAlarmSummary(_ value: JSONValue) -> String? {
        switch value {
        case .bool(let isActive):
            return isActive ? "已触发" : nil
        case .number(let number):
            guard number > 0 else { return nil }
            return value.displayText
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalizedAlarmText(trimmed)
            guard !inactiveAlarmValues.contains(normalized) else { return nil }
            return trimmed.nonEmpty
        case .object(let object):
            for key in ["message", "name", "title", "type", "code", "value", "status"] {
                if let candidate = object[key], let summary = activeAlarmSummary(candidate) {
                    return summary
                }
            }
            return nil
        case .array(let values):
            return values.compactMap(activeAlarmSummary).first
        case .null:
            return nil
        }
    }

    private static func isVehicleAlarmPayload(_ userInfo: [AnyHashable: Any]) -> Bool {
        for (key, value) in userInfo {
            let keyText = String(describing: key)
            let normalizedKey = normalizedAlarmText(keyText)
            if ["category", "event", "type", "kind", "alarmtype", "alerttype"].contains(normalizedKey),
               let summary = activePayloadAlarmSummary(value),
               isAlarmKey(summary) {
                return true
            }
            if isAlarmKey(keyText), let summary = activePayloadAlarmSummary(value), !summary.isEmpty {
                return true
            }
            if let dictionary = value as? [AnyHashable: Any], isVehicleAlarmPayload(dictionary) {
                return true
            }
            if let dictionary = value as? [String: Any], isVehicleAlarmPayload(Dictionary(uniqueKeysWithValues: dictionary.map { (AnyHashable($0.key), $0.value) })) {
                return true
            }
            if let array = value as? [Any], array.contains(where: { activePayloadAlarmSummary($0) != nil }) && isAlarmKey(keyText) {
                return true
            }
        }
        return false
    }

    private static func hasVisibleAlert(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let aps = userInfo["aps"] as? [AnyHashable: Any] else { return false }
        guard let alert = aps["alert"] else { return false }
        if let text = alert as? String { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let dictionary = alert as? [AnyHashable: Any] {
            return dictionary.values.contains { activePayloadAlarmSummary($0) != nil }
        }
        return true
    }

    private static func payloadText(for keys: [String], in userInfo: [AnyHashable: Any]) -> String? {
        let wanted = Set(keys.map { $0.lowercased() })
        for (key, value) in userInfo where wanted.contains(String(describing: key).lowercased()) {
            if let summary = activePayloadAlarmSummary(value) {
                return summary
            }
        }
        return nil
    }

    private static func activePayloadAlarmSummary(_ value: Any) -> String? {
        switch value {
        case let text as String:
            return text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "已触发" : nil
            }
            return number.doubleValue > 0 ? number.stringValue : nil
        case let dictionary as [AnyHashable: Any]:
            for key in ["body", "title", "message", "type", "event", "code", "value", "status"] {
                if let value = dictionary[AnyHashable(key)], let summary = activePayloadAlarmSummary(value) {
                    return summary
                }
            }
            return nil
        case let dictionary as [String: Any]:
            return activePayloadAlarmSummary(Dictionary(uniqueKeysWithValues: dictionary.map { (AnyHashable($0.key), $0.value) }))
        case let array as [Any]:
            return array.compactMap(activePayloadAlarmSummary).first
        default:
            return nil
        }
    }

    private static func isAlarmKey(_ key: String) -> Bool {
        let normalized = normalizedAlarmText(key)
        return alarmKeywords.contains { normalized.contains($0) }
    }

    private static func normalizedAlarmText(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
    }

    private static func signature(vehicleSN: String, path: String, summary: String) -> String {
        let raw = "\(vehicleSN)|\(path)|\(summary)"
        return raw.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
    }

    private func requestAuthorizationOnLaunchAndRegister() async {
        let settings = await notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            guard ((try? await requestAuthorization()) ?? false) else { return }
            await registerForRemoteNotifications()
        case .authorized, .provisional, .ephemeral:
            await registerForRemoteNotifications()
        default:
            break
        }
    }

    private func registerForRemoteNotifications() async {
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func waitForStoredToken() async -> String? {
        if let token = store.loadPushDeviceToken() {
            return token
        }

        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let token = store.loadPushDeviceToken() {
                return token
            }
        }

        return store.loadPushDeviceToken()
    }

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }
}

private struct VehicleAlarmSignal: Hashable {
    var signature: String
    var vehicleName: String
    var fieldDescription: String
    var valueDescription: String
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
