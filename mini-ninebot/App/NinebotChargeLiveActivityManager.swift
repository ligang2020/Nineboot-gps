import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

/// Keeps the charging Live Activity in step with every archived vehicle snapshot.
///
/// iOS 17 uses the original ActivityAttributes type. iOS 18 uses a separate
/// type that enables the Apple Watch Smart Stack supplemental activity family.
/// Only the selected charging vehicle owns an activity at a time.
enum NinebotChargeLiveActivityManager {
    static func sync(with dashboard: NinebotDashboard) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        Task {
            await NinebotChargeActivityController.sync(with: dashboard)
        }
        #endif
    }
}

#if canImport(ActivityKit)
@available(iOS 16.1, *)
private enum NinebotChargeActivityController {
    static func sync(with dashboard: NinebotDashboard) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              let snapshot = dashboard.primaryVehicle,
              snapshot.state.isCharging == true,
              snapshot.state.isFullyCharged == false else {
            await endAll()
            return
        }

        if #available(iOS 18.0, *) {
            await syncWatchActivity(with: snapshot)
        } else {
            await syncLegacyActivity(with: snapshot)
        }
    }

    private static func contentState(
        for snapshot: NinebotVehicleSnapshot,
        startedAt: Date
    ) -> NinebotChargeActivityContentState {
        let state = snapshot.state
        return NinebotChargeActivityContentState(
            battery: state.battery,
            batteryVoltage: state.batteryVoltage,
            batteryTemperatureCelsius: state.batteryTemperature,
            estimatedFullChargeMinutes: state.estimatedFullChargeMinutes,
            chargingPowerWatts: state.chargingPower,
            chargingStartedAt: startedAt,
            updatedAt: state.updatedAt
        )
    }

    private static func syncLegacyActivity(with snapshot: NinebotVehicleSnapshot) async {
        let activities = Activity<NinebotChargeActivityAttributes>.activities
        let matchingActivity = activities.first { $0.attributes.vehicleSN == snapshot.vehicle.sn }
        let startedAt = matchingActivity?.attributes.startedAt ?? Date()
        let attributes = NinebotChargeActivityAttributes(
            vehicleSN: snapshot.vehicle.sn,
            vehicleName: snapshot.vehicle.displayName,
            vehicleModel: snapshot.vehicle.model,
            startedAt: startedAt
        )
        let content = ActivityContent(
            state: contentState(for: snapshot, startedAt: startedAt),
            staleDate: Date().addingTimeInterval(35)
        )

        for activity in activities where activity.id != matchingActivity?.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        if let matchingActivity {
            await matchingActivity.update(content)
        } else {
            do {
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } catch {
                logStartFailure(error)
            }
        }
    }

    @available(iOS 18.0, *)
    private static func syncWatchActivity(with snapshot: NinebotVehicleSnapshot) async {
        // Remove a legacy activity after an OS upgrade so Dynamic Island does
        // not show two stale sessions for the same vehicle.
        await endLegacyActivities()

        let activities = Activity<NinebotWatchChargeActivityAttributes>.activities
        let matchingActivity = activities.first { $0.attributes.vehicleSN == snapshot.vehicle.sn }
        let startedAt = matchingActivity?.attributes.startedAt ?? Date()
        let attributes = NinebotWatchChargeActivityAttributes(
            vehicleSN: snapshot.vehicle.sn,
            vehicleName: snapshot.vehicle.displayName,
            vehicleModel: snapshot.vehicle.model,
            startedAt: startedAt
        )
        let content = ActivityContent(
            state: contentState(for: snapshot, startedAt: startedAt),
            staleDate: Date().addingTimeInterval(35)
        )

        for activity in activities where activity.id != matchingActivity?.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        if let matchingActivity {
            await matchingActivity.update(content)
        } else {
            do {
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } catch {
                logStartFailure(error)
            }
        }
    }

    private static func endAll() async {
        await endLegacyActivities()
        if #available(iOS 18.0, *) {
            await endWatchActivities()
        }
    }

    private static func endLegacyActivities() async {
        for activity in Activity<NinebotChargeActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    @available(iOS 18.0, *)
    private static func endWatchActivities() async {
        for activity in Activity<NinebotWatchChargeActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func logStartFailure(_ error: Error) {
        #if DEBUG
        print("Failed to start NineBot charging Live Activity: \(error)")
        #endif
    }
}
#endif
