import Foundation
import Security

enum NinebotOfficialError: LocalizedError {
    case invalidResponse
    case authentication(String)
    case api(String)
    case missingSession
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "九号官方接口返回的数据格式无效"
        case .authentication(let message):
            return message.isEmpty ? "九号账号登录失败" : message
        case .api(let message):
            return message.isEmpty ? "九号官方接口请求失败" : message
        case .missingSession:
            return "九号登录状态已失效，请重新登录"
        case .keychain(let status):
            return "无法保存九号登录状态（\(status)）"
        }
    }
}

struct NinebotOfficialSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?

    var isUsable: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (expiresAt == nil || expiresAt! > Date().addingTimeInterval(30))
    }
}

struct NinebotOfficialSessionStore {
    private static let service = "com.ninebot.live.official-session"
    private static let account = "ninebot-cloud"

    func load() -> NinebotOfficialSession? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(NinebotOfficialSession.self, from: data)
    }

    func save(_ session: NinebotOfficialSession) throws {
        let data = try JSONEncoder().encode(session)
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw NinebotOfficialError.keychain(updateStatus)
        }

        var item = identity
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NinebotOfficialError.keychain(addStatus)
        }
    }

    func clear() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecAttrAccount: Self.account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct NinebotOfficialClient {
    private static let passportBaseURL = URL(string: "https://api-passport-bj.ninebot.com")!
    private static let vehicleBaseURL = URL(string: "https://cn-cbu-gateway.ninebot.com")!
    private static let loginPath = ["v3", "openClaw", "user", "login"]
    private static let devicesPath = ["app-api", "inner", "device", "ai", "get-device-list"]
    private static let dynamicInfoPath = ["app-api", "inner", "device", "ai", "get-device-dynamic-info"]

    var urlSession: URLSession = .shared

    func login(account: String, password: String) async throws -> NinebotOfficialSession {
        let payload = try await post(
            baseURL: Self.passportBaseURL,
            path: Self.loginPath,
            body: ["username": account, "password": password],
            headers: [
                "clientId": "open_claw_client",
                "timestamp": String(Int64(Date().timeIntervalSince1970 * 1_000))
            ]
        )
        let object = payload.objectValue ?? [:]
        let data = object["data"]?.objectValue ?? [:]
        guard let accessToken = data["access_token"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            throw NinebotOfficialError.authentication(Self.message(from: object))
        }

        let validity = data["accessTokenValidity"]?.doubleValue
            ?? data["expires_in"]?.doubleValue
        return NinebotOfficialSession(
            accessToken: accessToken,
            refreshToken: data["refresh_token"]?.stringValue,
            expiresAt: validity.map { Date().addingTimeInterval($0) }
        )
    }

    func validate(_ session: NinebotOfficialSession) async throws {
        _ = try await fetchVehicles(session: session)
    }

    func fetchDashboard(
        session: NinebotOfficialSession,
        selectedSN: String? = nil
    ) async throws -> NinebotDashboard {
        guard session.isUsable else { throw NinebotOfficialError.missingSession }
        let vehicleValues = try await fetchVehicles(session: session)
        var snapshots: [NinebotVehicleSnapshot] = []

        for value in vehicleValues {
            guard let vehicle = NinebotProxyClient.vehicleInfo(from: value) else { continue }
            let status = try await fetchDynamicInfo(sn: vehicle.sn, session: session)
            let state = NinebotProxyClient.vehicleState(
                status: status,
                travel: nil,
                updatedAt: Date()
            )
            snapshots.append(NinebotVehicleSnapshot(
                vehicle: NinebotProxyClient.vehicleInfo(vehicle, addingImageFrom: status, battery: nil),
                state: state
            ))
        }

        let resolvedSN = selectedSN.flatMap { selected in
            snapshots.contains(where: { $0.vehicle.sn == selected }) ? selected : nil
        } ?? snapshots.first?.vehicle.sn
        return NinebotDashboard(vehicles: snapshots, selectedSN: resolvedSN, updatedAt: Date())
    }

    func fetchLiveDashboard(
        session: NinebotOfficialSession,
        from cached: NinebotDashboard
    ) async throws -> NinebotDashboard {
        guard session.isUsable else { throw NinebotOfficialError.missingSession }
        guard !cached.vehicles.isEmpty else {
            return try await fetchDashboard(session: session, selectedSN: cached.selectedSN)
        }

        var snapshots: [NinebotVehicleSnapshot] = []
        for cachedSnapshot in cached.vehicles {
            do {
                let status = try await fetchDynamicInfo(sn: cachedSnapshot.vehicle.sn, session: session)
                var state = NinebotProxyClient.vehicleState(
                    status: status,
                    travel: cachedSnapshot.state.rawTravel.map(JSONValue.object),
                    battery: cachedSnapshot.state.rawBattery.map(JSONValue.object),
                    updatedAt: Date()
                )
                state.totalMileage = state.totalMileage ?? cachedSnapshot.state.totalMileage
                state.monthMileage = cachedSnapshot.state.monthMileage
                state.monthEnergy = cachedSnapshot.state.monthEnergy
                state.monthUsedElectricity = cachedSnapshot.state.monthUsedElectricity
                state.lastMileage = cachedSnapshot.state.lastMileage
                state.lastEnergy = cachedSnapshot.state.lastEnergy
                state.lastUsedElectricity = cachedSnapshot.state.lastUsedElectricity
                state.rideRecords = cachedSnapshot.state.rideRecords
                state.dailyMileageRecords = cachedSnapshot.state.dailyMileageRecords
                snapshots.append(NinebotVehicleSnapshot(
                    vehicle: NinebotProxyClient.vehicleInfo(cachedSnapshot.vehicle, addingImageFrom: status, battery: nil),
                    state: state
                ))
            } catch let error as NinebotOfficialError {
                if case .authentication = error { throw error }
                snapshots.append(cachedSnapshot)
            } catch {
                snapshots.append(cachedSnapshot)
            }
        }

        return NinebotDashboard(
            vehicles: snapshots,
            selectedSN: cached.selectedSN,
            updatedAt: Date()
        )
    }

    private func fetchVehicles(session: NinebotOfficialSession) async throws -> [JSONValue] {
        let payload = try await post(
            baseURL: Self.vehicleBaseURL,
            path: Self.devicesPath,
            body: ["access_token": session.accessToken, "lang": "zh"]
        )
        let object = try checkedObject(payload)
        guard let values = object["data"]?.arrayValue else {
            throw NinebotOfficialError.invalidResponse
        }
        return values
    }

    private func fetchDynamicInfo(sn: String, session: NinebotOfficialSession) async throws -> JSONValue {
        let payload = try await post(
            baseURL: Self.vehicleBaseURL,
            path: Self.dynamicInfoPath,
            body: ["access_token": session.accessToken, "sn": sn]
        )
        let object = try checkedObject(payload)
        guard let data = object["data"], data.objectValue != nil else {
            throw NinebotOfficialError.invalidResponse
        }
        return data
    }

    private func post(
        baseURL: URL,
        path: [String],
        body: [String: String],
        headers: [String: String] = [:]
    ) async throws -> JSONValue {
        var url = baseURL
        path.forEach { url.appendPathComponent($0) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NinebotOfficialError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let root = try? JSONDecoder().decode(JSONValue.self, from: data)
            let message = root?.objectValue.map(Self.message(from:)) ?? "HTTP \(httpResponse.statusCode)"
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw NinebotOfficialError.authentication(message)
            }
            throw NinebotOfficialError.api(message)
        }
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw NinebotOfficialError.invalidResponse
        }
        return root
    }

    private func checkedObject(_ payload: JSONValue) throws -> [String: JSONValue] {
        guard let object = payload.objectValue else {
            throw NinebotOfficialError.invalidResponse
        }
        if let code = object["resultCode"]?.intValue ?? object["code"]?.intValue,
           code != 0, code != 1 {
            let message = Self.message(from: object)
            if Self.isAuthenticationMessage(message) {
                throw NinebotOfficialError.authentication(message)
            }
            throw NinebotOfficialError.api(message)
        }
        return object
    }

    private static func message(from object: [String: JSONValue]) -> String {
        object["resultDesc"]?.stringValue
            ?? object["desc"]?.stringValue
            ?? object["message"]?.stringValue
            ?? "九号官方接口请求失败"
    }

    private static func isAuthenticationMessage(_ message: String) -> Bool {
        let value = message.lowercased()
        return ["token", "auth", "login", "password", "account", "登录", "认证", "密码", "账号"]
            .contains(where: value.contains)
    }
}
