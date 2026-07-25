import Foundation
import Combine

/// 当前告警，既是 SwiftUI 状态源，也是防盗 Live Activity 的内容来源。
struct NinebotActiveAlarm: Hashable, Sendable {
    var vehicleSN: String
    var vehicleName: String
    var type: NinebotSecurityEventType
    var startedAt: Date
    var updatedAt: Date
    var location: NinebotVehicleLocation?
    var isSOS: Bool
}

/// 防盗控制台：监听标准化 BLE 状态、生成安全事件，并驱动通知、围栏、实时活动和 UI。
/// 车辆私有 BLE 协议只需映射到 `NinebotBLETelemetry.security`，无需进入本业务层。
@MainActor
final class NinebotAlarmManager: ObservableObject {
    static let shared = NinebotAlarmManager()

    @Published private(set) var activeAlarm: NinebotActiveAlarm?
    @Published private(set) var latestSecurityByVehicle: [String: NinebotVehicleSecurityTelemetry] = [:]
    @Published private(set) var latestTelemetryByVehicle: [String: NinebotBLETelemetry] = [:]
    @Published private(set) var lastEventByVehicle: [String: NinebotSecurityEventType] = [:]

    private var previousTelemetry: [String: NinebotBLETelemetry] = [:]
    private var sosTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    /// BLE 每秒状态入口。仅安全字段发生变化或锁车移动时触发告警，不会对同一异常重复发通知。
    func ingest(_ telemetry: NinebotBLETelemetry, vehicleName: String) {
        let vehicleSN = telemetry.vehicleSN
        let previous = previousTelemetry[vehicleSN]
        latestSecurityByVehicle[vehicleSN] = telemetry.security
        latestTelemetryByVehicle[vehicleSN] = telemetry

        if let location = telemetry.security.location {
            NinebotVehicleLocationManager.shared.ingest(location, vehicleSN: vehicleSN, isRiding: telemetry.isRiding)
            NinebotGeofenceManager.shared.ingestVehicleLocation(location, vehicleSN: vehicleSN, vehicleName: vehicleName)
        }

        let candidates = securityEvents(for: telemetry, previous: previous)
        for event in candidates {
            trigger(
                type: event,
                vehicleSN: vehicleSN,
                vehicleName: vehicleName,
                location: telemetry.security.location
            )
        }
        previousTelemetry[vehicleSN] = telemetry
    }

    func clearAlarm(vehicleSN: String) {
        guard activeAlarm?.vehicleSN == vehicleSN else { return }
        activeAlarm = nil
        sosTasks[vehicleSN]?.cancel()
        sosTasks.removeValue(forKey: vehicleSN)
        NinebotAntiTheftLiveActivityManager.end(vehicleSN: vehicleSN)
    }

    /// 允许用户在完成现场确认后手动清除告警。不能改变车辆锁状态。
    func acknowledgeAlarm(vehicleSN: String) {
        clearAlarm(vehicleSN: vehicleSN)
    }

    private func securityEvents(
        for telemetry: NinebotBLETelemetry,
        previous: NinebotBLETelemetry?
    ) -> [NinebotSecurityEventType] {
        var events: [NinebotSecurityEventType] = []
        let security = telemetry.security

        if let hardwareAlarm = security.activeAlarm { events.append(hardwareAlarm) }
        // 锁车且速度大于 2 km/h 是独立的强规则，不等待车辆端报警位。
        if telemetry.isLocked && telemetry.speedKmh > 2 { events.append(.illegalMovement) }
        if telemetry.isLocked && security.isVehicleMoving { events.append(.unauthorizedPush) }
        if security.isBatteryRemoved { events.append(.batteryRemoved) }

        if let previous {
            if previous.security.isPowerConnected && !security.isPowerConnected { events.append(.powerDisconnected) }
            if previous.security.isControllerPowered && !security.isControllerPowered { events.append(.controllerPowerLoss) }
            if previous.isGPSAvailable && !telemetry.isGPSAvailable { events.append(.gpsOffline) }
            if previous.isBluetoothConnected && !telemetry.isBluetoothConnected { events.append(.bluetoothDisconnected) }
            if previous.isLocked && !telemetry.isLocked && !telemetry.isRiding { events.append(.unauthorizedUnlock) }
            if !previous.isRiding && telemetry.isRiding && telemetry.isLocked { events.append(.unauthorizedStart) }
        }
        return Array(Set(events))
    }

    private func trigger(
        type: NinebotSecurityEventType,
        vehicleSN: String,
        vehicleName: String,
        location: NinebotVehicleLocation?
    ) {
        let now = Date()
        if let activeAlarm, activeAlarm.vehicleSN == vehicleSN, activeAlarm.type == type {
            // 同类告警只更新时间/定位；NotificationManager 另有冷却去重。
            self.activeAlarm?.updatedAt = now
            self.activeAlarm?.location = location ?? activeAlarm.location
            NinebotAntiTheftLiveActivityManager.update(alarm: self.activeAlarm!)
            return
        }

        let alarm = NinebotActiveAlarm(
            vehicleSN: vehicleSN,
            vehicleName: vehicleName,
            type: type,
            startedAt: now,
            updatedAt: now,
            location: location,
            isSOS: false
        )
        activeAlarm = alarm
        lastEventByVehicle[vehicleSN] = type
        NinebotAntiTheftLiveActivityManager.update(alarm: alarm)
        sendNotification(for: alarm)
        startSOSTimer(for: alarm)
    }

    private func startSOSTimer(for alarm: NinebotActiveAlarm) {
        sosTasks[alarm.vehicleSN]?.cancel()
        sosTasks[alarm.vehicleSN] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard let self,
                  let current = self.activeAlarm,
                  current.vehicleSN == alarm.vehicleSN,
                  current.startedAt == alarm.startedAt else { return }
            self.activateSOS(from: current)
        }
    }

    private func activateSOS(from alarm: NinebotActiveAlarm) {
        var sosAlarm = alarm
        sosAlarm.isSOS = true
        sosAlarm.updatedAt = .now
        activeAlarm = sosAlarm
        lastEventByVehicle[alarm.vehicleSN] = .sos
        NinebotAntiTheftLiveActivityManager.update(alarm: sosAlarm)
        NinebotNotificationManager.shared.send(
            category: .sos,
            title: NinebotSecurityEventType.sos.notificationTitle,
            body: NinebotSecurityEventType.sos.notificationBody,
            vehicleSN: sosAlarm.vehicleSN,
            destination: .location,
            dedupeInterval: 120,
            requestsCriticalAlert: true
        )
        // 预留服务端 SOS 上传接口：接入后将 `sosAlarm` 编码后调用你的 API。
        // Task { try? await securityAPI.uploadSOS(sosAlarm) }
    }

    private func sendNotification(for alarm: NinebotActiveAlarm) {
        let category: NinebotNotificationCategory
        switch alarm.type {
        case .illegalMovement: category = .illegalMovement
        case .unauthorizedPush: category = .vehiclePushed
        case .powerDisconnected, .controllerPowerLoss: category = .powerDisconnected
        case .batteryRemoved: category = .batteryRemoved
        case .bluetoothDisconnected: category = .bluetoothDisconnected
        case .gpsOffline: category = .gpsOffline
        case .sos: category = .sos
        default: category = .vehicleAlarm
        }
        NinebotNotificationManager.shared.send(
            category: category,
            title: alarm.type.notificationTitle,
            body: alarm.type.notificationBody,
            vehicleSN: alarm.vehicleSN,
            destination: category.destination,
            dedupeInterval: alarm.type == .illegalMovement ? 20 : 45,
            requestsCriticalAlert: alarm.type == .batteryRemoved || alarm.type == .powerDisconnected
        )
    }
}

/// 车辆指令协议。BLE 适配器可实现该协议来发送闪灯、鸣笛与停止指令。
protocol NinebotAntiTheftCommandSending: AnyObject {
    func sendFindVehicleCommand(vehicleSN: String, duration: TimeInterval) async throws
    func sendStopFindingVehicleCommand(vehicleSN: String) async throws
}

/// 查找车辆：控制器负责 30 秒闪灯+鸣笛，App 仅发起/停止命令并维护 UI 状态。
@MainActor
final class NinebotFindVehicleManager: ObservableObject {
    static let shared = NinebotFindVehicleManager()

    @Published private(set) var findingVehicleSN: String?
    @Published private(set) var findingUntil: Date?
    @Published private(set) var lastStatusMessage: String?
    @Published private(set) var lastErrorMessage: String?
    weak var commandSender: NinebotAntiTheftCommandSending?
    private var automaticStopTask: Task<Void, Never>?

    func start(vehicleSN: String) async {
        guard findingVehicleSN == nil else { return }
        lastStatusMessage = nil
        lastErrorMessage = nil
        do {
            // BLE 控制器可用时优先使用车端 30 秒闪灯/鸣笛命令；否则一定要走
            // 已登录代理的铃铛接口，不能因可选调用静默成功而让按钮毫无反应。
            if let commandSender {
                try await commandSender.sendFindVehicleCommand(vehicleSN: vehicleSN, duration: 30)
            } else if let configuration = NinebotSharedStore().loadConfiguration(), configuration.isUsable {
                _ = try await NinebotProxyClient(configuration: configuration).ringBell(sn: vehicleSN)
            } else {
                throw NinebotInputError.missingProxy
            }
            findingVehicleSN = vehicleSN
            findingUntil = Date().addingTimeInterval(30)
            lastStatusMessage = "寻车指令已发送，车辆将闪灯并鸣笛 30 秒。"
        } catch {
            findingVehicleSN = nil
            findingUntil = nil
            lastErrorMessage = "寻找车辆失败：\(error.localizedDescription)"
            return
        }
        automaticStopTask?.cancel()
        automaticStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            await self?.stop()
        }
    }

    func stop() async {
        guard let vehicleSN = findingVehicleSN else { return }
        automaticStopTask?.cancel()
        automaticStopTask = nil
        try? await commandSender?.sendStopFindingVehicleCommand(vehicleSN: vehicleSN)
        findingVehicleSN = nil
        findingUntil = nil
    }
}

/// 用于 Xcode Preview、演示和 BLE 接入测试的防盗 Mock 帧。
enum NinebotAntiTheftMockData {
    static let alarmTelemetry = NinebotBLETelemetry(
        vehicleSN: "NPLIVE-2026",
        speedKmh: 4.6,
        batteryPercent: 68,
        remainingRangeKm: 31,
        todayDistanceKm: 12.6,
        totalDistanceKm: 1_248.3,
        rideDistanceKm: 0,
        mode: .drive,
        isBluetoothConnected: true,
        isGPSAvailable: true,
        isLocked: true,
        isCharging: false,
        isRiding: false,
        security: NinebotVehicleSecurityTelemetry(
            activeAlarm: .illegalMovement,
            isVehicleMoving: true,
            location: NinebotVehicleLocation(latitude: 31.2304, longitude: 121.4737, heading: 80, horizontalAccuracy: 10)
        )
    )
}
