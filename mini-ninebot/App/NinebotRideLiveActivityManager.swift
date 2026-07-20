import Foundation

#if canImport(ActivityKit)
import ActivityKit
#endif

/// Keeps the Live Activity in step with every archived vehicle snapshot.
///
/// A vehicle starts an activity only after it is confirmed unlocked. The activity
/// is immediately dismissed when the vehicle is locked, unavailable, or not the
/// selected vehicle. The foreground app supplies a lightweight five-second data
/// pulse; true background live updates are delivered by ActivityKit push updates
/// when the backend is configured for them.
enum NinebotRideLiveActivityManager {
    static func sync(with dashboard: NinebotDashboard) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        Task {
            await NinebotRideActivityController.sync(with: dashboard)
        }
        #endif
    }
}

#if canImport(ActivityKit)
@available(iOS 16.1, *)
private enum NinebotRideActivityController {
    static func sync(with dashboard: NinebotDashboard) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              let snapshot = dashboard.primaryVehicle,
              snapshot.state.isLocked == false else {
            await endAll()
            return
        }

        let state = snapshot.state
        let activities = Activity<NinebotRideActivityAttributes>.activities
        let matchingActivity = activities.first { $0.attributes.vehicleSN == snapshot.vehicle.sn }
        let startedTotalMileage = matchingActivity?.attributes.startedTotalMileage ?? state.totalMileage
        let startedAt = matchingActivity?.attributes.startedAt ?? Date()
        let attributes = NinebotRideActivityAttributes(
            vehicleSN: snapshot.vehicle.sn,
            vehicleName: snapshot.vehicle.displayName,
            vehicleModel: snapshot.vehicle.model,
            startedTotalMileage: startedTotalMileage,
            startedAt: startedAt
        )
        let contentState = NinebotRideActivityAttributes.ContentState(
            battery: state.battery,
            batteryTemperatureCelsius: state.batteryTemperature,
            estimatedRange: state.localEstimatedMileage ?? state.endurance ?? state.aiEstimatedMileage,
            speedKmh: currentSpeed(from: state),
            usedElectricityWh: latestUsedElectricity(from: state),
            energyPerKmWh: latestEnergyPerKm(from: state),
            rideDistanceKm: rideDistance(from: state, startedTotalMileage: startedTotalMileage),
            rideStartedAt: startedAt,
            rideDurationSeconds: max(Date().timeIntervalSince(startedAt), 0),
            rideProgressTargetKm: progressTarget(for: rideDistance(from: state, startedTotalMileage: startedTotalMileage)),
            latitude: state.latitude,
            longitude: state.longitude,
            locationName: state.locationDescription,
            isPoweredOn: state.isPoweredOn,
            updatedAt: state.updatedAt
        )
        let content = ActivityContent(
            state: contentState,
            staleDate: Date().addingTimeInterval(35)
        )

        // One vehicle owns the Island at a time. Switching the selected vehicle
        // cleanly hands the activity to the newly selected, unlocked vehicle.
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

    private static func endAll() async {
        for activity in Activity<NinebotRideActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func currentSpeed(from state: NinebotVehicleState) -> Double? {
        let rawKeys = ["current_speed", "currentSpeed", "speed", "speed_kmh", "speedKmh", "real_time_speed", "realTimeSpeed", "velocity"]
        for payload in [state.rawStatus, state.rawTravel, state.rawBattery] {
            guard let payload else { continue }
            for key in rawKeys {
                if let value = payload[key]?.doubleValue, value >= 0, value <= 160 {
                    return value
                }
            }
        }
        return state.rideRecords?
            .sorted { ($0.endedAt ?? $0.startedAt ?? .distantPast) > ($1.endedAt ?? $1.startedAt ?? .distantPast) }
            .compactMap(\.speed)
            .first
    }

    private static func latestUsedElectricity(from state: NinebotVehicleState) -> Double? {
        if let value = state.lastRideEnergyWh { return value }
        return state.rideRecords?
            .sorted { ($0.endedAt ?? $0.startedAt ?? .distantPast) > ($1.endedAt ?? $1.startedAt ?? .distantPast) }
            .compactMap(\.consumedEnergyWh)
            .first
    }

    private static func latestEnergyPerKm(from state: NinebotVehicleState) -> Double? {
        if let value = state.lastEnergyPerKm ?? state.monthEnergyPerKm, value >= 0 { return value }
        return state.rideRecords?
            .sorted(by: { ($0.endedAt ?? $0.startedAt ?? .distantPast) > ($1.endedAt ?? $1.startedAt ?? .distantPast) })
            .compactMap(\.energyPerKmWh)
            .first
    }

    private static func rideDistance(from state: NinebotVehicleState, startedTotalMileage: Double?) -> Double? {
        if let startedTotalMileage, let currentTotalMileage = state.totalMileage {
            let distance = currentTotalMileage - startedTotalMileage
            if distance >= 0, distance < 500 { return distance }
        }
        if let lastMileage = state.lastMileage, lastMileage >= 0, lastMileage < 500 {
            return lastMileage
        }
        return nil
    }

    private static func progressTarget(for distance: Double?) -> Double {
        let milestones: [Double] = [1, 3, 5, 10, 20, 50]
        let value = max(distance ?? 0, 0)
        if let milestone = milestones.first(where: { value <= $0 }) {
            return milestone
        }
        // Long rides keep a meaningful visual scale instead of staying pinned
        // to a completed 50 km bar.
        return max(75, ceil(value / 25) * 25)
    }
}
#endif
