import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// The charge measurements displayed by both the iPhone and Apple Watch Live
/// Activities. Keeping the state independent of the ActivityAttributes type
/// lets iOS 17 and iOS 18 use their own activity registrations safely.
struct NinebotChargeActivityContentState: Codable, Hashable {
    /// Charge percentage, used directly as the 0–100% progress-bar value.
    var battery: Int?
    var batteryVoltage: Double?
    var batteryTemperatureCelsius: Double?
    /// Remaining minutes until full charge. Prefer the vehicle API estimate
    /// and fall back to the app's charge-curve estimate when unavailable.
    var estimatedFullChargeMinutes: Double?
    var chargingPowerWatts: Double?
    var chargingStartedAt: Date
    var updatedAt: Date
}

/// The common vehicle identity used by the Live Activity presentation.
protocol NinebotChargeActivityVehicleAttributes {
    var vehicleSN: String { get }
    var vehicleName: String { get }
    var vehicleModel: String { get }
    var startedAt: Date { get }
}

/// Live Activity data for the selected vehicle while it is actively charging
/// on iOS 16.1 through iOS 17.
@available(iOS 16.1, *)
struct NinebotChargeActivityAttributes: ActivityAttributes, NinebotChargeActivityVehicleAttributes {
    var vehicleSN: String
    var vehicleName: String
    var vehicleModel: String
    /// Stable start point for the charging session. It survives content updates.
    var startedAt: Date

    typealias ContentState = NinebotChargeActivityContentState
}

/// iOS 18 uses a distinct activity type so its Apple Watch Smart Stack
/// configuration can coexist with the iOS 17-compatible Live Activity.
@available(iOS 18.0, *)
struct NinebotWatchChargeActivityAttributes: ActivityAttributes, NinebotChargeActivityVehicleAttributes {
    var vehicleSN: String
    var vehicleName: String
    var vehicleModel: String
    var startedAt: Date

    typealias ContentState = NinebotChargeActivityContentState
}
#endif
