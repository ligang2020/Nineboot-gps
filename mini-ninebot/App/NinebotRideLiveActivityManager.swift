import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

/// Owns the single active riding Live Activity. Content is refreshed whenever
/// the app receives a fresh vehicle snapshot; the elapsed clock is rendered by
/// the system from the persisted session start time and therefore keeps moving
/// while the app is backgrounded or relaunched.
enum NinebotRideLiveActivityManager {
    static func sync(
        session: NinebotActiveRideSession?,
        snapshot: NinebotVehicleSnapshot?
    ) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        Task {
            await NinebotRideActivityController.sync(session: session, snapshot: snapshot)
        }
        #endif
    }
}

#if canImport(ActivityKit)
@available(iOS 16.1, *)
private enum NinebotRideActivityController {
    static func sync(
        session: NinebotActiveRideSession?,
        snapshot: NinebotVehicleSnapshot?
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              let session,
              let snapshot,
              snapshot.vehicle.sn == session.vehicleSN else {
            await endAll()
            return
        }

        let activities = Activity<NinebotRideActivityAttributes>.activities
        let matchingActivity = activities.first { $0.attributes.vehicleSN == session.vehicleSN }
        let attributes = NinebotRideActivityAttributes(
            vehicleSN: session.vehicleSN,
            vehicleName: session.vehicleName,
            vehicleModel: session.vehicleModel,
            startedAt: session.startedAt
        )
        let content = ActivityContent(
            state: NinebotRideActivityContentState(
                battery: snapshot.state.battery,
                speedKmh: session.latestSpeedKmh,
                distanceMeters: session.distanceMeters,
                remainingRangeKm: snapshot.state.endurance ?? snapshot.state.aiEstimatedMileage,
                batteryTemperature: snapshot.state.batteryTemperature,
                tripEnergyWh: tripEnergyWh(state: snapshot.state, distanceMeters: session.distanceMeters),
                updatedAt: session.updatedAt
            ),
            staleDate: Date().addingTimeInterval(15)
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
                #if DEBUG
                print("Failed to start NineBot ride Live Activity: \(error)")
                #endif
            }
        }
    }

    private static func tripEnergyWh(state: NinebotVehicleState, distanceMeters: Double?) -> Double? {
        guard let distanceMeters, distanceMeters.isFinite, distanceMeters > 0 else { return nil }
        let distanceKm = distanceMeters / 1_000
        let energyPerKm = state.lastEnergyPerKm ?? state.monthEnergyPerKm
        guard let energyPerKm, energyPerKm.isFinite, energyPerKm > 0 else { return nil }
        return distanceKm * energyPerKm
    }

    private static func endAll() async {
        for activity in Activity<NinebotRideActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
