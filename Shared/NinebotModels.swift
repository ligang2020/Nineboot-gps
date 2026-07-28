import CoreLocation
import Foundation

enum NinebotAppGroup {
    static let identifier = "group.com.ninebot.live.36K6L4C2YJ"
}

/// Resolves the friendly name used throughout the App, widget and Live Activity.
/// The vehicle SN remains available only as an internal identifier for API calls.
enum NinebotVehicleNameResolver {
    private static let aliasesKey = "ninebot.vehicle.display.names"
    private static let builtInAliases: [String: String] = [
        "2PDAA2525A0414": "B2轰炸机"
    ]

    static func displayName(for vehicle: NinebotVehicleInfo) -> String {
        displayName(sn: vehicle.sn, fallback: vehicle.name)
    }

    static func displayName(sn: String, fallback: String) -> String {
        let cleanSN = sn.trimmingCharacters(in: .whitespacesAndNewlines)
        if let alias = aliases()[cleanSN]?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            return alias
        }
        if let builtInAlias = builtInAliases[cleanSN] {
            return builtInAlias
        }

        let cleanFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanFallback.isEmpty, cleanFallback.caseInsensitiveCompare(cleanSN) != .orderedSame {
            return cleanFallback
        }
        return "九号电动车"
    }

    static func alias(for sn: String) -> String? {
        aliases()[sn]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func saveAlias(_ alias: String, for sn: String) {
        let cleanSN = sn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSN.isEmpty else { return }
        var values = aliases()
        let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanAlias.isEmpty {
            values.removeValue(forKey: cleanSN)
        } else {
            values[cleanSN] = cleanAlias
        }
        defaults.set(values, forKey: aliasesKey)
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: NinebotAppGroup.identifier) ?? .standard
    }

    private static func aliases() -> [String: String] {
        defaults.dictionary(forKey: aliasesKey) as? [String: String] ?? [:]
    }
}

enum NinebotDataSourceMode: String, Codable, CaseIterable, Identifiable {
    case proxy
    case platform

    var id: String { rawValue }

    var title: String {
        switch self {
        case .proxy: return "代理服务"
        case .platform: return "车辆服务"
        }
    }

    var shortTitle: String {
        switch self {
        case .proxy: return "代理"
        case .platform: return "车辆服务"
        }
    }

    var endpointPlaceholder: String {
        switch self {
        case .proxy: return "http://127.0.0.1:18009"
        case .platform: return "http://127.0.0.1:18009"
        }
    }

    var tokenPlaceholder: String {
        switch self {
        case .proxy: return "ninecli 设置了 Token 才填写"
        case .platform: return "服务端 Bearer Token（如开启鉴权）"
        }
    }

    var systemImage: String {
        switch self {
        case .proxy: return "server.rack"
        case .platform: return "shippingbox.fill"
        }
    }
}

struct NinebotProxyConfiguration: Codable, Equatable {
    var baseURLString: String
    var bearerToken: String
    var appSessionToken: String? = nil

    var baseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme: String
        if trimmed.contains("://") {
            withScheme = trimmed
        } else {
            withScheme = "http://\(trimmed)"
        }

        return URL(string: withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    var isUsable: Bool {
        baseURL != nil
    }
}

struct NinebotLoginResult: Codable, Equatable {
    var uuid: String?
    var phone: String?
    var areaCode: String?
    var region: String?
    var businessUID: String?
    var accountID: Int?
    var sessionToken: String?
}

struct NinebotRefreshEvent: Codable, Equatable {
    var source: String
    var operation: String
    var startedAt: Date
    var endedAt: Date
    var success: Bool
    var message: String?

    var durationSeconds: Double {
        max(endedAt.timeIntervalSince(startedAt), 0)
    }
}

struct NinebotVehicleInfo: Codable, Equatable, Identifiable {
    var sn: String
    var name: String
    var model: String
    var imageURLString: String?
    var raw: [String: JSONValue]?

    var id: String { sn }

    /// Human-readable name. Never falls back to showing the serial number in UI.
    var displayName: String {
        NinebotVehicleNameResolver.displayName(for: self)
    }

    var vin: String? {
        firstRawString(["vin", "VIN", "vehicle_vin", "vehicleVin", "car_vin", "carVin"])
    }

    var identifierSummaryText: String {
        if let vin, !vin.isEmpty {
            return "SN \(sn) · VIN \(vin)"
        }
        return "SN \(sn)"
    }

    var authDate: Date? {
        firstRawDate(["auth_date", "authDate", "bind_time", "bindTime", "created_at", "createdAt"])
    }

    private func firstRawString(_ keys: [String]) -> String? {
        guard let raw else { return nil }
        for key in keys {
            if let value = raw[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func firstRawDate(_ keys: [String]) -> Date? {
        guard let raw else { return nil }
        for key in keys {
            guard let value = raw[key] else { continue }
            if let date = Self.rawDateValue(value) {
                return date
            }
        }
        return nil
    }

    private static func rawDateValue(_ value: JSONValue) -> Date? {
        if let number = value.doubleValue {
            return epochDateValue(number)
        }

        guard let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }
        if let number = Double(string) {
            return epochDateValue(number)
        }
        return nil
    }

    private static func epochDateValue(_ number: Double) -> Date? {
        guard number > 0 else { return nil }
        let seconds = number > 1_000_000_000_000 ? number / 1000 : number
        let date = Date(timeIntervalSince1970: seconds)
        return date.timeIntervalSince1970 > 0 ? date : nil
    }
}

enum NinebotVehicleHealthLevel: String, Codable, Equatable {
    case good
    case attention
    case critical
    case charging
    case unknown
}

struct NinebotVehicleHealth: Codable, Equatable {
    var level: NinebotVehicleHealthLevel
    var title: String
    var message: String
    var systemImage: String
}

struct NinebotRideRecord: Codable, Equatable, Identifiable {
    var id: String
    var startedAt: Date?
    var endedAt: Date?
    var mileage: Double?
    var energy: Double?
    var usedElectricity: Double?
    var durationMinutes: Double?
    /// The highest speed reported by the service for this trip, when available.
    var maxSpeed: Double?
    /// A legacy/general speed field returned by some services. It is used only as
    /// a fallback when the service does not expose a dedicated maximum-speed field.
    var speed: Double?
    var raw: [String: JSONValue]?

    var maximumSpeed: Double? {
        if let maxSpeed, maxSpeed.isFinite, maxSpeed > 0 {
            return maxSpeed
        }
        if let speed, speed.isFinite, speed > 0 {
            return speed
        }
        return nil
    }
}

/// Normalises the several energy units returned by different Ninebot endpoints.
/// Some firmwares return Wh, while others return a decimal kWh-like value.  The
/// distance-aware selection keeps the displayed consumption in a realistic
/// electric-scooter range without changing the raw values kept for diagnostics.
enum NinebotEnergy {
    static func wattHours(_ rawValue: Double?, distanceKm: Double?) -> Double? {
        guard let rawValue, rawValue.isFinite, rawValue >= 0 else { return nil }
        guard rawValue > 0 else { return 0 }

        if let distanceKm, distanceKm > 0 {
            let candidates = [1.0, 10.0, 100.0, 1_000.0].map { rawValue * $0 }
            let plausible = candidates.filter {
                let consumption = $0 / distanceKm
                return consumption >= 5 && consumption <= 300
            }
            if let best = plausible.min(by: { candidate, other in
                abs(log(candidate / distanceKm) - log(38)) < abs(log(other / distanceKm) - log(38))
            }) {
                return best
            }
        }

        // A value below 10 with no distance context is normally represented in
        // kWh by the platform.  Keep larger values as Wh.
        return rawValue < 10 ? rawValue * 1_000 : rawValue
    }
}

extension NinebotRideRecord {
    /// Total electricity consumed during this ride, consistently displayed in Wh.
    var consumedEnergyWh: Double? {
        NinebotEnergy.wattHours(energy ?? usedElectricity, distanceKm: mileage)
    }

    var energyPerKmWh: Double? {
        guard let mileage, mileage > 0, let consumedEnergyWh else { return nil }
        return consumedEnergyWh / mileage
    }

    var resolvedDurationMinutes: Double? {
        if let durationMinutes, durationMinutes >= 0 { return durationMinutes }
        guard let startedAt, let endedAt else { return nil }
        let minutes = endedAt.timeIntervalSince(startedAt) / 60
        return minutes >= 0 && minutes <= 48 * 60 ? minutes : nil
    }
}

struct NinebotTravelPage: Equatable {
    var month: String
    var page: Int
    var pageSize: Int
    var total: Int
    var hasMore: Bool
    var records: [NinebotRideRecord]
    var raw: JSONValue
}

struct NinebotRideDetail: Codable, Equatable, Identifiable {
    var vehicleSN: String
    var rideID: String
    var fetchedAt: Date
    var raw: JSONValue
    var parsedRecord: NinebotRideRecord?
    /// Parsed once when the response arrives. Route parsing walks the complete
    /// JSON tree, so repeating it during every SwiftUI update made long trips
    /// feel as though the detail request itself was slow.
    var preparedTrackPoints: [NinebotInterfaceTrackPoint]?
    /// End-to-end time spent waiting for the proxy / platform response. This
    /// is intentionally kept with the in-memory detail so support can tell a
    /// slow service response apart from map rendering work in the app.
    var responseDuration: TimeInterval?
    /// Time spent parsing and preparing the returned route for presentation.
    var trackPreparationDuration: TimeInterval?

    var id: String {
        "\(vehicleSN)|\(rideID)"
    }

    var rawObject: [String: JSONValue]? {
        raw.objectValue
    }
}

struct NinebotInterfaceTrackPoint: Codable, Equatable, Identifiable {
    var id: String
    var latitude: Double
    var longitude: Double
    /// A speed calculated from two trusted track timestamps and their GPS distance,
    /// or an explicitly named speed field supplied by the interface.
    var speedKmh: Double?
    /// Elapsed seconds from the beginning of the ride when supplied by the
    /// official `trail` payload. It is never displayed as a speed.
    var elapsedSeconds: Double?
    var auxiliaryValue: Double?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension NinebotRideDetail {
    var interfaceTrackPoints: [NinebotInterfaceTrackPoint] {
        if let preparedTrackPoints {
            return preparedTrackPoints
        }

        let points = Self.bestTrackPoints(from: raw)
        if !points.isEmpty {
            return points
        }
        return Self.bestTrackCoordinates(from: raw).enumerated().map { index, coordinate in
            Self.interfaceTrackPoint(
                coordinate: coordinate,
                speedKmh: nil,
                elapsedSeconds: nil,
                auxiliaryValue: nil,
                index: index
            )
        }
    }

    var interfaceTrackCoordinates: [CLLocationCoordinate2D] {
        interfaceTrackPoints.map(\.coordinate)
    }

    private static func bestTrackPoints(from value: JSONValue) -> [NinebotInterfaceTrackPoint] {
        // Official ride details expose the route as a compact `trail` string.
        // Its third number is an elapsed time, but the meaning/unit of later
        // anonymous values is not stable across vehicle services. Calculate the
        // displayed speed only from GPS distance and consecutive elapsed times.
        let officialTrailCandidates = officialTrailValues(from: value)
            .map { derivedSpeeds(for: officialTrailTrackPoints(from: $0)) }
            .filter { $0.count > 1 }
        if let officialTrail = officialTrailCandidates.max(by: { $0.count < $1.count }) {
            return officialTrail
        }

        let candidateValues = trackCandidateValues(from: value)
        let parsedCandidates = candidateValues
            .map { trackPoints(from: $0) }
            .filter { $0.count > 1 }

        return parsedCandidates.max { $0.count < $1.count } ?? []
    }

    private static func bestTrackCoordinates(from value: JSONValue) -> [CLLocationCoordinate2D] {
        let candidateValues = trackCandidateValues(from: value)
        let parsedCandidates = candidateValues
            .map { trackCoordinates(from: $0) }
            .filter { $0.count > 1 }

        return parsedCandidates.max { $0.count < $1.count } ?? []
    }

    private static func trackCandidateValues(from value: JSONValue) -> [JSONValue] {
        let trackKeys: Set<String> = [
            "trial",
            "trail",
            "trace",
            "track",
            "tracks",
            "track_list",
            "trackList",
            "trajectory",
            "trajectory_list",
            "trajectoryList",
            "points",
            "point_list",
            "pointList",
            "gps",
            "gps_list",
            "gpsList",
            "location_list",
            "locationList",
            "coordinate_list",
            "coordinateList"
        ]

        var values: [JSONValue] = []

        func collect(_ value: JSONValue) {
            if let object = value.objectValue {
                for (key, child) in object {
                    if trackKeys.contains(key) {
                        values.append(child)
                    }
                    collect(child)
                }
            } else if let array = value.arrayValue {
                for child in array {
                    collect(child)
                }
            }
        }

        collect(value)
        return values
    }

    private static func officialTrailValues(from value: JSONValue) -> [JSONValue] {
        var values: [JSONValue] = []

        func collect(_ value: JSONValue) {
            if let object = value.objectValue {
                for (key, child) in object {
                    if key.caseInsensitiveCompare("trail") == .orderedSame {
                        values.append(child)
                    }
                    collect(child)
                }
            } else if let array = value.arrayValue {
                for child in array {
                    collect(child)
                }
            }
        }

        collect(value)
        return values
    }

    private static func officialTrailTrackPoints(from value: JSONValue) -> [NinebotInterfaceTrackPoint] {
        guard let string = value.stringValue else { return [] }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let separators = CharacterSet(charactersIn: ";|\n")
        let points = trimmed.components(separatedBy: separators).enumerated().compactMap { index, segment -> NinebotInterfaceTrackPoint? in
            let numbers = segment
                .split { character in
                    character == "," || character == " " || character == "\t"
                }
                .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard numbers.count >= 2,
                  let coordinate = coordinate(fromPair: [.number(numbers[0]), .number(numbers[1])]) else {
                return nil
            }

            return interfaceTrackPoint(
                coordinate: coordinate,
                // Do not interpret an anonymous fourth `trail` number as km/h.
                // It has varied between platform payloads and caused plausible
                // but false readings in the replay UI.
                speedKmh: nil,
                elapsedSeconds: normalizedElapsedSeconds(numbers.count >= 3 ? numbers[2] : nil),
                auxiliaryValue: numbers.count >= 4 ? numbers[3] : nil,
                index: index
            )
        }

        return points.count > 1 ? deduplicated(points) : []
    }

    private static func trackPoints(from value: JSONValue) -> [NinebotInterfaceTrackPoint] {
        if let array = value.arrayValue {
            return trackPoints(fromArray: array)
        }

        if let object = value.objectValue {
            if let point = trackPoint(fromObject: object, index: 0) {
                return [point]
            }

            let nestedCandidates = ["trial", "trail", "trace", "track", "tracks", "points", "list", "data", "gps", "locations", "coordinates"]
            for key in nestedCandidates {
                if let child = object[key] {
                    let points = trackPoints(from: child)
                    if points.count > 1 {
                        return points
                    }
                }
            }
        }

        if let string = value.stringValue {
            return trackPoints(fromString: string)
        }

        return []
    }

    private static func trackPoints(fromArray array: [JSONValue]) -> [NinebotInterfaceTrackPoint] {
        if let point = trackPoint(fromPair: array, index: 0) {
            return [point]
        }

        var result: [NinebotInterfaceTrackPoint] = []
        for (index, value) in array.enumerated() {
            if let object = value.objectValue, let point = trackPoint(fromObject: object, index: index) {
                result.append(point)
                continue
            }

            if let pair = value.arrayValue, let point = trackPoint(fromPair: pair, index: index) {
                result.append(point)
                continue
            }

            if let string = value.stringValue {
                result.append(contentsOf: trackPoints(fromString: string, startIndex: result.count))
            }
        }

        return deduplicated(result)
    }

    private static func trackPoint(fromObject object: [String: JSONValue], index: Int) -> NinebotInterfaceTrackPoint? {
        guard let coordinate = coordinate(fromObject: object) else { return nil }
        return interfaceTrackPoint(
            coordinate: coordinate,
            speedKmh: normalizedSpeed(firstDouble(["speed", "spd", "speed_kmh", "speedKmh", "velocity", "v"], in: object)),
            elapsedSeconds: normalizedElapsedSeconds(firstDouble(["elapsed", "elapsed_seconds", "elapsedSeconds"], in: object)),
            auxiliaryValue: firstDouble(["direction", "bearing", "heading", "course", "angle", "aux", "auxiliary"], in: object),
            index: index
        )
    }

    private static func trackPoint(fromPair pair: [JSONValue], index: Int) -> NinebotInterfaceTrackPoint? {
        let numbers = pair.compactMap(\.doubleValue)
        return trackPoint(fromNumbers: numbers, index: index)
    }

    private static func trackPoints(fromString string: String, startIndex: Int = 0) -> [NinebotInterfaceTrackPoint] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let jsonPoints = trackPointsFromJSONString(trimmed), jsonPoints.count > 1 {
            return jsonPoints
        }

        let separators = CharacterSet(charactersIn: ";|\n")
        let segments = trimmed.components(separatedBy: separators)
        let points = segments.enumerated().compactMap { offset, segment -> NinebotInterfaceTrackPoint? in
            let numbers = segment
                .split { character in
                    character == "," || character == " " || character == "\t"
                }
                .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return trackPoint(fromNumbers: numbers, index: startIndex + offset)
        }

        return points.count > 1 ? deduplicated(points) : []
    }

    private static func trackPointsFromJSONString(_ string: String) -> [NinebotInterfaceTrackPoint]? {
        guard string.first == "{" || string.first == "[" else { return nil }
        guard let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        return trackPoints(from: value)
    }

    private static func trackPoint(fromNumbers numbers: [Double], index: Int) -> NinebotInterfaceTrackPoint? {
        guard numbers.count >= 2,
              let coordinate = coordinate(fromPair: [.number(numbers[0]), .number(numbers[1])]) else {
            return nil
        }

        // An unnamed third value in generic coordinate arrays is commonly a
        // timestamp, elapsed seconds, altitude or heading. Treating it as a
        // speed produced believable-looking but false speed labels. Only the
        // documented official `trail` layout and explicitly named object
        // fields are allowed to supply a displayed speed.
        return interfaceTrackPoint(
            coordinate: coordinate,
            speedKmh: nil,
            elapsedSeconds: nil,
            auxiliaryValue: numbers.count >= 3 ? numbers[2] : nil,
            index: index
        )
    }

    private static func interfaceTrackPoint(
        coordinate: CLLocationCoordinate2D,
        speedKmh: Double?,
        elapsedSeconds: Double?,
        auxiliaryValue: Double?,
        index: Int
    ) -> NinebotInterfaceTrackPoint {
        NinebotInterfaceTrackPoint(
            id: "\(index)-\(Int((coordinate.latitude * 1_000_000).rounded()))-\(Int((coordinate.longitude * 1_000_000).rounded()))",
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            speedKmh: speedKmh,
            elapsedSeconds: elapsedSeconds,
            auxiliaryValue: auxiliaryValue
        )
    }

    /// Returns an honest per-point replay speed. A value is available only
    /// when the interface supplied a monotonically increasing elapsed time and
    /// the GPS segment is physically plausible; otherwise it remains nil.
    private static func derivedSpeeds(for points: [NinebotInterfaceTrackPoint]) -> [NinebotInterfaceTrackPoint] {
        guard points.count > 1 else { return points }

        var segmentSpeeds = Array<Double?>(repeating: nil, count: points.count - 1)
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            guard let previousElapsed = previous.elapsedSeconds,
                  let currentElapsed = current.elapsedSeconds else {
                continue
            }

            let elapsed = currentElapsed - previousElapsed
            // A non-positive interval, or a large gap in an otherwise sampled
            // trace, cannot describe an instantaneous route speed.
            guard elapsed > 0, elapsed <= 15 * 60 else { continue }

            let distanceMeters = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: current.latitude, longitude: current.longitude))
            guard distanceMeters.isFinite else { continue }

            let speedKmh = distanceMeters / elapsed * 3.6
            // Ignore coordinate jumps rather than clamping them into a speed
            // that looks real. This safely covers every current Ninebot model
            // while retaining valid stopped (0 km/h) segments.
            guard speedKmh.isFinite, speedKmh <= 120 else { continue }
            segmentSpeeds[index - 1] = speedKmh
        }

        var result = points
        for index in result.indices {
            // A point represents the vehicle after travelling the preceding
            // segment. For the first point, use the immediately following one.
            let estimatedSpeed = index == 0 ? segmentSpeeds.first ?? nil : segmentSpeeds[index - 1]
            result[index].speedKmh = estimatedSpeed
        }
        return result
    }

    private static func trackCoordinates(from value: JSONValue) -> [CLLocationCoordinate2D] {
        if let array = value.arrayValue {
            return coordinates(fromArray: array)
        }

        if let object = value.objectValue {
            if let coordinate = coordinate(fromObject: object) {
                return [coordinate]
            }

            let nestedCandidates = ["trial", "trail", "trace", "track", "tracks", "points", "list", "data", "gps", "locations", "coordinates"]
            for key in nestedCandidates {
                if let child = object[key] {
                    let coordinates = trackCoordinates(from: child)
                    if coordinates.count > 1 {
                        return coordinates
                    }
                }
            }
        }

        if let string = value.stringValue {
            return coordinates(fromString: string)
        }

        return []
    }

    private static func coordinates(fromArray array: [JSONValue]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []

        for value in array {
            if let object = value.objectValue, let coordinate = coordinate(fromObject: object) {
                result.append(coordinate)
                continue
            }

            if let pair = value.arrayValue, let coordinate = coordinate(fromPair: pair) {
                result.append(coordinate)
                continue
            }

            if let string = value.stringValue {
                result.append(contentsOf: coordinates(fromString: string))
            }
        }

        return deduplicated(result)
    }

    private static func coordinate(fromObject object: [String: JSONValue]) -> CLLocationCoordinate2D? {
        let latitude = firstDouble(["lat", "latitude", "y", "gcj_lat", "gcjLat", "wgs_lat", "wgsLat"], in: object)
        let longitude = firstDouble(["lon", "lng", "longitude", "x", "gcj_lng", "gcjLng", "gcj_lon", "gcjLon", "wgs_lng", "wgsLng", "wgs_lon", "wgsLon"], in: object)

        if let coordinate = coordinate(latitude: latitude, longitude: longitude) {
            return coordinate
        }

        for key in ["location", "loc", "coordinate", "coordinates", "point", "gps"] {
            if let value = object[key] {
                let coordinates = trackCoordinates(from: value)
                if let first = coordinates.first {
                    return first
                }
            }
        }

        return nil
    }

    private static func coordinate(fromPair pair: [JSONValue]) -> CLLocationCoordinate2D? {
        guard pair.count >= 2,
              let first = pair[0].doubleValue,
              let second = pair[1].doubleValue else {
            return nil
        }

        if abs(first) > 90, abs(second) <= 90 {
            return coordinate(latitude: second, longitude: first)
        }

        return coordinate(latitude: first, longitude: second)
    }

    private static func coordinates(fromString string: String) -> [CLLocationCoordinate2D] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let jsonCoordinates = coordinatesFromJSONString(trimmed), jsonCoordinates.count > 1 {
            return jsonCoordinates
        }

        let separators = CharacterSet(charactersIn: ";|\n")
        let segments = trimmed.components(separatedBy: separators)
        let coordinates = segments.compactMap { segment -> CLLocationCoordinate2D? in
            let parts = segment
                .split { character in
                    character == "," || character == " " || character == "\t"
                }
                .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return coordinate(fromPair: parts.map { .number($0) })
        }

        if coordinates.count > 1 {
            return deduplicated(coordinates)
        }

        return []
    }

    private static func coordinatesFromJSONString(_ string: String) -> [CLLocationCoordinate2D]? {
        guard string.first == "{" || string.first == "[" else { return nil }
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return coordinates(fromAny: object)
    }

    private static func coordinates(fromAny value: Any) -> [CLLocationCoordinate2D] {
        if let array = value as? [Any] {
            var result: [CLLocationCoordinate2D] = []
            for item in array {
                result.append(contentsOf: coordinates(fromAny: item))
            }

            if result.isEmpty,
               array.count >= 2,
               let first = number(fromAny: array[0]),
               let second = number(fromAny: array[1]),
               let coordinate = coordinate(fromPair: [.number(first), .number(second)]) {
                return [coordinate]
            }

            return deduplicated(result)
        }

        if let object = value as? [String: Any] {
            if let coordinate = coordinate(fromAnyObject: object) {
                return [coordinate]
            }

            var result: [CLLocationCoordinate2D] = []
            for child in object.values {
                result.append(contentsOf: coordinates(fromAny: child))
            }
            return deduplicated(result)
        }

        return []
    }

    private static func coordinate(fromAnyObject object: [String: Any]) -> CLLocationCoordinate2D? {
        let latitude = firstNumber(["lat", "latitude", "y", "gcj_lat", "gcjLat", "wgs_lat", "wgsLat"], in: object)
        let longitude = firstNumber(["lon", "lng", "longitude", "x", "gcj_lng", "gcjLng", "gcj_lon", "gcjLon", "wgs_lng", "wgsLng", "wgs_lon", "wgsLon"], in: object)
        return coordinate(latitude: latitude, longitude: longitude)
    }

    private static func coordinate(latitude: Double?, longitude: Double?) -> CLLocationCoordinate2D? {
        guard let latitude,
              let longitude,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            return nil
        }

        return NinebotCoordinateTransform.mapKitCoordinate(latitude: latitude, longitude: longitude)
    }

    private static func firstDouble(_ keys: [String], in object: [String: JSONValue]) -> Double? {
        for key in keys {
            if let value = object[key]?.doubleValue {
                return value
            }
        }
        return nil
    }

    private static func firstNumber(_ keys: [String], in object: [String: Any]) -> Double? {
        for key in keys {
            if let value = object[key], let number = number(fromAny: value) {
                return number
            }
        }
        return nil
    }

    private static func number(fromAny value: Any) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    private static func normalizedSpeed(_ value: Double?) -> Double? {
        guard let value, value >= 0, value <= 160 else { return nil }
        return value
    }

    private static func normalizedElapsedSeconds(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func deduplicated(_ points: [NinebotInterfaceTrackPoint]) -> [NinebotInterfaceTrackPoint] {
        var result: [NinebotInterfaceTrackPoint] = []
        var lastKey: String?

        for point in points {
            let key = "\(Int((point.latitude * 1_000_000).rounded()))|\(Int((point.longitude * 1_000_000).rounded()))"
            guard key != lastKey else { continue }
            result.append(point)
            lastKey = key
        }

        return result
    }

    private static func deduplicated(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        var lastKey: String?

        for coordinate in coordinates {
            let key = "\(Int((coordinate.latitude * 1_000_000).rounded()))|\(Int((coordinate.longitude * 1_000_000).rounded()))"
            guard key != lastKey else { continue }
            result.append(coordinate)
            lastKey = key
        }

        return result
    }
}

extension NinebotRideRecord {
    var stableIdentityKey: String {
        if let travelID = firstRawText(["travel_id", "travelId"]) {
            return "travel:\(travelID)"
        }

        if let explicitIdentifier = firstRawText(["ride_id", "rideId", "record_id", "recordId", "id"]) {
            return "id:\(explicitIdentifier)"
        }

        if let rawStart = firstRawText(["start_time", "startTime", "begin_time", "beginTime", "stime", "date", "day", "create_time", "createTime"]) {
            let rawEnd = firstRawText(["end_time", "endTime", "stop_time", "stopTime", "etime", "finish_time", "finishTime"]) ?? "none"
            let rawMileage = firstRawText(["mileages", "mileage", "distance", "rideMileage"]) ?? Self.metricText(mileage, scale: 100)
            let rawUsed = firstRawText(["used_electricity", "usedElectricity", "usedElectric", "useElectricity"]) ?? Self.metricText(usedElectricity, scale: 100)
            return "raw:start=\(rawStart)|end=\(rawEnd)|km=\(rawMileage)|used=\(rawUsed)"
        }

        if let startedAt {
            return [
                "start:\(Self.timestampText(startedAt))",
                "end:\(endedAt.map { Self.timestampText($0) } ?? "none")",
                "km:\(Self.metricText(mileage, scale: 100))",
                "used:\(Self.metricText(usedElectricity, scale: 100))"
            ].joined(separator: "|")
        }

        return [
            "fallback:\(id)",
            "km:\(Self.metricText(mileage, scale: 100))",
            "energy:\(Self.metricText(energy, scale: 10))",
            "used:\(Self.metricText(usedElectricity, scale: 100))",
            "duration:\(Self.metricText(durationMinutes, scale: 10))",
            "speed:\(Self.metricText(speed, scale: 10))"
        ].joined(separator: "|")
    }

    private func firstRawText(_ keys: [String]) -> String? {
        guard let raw else { return nil }
        for key in keys {
            if let text = raw[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return "\(key)=\(text)"
            }
        }
        return nil
    }

    private static func timestampText(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }

    private static func metricText(_ value: Double?, scale: Double) -> String {
        guard let value else { return "none" }
        return String(Int((value * scale).rounded()))
    }
}

struct NinebotDailyMileageRecord: Codable, Equatable, Identifiable {
    var id: String
    var day: Int
    var date: Date?
    var mileage: Double
}


struct NinebotVehicleState: Codable, Equatable {
    var battery: Int?
    var batteryVoltage: Double?
    var batteryTemperature: Double?
    var batteryCycleCount: Int?
    var chargingPower: Double?
    var endurance: Double?
    var aiEstimatedMileage: Double?
    var isCharging: Bool?
    var isPoweredOn: Bool?
    var isLocked: Bool?
    var remainingChargeTime: Double?
    var locationDescription: String?
    var latitude: Double?
    var longitude: Double?
    var totalMileage: Double?
    var monthMileage: Double?
    var monthEnergy: Double?
    var monthUsedElectricity: Double?
    var lastMileage: Double?
    var lastEnergy: Double?
    var lastUsedElectricity: Double?
    var rideRecords: [NinebotRideRecord]?
    var dailyMileageRecords: [NinebotDailyMileageRecord]?
    var updatedAt: Date
    var rawStatus: [String: JSONValue]?
    var rawTravel: [String: JSONValue]?
    var rawBattery: [String: JSONValue]?

    var batteryText: String {
        guard let battery else { return "--%" }
        return "\(battery)%"
    }

    var batteryFraction: Double {
        guard let battery else { return 0 }
        return min(max(Double(battery) / 100, 0), 1)
    }

    var batteryVoltageText: String {
        guard let batteryVoltage else { return "接口未返回" }
        return "\(Self.numberText(batteryVoltage, maximumFractionDigits: 1)) V"
    }

    var batteryTemperatureText: String {
        guard let batteryTemperature else { return "接口未返回" }
        return "\(Self.numberText(batteryTemperature, maximumFractionDigits: 1)) °C"
    }

    var batteryCycleCountText: String {
        guard let batteryCycleCount else { return "接口未返回" }
        return "\(batteryCycleCount) 次"
    }

    var chargingPowerText: String {
        guard let chargingPower else { return "接口未返回" }
        return "\(Self.numberText(chargingPower, maximumFractionDigits: 0)) W"
    }

    var enduranceText: String {
        guard let endurance else { return "-- km" }
        return "\(Self.decimalFormatter.string(from: NSNumber(value: endurance)) ?? "--") km"
    }

    var aiEstimatedMileageText: String {
        guard let aiEstimatedMileage else { return "接口未返回" }
        return "\(Self.numberText(aiEstimatedMileage, maximumFractionDigits: 1)) km"
    }

    var lockText: String {
        guard let isLocked else { return "未知" }
        return isLocked ? "已锁" : "未锁"
    }

    var powerText: String {
        if isFullyCharged { return "已充满" }
        if isCharging == true { return "充电中" }
        guard let isPoweredOn else { return "离线" }
        return isPoweredOn ? "已上电" : "已熄火"
    }

    var primaryStatusText: String {
        health.title
    }

    var monthMileageText: String {
        guard let monthMileage else { return "-- km" }
        return "\(Self.decimalFormatter.string(from: NSNumber(value: monthMileage)) ?? "--") km"
    }

    var totalMileageText: String {
        guard let totalMileage else { return "-- km" }
        return "\(Self.decimalFormatter.string(from: NSNumber(value: totalMileage)) ?? "--") km"
    }

    var remainingChargeTimeText: String {
        guard let remainingChargeTime else { return "未知" }
        return Self.durationText(minutes: remainingChargeTime)
    }

    var estimatedChargeTo80Minutes: Double? {
        guard isCharging == true else { return nil }
        guard let battery else { return nil }

        let level = min(max(Double(battery), 0), 100)
        guard level < 80 else { return 0 }

        let minutes = (80 - level) * Self.fastMinutesPerPercent
        return (minutes / 5).rounded(.up) * 5
    }

    var estimatedChargeTo80TimeText: String {
        guard isCharging == true else { return "未充电" }
        guard let estimatedChargeTo80Minutes else { return "计算中" }
        guard estimatedChargeTo80Minutes > 0 else { return "已超过 80%" }
        return Self.durationText(minutes: estimatedChargeTo80Minutes)
    }

    var estimatedChargeTo80ClockText: String {
        guard isCharging == true, let estimatedChargeTo80Minutes else { return "--" }
        guard estimatedChargeTo80Minutes > 0 else { return "已超过 80%" }
        return Self.clockFormatter.string(from: updatedAt.addingTimeInterval(estimatedChargeTo80Minutes * 60))
    }

    var estimatedFullChargeMinutes: Double? {
        guard isCharging == true else { return nil }
        if let remainingChargeTime, remainingChargeTime >= 0 {
            return remainingChargeTime
        }
        guard let battery else { return nil }

        let level = min(max(Double(battery), 0), 100)
        guard level < 100 else { return 0 }

        let fastPercentRemaining = max(min(Self.fastChargeUpperBound, 100) - min(level, Self.fastChargeUpperBound), 0)
        let taperPercentRemaining = max(100 - max(level, Self.fastChargeUpperBound), 0)
        let minutes = fastPercentRemaining * Self.fastMinutesPerPercent + taperPercentRemaining * Self.taperMinutesPerPercent
        return (minutes / 5).rounded(.up) * 5
    }

    var estimatedFullChargeTimeText: String {
        guard isCharging == true else { return "未充电" }
        guard let estimatedFullChargeMinutes else { return "计算中" }
        guard estimatedFullChargeMinutes > 0 else { return "已充满" }
        return Self.durationText(minutes: estimatedFullChargeMinutes)
    }

    var estimatedFullChargeClockText: String {
        guard isCharging == true, let estimatedFullChargeMinutes else { return "--" }
        guard estimatedFullChargeMinutes > 0 else { return "已充满" }
        return Self.clockFormatter.string(from: updatedAt.addingTimeInterval(estimatedFullChargeMinutes * 60))
    }

    var chargeSummaryText: String {
        if isFullyCharged { return "已充满" }
        guard let isCharging else { return "充电未知" }
        return isCharging ? "充电中 · 约 \(estimatedFullChargeTimeText) 充满" : "未充电"
    }

    var chargingStateText: String {
        if isFullyCharged { return "已充满" }
        guard let isCharging else { return "未知" }
        return isCharging ? "充电中" : "未充电"
    }

    var isFullyCharged: Bool {
        if let battery, battery >= 100 {
            return true
        }
        return isCharging == true && estimatedFullChargeMinutes == 0
    }

    var estimatedChargingSpeedKmh: Double? {
        guard isCharging == true,
              let battery,
              battery < 100,
              let minutes = estimatedFullChargeMinutes,
              minutes > 0 else {
            return nil
        }

        let kmPerPercent: Double?
        if let observedKmPerBatteryPercent, observedKmPerBatteryPercent > 0 {
            kmPerPercent = observedKmPerBatteryPercent
        } else if let rangePerBatteryPercent, rangePerBatteryPercent > 0 {
            kmPerPercent = rangePerBatteryPercent
        } else if let localEstimatedMileage, battery > 0 {
            kmPerPercent = localEstimatedMileage / Double(battery)
        } else {
            kmPerPercent = nil
        }

        guard let kmPerPercent, kmPerPercent > 0 else { return nil }
        let remainingRange = kmPerPercent * Double(100 - battery)
        return remainingRange / (minutes / 60)
    }

    var estimatedChargingSpeedText: String {
        guard let estimatedChargingSpeedKmh else { return "-- km/h" }
        return "\(Self.numberText(estimatedChargingSpeedKmh, maximumFractionDigits: 0)) km/h"
    }

    var locationText: String {
        guard let locationDescription, !locationDescription.isEmpty else { return "未知位置" }
        return locationDescription
    }

    var rangePerBatteryPercent: Double? {
        guard let battery, battery > 0, let endurance else { return nil }
        return max(endurance, 0) / Double(battery)
    }

    var rangePerBatteryPercentText: String {
        guard let rangePerBatteryPercent else { return "-- km/%" }
        return "\(Self.numberText(rangePerBatteryPercent, maximumFractionDigits: 2)) km/%"
    }

    var observedKmPerBatteryPercent: Double? {
        let samples = observedRangeSamples
        let totalWeight = samples.reduce(0) { $0 + $1.weightedBattery }
        guard totalWeight > 0 else { return nil }
        let weightedMileage = samples.reduce(0) { $0 + $1.weightedMileage }
        return weightedMileage / totalWeight
    }

    var observedRangeSampleCount: Int {
        observedRangeSamples.count
    }

    var rangeEstimateAccuracy: Double? {
        let ratios = observedRangeRatios
        guard !ratios.isEmpty else { return nil }

        let consistencyScore = observedRangeConsistencyScore ?? 0.55

        let sampleScore = min(Double(ratios.count) / 10, 1)
        let comparisonScore: Double
        if let observedEstimatedMileage, let interfaceEstimatedMileage {
            let denominator = max(max(observedEstimatedMileage, interfaceEstimatedMileage), 1)
            let delta = abs(observedEstimatedMileage - interfaceEstimatedMileage) / denominator
            comparisonScore = max(0, 1 - min(delta, 0.7) / 0.7)
        } else {
            comparisonScore = 0.7
        }

        let score = 0.35 + sampleScore * 0.35 + consistencyScore * 0.2 + comparisonScore * 0.1
        return min(max(score, 0.35), 0.96)
    }

    var rangeEstimateAccuracyText: String {
        guard let rangeEstimateAccuracy else { return "样本不足" }
        return "\(Self.numberText(rangeEstimateAccuracy * 100, maximumFractionDigits: 0))%"
    }

    var rangeEstimateAccuracyDetailText: String {
        guard observedRangeSampleCount > 0 else { return "等待有效行程样本" }
        return "本地模型 · \(observedRangeSampleCount) 次有效行程"
    }

    var rangeModelSummaryText: String {
        guard let observedKmPerBatteryPercent else { return "等待行程样本" }
        return "\(Self.numberText(observedKmPerBatteryPercent, maximumFractionDigits: 2)) km/% · \(rangeEstimateAccuracyText)"
    }

    var rangeModelInsightText: String {
        guard observedRangeSampleCount > 0 else { return "刷新更多行程后生成本地估算。" }
        if let rangeEstimateAccuracy, rangeEstimateAccuracy >= 0.82 {
            return "近期样本稳定，估算可信。"
        }
        if observedRangeSampleCount < 5 {
            return "样本偏少，后续行程会继续校准。"
        }
        return "样本波动较大，已降低本地模型权重。"
    }

    var localEstimatedMileage: Double? {
        if let interfaceEstimatedMileage, let observedEstimatedMileage {
            let weight = observedRangeBlendWeight ?? 0.18
            return max(interfaceEstimatedMileage + (observedEstimatedMileage - interfaceEstimatedMileage) * weight, 0)
        }
        if let observedEstimatedMileage {
            return max(observedEstimatedMileage, 0)
        }
        return interfaceEstimatedMileage
    }

    var localEstimatedMileageText: String {
        guard let localEstimatedMileage else { return "-- km" }
        return "\(Self.numberText(localEstimatedMileage, maximumFractionDigits: 1)) km"
    }

    var localEstimateBasisText: String {
        if let observedKmPerBatteryPercent, interfaceEstimatedMileage != nil {
            return "结合接口续航和 \(observedRangeSampleCount) 次近期行程，约 \(Self.numberText(observedKmPerBatteryPercent, maximumFractionDigits: 2)) km/%。"
        }
        if let observedKmPerBatteryPercent {
            return "按 \(observedRangeSampleCount) 次近期行程估算，约 \(Self.numberText(observedKmPerBatteryPercent, maximumFractionDigits: 2)) km/%。"
        }
        if rangePerBatteryPercent != nil {
            return "按接口续航估算。"
        }
        return "刷新更多行程后生成估算。"
    }

    /// Monthly electricity consumption in Wh.  The server field differs by
    /// firmware, so the normalisation uses the matching monthly distance.
    var monthEnergyWh: Double? {
        NinebotEnergy.wattHours(monthEnergy ?? monthUsedElectricity, distanceKm: monthMileage)
    }

    var monthUsedElectricityText: String {
        guard let monthEnergyWh else { return "-- Wh" }
        return "\(Self.numberText(monthEnergyWh, maximumFractionDigits: 0)) Wh"
    }

    var monthEnergyPerKm: Double? {
        guard let monthMileage, monthMileage > 0, let monthEnergyWh else { return nil }
        return monthEnergyWh / monthMileage
    }

    var monthEnergyPerKmText: String {
        guard let monthEnergyPerKm else { return "-- Wh/km" }
        return "\(Self.numberText(monthEnergyPerKm, maximumFractionDigits: 1)) Wh/km"
    }

    /// The latest completed ride's consumption, favouring the endpoint's energy
    /// value and falling back to its used-electricity field when needed.
    var lastRideEnergyWh: Double? {
        NinebotEnergy.wattHours(lastEnergy ?? lastUsedElectricity, distanceKm: lastMileage)
    }

    var lastUsedElectricityText: String {
        guard let lastRideEnergyWh else { return "-- Wh" }
        return "\(Self.numberText(lastRideEnergyWh, maximumFractionDigits: 0)) Wh"
    }

    var lastEnergyPerKm: Double? {
        guard let lastMileage, lastMileage > 0, let lastRideEnergyWh else { return nil }
        return lastRideEnergyWh / lastMileage
    }

    var lastEnergyPerKmText: String {
        guard let lastEnergyPerKm else { return "-- Wh/km" }
        return "\(Self.numberText(lastEnergyPerKm, maximumFractionDigits: 1)) Wh/km"
    }

    var dailyAverageMileageText: String {
        guard let monthMileage else { return "-- km/日" }
        let day = max(Calendar.current.component(.day, from: updatedAt), 1)
        let value = monthMileage / Double(day)
        return "\(Self.numberText(value, maximumFractionDigits: 1)) km/日"
    }

    var todayMileage: Double? {
        if let record = dailyMileages.last(where: { record in
            guard let date = record.date else { return false }
            return Calendar.current.isDateInToday(date)
        }) {
            return record.mileage
        }

        let currentDay = Calendar.current.component(.day, from: updatedAt)
        return dailyMileages.last(where: { $0.day == currentDay })?.mileage
    }

    var todayMileageText: String {
        guard let todayMileage else { return "-- km" }
        return "\(Self.numberText(todayMileage, maximumFractionDigits: 1)) km"
    }

    var monthEstimatedCostText: String {
        guard let electricityWh = monthEnergyWh else { return "--" }
        return "¥\(Self.numberText(electricityWh / 1000 * Self.electricityPricePerKWh, maximumFractionDigits: 1, minimumFractionDigits: 1))"
    }

    var lastRideSummaryText: String {
        let mileage = lastMileage.map { "\(Self.numberText($0, maximumFractionDigits: 1)) km" } ?? "-- km"
        let energy = lastRideEnergyWh.map { "\(Self.numberText($0, maximumFractionDigits: 0)) Wh" } ?? "-- Wh"
        return "\(mileage) · \(energy)"
    }

    var latestSpeed: Double? {
        rides.compactMap(rideSpeed).first
    }

    var averageSpeed: Double? {
        let samples = rides.compactMap(rideSpeed)
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    var latestSpeedText: String {
        guard let latestSpeed else { return "-- km/h" }
        return "\(Self.numberText(latestSpeed, maximumFractionDigits: 1)) km/h"
    }

    var averageSpeedText: String {
        guard let averageSpeed else { return "-- km/h" }
        return "\(Self.numberText(averageSpeed, maximumFractionDigits: 1)) km/h"
    }

    var maximumSpeed: Double? {
        rides.compactMap(\.maximumSpeed).max()
    }

    var maximumSpeedText: String {
        guard let maximumSpeed else { return "-- km/h" }
        return "\(Self.numberText(maximumSpeed, maximumFractionDigits: 1)) km/h"
    }

    var rides: [NinebotRideRecord] {
        Self.deduplicatedRideRecords(rideRecords ?? [])
    }

    var dailyMileages: [NinebotDailyMileageRecord] {
        dailyMileageRecords ?? []
    }

    var health: NinebotVehicleHealth {
        if isFullyCharged {
            return NinebotVehicleHealth(
                level: .good,
                title: "已充满",
                message: "电量已满，可以拔掉充电器",
                systemImage: "battery.100"
            )
        }

        if isCharging == true {
            return NinebotVehicleHealth(
                level: .charging,
                title: "充电中",
                message: "约 \(estimatedFullChargeTimeText) 充满，\(estimatedFullChargeClockText) 左右",
                systemImage: "bolt.fill"
            )
        }

        if let battery, battery < 15 {
            return NinebotVehicleHealth(
                level: .critical,
                title: "低电量",
                message: "当前 \(battery)%，建议尽快充电",
                systemImage: "exclamationmark.triangle.fill"
            )
        }

        if isLocked == false {
            return NinebotVehicleHealth(
                level: .attention,
                title: "未锁车",
                message: "车辆未锁定，请确认停放环境",
                systemImage: "lock.open.fill"
            )
        }

        if let battery, battery < 25 {
            return NinebotVehicleHealth(
                level: .attention,
                title: "电量偏低",
                message: "当前 \(battery)%，续航约 \(enduranceText)",
                systemImage: "battery.25"
            )
        }

        if isLocked == true || isPoweredOn == false {
            return NinebotVehicleHealth(
                level: .good,
                title: "状态正常",
                message: "车辆已停放，续航约 \(enduranceText)",
                systemImage: "checkmark.shield.fill"
            )
        }

        return NinebotVehicleHealth(
            level: .unknown,
            title: "状态未知",
            message: "部分车况字段暂未返回",
            systemImage: "questionmark.circle.fill"
        )
    }

    var warningTexts: [String] {
        var warnings: [String] = []
        if let battery, battery < 15 {
            warnings.append("电量低于 15%，建议尽快充电")
        } else if let battery, battery < 25 {
            warnings.append("电量偏低，出门前建议确认续航")
        }
        if isPoweredOn == false {
            warnings.append("上电状态为 0，请确认车辆电源")
        }
        if isLocked == false {
            warnings.append("车辆当前未锁车")
        }
        return warnings
    }

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let fastChargeUpperBound = 80.0
    private static let fastMinutesPerPercent = 4.0
    private static let taperMinutesPerPercent = 7.0
    private static let electricityPricePerKWh = 0.6
    private static let minimumObservedKmPerPercent = 0.2
    private static let maximumObservedKmPerPercent = 3.0
    private static let rangeRecencyHalfLifeDays = 14.0

    private struct ObservedRangeSample {
        var mileage: Double
        var usedBattery: Double
        var date: Date?

        var ratio: Double {
            mileage / usedBattery
        }

        var recencyWeight: Double {
            guard let date else { return 0.55 }
            let days = max(Date().timeIntervalSince(date) / 86_400, 0)
            return max(pow(0.5, days / NinebotVehicleState.rangeRecencyHalfLifeDays), 0.25)
        }

        var weightedMileage: Double {
            mileage * recencyWeight
        }

        var weightedBattery: Double {
            usedBattery * recencyWeight
        }
    }

    private static func deduplicatedRideRecords(_ records: [NinebotRideRecord]) -> [NinebotRideRecord] {
        var seenKeys = Set<String>()
        var result: [NinebotRideRecord] = []

        for record in records {
            let key = record.stableIdentityKey
            guard !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            result.append(record)
        }

        return result
    }

    private var interfaceEstimatedMileage: Double? {
        if let endurance {
            return max(endurance, 0)
        }
        if let aiEstimatedMileage {
            return max(aiEstimatedMileage, 0)
        }
        return nil
    }

    private var normalizedBatteryPercent: Double? {
        guard let battery else { return nil }
        return min(max(Double(battery), 0), 100)
    }

    private var observedEstimatedMileage: Double? {
        guard let normalizedBatteryPercent, let observedKmPerBatteryPercent else { return nil }
        return max(observedKmPerBatteryPercent * normalizedBatteryPercent, 0)
    }

    private var observedRangeSamples: [ObservedRangeSample] {
        rides.compactMap { ride in
            guard let mileage = ride.mileage, mileage >= 0.3,
                  let usedBattery = ride.usedElectricity, usedBattery > 0, usedBattery <= 60 else {
                return nil
            }
            if let durationMinutes = ride.durationMinutes, durationMinutes > 0, durationMinutes < 1 {
                return nil
            }
            if let speed = ride.speed, speed > 90 {
                return nil
            }

            let ratio = mileage / usedBattery
            guard ratio >= Self.minimumObservedKmPerPercent,
                  ratio <= Self.maximumObservedKmPerPercent else {
                return nil
            }

            return ObservedRangeSample(
                mileage: mileage,
                usedBattery: usedBattery,
                date: ride.endedAt ?? ride.startedAt
            )
        }
    }

    private var observedRangeRatios: [Double] {
        observedRangeSamples.map(\.ratio)
    }

    private var observedRangeConsistencyScore: Double? {
        let ratios = observedRangeRatios
        guard !ratios.isEmpty else { return nil }
        guard ratios.count >= 2 else { return 0.55 }

        let mean = ratios.reduce(0, +) / Double(ratios.count)
        guard mean > 0 else { return 0 }

        let variance = ratios.reduce(0) { partial, value in
            let delta = value - mean
            return partial + delta * delta
        } / Double(ratios.count)
        let coefficientOfVariation = sqrt(variance) / mean
        return max(0, 1 - min(coefficientOfVariation, 0.6) / 0.6)
    }

    private var observedRangeBlendWeight: Double? {
        guard observedRangeSampleCount > 0 else { return nil }

        let sampleScore = min(Double(observedRangeSampleCount) / 12, 1)
        let consistencyScore = observedRangeConsistencyScore ?? 0.55
        let weight = 0.12 + sampleScore * 0.53 + consistencyScore * 0.25
        return min(max(weight, 0.18), 0.85)
    }

    private func rideSpeed(_ ride: NinebotRideRecord) -> Double? {
        if let speed = ride.speed, speed > 0 {
            return speed
        }
        guard let mileage = ride.mileage, mileage > 0,
              let durationMinutes = ride.durationMinutes, durationMinutes > 0 else {
            return nil
        }
        return mileage / (durationMinutes / 60)
    }

    private static func durationText(minutes: Double) -> String {
        if minutes >= 60 {
            let hours = minutes / 60
            return "\(decimalFormatter.string(from: NSNumber(value: hours)) ?? "--") 小时"
        }
        return "\(decimalFormatter.string(from: NSNumber(value: minutes)) ?? "--") 分钟"
    }

    private static func numberText(
        _ value: Double,
        maximumFractionDigits: Int,
        minimumFractionDigits: Int = 0
    ) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.minimumFractionDigits = minimumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

struct NinebotVehicleHistoryPoint: Codable, Equatable, Identifiable {
    var id: String
    var sn: String
    var date: Date
    var battery: Int?
    var endurance: Double?
    var totalMileage: Double?
    var isCharging: Bool?
    var isLocked: Bool?
    var isPoweredOn: Bool?

    init(sn: String, state: NinebotVehicleState) {
        self.sn = sn
        self.date = state.updatedAt
        self.battery = state.battery
        self.endurance = state.endurance
        self.totalMileage = state.totalMileage
        self.isCharging = state.isCharging
        self.isLocked = state.isLocked
        self.isPoweredOn = state.isPoweredOn
        self.id = "\(sn)-\(Int(state.updatedAt.timeIntervalSince1970))"
    }
}

struct NinebotVehicleHistorySummary: Equatable {
    var first: NinebotVehicleHistoryPoint
    var latest: NinebotVehicleHistoryPoint
    var sampleCount: Int

    init?(points: [NinebotVehicleHistoryPoint]) {
        let sorted = points.sorted { $0.date < $1.date }
        guard let first = sorted.first, let latest = sorted.last else { return nil }
        self.first = first
        self.latest = latest
        self.sampleCount = sorted.count
    }

    var batteryDelta: Int? {
        guard let first = first.battery, let latest = latest.battery else { return nil }
        return latest - first
    }

    var mileageDelta: Double? {
        guard let first = first.totalMileage, let latest = latest.totalMileage else { return nil }
        return latest - first
    }

    var periodText: String {
        let seconds = latest.date.timeIntervalSince(first.date)
        guard seconds > 0 else { return "刚刚开始记录" }
        let hours = seconds / 3600
        if hours >= 24 {
            return "\(Self.numberText(hours / 24, maximumFractionDigits: 1)) 天"
        }
        if hours >= 1 {
            return "\(Self.numberText(hours, maximumFractionDigits: 1)) 小时"
        }
        return "\(Self.numberText(seconds / 60, maximumFractionDigits: 0)) 分钟"
    }

    var batteryDeltaText: String {
        guard let batteryDelta else { return "--%" }
        return "\(batteryDelta >= 0 ? "+" : "")\(batteryDelta)%"
    }

    var mileageDeltaText: String {
        guard let mileageDelta else { return "-- km" }
        return "\(mileageDelta >= 0 ? "+" : "")\(Self.numberText(mileageDelta, maximumFractionDigits: 1)) km"
    }

    private static func numberText(_ value: Double, maximumFractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

struct NinebotResolvedAddress: Codable, Equatable {
    var sn: String
    var address: String
    var latitude: Double
    var longitude: Double
    var updatedAt: Date
    var source: String?
}

struct NinebotVehicleSnapshot: Codable, Equatable, Identifiable {
    var vehicle: NinebotVehicleInfo
    var state: NinebotVehicleState

    var id: String { vehicle.sn }
}

struct NinebotDashboard: Codable, Equatable {
    var vehicles: [NinebotVehicleSnapshot]
    var selectedSN: String?
    var updatedAt: Date

    var primaryVehicle: NinebotVehicleSnapshot? {
        if let selectedSN, let selected = vehicles.first(where: { $0.vehicle.sn == selectedSN }) {
            return selected
        }
        return vehicles.first
    }

    static let empty = NinebotDashboard(vehicles: [], selectedSN: nil, updatedAt: .distantPast)

    static let preview = NinebotDashboard(
        vehicles: [
            NinebotVehicleSnapshot(
                vehicle: NinebotVehicleInfo(
                    sn: "NINEBOT-DEMO",
                    name: "我的九号",
                    model: "Ninebot E-bike",
                    imageURLString: nil,
                    raw: [
                        "device_name": .string("我的九号"),
                        "wnumber": .string("NINEBOT-DEMO"),
                        "vehicle_name": .string("Ninebot E-bike")
                    ]
                ),
                state: NinebotVehicleState(
                    battery: 86,
                    batteryVoltage: 52.3,
                    batteryTemperature: 28.5,
                    batteryCycleCount: 36,
                    chargingPower: 0,
                    endurance: 42.5,
                    aiEstimatedMileage: 38.2,
                    isCharging: false,
                    isPoweredOn: false,
                    isLocked: true,
                    remainingChargeTime: nil,
                    locationDescription: "河畔花园",
                    latitude: nil,
                    longitude: nil,
                    totalMileage: 1048.9,
                    monthMileage: 128.4,
                    monthEnergy: 3200,
                    monthUsedElectricity: 2800,
                    lastMileage: 4.6,
                    lastEnergy: 200,
                    lastUsedElectricity: 4,
                    rideRecords: [
                        NinebotRideRecord(
                            id: "preview-ride-1",
                            startedAt: Date().addingTimeInterval(-7200),
                            endedAt: Date().addingTimeInterval(-6600),
                            mileage: 4.6,
                            energy: 200,
                            usedElectricity: 4,
                            durationMinutes: 10,
                            maxSpeed: 32,
                            speed: 27.6,
                            raw: nil
                        )
                    ],
                    dailyMileageRecords: [
                        NinebotDailyMileageRecord(id: "preview-1", day: 1, date: Date().addingTimeInterval(-345600), mileage: 12.3),
                        NinebotDailyMileageRecord(id: "preview-2", day: 2, date: Date().addingTimeInterval(-259200), mileage: 4.8),
                        NinebotDailyMileageRecord(id: "preview-3", day: 3, date: Date().addingTimeInterval(-172800), mileage: 18.5),
                        NinebotDailyMileageRecord(id: "preview-4", day: 4, date: Date().addingTimeInterval(-86400), mileage: 9.7),
                        NinebotDailyMileageRecord(id: "preview-5", day: 5, date: Date(), mileage: 6.7)
                    ],
                    updatedAt: Date(),
                    rawStatus: [
                        "dump_energy": .number(86),
                        "precise_estimate_mileage": .number(42.5),
                        "charging": .number(0),
                        "pwr": .number(0),
                        "loc": .object([
                            "lock": .number(1),
                            "lat": .number(31.2304),
                            "lon": .number(121.4737)
                        ])
                    ],
                    rawTravel: [
                        "total_mileages": .number(128.4),
                        "ec": .number(3.2),
                        "used_electricity": .number(2.8)
                    ],
                    rawBattery: [
                        "battery_list": .array([
                            .object([
                                "bms_volt": .number(52.3),
                                "bat_temp": .number(28.5),
                                "bms_cycle": .number(36)
                            ])
                        ]),
                        "charging_power": .number(0)
                    ]
                )
            )
        ],
        selectedSN: "NINEBOT-DEMO",
        updatedAt: Date()
    )
}

enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var object: [String: JSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var array: [JSONValue] = []
            while !container.isAtEnd {
                array.append(try container.decode(JSONValue.self))
            }
            self = .array(array)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let object):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in object {
                try container.encode(value, forKey: DynamicCodingKey(key))
            }
        case .array(let array):
            var container = encoder.unkeyedContainer()
            for value in array {
                try container.encode(value)
            }
        case .string(let string):
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case .number(let number):
            var container = encoder.singleValueContainer()
            try container.encode(number)
        case .bool(let bool):
            var container = encoder.singleValueContainer()
            try container.encode(bool)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let array) = self else { return nil }
        return array
    }

    var stringValue: String? {
        switch self {
        case .string(let string):
            return string
        case .number(let number):
            if number.rounded() == number {
                return String(Int(number))
            }
            return String(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let number):
            return number
        case .string(let string):
            return Double(string)
        case .bool(let bool):
            return bool ? 1 : 0
        default:
            return nil
        }
    }

    var intValue: Int? {
        guard let doubleValue else { return nil }
        return Int(doubleValue)
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let bool):
            return bool
        case .number(let number):
            return number != 0
        case .string(let string):
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "on"].contains(normalized) { return true }
            if ["0", "false", "no", "off"].contains(normalized) { return false }
            return nil
        default:
            return nil
        }
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    var displayText: String {
        switch self {
        case .object(let object):
            if object.isEmpty { return "{}" }
            return object
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.displayText)" }
                .joined(separator: ", ")
        case .array(let array):
            if array.isEmpty { return "[]" }
            return array.map(\.displayText).joined(separator: ", ")
        case .string(let string):
            return string
        case .number(let number):
            if number.rounded() == number {
                return String(Int(number))
            }
            return String(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            return "null"
        }
    }
}

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(_ intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.init(intValue)
    }
}
