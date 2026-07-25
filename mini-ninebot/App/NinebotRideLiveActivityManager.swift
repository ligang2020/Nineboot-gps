import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

/// 骑行 Live Activity 的唯一入口。
///
/// BLE 可以每秒向 ViewModel 推送数据；管理器会在保留实时感的前提下合并重复 UI 状态：
/// - 系统计时由 WidgetKit 负责，不发送“仅时间变化”的更新；
/// - 最大频率为每秒一次，并且只在可见值真正变化时提交；
/// - 电量、模式、连接状态等关键变化立即优先提交。
///
/// 这符合 Live Activities 的资源预算模型：`NSSupportsLiveActivitiesFrequentUpdates`
/// 允许较高频更新，但并不保证系统一定展示每一个中间帧。
enum NinebotRideLiveActivityManager {
    static func sync(
        session: NinebotActiveRideSession?,
        snapshot: NinebotVehicleSnapshot?
    ) {
        #if canImport(ActivityKit)
        guard #available(iOS 18.0, *) else { return }
        Task {
            await NinebotRideLiveActivityController.shared.sync(session: session, snapshot: snapshot)
        }
        #endif
    }

    /// 骑行手动或自动结束时立即收起对应车辆的 Live Activity。
    static func end(vehicleSN: String?) {
        #if canImport(ActivityKit)
        guard #available(iOS 18.0, *), let vehicleSN else { return }
        Task {
            await NinebotRideLiveActivityController.shared.end(vehicleSN: vehicleSN)
        }
        #endif
    }

    /// 给 BLE 接入层使用的高保真入口。每收到一帧（通常每秒一次）即可调用。
    static func sync(
        session: NinebotActiveRideSession?,
        telemetry: NinebotBLETelemetry
    ) {
        #if canImport(ActivityKit)
        guard #available(iOS 18.0, *) else { return }
        Task {
            await NinebotRideLiveActivityController.shared.sync(session: session, telemetry: telemetry)
        }
        #endif
    }
}

#if canImport(ActivityKit)
@available(iOS 18.0, *)
private actor NinebotRideLiveActivityController {
    static let shared = NinebotRideLiveActivityController()

    /// 每秒一帧 BLE 数据已足够实时；不要把计时器本身变成更新源。
    private let minimumUpdateInterval: TimeInterval = 1
    private var lastSubmittedState: NinebotRideActivityContentState?
    private var lastSubmissionDate: Date = .distantPast

    func sync(
        session: NinebotActiveRideSession?,
        snapshot: NinebotVehicleSnapshot?
    ) async {
        guard let session, let snapshot else {
            await endAll()
            return
        }

        let state = makeContentState(session: session, snapshot: snapshot)
        await startOrUpdate(session: session, state: state)
    }

    func sync(
        session: NinebotActiveRideSession?,
        telemetry: NinebotBLETelemetry
    ) async {
        guard let session, telemetry.isRiding, !telemetry.isCharging else {
            await endAll()
            return
        }

        let state = NinebotRideActivityContentState(
            vehicleLocationText: vehicleLocationText(from: telemetry.security.location),
            batteryPercent: telemetry.batteryPercent,
            remainingRangeKm: telemetry.remainingRangeKm,
            todayDistanceKm: telemetry.todayDistanceKm,
            totalDistanceKm: telemetry.totalDistanceKm,
            rideDistanceKm: telemetry.rideDistanceKm,
            mode: telemetry.mode,
            isBluetoothConnected: telemetry.isBluetoothConnected,
            isGPSAvailable: telemetry.isGPSAvailable,
            isLocked: telemetry.isLocked,
            isCharging: telemetry.isCharging,
            updatedAt: telemetry.receivedAt
        )
        await startOrUpdate(session: session, state: state)
    }

    func end(vehicleSN: String) async {
        for activity in Activity<NinebotRideActivityAttributes>.activities where activity.attributes.vehicleSN == vehicleSN {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        lastSubmittedState = nil
        lastSubmissionDate = .distantPast
    }

    private func startOrUpdate(
        session: NinebotActiveRideSession,
        state: NinebotRideActivityContentState
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // 每辆车最多保留一条骑行实况；切车时先结束旧 Activity，避免 Dynamic Island 信息混淆。
        let matchingActivity = Activity<NinebotRideActivityAttributes>.activities.first {
            $0.attributes.vehicleSN == session.vehicleSN
        }
        for activity in Activity<NinebotRideActivityAttributes>.activities where activity.id != matchingActivity?.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        let content = ActivityContent(
            state: state,
            staleDate: state.updatedAt.addingTimeInterval(90)
        )

        if let matchingActivity {
            guard shouldSubmit(state) else { return }
            await matchingActivity.update(content)
        } else {
            let attributes = NinebotRideActivityAttributes(
                vehicleSN: session.vehicleSN,
                vehicleName: session.vehicleName,
                vehicleModel: session.vehicleModel,
                startedAt: session.startedAt
            )
            do {
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } catch {
                // 用户可能在“设置 > Face ID 与密码 > 实时活动”中关闭授权。
                // 不影响骑行主流程，下一帧 BLE 数据会自动重试。
            }
        }

        lastSubmittedState = state
        lastSubmissionDate = .now
    }

    private func shouldSubmit(_ next: NinebotRideActivityContentState) -> Bool {
        guard let previous = lastSubmittedState else { return true }
        guard Date.now.timeIntervalSince(lastSubmissionDate) >= minimumUpdateInterval else {
            return hasCriticalChange(from: previous, to: next)
        }
        return hasVisibleChange(from: previous, to: next)
    }

    private func hasCriticalChange(
        from previous: NinebotRideActivityContentState,
        to next: NinebotRideActivityContentState
    ) -> Bool {
        previous.batteryPercent != next.batteryPercent
            || previous.mode != next.mode
            || previous.isBluetoothConnected != next.isBluetoothConnected
            || previous.isGPSAvailable != next.isGPSAvailable
            || previous.isLocked != next.isLocked
    }

    private func hasVisibleChange(
        from previous: NinebotRideActivityContentState,
        to next: NinebotRideActivityContentState
    ) -> Bool {
        previous.vehicleLocationText != next.vehicleLocationText
            || previous.batteryPercent != next.batteryPercent
            || Int(previous.remainingRangeKm.rounded()) != Int(next.remainingRangeKm.rounded())
            || abs(previous.todayDistanceKm - next.todayDistanceKm) >= 0.01
            || abs(previous.rideDistanceKm - next.rideDistanceKm) >= 0.01
            || abs(previous.totalDistanceKm - next.totalDistanceKm) >= 0.1
            || hasCriticalChange(from: previous, to: next)
    }

    private func endAll() async {
        for activity in Activity<NinebotRideActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        lastSubmittedState = nil
        lastSubmissionDate = .distantPast
    }

    private func makeContentState(
        session: NinebotActiveRideSession,
        snapshot: NinebotVehicleSnapshot
    ) -> NinebotRideActivityContentState {
        let state = snapshot.state
        return NinebotRideActivityContentState(
            vehicleLocationText: vehicleLocationText(from: state),
            batteryPercent: state.battery ?? 0,
            remainingRangeKm: state.endurance ?? state.aiEstimatedMileage ?? 0,
            todayDistanceKm: todayDistanceKm(from: state),
            totalDistanceKm: state.totalMileage ?? 0,
            rideDistanceKm: (session.distanceMeters ?? 0) / 1_000,
            mode: rideMode(from: state),
            // 旧的网络数据源没有 BLE 字段时不伪造已连接状态；BLE 接入后会走 telemetry 入口。
            isBluetoothConnected: booleanValue(in: state.rawStatus, keys: ["bleConnected", "bluetoothConnected", "isBluetoothConnected"]) ?? false,
            isGPSAvailable: booleanValue(in: state.rawStatus, keys: ["gpsAvailable", "gpsEnabled", "isGPSAvailable"]) ?? (state.latitude != nil && state.longitude != nil),
            isLocked: state.isLocked ?? false,
            isCharging: state.isCharging ?? false,
            updatedAt: state.updatedAt
        )
    }

    private func liveSpeedKmh(from state: NinebotVehicleState) -> Double? {
        for key in ["speed", "currentSpeed", "current_speed", "speedKmh", "speed_kmh", "velocity"] {
            if let value = state.rawStatus?[key]?.doubleValue, value.isFinite, (0...180).contains(value) {
                return value
            }
        }
        return nil
    }

    private func vehicleLocationText(from state: NinebotVehicleState) -> String {
        let description = state.locationDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !description.isEmpty { return description }
        guard let latitude = state.latitude,
              let longitude = state.longitude,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            return "正在获取车辆定位"
        }
        return String(format: "%.4f, %.4f", latitude, longitude)
    }

    private func vehicleLocationText(from location: NinebotVehicleLocation?) -> String {
        guard let location, location.isValid else { return "正在获取车辆定位" }
        return String(format: "%.4f, %.4f", location.latitude, location.longitude)
    }

    private func todayDistanceKm(from state: NinebotVehicleState) -> Double {
        for key in ["todayMileage", "todayDistance", "dailyMileage", "dayMileage"] {
            if let value = state.rawTravel?[key]?.doubleValue ?? state.rawStatus?[key]?.doubleValue,
               value.isFinite, value >= 0 {
                return value
            }
        }
        // 数据源未提供日里程时保守显示本月累计，避免错误计算；BLE 接入会提供准确值。
        return max(state.monthMileage ?? 0, 0)
    }

    private func rideMode(from state: NinebotVehicleState) -> NinebotRideMode {
        let raw = ["rideMode", "driveMode", "mode", "gear"]
            .compactMap { state.rawStatus?[$0]?.stringValue }
            .first?
            .lowercased() ?? ""
        if raw.contains("sport") || raw == "3" { return .sport }
        if raw.contains("eco") || raw == "1" { return .eco }
        return .drive
    }

    private func booleanValue(in values: [String: JSONValue]?, keys: [String]) -> Bool? {
        for key in keys {
            if let value = values?[key]?.boolValue { return value }
        }
        return nil
    }
}
#endif
