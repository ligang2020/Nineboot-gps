import Foundation

/// A persisted riding session. The start timestamp is stored in the App Group
/// so the dashboard, recorder, and Live Activity all continue the same timer
/// after the app is terminated and opened again.
struct NinebotActiveRideSession: Codable, Hashable {
    var vehicleSN: String
    var vehicleName: String
    var vehicleModel: String
    var startedAt: Date
    var latestSpeedKmh: Double?
    var distanceMeters: Double?
    var updatedAt: Date

    init(
        vehicleSN: String,
        vehicleName: String,
        vehicleModel: String,
        startedAt: Date,
        latestSpeedKmh: Double? = nil,
        distanceMeters: Double? = nil,
        updatedAt: Date = .now
    ) {
        self.vehicleSN = vehicleSN
        self.vehicleName = vehicleName
        self.vehicleModel = vehicleModel
        self.startedAt = startedAt
        self.latestSpeedKmh = latestSpeedKmh
        self.distanceMeters = distanceMeters
        self.updatedAt = updatedAt
    }
}

#if canImport(ActivityKit)
import ActivityKit

struct NinebotRideActivityContentState: Codable, Hashable {
    var battery: Int?
    var speedKmh: Double?
    var distanceMeters: Double?
    var updatedAt: Date
}

/// The ride-focused ActivityAttributes registration used by the iPhone Live
/// Activity / Dynamic Island. The elapsed time deliberately lives in the
/// attributes: `Text(_:style: .timer)` then keeps ticking in real time without
/// requiring frequent background execution from the app.
@available(iOS 16.1, *)
struct NinebotRideActivityAttributes: ActivityAttributes {
    var vehicleSN: String
    var vehicleName: String
    var vehicleModel: String
    var startedAt: Date

    typealias ContentState = NinebotRideActivityContentState
}
#endif
