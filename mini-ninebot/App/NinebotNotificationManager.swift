import Foundation
import UIKit
import UserNotifications
import Combine

/// 通知点击后的 App 内路由。ContentView 监听该对象并切换到对应页面。
enum NinebotNotificationDestination: String, Codable, Hashable, Sendable {
    case vehicle
    case map
    case charging
    case chargingDetail
    case location
    case vehicleStatus
}

/// 所有本地/远程通知共用的分类、分组与默认跳转位置。
enum NinebotNotificationCategory: String, CaseIterable, Sendable {
    case chargingStarted = "NINEBOT_CHARGING_STARTED"
    case chargingFull = "NINEBOT_CHARGING_FULL"
    case chargingInterrupted = "NINEBOT_CHARGING_INTERRUPTED"
    case vehicleAlarm = "NINEBOT_VEHICLE_ALARM"
    case illegalMovement = "NINEBOT_ILLEGAL_MOVEMENT"
    case vehiclePushed = "NINEBOT_VEHICLE_PUSHED"
    case powerDisconnected = "NINEBOT_POWER_DISCONNECTED"
    case batteryRemoved = "NINEBOT_BATTERY_REMOVED"
    case bluetoothDisconnected = "NINEBOT_BLUETOOTH_DISCONNECTED"
    case gpsOffline = "NINEBOT_GPS_OFFLINE"
    case lowBattery = "NINEBOT_LOW_BATTERY"
    case criticalBattery = "NINEBOT_CRITICAL_BATTERY"
    case geofenceEntered = "NINEBOT_GEOFENCE_ENTERED"
    case geofenceExited = "NINEBOT_GEOFENCE_EXITED"
    case vehicleLocationUpdated = "NINEBOT_LOCATION_UPDATED"
    case sos = "NINEBOT_SOS"
    case rideCompleted = "NINEBOT_RIDE_COMPLETED"

    var threadIdentifier: String {
        switch self {
        case .chargingStarted, .chargingFull, .chargingInterrupted:
            return "ninebot.charging"
        case .geofenceEntered, .geofenceExited, .vehicleLocationUpdated:
            return "ninebot.location"
        case .lowBattery, .criticalBattery:
            return "ninebot.battery"
        case .rideCompleted:
            return "ninebot.ride"
        default:
            return "ninebot.security"
        }
    }

    var destination: NinebotNotificationDestination {
        switch self {
        case .chargingStarted: return .charging
        case .chargingFull: return .vehicle
        case .chargingInterrupted: return .chargingDetail
        case .vehicleAlarm, .sos: return .location
        case .illegalMovement, .vehiclePushed, .geofenceEntered, .geofenceExited, .vehicleLocationUpdated: return .map
        case .powerDisconnected, .batteryRemoved, .bluetoothDisconnected, .gpsOffline: return .vehicleStatus
        case .lowBattery, .criticalBattery: return .vehicle
        case .rideCompleted: return .vehicleStatus
        }
    }
}

/// SwiftUI 侧的通知跳转状态。远程推送与本地通知均在此收口。
@MainActor
final class NinebotNotificationRouter: ObservableObject {
    static let shared = NinebotNotificationRouter()

    @Published private(set) var destination: NinebotNotificationDestination?
    @Published private(set) var vehicleSN: String?
    @Published private(set) var routeToken = UUID()

    func route(userInfo: [AnyHashable: Any]) {
        let rawDestination = (userInfo["destination"] as? String)
            ?? (userInfo["ninebot_destination"] as? String)
        let category = (userInfo["category"] as? String).flatMap(NinebotNotificationCategory.init(rawValue:))
        destination = rawDestination.flatMap(NinebotNotificationDestination.init(rawValue:)) ?? category?.destination ?? .vehicle
        vehicleSN = (userInfo["vehicleSN"] as? String) ?? (userInfo["vehicle_sn"] as? String)
        routeToken = UUID()
    }

    func consume() {
        destination = nil
        vehicleSN = nil
    }
}

/// 权限查询与请求单独封装，供设置页、首次启动与防盗开关共用。
@MainActor
final class NinebotNotificationPermissionManager: ObservableObject {
    static let shared = NinebotNotificationPermissionManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    func refresh() async {
        authorizationStatus = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .badge, .sound, .providesAppNotificationSettings]
            )
            await refresh()
            return granted
        } catch {
            await refresh()
            return false
        }
    }
}

/// 统一的本地/远程通知管理器。
/// - 本地事件：BLE、GPS、电子围栏、充电状态。
/// - 远程事件：APNs 静默推送可调用 `handleRemotePayload(_:)` 复用相同规则。
/// - 去重：相同车辆、分类、正文在冷却时间内仅提醒一次，避免 BLE 每秒重复上报造成打扰。
@MainActor
final class NinebotNotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NinebotNotificationManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private var recentlySent: [String: Date] = [:]
    private let defaults = UserDefaults(suiteName: NinebotAppGroup.identifier) ?? .standard
    private let dedupePrefix = "ninebot.notification.last."

    func configure() {
        UNUserNotificationCenter.current().delegate = self
        let openAction = UNNotificationAction(
            identifier: "NINEBOT_OPEN_VEHICLE",
            title: "查看车辆",
            options: [.foreground]
        )
        let mapAction = UNNotificationAction(
            identifier: "NINEBOT_OPEN_MAP",
            title: "查看定位",
            options: [.foreground]
        )
        let stopFindAction = UNNotificationAction(
            identifier: "NINEBOT_STOP_FIND",
            title: "停止寻车",
            options: [.foreground]
        )
        let categories = Set(NinebotNotificationCategory.allCases.map { category in
            UNNotificationCategory(
                identifier: category.rawValue,
                actions: [openAction, mapAction, stopFindAction],
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
        })
        UNUserNotificationCenter.current().setNotificationCategories(categories)
        Task { await refreshAuthorizationStatus() }
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    /// 发送标准本地通知。Critical Alert 必须由 Apple 授予 entitlement；未获授权时降级为 time-sensitive。
    func send(
        category: NinebotNotificationCategory,
        title: String,
        body: String,
        vehicleSN: String? = nil,
        destination: NinebotNotificationDestination? = nil,
        dedupeInterval: TimeInterval = 45,
        isSilent: Bool = false,
        requestsCriticalAlert: Bool = false,
        badge: NSNumber? = 1
    ) {
        let key = "\(category.rawValue).\(vehicleSN ?? "default").\(body)"
        let now = Date()
        let persistedDate = defaults.object(forKey: dedupePrefix + key.sha256Key) as? Date
        if let last = recentlySent[key] ?? persistedDate, now.timeIntervalSince(last) < dedupeInterval {
            return
        }
        recentlySent[key] = now
        defaults.set(now, forKey: dedupePrefix + key.sha256Key)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category.rawValue
        content.threadIdentifier = category.threadIdentifier
        content.userInfo = [
            "category": category.rawValue,
            "vehicleSN": vehicleSN ?? "",
            "destination": (destination ?? category.destination).rawValue
        ]
        content.badge = badge
        if !isSilent {
            content.sound = .default
        }
        // 仅作为预留：没有 Critical Alerts entitlement 时不能设置 .critical，避免审核/运行时问题。
        content.interruptionLevel = requestsCriticalAlert ? .timeSensitive : .active

        let request = UNNotificationRequest(identifier: "ninebot.\(key.sha256Key)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 骑行结束后发送一次本地通知；通知内容与总结页核心数据保持一致。
    func sendRideCompletedNotification(for ride: RideRecord) {
        send(
            category: .rideCompleted,
            title: "🏁 骑行结束",
            body: "本次骑行：\(String(format: "%.1f km", ride.distanceKilometers))\n\(ride.duration.notificationRideDurationText)\n最高速度：\(String(format: "%.0f km/h", ride.maxSpeedKmh))",
            vehicleSN: ride.vehicleSN,
            destination: .vehicleStatus,
            dedupeInterval: 1
        )
    }

    /// 监听 BLE 电池与充电状态变化。安全异常由 `NinebotAlarmManager` 处理，
    /// 这里仅处理充电、低电量等非防盗类通知。
    func ingestVehicleTelemetry(_ telemetry: NinebotBLETelemetry, previous: NinebotBLETelemetry?) {
        if let previous {
            if !previous.isCharging && telemetry.isCharging {
                send(
                    category: .chargingStarted,
                    title: "⚡ 开始充电",
                    body: "车辆已开始充电\n当前电量：\(telemetry.batteryPercent)%",
                    vehicleSN: telemetry.vehicleSN,
                    destination: .charging,
                    dedupeInterval: 180
                )
            }
            if previous.isCharging && !telemetry.isCharging && telemetry.batteryPercent < 100 {
                send(
                    category: .chargingInterrupted,
                    title: "⚠️ 充电异常",
                    body: "充电已中断，请检查充电器连接。",
                    vehicleSN: telemetry.vehicleSN,
                    destination: .chargingDetail,
                    dedupeInterval: 120
                )
            }
            if previous.batteryPercent < 100 && telemetry.batteryPercent >= 100 {
                send(
                    category: .chargingFull,
                    title: "🔋 已充满",
                    body: "车辆已经充满电，可以拔掉充电器。",
                    vehicleSN: telemetry.vehicleSN,
                    destination: .vehicle,
                    dedupeInterval: 600
                )
            }
            if previous.batteryPercent > 20 && telemetry.batteryPercent <= 20 {
                send(
                    category: .lowBattery,
                    title: "🔋 电量不足",
                    body: "剩余 \(telemetry.batteryPercent)% ，建议尽快充电。",
                    vehicleSN: telemetry.vehicleSN,
                    dedupeInterval: 3_600
                )
            }
            if previous.batteryPercent > 10 && telemetry.batteryPercent <= 10 {
                send(
                    category: .criticalBattery,
                    title: "🔴 电量过低",
                    body: "剩余 \(telemetry.batteryPercent)% ，请立即寻找充电地点。",
                    vehicleSN: telemetry.vehicleSN,
                    dedupeInterval: 3_600,
                    requestsCriticalAlert: true
                )
            }
        }
    }

    /// 统一处理服务端 APNs payload。服务端可传入 title/body/category/destination；缺失时按安全事件兜底。
    func handleRemotePayload(_ userInfo: [AnyHashable: Any]) {
        let category = ((userInfo["category"] as? String) ?? (userInfo["event"] as? String))
            .flatMap(NinebotNotificationCategory.init(rawValue:)) ?? .vehicleAlarm
        let title = (userInfo["title"] as? String) ?? "🚨 车辆报警"
        let body = (userInfo["body"] as? String) ?? "检测到车辆异常，请立即查看。"
        send(
            category: category,
            title: title,
            body: body,
            vehicleSN: (userInfo["vehicle_sn"] as? String) ?? (userInfo["vehicleSN"] as? String),
            isSilent: false
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            NinebotNotificationRouter.shared.route(userInfo: response.notification.request.content.userInfo)
            if response.actionIdentifier == "NINEBOT_STOP_FIND" {
                NotificationCenter.default.post(name: .ninebotStopFindingVehicle, object: nil)
            }
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let ninebotStopFindingVehicle = Notification.Name("ninebot.stop.finding.vehicle")
}

private extension String {
    /// 文件系统/通知 identifier 可安全使用的稳定短键，不引入第三方哈希依赖。
    var sha256Key: String {
        var hash = UInt64(1469598103934665603)
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

private extension TimeInterval {
    /// 通知中使用简洁的本地化骑行时长文本。
    var notificationRideDurationText: String {
        let totalMinutes = max(Int((self / 60).rounded()), 0)
        if totalMinutes >= 60 { return "\(totalMinutes / 60) 小时 \(totalMinutes % 60) 分钟" }
        return "\(totalMinutes) 分钟"
    }
}
