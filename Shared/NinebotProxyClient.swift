import Foundation

enum NinebotProxyError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case server(String)
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "代理地址无效"
        case .invalidResponse:
            return "代理返回的数据格式无效"
        case .server(let message):
            return message
        case .httpStatus(let statusCode, let message):
            if message.isEmpty {
                return "HTTP \(statusCode)"
            }
            return "HTTP \(statusCode): \(message)"
        }
    }
}

struct NinebotProxyClient {
    var configuration: NinebotProxyConfiguration
    var session: URLSession = .shared

    func healthCheck() async throws {
        _ = try await request(method: "GET", path: ["healthz"])
    }

    func login(account: String, password: String) async throws -> NinebotLoginResult {
        let payload = try await request(
            method: "POST",
            path: ["auth", "login"],
            body: [
                "account": account,
                "password": password,
            ]
        )
        return Self.loginResult(from: payload)
    }

    func platformLogin(account: String, password: String, areaCode: String?) async throws -> NinebotLoginResult {
        // 平台登录：交给项目服务端处理账号密码，不在 App 内做官方 Passport 直连。
        var body = [
            "account": account,
            "password": password,
        ]
        if let areaCode = areaCode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !areaCode.isEmpty {
            body["area_code"] = areaCode.trimmingCharacters(in: CharacterSet(charactersIn: "+"))
        }

        let payload = try await request(
            method: "POST",
            path: ["accounts", "login"],
            body: body
        )
        return Self.loginResult(from: payload)
    }

    func sendLoginCode(account: String) async throws {
        _ = try await request(
            method: "POST",
            path: ["auth", "login-code"],
            body: ["account": account]
        )
    }

    func sendPlatformLoginCode(account: String, areaCode: String?) async throws {
        var body = ["account": account]
        if let areaCode = areaCode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !areaCode.isEmpty {
            body["area_code"] = areaCode.trimmingCharacters(in: CharacterSet(charactersIn: "+"))
        }

        _ = try await request(
            method: "POST",
            path: ["accounts", "login-code"],
            body: body
        )
    }

    func consumeLoginCode(account: String, code: String) async throws -> NinebotLoginResult {
        let payload = try await request(
            method: "POST",
            path: ["auth", "login-code", "consume"],
            body: [
                "account": account,
                "code": code,
            ]
        )
        return Self.loginResult(from: payload)
    }

    func consumePlatformLoginCode(account: String, code: String, areaCode: String?) async throws -> NinebotLoginResult {
        var body = [
            "account": account,
            "code": code,
        ]
        if let areaCode = areaCode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !areaCode.isEmpty {
            body["area_code"] = areaCode.trimmingCharacters(in: CharacterSet(charactersIn: "+"))
        }

        let payload = try await request(
            method: "POST",
            path: ["accounts", "login-code", "consume"],
            body: body
        )
        return Self.loginResult(from: payload)
    }

    func refreshAccessToken() async throws {
        _ = try await request(method: "POST", path: ["auth", "refresh"])
    }

    func ringBell(sn: String) async throws -> JSONValue {
        try await request(method: "POST", path: ["vehicles", sn, "bell"])
    }

    func openBucket(sn: String) async throws -> JSONValue {
        try await request(method: "POST", path: ["vehicles", sn, "buck"])
    }

    func engineStart(sn: String) async throws -> JSONValue {
        try await request(method: "POST", path: ["vehicles", sn, "engine", "start"])
    }

    func engineStop(sn: String) async throws -> JSONValue {
        try await request(method: "POST", path: ["vehicles", sn, "engine", "stop"])
    }

    func fetchDashboard(selectedSN: String? = nil) async throws -> NinebotDashboard {
        let vehiclesPayload = try await request(method: "GET", path: ["vehicles"])
        let vehicleValues = Self.arrayPayload(from: vehiclesPayload, preferredKeys: ["vehicles", "data"])
        let vehicles = vehicleValues.compactMap(Self.vehicleInfo)
        let currentMonth = Self.currentMonthString()

        var snapshots: [NinebotVehicleSnapshot] = []
        for vehicle in vehicles {
            let status = try? await request(method: "GET", path: ["vehicles", vehicle.sn, "status"])
            let travel = try? await fetchTravel(sn: vehicle.sn, month: currentMonth)
            let battery = try? await request(method: "GET", path: ["vehicles", vehicle.sn, "battery"])
            let monthlyTravels = await fetchMonthlyTravels(
                sn: vehicle.sn,
                authDate: vehicle.authDate,
                currentMonth: currentMonth,
                currentTravel: travel
            )
            var state = Self.vehicleState(status: status, travel: travel, battery: battery, updatedAt: Date())
            if let totalMileage = Self.totalMileage(fromMonthlyTravels: monthlyTravels) {
                state.totalMileage = totalMileage
            }
            let resolvedVehicle = Self.vehicleInfo(vehicle, addingImageFrom: status, battery: battery)
            snapshots.append(NinebotVehicleSnapshot(vehicle: resolvedVehicle, state: state))
        }

        let resolvedSelectedSN: String?
        if let selectedSN, snapshots.contains(where: { $0.vehicle.sn == selectedSN }) {
            resolvedSelectedSN = selectedSN
        } else {
            resolvedSelectedSN = snapshots.first?.vehicle.sn
        }

        return NinebotDashboard(
            vehicles: snapshots,
            selectedSN: resolvedSelectedSN,
            updatedAt: Date()
        )
    }

    /// Lightweight foreground pulse used while the App is visible.  It avoids
    /// re-downloading monthly travel history every few seconds while still
    /// refreshing the fields that power the dashboard and Live Activity.
    func fetchLiveDashboard(from cached: NinebotDashboard) async throws -> NinebotDashboard {
        guard !cached.vehicles.isEmpty else {
            return try await fetchDashboard(selectedSN: cached.selectedSN)
        }

        var snapshots: [NinebotVehicleSnapshot] = []
        snapshots.reserveCapacity(cached.vehicles.count)

        for cachedSnapshot in cached.vehicles {
            let sn = cachedSnapshot.vehicle.sn
            let status = try? await request(method: "GET", path: ["vehicles", sn, "status"])
            let battery = try? await request(method: "GET", path: ["vehicles", sn, "battery"])

            // If the network momentarily fails, preserve the last good snapshot
            // rather than wiping the Live Activity with empty values.
            guard status != nil || battery != nil else {
                snapshots.append(cachedSnapshot)
                continue
            }

            var refreshedState = Self.vehicleState(
                status: status,
                travel: cachedSnapshot.state.rawTravel.map(JSONValue.object),
                battery: battery,
                updatedAt: Date()
            )
            refreshedState.totalMileage = cachedSnapshot.state.totalMileage
            refreshedState.monthMileage = cachedSnapshot.state.monthMileage
            refreshedState.monthEnergy = cachedSnapshot.state.monthEnergy
            refreshedState.monthUsedElectricity = cachedSnapshot.state.monthUsedElectricity
            refreshedState.lastMileage = refreshedState.lastMileage ?? cachedSnapshot.state.lastMileage
            refreshedState.lastEnergy = refreshedState.lastEnergy ?? cachedSnapshot.state.lastEnergy
            refreshedState.lastUsedElectricity = refreshedState.lastUsedElectricity ?? cachedSnapshot.state.lastUsedElectricity
            refreshedState.rideRecords = cachedSnapshot.state.rideRecords
            refreshedState.dailyMileageRecords = cachedSnapshot.state.dailyMileageRecords
            refreshedState.locationDescription = refreshedState.locationDescription ?? cachedSnapshot.state.locationDescription
            refreshedState.latitude = refreshedState.latitude ?? cachedSnapshot.state.latitude
            refreshedState.longitude = refreshedState.longitude ?? cachedSnapshot.state.longitude

            let refreshedVehicle = Self.vehicleInfo(cachedSnapshot.vehicle, addingImageFrom: status, battery: battery)
            snapshots.append(NinebotVehicleSnapshot(vehicle: refreshedVehicle, state: refreshedState))
        }

        return NinebotDashboard(
            vehicles: snapshots,
            selectedSN: cached.selectedSN,
            updatedAt: Date()
        )
    }

    func fetchTravelDetail(sn: String, travelID: String) async throws -> NinebotRideDetail {
        let responseStartedAt = Date()
        let payload = try await request(
            method: "GET",
            path: ["vehicles", sn, "travel", travelID]
        )
        let responseDuration = Date().timeIntervalSince(responseStartedAt)

        // Prepare the route once. Previously SwiftUI recomputed the recursive
        // route extraction every time the detail view updated, which is very
        // expensive for a travel response containing thousands of GPS points.
        let preparationStartedAt = Date()
        var detail = NinebotRideDetail(
            vehicleSN: sn,
            rideID: travelID,
            fetchedAt: Date(),
            raw: payload,
            parsedRecord: Self.rideRecord(from: payload, index: 0),
            preparedTrackPoints: nil,
            responseDuration: responseDuration,
            trackPreparationDuration: nil
        )
        detail.preparedTrackPoints = detail.interfaceTrackPoints
        detail.trackPreparationDuration = Date().timeIntervalSince(preparationStartedAt)
        return detail
    }

    func syncTravelMonth(sn: String, month: String, pageSize: Int = 20) async throws -> NinebotTravelPage {
        do {
            let payload = try await request(
                method: "POST",
                path: ["vehicles", sn, "travel-sync"],
                queryItems: [
                    URLQueryItem(name: "month", value: month),
                    URLQueryItem(name: "page_size", value: "\(pageSize)")
                ]
            )
            return Self.travelPage(from: payload, fallbackMonth: month)
        } catch {
            guard Self.shouldTryLegacyPlatformFallback(after: error) else {
                throw error
            }
            // 平台服务 exposes the travel API as a
            // read-only GET endpoint instead of the Platform archive sync API.
            let payload = try await fetchTravel(sn: sn, month: month)
            return Self.travelPage(from: payload, fallbackMonth: month)
        }
    }

    private func fetchTravel(sn: String, month: String) async throws -> JSONValue {
        try await request(
            method: "GET",
            path: ["vehicles", sn, "travel"],
            queryItems: [URLQueryItem(name: "month", value: month)]
        )
    }

    private func fetchMonthlyTravels(
        sn: String,
        authDate: Date?,
        currentMonth: String,
        currentTravel: JSONValue?
    ) async -> [JSONValue]? {
        let months = Self.monthStrings(from: authDate, through: Date())
        guard !months.isEmpty else {
            return currentTravel.map { [$0] }
        }

        var payloads: [JSONValue] = []
        for month in months {
            if month == currentMonth, let currentTravel {
                payloads.append(currentTravel)
                continue
            }

            do {
                payloads.append(try await fetchTravel(sn: sn, month: month))
            } catch {
                return nil
            }
        }
        return payloads
    }

    func registerPushDevice(token: String, bundleID: String, environment: String) async throws {
        _ = try await request(
            method: "POST",
            path: ["devices", "register"],
            body: [
                "token": token,
                "bundle_id": bundleID,
                "environment": environment,
            ]
        )
    }

    private func assertTrustedCredentialEndpoint() throws {
        let token = configuration.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.isEmpty else { return }
        guard let url = configuration.baseURL, Self.isLocalOrPrivateNetwork(url) else {
            throw NinebotProxyError.server("未填写 Bearer Token 时请确认服务地址可信；公网服务建议开启鉴权并填写 Token")
        }
    }

    private func request(
        method: String,
        path: [String],
        queryItems: [URLQueryItem] = [],
        body: [String: String]? = nil
    ) async throws -> JSONValue {
        let url = try buildURL(path: path, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let token = configuration.bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let sessionToken = configuration.appSessionToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionToken.isEmpty {
            request.setValue(sessionToken, forHTTPHeaderField: "X-NinePlus-Session")
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NinebotProxyError.invalidResponse
        }

        if !(200..<300).contains(httpResponse.statusCode) {
            throw NinebotProxyError.httpStatus(httpResponse.statusCode, Self.errorMessage(from: data))
        }

        if data.isEmpty {
            return .object([:])
        }

        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        return try Self.unwrapEnvelope(root)
    }

    private func buildURL(path: [String], queryItems: [URLQueryItem]) throws -> URL {
        guard var url = configuration.baseURL else {
            throw NinebotProxyError.invalidBaseURL
        }

        for component in path {
            url.appendPathComponent(component)
        }

        guard !queryItems.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw NinebotProxyError.invalidBaseURL
        }
        components.queryItems = queryItems
        guard let finalURL = components.url else {
            throw NinebotProxyError.invalidBaseURL
        }
        return finalURL
    }
}

private extension NinebotProxyClient {
    static func normalizedLoginAccount(_ account: String, areaCode: String?) -> String {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArea = (areaCode ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "+"))
        let digits = trimmed.filter(\.isNumber)

        guard cleanArea == "86" else { return trimmed }
        if trimmed.hasPrefix("+86"), digits.count == 13, digits.hasPrefix("86") {
            return String(digits.dropFirst(2))
        }
        if trimmed.hasPrefix("86"), digits.count == 13, digits.hasPrefix("86") {
            return String(digits.dropFirst(2))
        }
        return trimmed
    }

    static func normalizedAreaCode(_ areaCode: String?) -> String? {
        let cleanArea = (areaCode ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "+"))
        return cleanArea.isEmpty ? nil : cleanArea
    }

    static func isLocalOrPrivateNetwork(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" { return true }
        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }

        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 172, (16...31).contains(parts[1]) {
            return true
        }
        if host.hasPrefix("fe80:") || host.hasPrefix("fd") { return true }
        return false
    }

    static func shouldTryLegacyPlatformFallback(after error: Error) -> Bool {
        if case NinebotProxyError.httpStatus(let statusCode, _) = error {
            return [404, 405, 501].contains(statusCode)
        }
        return false
    }

    static func unwrapEnvelope(_ root: JSONValue) throws -> JSONValue {
        guard let object = root.objectValue, object.keys.contains("ok") else {
            return root
        }

        if object["ok"]?.boolValue == true {
            return object["data"] ?? .object([:])
        }

        let error = object["error"]?.objectValue
        let message = error?["message"]?.stringValue
            ?? error?["code"]?.stringValue
            ?? "九号代理请求失败"
        throw NinebotProxyError.server(message)
    }

    static func errorMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if let root = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if let object = root.objectValue {
                if let error = object["error"]?.objectValue {
                    return error["message"]?.stringValue ?? error["code"]?.stringValue ?? ""
                }
                return object["message"]?.stringValue ?? ""
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func loginResult(from value: JSONValue) -> NinebotLoginResult {
        let object = value.objectValue ?? [:]
        return NinebotLoginResult(
            uuid: object["uuid"]?.stringValue ?? object["user_id"]?.stringValue ?? object["userId"]?.stringValue ?? object["uid"]?.stringValue,
            phone: object["phone"]?.stringValue ?? object["username"]?.stringValue ?? object["account"]?.stringValue,
            areaCode: object["area_code"]?.stringValue ?? object["areaCode"]?.stringValue,
            region: object["region"]?.stringValue,
            businessUID: object["business_uid"]?.stringValue ?? object["businessUid"]?.stringValue ?? object["businessUID"]?.stringValue,
            accountID: object["account_id"]?.intValue ?? object["accountId"]?.intValue ?? object["id"]?.intValue,
            sessionToken: object["session_token"]?.stringValue
                ?? object["sessionToken"]?.stringValue
                ?? object["access_token"]?.stringValue
                ?? object["accessToken"]?.stringValue
        )
    }

    static func arrayPayload(from value: JSONValue, preferredKeys: [String]) -> [JSONValue] {
        if let array = value.arrayValue {
            return array
        }

        guard let object = value.objectValue else {
            return []
        }

        for key in preferredKeys {
            if let array = object[key]?.arrayValue {
                return array
            }
        }

        return []
    }

    static func vehicleInfo(from value: JSONValue) -> NinebotVehicleInfo? {
        guard let object = value.objectValue else { return nil }
        guard let sn = firstString(["wnumber", "sn"], in: object), !sn.isEmpty else {
            return nil
        }

        var model = firstString(["vehicle_name_en", "vehicle_name", "model", "vehicleModel", "model_name", "modelName"], in: object) ?? sn
        if let vehicleType = object["vehicle_type"]?.stringValue, !vehicleType.isEmpty {
            model = "\(model) (\(vehicleType))"
        }

        return NinebotVehicleInfo(
            sn: sn,
            name: firstString(["device_name", "deviceName", "ble_name", "name", "vehicleName", "vehicle_name"], in: object) ?? sn,
            model: model,
            imageURLString: firstString(["v6_light_img_url", "img_url", "img", "image_url", "imageUrl"], in: object),
            raw: object
        )
    }

    static func vehicleInfo(_ vehicle: NinebotVehicleInfo, addingImageFrom status: JSONValue?, battery: JSONValue?) -> NinebotVehicleInfo {
        guard vehicle.imageURLString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            return vehicle
        }

        let statusObject = status?.objectValue ?? [:]
        let batteryObject = battery?.objectValue ?? [:]
        guard let imageURLString = firstString(
            ["v6_light_img_url", "v6LightImgUrl", "img_url", "imgUrl", "img", "image_url", "imageUrl"],
            in: statusObject
        ) ?? firstString(
            ["v6_light_img_url", "v6LightImgUrl", "img_url", "imgUrl", "img", "image_url", "imageUrl"],
            in: batteryObject
        ) else {
            return vehicle
        }

        var resolved = vehicle
        resolved.imageURLString = imageURLString
        return resolved
    }

    static func travelPage(from value: JSONValue, fallbackMonth: String) -> NinebotTravelPage {
        let object = value.objectValue ?? [:]
        let rides = object["list"]?.arrayValue ?? []
        let records = rides.enumerated().compactMap { index, value in
            rideRecord(from: value, index: index)
        }
        return NinebotTravelPage(
            month: firstString(["month"], in: object) ?? fallbackMonth,
            page: object["page"]?.intValue ?? 1,
            pageSize: object["page_size"]?.intValue ?? object["pageSize"]?.intValue ?? records.count,
            total: object["total"]?.intValue ?? records.count,
            hasMore: object["has_more"]?.boolValue ?? object["hasMore"]?.boolValue ?? false,
            records: records,
            raw: value
        )
    }

    static func vehicleState(status: JSONValue?, travel: JSONValue?, battery: JSONValue? = nil, updatedAt: Date) -> NinebotVehicleState {
        let statusObject = status?.objectValue ?? [:]
        let travelObject = travel?.objectValue ?? [:]
        let batteryPayloadObject = battery?.objectValue ?? [:]
        let batteryObject = firstObject(["battery", "batteryInfo", "battery_info", "bms", "bmsInfo", "bms_info"], in: statusObject) ?? [:]
        let batteryListObject = firstArrayObject(["battery_list", "batteryList", "batteries"], in: batteryPayloadObject) ?? [:]
        let batteryMainObject = firstObject(["battery_main", "batteryMain"], in: batteryPayloadObject) ?? [:]
        let batterySources = [statusObject, batteryObject, batteryPayloadObject, batteryListObject, batteryMainObject]
        let loc = statusObject["loc"]?.objectValue
        let locationInfo = statusObject["locationInfo"]?.objectValue
        // Different Ninebot endpoints use different wrappers and longitude
        // keys for the same GPS value. Keep all supported location objects in
        // one source list so weather, map, and address services receive the
        // coordinates already returned by the App API.
        let locationSources = [
            statusObject,
            loc,
            locationInfo,
            firstObject(["location", "gps", "coordinate", "coordinates", "point"], in: statusObject)
        ].compactMap { $0 }
        let lockNumber = loc?["lock"]?.intValue ?? statusObject["lock_status"]?.intValue
        let rides = travelObject["list"]?.arrayValue ?? []
        let rideRecords = rides.enumerated().compactMap { index, value in
            rideRecord(from: value, index: index)
        }
        let lastRide = rideRecords.first
        let dailyMileageRecords = dailyMileageRecords(from: travelObject)

        return NinebotVehicleState(
            battery: firstInt(["dump_energy", "dumpEnergy", "battery", "batteryLevel"], in: statusObject)
                ?? firstInt(["electricity", "dump_energy", "dumpEnergy", "battery", "batteryLevel"], in: batteryPayloadObject)
                ?? firstInt(["electricity", "dump_energy", "dumpEnergy", "battery", "batteryLevel"], in: batteryListObject),
            batteryVoltage: normalizedBatteryVoltage(
                firstDouble(
                    [
                        "battery_voltage",
                        "batteryVoltage",
                        "battery_vol",
                        "batteryVol",
                        "batt_voltage",
                        "battVoltage",
                        "bat_voltage",
                        "batVoltage",
                        "bms_voltage",
                        "bmsVoltage",
                        "bms_volt",
                        "bmsVolt",
                        "voltage",
                        "volt"
                    ],
                    in: batterySources
                )
            ),
            batteryTemperature: normalizedBatteryTemperature(
                firstDouble(
                    [
                        "battery_temperature",
                        "batteryTemperature",
                        "battery_temp",
                        "batteryTemp",
                        "batt_temperature",
                        "battTemperature",
                        "batt_temp",
                        "battTemp",
                        "bat_temperature",
                        "batTemperature",
                        "bat_temp",
                        "batTemp",
                        "bms_temperature",
                        "bmsTemperature",
                        "bms_temp",
                        "bmsTemp",
                        "bat_temp",
                        "batTemp",
                        "temperature",
                        "temp"
                    ],
                    in: batterySources
                )
            ),
            batteryCycleCount: firstInt(["bms_cycle", "bmsCycle", "bms_cycles", "bmsCycles", "cycle", "cycles"], in: batteryListObject)
                ?? firstInt(["bms_cycle", "bmsCycle", "bms_cycles", "bmsCycles", "cycle", "cycles"], in: batteryPayloadObject),
            chargingPower: firstDouble(["charging_power", "chargingPower", "charge_power", "chargePower"], in: batteryPayloadObject),
            endurance: firstDouble(["precise_estimate_mileage", "preciseEstimateMileage", "estimate_mileage", "estimateMileage", "endurance", "range"], in: statusObject),
            aiEstimatedMileage: firstDouble(["ai_estimate_mileage", "aiEstimateMileage", "ai_estimated_mileage", "aiEstimatedMileage"], in: statusObject),
            isCharging: firstBoolLike(["charging", "chargingState"], in: statusObject, trueValue: 1)
                ?? firstBoolLike(["charging", "chargingState"], in: batteryPayloadObject, trueValue: 1),
            isPoweredOn: firstBoolLike(["pwr", "power", "powerStatus"], in: statusObject, trueValue: 1),
            isLocked: (lockNumber ?? statusObject["lock"]?.intValue).map { $0 == 1 },
            remainingChargeTime: firstDouble(["remain_charge_time", "remainChargeTime", "remainingChargeTime"], in: statusObject)
                ?? firstDouble(["remain_charge_time", "remainChargeTime", "remainingChargeTime"], in: batteryPayloadObject),
            locationDescription: firstString(["locationDesc", "desc", "address", "addressDesc"], in: locationInfo ?? [:]),
            latitude: normalizedCoordinate(
                firstDouble(["lat", "latitude", "gcj_lat", "gcjLat", "wgs_lat", "wgsLat", "y"], in: locationSources),
                limit: 90
            ),
            longitude: normalizedCoordinate(
                firstDouble(["lon", "lng", "longitude", "gcj_lng", "gcjLng", "wgs_lng", "wgsLng", "x"], in: locationSources),
                limit: 180
            ),
            totalMileage: firstDouble(["total_mileage", "totalMileage", "total_mileages"], in: statusObject)
                ?? firstDouble(["total_mileage", "totalMileage"], in: travelObject),
            distanceSinceLastCharge: normalizedDistanceSinceCharge(firstDouble([
                "mileage_since_last_charge", "mileageSinceLastCharge", "distance_since_charge", "distanceSinceCharge",
                "last_charge_distance", "lastChargeDistance", "charge_mileage", "chargeMileage"
            ], in: [statusObject, batteryPayloadObject, batteryListObject, batteryMainObject])),
            tireTelemetry: tireTelemetry(in: [statusObject, batteryPayloadObject, batteryListObject, batteryMainObject]),
            monthMileage: firstDouble(["total_mileages", "monthMileage", "month_mileage"], in: travelObject),
            monthEnergy: firstDouble([
                "ec", "monthEnergy", "month_energy", "monthElectricity",
                "electricity", "energy", "consume_electricity", "consumeElectricity"
            ], in: travelObject),
            monthUsedElectricity: firstDouble([
                "used_electricity", "usedElectricity", "used_electric", "usedElectric",
                "electricity_used", "electricityUsed", "power_consumption", "powerConsumption", "month_used_electricity"
            ], in: travelObject),
            lastMileage: lastRide?.mileage ?? firstDouble(["last_mileage", "lastMileage"], in: travelObject),
            lastEnergy: lastRide?.energy ?? firstDouble(["last_energy", "lastEnergy"], in: travelObject),
            lastUsedElectricity: lastRide?.usedElectricity ?? firstDouble(["last_used_electricity", "lastUsedElectricity"], in: travelObject),
            rideRecords: rideRecords.isEmpty ? nil : rideRecords,
            dailyMileageRecords: dailyMileageRecords.isEmpty ? nil : dailyMileageRecords,
            updatedAt: updatedAt,
            rawStatus: statusObject.isEmpty ? nil : statusObject,
            rawTravel: travelObject.isEmpty ? nil : travelObject,
            rawBattery: batteryPayloadObject.isEmpty ? nil : batteryPayloadObject
        )
    }

    static func normalizedCoordinate(_ value: Double?, limit: Double) -> Double? {
        guard let value else { return nil }
        if abs(value) <= limit { return value }

        for divisor in [1_000_000.0, 10_000_000.0, 100_000.0] {
            let normalized = value / divisor
            if abs(normalized) <= limit {
                return normalized
            }
        }

        return nil
    }

    static func rideRecord(from value: JSONValue, index: Int) -> NinebotRideRecord? {
        guard let object = value.objectValue else { return nil }
        let startedAt = firstDate(
            ["start_time", "startTime", "begin_time", "beginTime", "stime", "date", "day", "create_time", "createTime"],
            in: object
        )
        let endedAt = firstDate(
            ["end_time", "endTime", "stop_time", "stopTime", "etime", "finish_time", "finishTime"],
            in: object
        )
        let mileage = firstDouble(["mileages", "mileage", "distance", "rideMileage"], in: object)
        let energy = firstDouble([
            "ec", "energy", "electricity", "consume", "consumption",
            "consume_electricity", "consumeElectricity", "power_consumption", "powerConsumption"
        ], in: object)
        let usedElectricity = firstDouble([
            "used_electricity", "usedElectricity", "used_electric", "usedElectric",
            "useElectricity", "electricity_used", "electricityUsed", "power_used", "powerUsed"
        ], in: object)
        let durationMinutes = firstDurationMinutes(in: object, startedAt: startedAt, endedAt: endedAt)
        let maxSpeed = firstDouble([
            "max_speed", "maxSpeed", "maximum_speed", "maximumSpeed",
            "top_speed", "topSpeed", "peak_speed", "peakSpeed"
        ], in: object)
        let speed = firstDouble(["speed", "avg_speed", "avgSpeed", "average_speed", "averageSpeed"], in: object)

        let id = firstString(["travel_id", "travelId", "ride_id", "rideId", "record_id", "recordId", "id"], in: object)
            ?? startedAt.map { "\(Int($0.timeIntervalSince1970))" }
            ?? "\(index)"

        return NinebotRideRecord(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            mileage: mileage,
            energy: energy,
            usedElectricity: usedElectricity,
            durationMinutes: durationMinutes,
            maxSpeed: maxSpeed,
            speed: speed,
            raw: object
        )
    }

    static func dailyMileageRecords(from travelObject: [String: JSONValue]) -> [NinebotDailyMileageRecord] {
        guard let detail = travelObject["detail"]?.arrayValue else { return [] }
        let month = firstString(["month"], in: travelObject)
        let currentMonth = currentMonthString()
        let currentDay = Calendar.current.component(.day, from: Date())
        let limit = month == currentMonth ? min(detail.count, currentDay) : detail.count

        return detail.prefix(limit).enumerated().compactMap { index, value in
            guard let mileage = value.doubleValue else { return nil }
            let day = index + 1
            return NinebotDailyMileageRecord(
                id: "\(month ?? "month")-\(day)",
                day: day,
                date: date(month: month, day: day),
                mileage: mileage
            )
        }
    }

    static func totalMileage(fromMonthlyTravels travels: [JSONValue]?) -> Double? {
        guard let travels else { return nil }
        var total = 0.0
        var hasMileage = false

        for travel in travels {
            guard let object = travel.objectValue else { continue }
            if let mileage = firstDouble(["total_mileages", "totalMileage", "monthMileage", "mileage"], in: object) {
                total += max(mileage, 0)
                hasMileage = true
                continue
            }

            let dailyTotal = dailyMileageRecords(from: object).reduce(0) { $0 + max($1.mileage, 0) }
            if dailyTotal > 0 {
                total += dailyTotal
                hasMileage = true
            }
        }

        return hasMileage ? total : nil
    }

    static func firstInt(_ keys: [String], in object: [String: JSONValue]) -> Int? {
        for key in keys {
            if let value = object[key]?.intValue {
                return value
            }
        }
        return nil
    }

    static func firstDouble(_ keys: [String], in object: [String: JSONValue]) -> Double? {
        for key in keys {
            if let value = object[key]?.doubleValue {
                return value
            }
        }
        return nil
    }

    static func firstDouble(_ keys: [String], in objects: [[String: JSONValue]]) -> Double? {
        for object in objects {
            if let value = firstDouble(keys, in: object) {
                return value
            }
        }
        return nil
    }

    static func firstString(_ keys: [String], in object: [String: JSONValue]) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    static func firstObject(_ keys: [String], in object: [String: JSONValue]) -> [String: JSONValue]? {
        for key in keys {
            if let value = object[key]?.objectValue {
                return value
            }
        }
        return nil
    }

    static func firstArrayObject(_ keys: [String], in object: [String: JSONValue]) -> [String: JSONValue]? {
        for key in keys {
            guard let array = object[key]?.arrayValue else { continue }
            for value in array {
                if let objectValue = value.objectValue {
                    return objectValue
                }
            }
        }
        return nil
    }

    static func normalizedDistanceSinceCharge(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        // Some firmwares expose metres while the vehicle API otherwise uses km.
        return value > 10_000 ? value / 1_000 : value
    }

    static func tireTelemetry(in sources: [[String: JSONValue]]) -> NinebotTireTelemetry? {
        let nestedKeys = ["tpms", "TPMS", "tire", "tires", "tire_info", "tireInfo", "tire_status", "tireStatus", "wheel", "wheels"]
        var objects = sources
        for source in sources {
            for key in nestedKeys {
                if let object = source[key]?.objectValue { objects.append(object) }
            }
        }

        func reading(
            _ position: NinebotTirePosition,
            pressureKeys: [String],
            temperatureKeys: [String],
            pressureStatusKeys: [String],
            temperatureStatusKeys: [String]
        ) -> NinebotTireReading? {
            let pressure = normalizedTirePressure(firstDouble(pressureKeys, in: objects))
            let temperature = normalizedTireTemperature(firstDouble(temperatureKeys, in: objects))
            let pressureStatus = firstString(pressureStatusKeys, in: objects.first ?? [:])
                ?? objects.compactMap { firstString(pressureStatusKeys, in: $0) }.first
            let temperatureStatus = firstString(temperatureStatusKeys, in: objects.first ?? [:])
                ?? objects.compactMap { firstString(temperatureStatusKeys, in: $0) }.first
            let value = NinebotTireReading(position: position, pressureKPa: pressure, temperatureC: temperature, pressureStatus: pressureStatus, temperatureStatus: temperatureStatus)
            return value.hasReading || !(value.statusText.isEmpty) ? value : nil
        }

        let readings = [
            reading(.front, pressureKeys: ["front_pressure", "frontPressure", "front_tire_pressure", "frontTirePressure", "frontTyrePressure"], temperatureKeys: ["front_temperature", "frontTemperature", "front_tire_temperature", "frontTireTemperature", "frontTyreTemperature"], pressureStatusKeys: ["front_pressure_status", "frontPressureStatus"], temperatureStatusKeys: ["front_tire_temperature_status", "frontTireTemperatureStatus"]),
            reading(.rear, pressureKeys: ["rear_pressure", "rearPressure", "rear_tire_pressure", "rearTirePressure", "rearTyrePressure"], temperatureKeys: ["rear_temperature", "rearTemperature", "rear_tire_temperature", "rearTireTemperature", "rearTyreTemperature"], pressureStatusKeys: ["rear_pressure_status", "rearPressureStatus"], temperatureStatusKeys: ["rear_tire_temperature_status", "rearTireTemperatureStatus", "rightBehindTireTemperatureStatus"]),
            reading(.leftFront, pressureKeys: ["left_front_pressure", "leftFrontPressure", "left_front_tire_pressure", "leftFrontTirePressure"], temperatureKeys: ["left_front_temperature", "leftFrontTemperature", "left_front_tire_temperature", "leftFrontTireTemperature"], pressureStatusKeys: ["left_front_pressure_status", "leftFrontPressureStatus"], temperatureStatusKeys: ["left_front_tire_temperature_status", "leftFrontTireTemperatureStatus", "isLeftFrontTireTemperatureStatus"]),
            reading(.rightFront, pressureKeys: ["right_front_pressure", "rightFrontPressure", "right_front_tire_pressure", "rightFrontTirePressure"], temperatureKeys: ["right_front_temperature", "rightFrontTemperature", "right_front_tire_temperature", "rightFrontTireTemperature"], pressureStatusKeys: ["right_front_pressure_status", "rightFrontPressureStatus"], temperatureStatusKeys: ["right_front_tire_temperature_status", "rightFrontTireTemperatureStatus"]),
            reading(.leftRear, pressureKeys: ["left_rear_pressure", "leftRearPressure", "left_behind_pressure", "leftBehindPressure"], temperatureKeys: ["left_rear_temperature", "leftRearTemperature", "left_behind_tire_temperature", "leftBehindTireTemperature"], pressureStatusKeys: ["left_rear_pressure_status", "leftRearPressureStatus"], temperatureStatusKeys: ["left_rear_tire_temperature_status", "leftRearTireTemperatureStatus"]),
            reading(.rightRear, pressureKeys: ["right_rear_pressure", "rightRearPressure", "right_behind_pressure", "rightBehindPressure"], temperatureKeys: ["right_rear_temperature", "rightRearTemperature", "right_behind_tire_temperature", "rightBehindTireTemperature"], pressureStatusKeys: ["right_rear_pressure_status", "rightRearPressureStatus"], temperatureStatusKeys: ["right_rear_tire_temperature_status", "rightRearTireTemperatureStatus", "rightBehindTireTemperatureStatus"])
        ].compactMap { $0 }
        return readings.isEmpty ? nil : NinebotTireTelemetry(readings: readings)
    }

    static func normalizedTirePressure(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        if value <= 6 { return value * 100 } // bar → kPa
        if value <= 80 { return value * 6.89476 } // psi → kPa
        return value <= 1_200 ? value : nil
    }

    static func normalizedTireTemperature(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        let celsius = value > 150 ? value / 10 : value
        return (-50...180).contains(celsius) ? celsius : nil
    }

    static func normalizedBatteryVoltage(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if value > 1_000 {
            return value / 1_000
        }
        if value > 120 {
            return value / 10
        }
        return value
    }

    static func normalizedBatteryTemperature(_ value: Double?) -> Double? {
        guard let value else { return nil }
        if abs(value) > 120 {
            return value / 10
        }
        return value
    }

    static func firstDate(_ keys: [String], in object: [String: JSONValue]) -> Date? {
        for key in keys {
            if let value = dateValue(object[key]) {
                return value
            }
        }
        return nil
    }

    static func firstDurationMinutes(in object: [String: JSONValue], startedAt: Date?, endedAt: Date?) -> Double? {
        let derived = durationMinutes(startedAt: startedAt, endedAt: endedAt)

        if let minutes = firstDurationValue(["durationMinutes", "duration_min", "durationMin"], in: object) {
            return saneDuration(minutes, fallback: derived)
        }
        if let seconds = firstDurationValue(["duration_seconds", "durationSeconds", "ride_seconds", "riding_seconds"], in: object) {
            return saneDuration(seconds / 60, fallback: derived)
        }
        if let value = firstDurationValue(["duration", "ride_time", "rideTime", "riding_time", "ridingTime", "use_time", "useTime", "cost_time", "costTime"], in: object) {
            return saneDuration(ambiguousDurationMinutes(value, derived: derived), fallback: derived)
        }

        return derived
    }

    static func firstBoolLike(_ keys: [String], in object: [String: JSONValue], trueValue: Int) -> Bool? {
        for key in keys {
            if let value = boolLike(object[key], trueValue: trueValue) {
                return value
            }
        }
        return nil
    }

    static func boolLike(_ value: JSONValue?, trueValue: Int) -> Bool? {
        guard let value else { return nil }
        if let intValue = value.intValue {
            return intValue == trueValue
        }
        return value.boolValue
    }

    static func dateValue(_ value: JSONValue?) -> Date? {
        guard let value else { return nil }

        guard let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }

        if let structuredDate = structuredChinaDateValue(string) {
            return structuredDate
        }

        if let number = Double(string) {
            return epochDateValue(number)
        }

        for format in [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "yyyy/MM/dd",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ"
        ] {
            let formatter = chinaDateFormatter(format: format)
            if let date = formatter.date(from: string) {
                return date
            }
        }

        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: string) {
            return date
        }

        return nil
    }

    static func date(month: String?, day: Int) -> Date? {
        guard let month, month.count == 6 else { return nil }
        let yearText = String(month.prefix(4))
        let monthText = String(month.suffix(2))
        guard let year = Int(yearText), let monthNumber = Int(monthText) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chinaTimeZone
        return calendar.date(from: DateComponents(year: year, month: monthNumber, day: day))
    }

    static func currentMonthString() -> String {
        monthString(for: Date())
    }

    static func monthString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = chinaTimeZone
        formatter.dateFormat = "yyyyMM"
        return formatter.string(from: date)
    }

    static func monthStrings(from startDate: Date?, through endDate: Date) -> [String] {
        guard let startDate else {
            return [monthString(for: endDate)]
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = chinaTimeZone
        let startComponents = calendar.dateComponents([.year, .month], from: startDate)
        let endComponents = calendar.dateComponents([.year, .month], from: endDate)
        guard let start = calendar.date(from: startComponents),
              let end = calendar.date(from: endComponents),
              start <= end else {
            return [monthString(for: endDate)]
        }

        var result: [String] = []
        var cursor = start
        while cursor <= end {
            result.append(monthString(for: cursor))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    static var chinaTimeZone: TimeZone {
        TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 60 * 60) ?? .current
    }

    static func chinaDateFormatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = chinaTimeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    static func structuredChinaDateValue(_ text: String) -> Date? {
        let digitsOnly = text.allSatisfy(\.isNumber)
        guard digitsOnly else { return nil }

        let format: String
        switch text.count {
        case 14:
            format = "yyyyMMddHHmmss"
        case 12:
            format = "yyyyMMddHHmm"
        case 8:
            format = "yyyyMMdd"
        default:
            return nil
        }

        return chinaDateFormatter(format: format).date(from: text)
    }

    static func epochDateValue(_ number: Double) -> Date? {
        if number > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: number / 1000)
        }
        if number > 1_000_000_000 {
            return Date(timeIntervalSince1970: number)
        }
        return nil
    }

    static func firstDurationValue(_ keys: [String], in object: [String: JSONValue]) -> Double? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let clockDuration = clockDurationMinutes(value) {
                return clockDuration
            }
            if let numericDuration = value.doubleValue, numericDuration > 0 {
                return numericDuration
            }
        }
        return nil
    }

    static func clockDurationMinutes(_ value: JSONValue) -> Double? {
        guard let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              string.contains(":") else {
            return nil
        }

        let parts = string.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }

        if parts.count == 2 {
            return parts[0] + parts[1] / 60
        }
        return parts[0] * 60 + parts[1] + parts[2] / 60
    }

    static func durationMinutes(startedAt: Date?, endedAt: Date?) -> Double? {
        guard let startedAt, let endedAt else { return nil }
        let minutes = endedAt.timeIntervalSince(startedAt) / 60
        guard minutes > 0, minutes <= 48 * 60 else { return nil }
        return minutes
    }

    static func ambiguousDurationMinutes(_ value: Double, derived: Double?) -> Double {
        guard let derived else {
            return value > 300 ? value / 60 : value
        }

        let minuteCandidate = value
        let secondCandidate = value / 60
        return abs(secondCandidate - derived) < abs(minuteCandidate - derived)
            ? secondCandidate
            : minuteCandidate
    }

    static func saneDuration(_ value: Double, fallback: Double?) -> Double? {
        guard value > 0, value <= 48 * 60 else {
            return fallback
        }
        return value
    }
}
