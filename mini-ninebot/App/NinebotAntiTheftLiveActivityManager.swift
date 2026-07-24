import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// 防盗实况的唯一入口。告警状态只在首次触发、事件变化、位置变化或 SOS 升级时更新，
/// 避免把 BLE 的每秒心跳直接映射为 ActivityKit 高频刷新。
enum NinebotAntiTheftLiveActivityManager {
    static func update(alarm: NinebotActiveAlarm) {
        Task {
            await NinebotAntiTheftActivityController.shared.update(alarm: alarm)
        }
    }

    static func end(vehicleSN: String) {
        Task {
            await NinebotAntiTheftActivityController.shared.end(vehicleSN: vehicleSN)
        }
    }
}

@available(iOS 18.0, *)
private actor NinebotAntiTheftActivityController {
    static let shared = NinebotAntiTheftActivityController()
    private var lastStateByVehicle: [String: NinebotAntiTheftActivityAttributes.ContentState] = [:]

    func update(alarm: NinebotActiveAlarm) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = NinebotAntiTheftActivityAttributes.ContentState(
            alarmType: alarm.type,
            location: alarm.location,
            isSOS: alarm.isSOS,
            updatedAt: alarm.updatedAt
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
        let activities = Activity<NinebotAntiTheftActivityAttributes>.activities.filter {
            $0.attributes.vehicleSN == alarm.vehicleSN
        }

        if activities.isEmpty {
            let attributes = NinebotAntiTheftActivityAttributes(
                vehicleSN: alarm.vehicleSN,
                vehicleName: alarm.vehicleName,
                startedAt: alarm.startedAt
            )
            do {
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
                lastStateByVehicle[alarm.vehicleSN] = state
            } catch {
                // ActivityKit 在系统限制、用户关闭实时活动时可能拒绝请求；主业务不能受影响。
            }
            return
        }

        guard shouldUpdate(previous: lastStateByVehicle[alarm.vehicleSN], next: state) else { return }
        for activity in activities {
            await activity.update(content)
        }
        lastStateByVehicle[alarm.vehicleSN] = state
    }

    func end(vehicleSN: String) async {
        let activities = Activity<NinebotAntiTheftActivityAttributes>.activities.filter {
            $0.attributes.vehicleSN == vehicleSN
        }
        for activity in activities {
            await activity.end(nil, dismissalPolicy: .default)
        }
        lastStateByVehicle.removeValue(forKey: vehicleSN)
    }

    private func shouldUpdate(
        previous: NinebotAntiTheftActivityAttributes.ContentState?,
        next: NinebotAntiTheftActivityAttributes.ContentState
    ) -> Bool {
        guard let previous else { return true }
        if previous.alarmType != next.alarmType || previous.isSOS != next.isSOS { return true }
        guard let old = previous.location, let new = next.location else {
            return (previous.location == nil) != (next.location == nil)
        }
        // 位置变化超过约 15 米才刷新动态岛，防止 GPS 抖动消耗刷新配额。
        return haversineMeters(old, new) >= 15
    }

    private func haversineMeters(_ lhs: NinebotVehicleLocation, _ rhs: NinebotVehicleLocation) -> Double {
        let radius = 6_371_000.0
        let dLat = (rhs.latitude - lhs.latitude) * .pi / 180
        let dLon = (rhs.longitude - lhs.longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lhs.latitude * .pi / 180) * cos(rhs.latitude * .pi / 180)
            * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
#else
enum NinebotAntiTheftLiveActivityManager {
    static func update(alarm: NinebotActiveAlarm) {}
    static func end(vehicleSN: String) {}
}
#endif
