import CoreLocation
import Foundation
import MapKit
import Combine

/// 电子围栏采用由地图缩放确定的半径。界面不提供固定数字档位，
/// 但在数据层保留合理边界，避免过小范围造成误报或过大范围失去安全意义。
struct NinebotGeofence: Codable, Hashable, Sendable {
    static let supportedRadiusRange: ClosedRange<CLLocationDistance> = 50 ... 20_000

    var vehicleSN: String
    var center: NinebotVehicleLocation
    var radiusMeters: CLLocationDistance
    var isEnabled: Bool
    var wasInside: Bool?
    var updatedAt: Date

    init(
        vehicleSN: String,
        center: NinebotVehicleLocation,
        radiusMeters: CLLocationDistance = 500,
        isEnabled: Bool = true,
        wasInside: Bool? = nil,
        updatedAt: Date = .now
    ) {
        self.vehicleSN = vehicleSN
        self.center = center
        self.radiusMeters = radiusMeters.clamped(to: Self.supportedRadiusRange)
        self.isEnabled = isEnabled
        self.wasInside = wasInside
        self.updatedAt = updatedAt
    }

    /// 兼容此前以 `radius`（100 / 300 / 500 / 1000）存储的旧围栏数据。
    private enum CodingKeys: String, CodingKey {
        case vehicleSN, center, radiusMeters, radius, isEnabled, wasInside, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vehicleSN = try container.decode(String.self, forKey: .vehicleSN)
        center = try container.decode(NinebotVehicleLocation.self, forKey: .center)
        let savedRadius = try container.decodeIfPresent(CLLocationDistance.self, forKey: .radiusMeters)
            ?? container.decodeIfPresent(CLLocationDistance.self, forKey: .radius)
            ?? 500
        radiusMeters = savedRadius.clamped(to: Self.supportedRadiusRange)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        wasInside = try container.decodeIfPresent(Bool.self, forKey: .wasInside)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vehicleSN, forKey: .vehicleSN)
        try container.encode(center, forKey: .center)
        try container.encode(radiusMeters, forKey: .radiusMeters)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(wasInside, forKey: .wasInside)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// 车辆位置和轨迹记录。车辆 GPS 通过 BLE/服务端上传时调用 `ingest`；
/// iPhone CoreLocation 只用于选择围栏中心和将来系统区域监控的授权，不会误把手机位置当车辆位置。
@MainActor
final class NinebotVehicleLocationManager: ObservableObject {
    static let shared = NinebotVehicleLocationManager()

    @Published private(set) var latestLocations: [String: NinebotVehicleLocation] = [:]
    @Published private(set) var tracks: [String: [NinebotVehicleLocation]] = [:]

    private let defaults = UserDefaults(suiteName: NinebotAppGroup.identifier) ?? .standard
    private let tracksKey = "ninebot.antitheft.vehicle.tracks"

    private init() {
        if let data = defaults.data(forKey: tracksKey),
           let saved = try? JSONDecoder().decode([String: [NinebotVehicleLocation]].self, from: data) {
            tracks = saved
            latestLocations = saved.compactMapValues(\.last)
        }
    }

    func ingest(_ location: NinebotVehicleLocation, vehicleSN: String, isRiding: Bool) {
        guard location.isValid else { return }
        latestLocations[vehicleSN] = location
        guard isRiding else { return }

        var values = tracks[vehicleSN] ?? []
        // 每 10 秒或移动 15 米记录一个点；既保证轨迹可用，也避免每秒 I/O。
        if let last = values.last,
           location.updatedAt.timeIntervalSince(last.updatedAt) < 10,
           Self.distanceMeters(last, location) < 15 {
            return
        }
        values.append(location)
        tracks[vehicleSN] = Array(values.suffix(2_000))
        persistTracks()
    }

    func clearTrack(vehicleSN: String) {
        tracks.removeValue(forKey: vehicleSN)
        persistTracks()
    }

    func mapItem(for location: NinebotVehicleLocation, name: String) -> MKMapItem {
        let coordinate = NinebotCoordinateTransform.mapKitCoordinate(latitude: location.latitude, longitude: location.longitude)
        let placemark = MKPlacemark(coordinate: coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = name
        return item
    }

    static func distanceMeters(_ lhs: NinebotVehicleLocation, _ rhs: NinebotVehicleLocation) -> Double {
        let first = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        let second = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        return first.distance(from: second)
    }

    private func persistTracks() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        defaults.set(data, forKey: tracksKey)
    }
}

/// 电子围栏业务以「车辆上报的位置」为判断对象。这样即使手机不在附近，
/// 只要 BLE 网关或服务端提供车辆定位，就能正确判断进出围栏。
@MainActor
final class NinebotGeofenceManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = NinebotGeofenceManager()

    @Published private(set) var fences: [String: NinebotGeofence] = [:]
    @Published private(set) var phoneAuthorizationStatus: CLAuthorizationStatus

    private let locationManager = CLLocationManager()
    private let defaults = UserDefaults(suiteName: NinebotAppGroup.identifier) ?? .standard
    private let storageKey = "ninebot.antitheft.geofences"

    private override init() {
        phoneAuthorizationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: NinebotGeofence].self, from: data) {
            fences = decoded
        }
    }

    /// 请求「始终允许」仅用于用户主动启用围栏时；若用户拒绝，车辆远端定位判断仍能工作。
    func requestPhoneLocationAuthorization() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func setFence(vehicleSN: String, center: NinebotVehicleLocation, radiusMeters: CLLocationDistance) {
        fences[vehicleSN] = NinebotGeofence(vehicleSN: vehicleSN, center: center, radiusMeters: radiusMeters)
        persist()
    }

    func setEnabled(_ enabled: Bool, vehicleSN: String) {
        guard var fence = fences[vehicleSN] else { return }
        fence.isEnabled = enabled
        fence.wasInside = nil
        fence.updatedAt = .now
        fences[vehicleSN] = fence
        persist()
    }

    func removeFence(vehicleSN: String) {
        fences.removeValue(forKey: vehicleSN)
        persist()
    }

    func ingestVehicleLocation(_ location: NinebotVehicleLocation, vehicleSN: String, vehicleName: String) {
        guard var fence = fences[vehicleSN], fence.isEnabled, location.isValid else { return }
        let distance = NinebotVehicleLocationManager.distanceMeters(fence.center, location)
        let isInside = distance <= fence.radiusMeters
        defer {
            fence.wasInside = isInside
            fence.updatedAt = .now
            fences[vehicleSN] = fence
            persist()
        }

        guard let previousInside = fence.wasInside, previousInside != isInside else { return }
        if isInside {
            NinebotNotificationManager.shared.send(
                category: .geofenceEntered,
                title: "📍 车辆已进入安全区域",
                body: "\(vehicleName) 已进入你设定的安全区域。",
                vehicleSN: vehicleSN,
                destination: .map,
                dedupeInterval: 60
            )
        } else {
            NinebotNotificationManager.shared.send(
                category: .geofenceExited,
                title: "📍 车辆已离开安全区域",
                body: "\(vehicleName) 已离开你设定的安全区域。",
                vehicleSN: vehicleSN,
                destination: .map,
                dedupeInterval: 30,
                requestsCriticalAlert: true
            )
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        phoneAuthorizationStatus = manager.authorizationStatus
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(fences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
