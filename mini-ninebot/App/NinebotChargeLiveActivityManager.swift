import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

/// Keeps the charging Live Activity in step with every archived vehicle snapshot.
///
/// An activity is created only when the selected vehicle reports that it is
/// charging. It is dismissed as soon as charging stops, the battery is full,
/// the vehicle is unavailable, or another vehicle becomes selected.
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

        let state = snapshot.state
        let activities = Activity<NinebotChargeActivityAttributes>.activities
        let matchingActivity = activities.first { $0.attributes.vehicleSN == snapshot.vehicle.sn }
        let startedAt = matchingActivity?.attributes.startedAt ?? Date()
        let attributes = NinebotChargeActivityAttributes(
            vehicleSN: snapshot.vehicle.sn,
            vehicleName: snapshot.vehicle.displayName,
            vehicleModel: snapshot.vehicle.model,
            startedAt: startedAt
        )
        let contentState = NinebotChargeActivityAttributes.ContentState(
            battery: state.battery,
            batteryVoltage: state.batteryVoltage,
            batteryTemperatureCelsius: state.batteryTemperature,
            estimatedFullChargeMinutes: state.estimatedFullChargeMinutes,
            chargingPowerWatts: state.chargingPower,
            chargingStartedAt: startedAt,
            updatedAt: state.updatedAt
        )
        let content = ActivityContent(
            state: contentState,
            staleDate: Date().addingTimeInterval(35)
        )

        // The selected vehicle exclusively owns the Dynamic Island / Live
        // Activity so switching vehicles cannot leave stale charging cards.
        for activity in activities where activity.id != matchingActivity?.id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        if let matchingActivity {
            await matchingActivity.update(content)
        } else {
            do {
                _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            } catch {
                #if DEBUG
                print("Failed to start NineBot charging Live Activity: \(error)")
                #endif
            }
        }
    }

    private static func endAll() async {
        for activity in Activity<NinebotChargeActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
