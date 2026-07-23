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
        // The riding Lock Screen Live Activity has been removed from the app.
        // End any previously-started riding activities and never create a new one.
        await endAll()
    }

    private static func endAll() async {
        for activity in Activity<NinebotRideActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

#endif
