import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// Live Activity data for the selected vehicle while it is actively charging.
/// The activity starts only from a confirmed charging state and ends when
/// charging stops or the battery reaches full charge.
@available(iOS 16.1, *)
struct NinebotChargeActivityAttributes: ActivityAttributes {
    var vehicleSN: String
    var vehicleName: String
    var vehicleModel: String
    /// Stable start point for the charging session. It survives content updates.
    var startedAt: Date

    struct ContentState: Codable, Hashable {
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
}
#endif
