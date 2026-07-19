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

    struct ContentState: Codable, Hashable {
        var battery: Int?
        var estimatedRange: Double?
        var speedKmh: Double?
        var usedElectricityWh: Double?
        var energyPerKmWh: Double?
        var isPoweredOn: Bool?
        var updatedAt: Date
    }
}
#endif
