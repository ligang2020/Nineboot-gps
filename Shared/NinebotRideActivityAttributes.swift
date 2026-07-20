import Foundation

#if canImport(ActivityKit)
import ActivityKit

/// A ride-status activity is intentionally tied to the lock state:
/// it begins after the selected vehicle has been unlocked and is dismissed
/// as soon as the vehicle is locked again.
@available(iOS 16.1, *)
struct NinebotRideActivityAttributes: ActivityAttributes {
    var vehicleSN: String
    var vehicleName: String
    var vehicleModel: String
    /// Total odometer reading when this ride activity was started.
    var startedTotalMileage: Double?
    /// Stable start point for the live timer.  It survives content updates.
    var startedAt: Date

    struct ContentState: Codable, Hashable {
        var battery: Int?
        var batteryTemperatureCelsius: Double?
        var estimatedRange: Double?
        var speedKmh: Double?
        var usedElectricityWh: Double?
        var energyPerKmWh: Double?
        var rideDistanceKm: Double?
        var rideStartedAt: Date
        var rideDurationSeconds: Double
        var rideProgressTargetKm: Double
        var latitude: Double?
        var longitude: Double?
        var locationName: String?
        var isPoweredOn: Bool?
        var updatedAt: Date
    }
}
#endif
