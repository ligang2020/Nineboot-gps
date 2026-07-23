import Combine
import CoreLocation
import Foundation
import MapKit
import WidgetKit

enum NinebotInputError: LocalizedError {
    case missingProxy
    case missingAccount
    case missingPassword
    case missingCode
    case platformOnly
    case officialPasswordOnly
    case officialReadOnly

    var errorDescription: String? {
        switch self {
        case .missingProxy:
            return "请先填写代理或 NinePlus 平台地址"
        case .missingAccount:
            return "请填写手机号"
        case .missingPassword:
            return "请填写密码"
        case .missingCode:
            return "请填写验证码"
        case .platformOnly:
            return "请切换到服务器模式后再拉取历史行程"
        case .officialPasswordOnly:
            return "九号官方直连目前仅支持账号密码登录"
        case .officialReadOnly:
            return "九号官方直连目前只开放车况读取，车辆控制请切换到 NinePlus 服务器"
        }
    }
}

enum NinebotVehicleAction: String, CaseIterable, Identifiable {
    case bell
    case openBucket
    case engineStart
    case engineStop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bell: return "寻车铃"
        case .openBucket: return "开座桶"
        case .engineStart: return "上电"
        case .engineStop: return "熄火"
        }
    }

    var resultTitle: String {
        switch self {
        case .bell: return "寻车铃已发送"
        case .openBucket: return "开座桶指令已发送"
        case .engineStart: return "上电指令已发送"
        case .engineStop: return "熄火指令已发送"
        }
    }

    var loadingTitle: String {
        switch self {
        case .bell: return "正在寻车鸣笛"
        case .openBucket: return "正在打开座桶"
        case .engineStart: return "正在开锁"
        case .engineStop: return "正在关锁"
        }
    }

    var subtitle: String {
        switch self {
        case .bell: return "让车辆发出提示音"
        case .openBucket: return "打开座桶"
        case .engineStart: return "车辆进入可骑行状态"
        case .engineStop: return "关闭电源并锁车"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .bell: return "发送寻车铃？"
        case .openBucket: return "打开座桶？"
        case .engineStart: return "车辆上电？"
        case .engineStop: return "车辆熄火？"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .bell:
            return "车辆会发出提示音。"
        case .openBucket:
            return "座桶会被打开，请确认车辆在你身边。"
        case .engineStart:
            return "车辆会进入上电/解锁状态，请确认车辆在你身边。"
        case .engineStop:
            return "车辆会进入熄火/锁车状态，请确认不会影响当前骑行。"
        }
    }

    var systemImage: String {
        switch self {
        case .bell: return "bell.fill"
        case .openBucket: return "shippingbox.fill"
        case .engineStart: return "power.circle.fill"
        case .engineStop: return "lock.fill"
        }
    }

    var isDangerous: Bool {
        switch self {
        case .engineStart, .engineStop, .openBucket:
            return true
        case .bell:
            return false
        }
    }
}

struct NinebotDiagnosticsSnapshot {
    var hasConfiguration: Bool
    var proxyText: String
    var accountText: String
    var vehicleCount: Int
    var selectedVehicleName: String
    var dashboardUpdatedAt: Date?
    var lastAppRefreshEvent: NinebotRefreshEvent?
    var lastWidgetRefreshEvent: NinebotRefreshEvent?
    var lastError: String?
    var interfaceRideCount: Int
    var historyPointCount: Int
    var recordedRideCount: Int
    var rideDetailCount: Int
    var resolvedAddressCount: Int
    var dashboardCacheBytes: Int
}

@MainActor
final class NinebotViewModel: ObservableObject {
    @Published var dataSourceMode: NinebotDataSourceMode = .official
    @Published var baseURLString = ""
    @Published var bearerToken = ""
    @Published var account = ""
    @Published var password = ""
    @Published var smsCode = ""
    @Published var pushDeviceToken: String?
    @Published var loginResult: NinebotLoginResult?
    @Published var dashboard: NinebotDashboard
    @Published var isLoading = false
    @Published var loadingMessage: String?
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published private(set) var activeVehicleAction: NinebotVehicleAction?
    @Published private(set) var activeVehicleActionSN: String?
    @Published private(set) var history: [String: [NinebotVehicleHistoryPoint]] = [:]
    @Published private(set) var resolvedAddresses: [String: NinebotResolvedAddress] = [:]
    @Published private(set) var recordedRides: [NinebotRecordedRide] = []
    @Published private(set) var rideDetails: [String: NinebotRideDetail] = [:]
    @Published private(set) var loadingRideDetailKeys: Set<String> = []
    @Published private(set) var syncingTravelMonth: String?

    private let store = NinebotSharedStore()
    private let officialSessionStore = NinebotOfficialSessionStore()
    private var lastAutomaticRefreshAt: Date?
    private var lastWidgetTimelineRefreshAt: Date?

    init() {
        let configuration = store.loadConfiguration()
        let loginResult = store.loadLoginResult()
        let storedMode = store.loadDataSourceMode()
        self.dataSourceMode = configuration == nil && storedMode == .platform ? .official : storedMode
        self.baseURLString = configuration?.baseURLString ?? ""
        self.bearerToken = configuration?.bearerToken ?? ""
        self.loginResult = loginResult
        self.account = loginResult?.phone ?? ""
        self.pushDeviceToken = store.loadPushDeviceToken()
        self.dashboard = store.loadDashboard() ?? .empty
        self.errorMessage = store.loadLastError()
        self.history = Self.historyMap(for: self.dashboard, store: store)
        self.resolvedAddresses = store.loadResolvedAddresses().filter { $0.value.source == Self.addressGeocodingSource }
        self.recordedRides = store.loadRecordedRides()
    }

    var hasConfiguration: Bool {
        dataSourceMode == .official || currentConfiguration.isUsable
    }

    var dataSourceStatusTitle: String {
        hasConfiguration ? "\(dataSourceMode.shortTitle)已配置" : "未配置\(dataSourceMode.shortTitle)"
    }

    var dataSourceStatusDetail: String {
        if dataSourceMode == .official {
            return "直接连接九号官方云，无需服务器地址"
        }
        let value = baseURLString.trimmed
        if !value.isEmpty {
            return value
        }
        return dataSourceMode == .platform ? "填写 NinePlus Platform 地址后读取服务器归档数据" : "填写 ninecli serve 地址后直接读取代理"
    }

    var hasVehicles: Bool {
        !dashboard.vehicles.isEmpty
    }

    var currentAccountDisplay: String {
        let savedPhone = loginResult?.phone?.trimmed ?? ""
        return savedPhone.isEmpty ? "未绑定账号" : savedPhone
    }

    var hasLoginAccount: Bool {
        let hasPhone = !(loginResult?.phone?.trimmed ?? "").isEmpty
        if dataSourceMode == .official {
            return hasPhone && officialSessionStore.load()?.isUsable == true
        }
        if dataSourceMode == .platform {
            return hasPhone && !(loginResult?.sessionToken?.trimmed ?? "").isEmpty
        }
        return hasPhone
    }

    var loginAccountCount: Int {
        dataSourceMode == .proxy ? (hasLoginAccount ? 1 : 0) : dashboard.vehicles.count
    }

    var isAddressGeocodingEnabled: Bool {
        true
    }

    /// Charge status is refreshed every five seconds while the selected vehicle
    /// is charging so the Live Activity's battery progress remains responsive.
    var foregroundRefreshInterval: TimeInterval {
        dashboard.primaryVehicle?.state.isCharging == true ? 5 : 8
    }

    func refreshOnLaunchIfPossible() async {
        await syncPushDeviceTokenIfPossible()
        await refreshResolvedAddressesIfNeeded(for: dashboard)
        await refreshAutomaticallyIfPossible()
    }

    func refreshWhenActiveIfPossible() async {
        await syncPushDeviceTokenIfPossible()
        await refreshResolvedAddressesIfNeeded(for: dashboard)
        await refreshAutomaticallyIfPossible()
    }

    private func refreshAutomaticallyIfPossible() async {
        guard hasConfiguration else { return }
        guard dataSourceMode != .official || hasLoginAccount else { return }
        guard !isLoading else { return }

        let now = Date()
        if let lastAutomaticRefreshAt, now.timeIntervalSince(lastAutomaticRefreshAt) < foregroundRefreshInterval {
            return
        }

        lastAutomaticRefreshAt = now
        await refreshDashboard()
    }

    func saveConfiguration() {
        if dataSourceMode == .official {
            store.saveDataSourceMode(.official)
            errorMessage = nil
            statusMessage = "已切换为九号官方直连"
            return
        }
        let configuration = currentConfiguration
        guard configuration.isUsable else {
            errorMessage = NinebotInputError.missingProxy.localizedDescription
            return
        }

        store.saveDataSourceMode(dataSourceMode)
        store.saveConfiguration(configuration)
        errorMessage = nil
        statusMessage = "\(dataSourceMode.shortTitle)配置已保存"
    }

    func saveDataSourceMode() {
        store.saveDataSourceMode(dataSourceMode)
        clearMessages()
        statusMessage = "已切换为\(dataSourceMode.title)"
    }

    func testConnection() async {
        await runLoadingOperation(message: "正在测试连接") {
            if self.dataSourceMode == .official {
                let session = try self.requireOfficialSession()
                try await NinebotOfficialClient().validate(session)
            } else {
                let client = try self.makeClient()
                try await client.healthCheck()
            }
            self.errorMessage = nil
            self.statusMessage = "\(self.dataSourceMode.shortTitle)连接正常"
        }
    }

    func refreshLoginToken() async {
        await runLoadingOperation(message: "正在刷新登录状态") {
            if self.dataSourceMode == .official {
                let session = try self.requireOfficialSession()
                try await NinebotOfficialClient().validate(session)
            } else {
                let client = try self.makeClient()
                try await client.refreshAccessToken()
            }
            self.errorMessage = nil
            self.statusMessage = "登录状态已刷新"
        }
    }

    func refreshDashboard() async {
        await runLoadingOperation(message: "正在刷新车况") {
            let dashboard = try await self.fetchDashboard(selectedSN: self.dashboard.selectedSN)
            let archivedDashboard = self.saveDashboard(dashboard)
            await self.cacheVehicleImages(for: archivedDashboard)
            await self.refreshResolvedAddressesIfNeeded(for: archivedDashboard)
            self.errorMessage = nil
            self.statusMessage = "已更新 \(Self.timeFormatter.string(from: archivedDashboard.updatedAt))"
        }
    }

    /// Foreground-only fast refresh for the dashboard and Live Activity.
    /// It fetches status and battery endpoints only, does not show a loading
    /// overlay, and keeps the last known values when the network has a blip.
    func refreshDashboardSilently() async {
        guard hasConfiguration, !isLoading else { return }
        guard dataSourceMode != .official || hasLoginAccount else { return }

        do {
            let dashboard = try await fetchLiveDashboard(from: self.dashboard)
            let archivedDashboard = self.saveDashboard(dashboard, reloadWidgets: false)
            lastAutomaticRefreshAt = Date()

            // WidgetKit coalesces timeline reloads. Asking no more than once per
            // minute prevents the foreground vehicle pulse from wasting reloads.
            let now = Date()
            if lastWidgetTimelineRefreshAt == nil || now.timeIntervalSince(lastWidgetTimelineRefreshAt!) >= 60 {
                lastWidgetTimelineRefreshAt = now
                WidgetCenter.shared.reloadAllTimelines()
            }

            // Keep reverse-geocoded text fresh only when it is inexpensive; the
            // raw GPS coordinates continue to update on every fast pulse.
            if archivedDashboard.primaryVehicle?.state.locationDescription == nil {
                await refreshResolvedAddressesIfNeeded(for: archivedDashboard)
            }
        } catch {
            // A rapid refresh must never interrupt the driver or replace the last
            // valid Live Activity content with an error state.
        }
    }

    func syncTravelMonth(vehicleSN: String, month: String) async {
        await runLoadingOperation(message: "正在获取 \(Self.displayMonth(month)) 行程") {
            guard self.dataSourceMode == .platform else {
                throw NinebotInputError.platformOnly
            }
            self.syncingTravelMonth = month
            defer { self.syncingTravelMonth = nil }

            let client = try makeClient()
            let page = try await client.syncTravelMonth(sn: vehicleSN, month: month, pageSize: 100)
            self.store.upsertInterfaceRideRecords(page.records, sn: vehicleSN)

            let dashboard = try await self.fetchDashboard(selectedSN: vehicleSN)
            let archivedDashboard = self.saveDashboard(dashboard)
            await self.cacheVehicleImages(for: archivedDashboard)
            await self.refreshResolvedAddressesIfNeeded(for: archivedDashboard)

            if page.total == 0 {
                self.statusMessage = "\(Self.displayMonth(month)) 暂无行程"
            } else {
                self.statusMessage = "已获取 \(Self.displayMonth(month)) \(page.total) 条行程"
            }
            self.errorMessage = nil
        }
    }

    func resolveAddressesNow() async {
        await runLoadingOperation(message: "正在解析车辆位置") {
            try await self.resolveAddresses(for: self.dashboard, force: true)
            self.errorMessage = nil
            self.statusMessage = "车辆位置已解析"
        }
    }

    func enableVehicleNotifications() async {
        await runLoadingOperation(message: "正在开启车辆通知") {
            guard self.dataSourceMode == .platform else {
                throw NinebotPushError.missingServer
            }
            _ = try await NinebotPushManager.shared.requestAuthorizationRegisterAndWaitForToken()
            self.pushDeviceToken = self.store.loadPushDeviceToken()
            if self.pushDeviceToken != nil {
                try await NinebotPushManager.shared.registerStoredTokenWithServer()
                self.statusMessage = "充电与车辆报警通知已开启"
            } else {
                self.statusMessage = "已允许通知，系统返回设备 Token 后会自动上报"
            }
            self.errorMessage = nil
        }
    }

    func syncPushDeviceToken() async {
        await runLoadingOperation(message: "正在上报设备 Token") {
            guard self.dataSourceMode == .platform else {
                throw NinebotPushError.missingServer
            }
            _ = try await NinebotPushManager.shared.requestAuthorizationRegisterAndWaitForToken()
            self.pushDeviceToken = self.store.loadPushDeviceToken()
            try await NinebotPushManager.shared.registerStoredTokenWithServer()
            self.statusMessage = "设备 Token 已上报"
            self.errorMessage = nil
        }
    }

    func syncPushDeviceTokenIfPossible() async {
        guard dataSourceMode == .platform, hasConfiguration else { return }
        do {
            _ = try await NinebotPushManager.shared.requestAuthorizationRegisterAndWaitForToken()
            pushDeviceToken = store.loadPushDeviceToken()
            if pushDeviceToken != nil {
                try await NinebotPushManager.shared.registerStoredTokenWithServer()
            }
        } catch {
            // Token sync should not block normal app refresh; diagnostics can surface manual retry errors.
        }
    }

    func loginWithPassword() async {
        await runLoadingOperation(message: "正在密码登录") {
            guard !account.trimmed.isEmpty else { throw NinebotInputError.missingAccount }
            guard !password.isEmpty else { throw NinebotInputError.missingPassword }

            let result: NinebotLoginResult
            if self.dataSourceMode == .official {
                let session = try await NinebotOfficialClient().login(
                    account: self.account.trimmed,
                    password: self.password
                )
                try self.officialSessionStore.save(session)
                result = NinebotLoginResult(
                    uuid: nil,
                    phone: self.account.trimmed,
                    areaCode: "86",
                    region: "CN",
                    businessUID: nil,
                    accountID: nil,
                    sessionToken: nil
                )
                self.store.saveDataSourceMode(.official)
            } else {
                self.saveConfiguration()
                let client = try self.makeClient()
                result = try await self.loginWithPassword(
                    client: client,
                    account: self.account.trimmed,
                    password: self.password
                )
            }
            rememberLoginResult(result, fallbackAccount: account.trimmed)
            password = ""
            await self.syncPushDeviceTokenIfPossible()

            let dashboard = try await self.fetchDashboard(selectedSN: self.dashboard.selectedSN)
            let archivedDashboard = self.saveDashboard(dashboard)
            await self.cacheVehicleImages(for: archivedDashboard)
            await self.refreshResolvedAddressesIfNeeded(for: archivedDashboard)
            self.errorMessage = nil
            self.statusMessage = "登录成功"
        }
    }

    func sendSMSCode() async {
        await runLoadingOperation(message: "正在发送验证码") {
            guard !account.trimmed.isEmpty else { throw NinebotInputError.missingAccount }
            guard self.dataSourceMode != .official else { throw NinebotInputError.officialPasswordOnly }

            saveConfiguration()
            let client = try makeClient()
            if dataSourceMode == .platform {
                try await client.sendPlatformLoginCode(account: account.trimmed)
            } else {
                try await client.sendLoginCode(account: account.trimmed)
            }
            self.errorMessage = nil
            self.statusMessage = "验证码已发送"
        }
    }

    func consumeSMSCode() async {
        await runLoadingOperation(message: "正在验证码登录") {
            guard !account.trimmed.isEmpty else { throw NinebotInputError.missingAccount }
            guard !smsCode.trimmed.isEmpty else { throw NinebotInputError.missingCode }
            guard self.dataSourceMode != .official else { throw NinebotInputError.officialPasswordOnly }

            saveConfiguration()
            let client = try makeClient()
            let result = try await consumeLoginCode(client: client, account: account.trimmed, code: smsCode.trimmed)
            rememberLoginResult(result, fallbackAccount: account.trimmed)
            smsCode = ""
            await self.syncPushDeviceTokenIfPossible()

            let dashboard = try await self.fetchDashboard(selectedSN: self.dashboard.selectedSN)
            let archivedDashboard = self.saveDashboard(dashboard)
            await self.cacheVehicleImages(for: archivedDashboard)
            await self.refreshResolvedAddressesIfNeeded(for: archivedDashboard)
            self.errorMessage = nil
            self.statusMessage = "登录成功"
        }
    }

    func selectVehicle(sn: String) {
        dashboard.selectedSN = sn
        saveDashboard(dashboard)
    }

    /// Saves a friendly local display name without changing the vehicle's server
    /// identifier. The name is shared with the widget and Live Activity.
    func saveVehicleDisplayName(_ name: String, for sn: String) {
        NinebotVehicleNameResolver.saveAlias(name, for: sn)
        objectWillChange.send()
        NinebotChargeLiveActivityManager.sync(with: dashboard)
        WidgetCenter.shared.reloadAllTimelines()
        statusMessage = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "已恢复车辆默认名称" : "车辆名称已更新"
    }

    func perform(_ action: NinebotVehicleAction, sn: String) async {
        activeVehicleAction = action
        activeVehicleActionSN = sn
        defer {
            activeVehicleAction = nil
            activeVehicleActionSN = nil
        }

        await runLoadingOperation(message: action.loadingTitle) {
            guard self.dataSourceMode != .official else {
                throw NinebotInputError.officialReadOnly
            }
            let client = try makeClient()
            switch action {
            case .bell:
                _ = try await client.ringBell(sn: sn)
            case .openBucket:
                _ = try await client.openBucket(sn: sn)
            case .engineStart:
                _ = try await client.engineStart(sn: sn)
            case .engineStop:
                _ = try await client.engineStop(sn: sn)
            }

            self.statusMessage = action.resultTitle
            self.errorMessage = nil

            let dashboard = try await self.fetchDashboard(selectedSN: sn)
            let archivedDashboard = self.saveDashboard(dashboard)
            await self.cacheVehicleImages(for: archivedDashboard)
            await self.refreshResolvedAddressesIfNeeded(for: archivedDashboard)
        }
    }

    func history(for sn: String) -> [NinebotVehicleHistoryPoint] {
        history[sn] ?? []
    }

    func recordedRides(for sn: String?) -> [NinebotRecordedRide] {
        recordedRides.filter { ride in
            guard let sn else { return true }
            return ride.vehicleSN == nil || ride.vehicleSN == sn
        }
    }

    func recordedRide(associatedWith rideID: String, vehicleSN: String?) -> NinebotRecordedRide? {
        recordedRides.first { ride in
            ride.associatedRideID == rideID && (vehicleSN == nil || ride.vehicleSN == nil || ride.vehicleSN == vehicleSN)
        }
    }

    func rideDetail(vehicleSN: String, rideID: String) -> NinebotRideDetail? {
        rideDetails[rideDetailKey(vehicleSN: vehicleSN, rideID: rideID)]
    }

    func isLoadingRideDetail(vehicleSN: String, rideID: String) -> Bool {
        loadingRideDetailKeys.contains(rideDetailKey(vehicleSN: vehicleSN, rideID: rideID))
    }

    func refreshRideDetail(vehicleSN: String, rideID: String, force: Bool = false) async {
        let key = rideDetailKey(vehicleSN: vehicleSN, rideID: rideID)
        guard force || rideDetails[key] == nil else { return }
        guard !loadingRideDetailKeys.contains(key) else { return }

        loadingRideDetailKeys.insert(key)
        defer {
            loadingRideDetailKeys.remove(key)
        }

        do {
            guard dataSourceMode != .official else {
                throw NinebotInputError.officialReadOnly
            }
            let client = try makeClient()
            let detail = try await client.fetchTravelDetail(sn: vehicleSN, travelID: rideID)
            rideDetails[key] = detail
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveRecordedRide(_ ride: NinebotRecordedRide) {
        store.upsertRecordedRide(ride)
        recordedRides = store.loadRecordedRides()
        statusMessage = "骑行记录已保存"
    }

    func deleteRecordedRide(id: String) {
        store.deleteRecordedRide(id: id)
        recordedRides = store.loadRecordedRides()
        statusMessage = "骑行记录已删除"
    }

    func resolvedAddressText(for snapshot: NinebotVehicleSnapshot) -> String? {
        return resolvedAddresses[snapshot.vehicle.sn]?.address
    }

    func clearMessages() {
        errorMessage = nil
        statusMessage = nil
    }

    func diagnosticsSnapshot() -> NinebotDiagnosticsSnapshot {
        let vehicles = dashboard.vehicles
        let interfaceRideCount = vehicles.reduce(0) { count, snapshot in
            count + store.interfaceRideCount(sn: snapshot.vehicle.sn)
        }
        let historyPointCount = vehicles.reduce(0) { count, snapshot in
            count + store.historyCount(sn: snapshot.vehicle.sn)
        }

        return NinebotDiagnosticsSnapshot(
            hasConfiguration: hasConfiguration,
            proxyText: diagnosticsConnectionText,
            accountText: currentAccountDisplay,
            vehicleCount: vehicles.count,
            selectedVehicleName: dashboard.primaryVehicle?.vehicle.displayName ?? "暂无车辆",
            dashboardUpdatedAt: dashboard.updatedAt == .distantPast ? nil : dashboard.updatedAt,
            lastAppRefreshEvent: store.loadLastAppRefreshEvent(),
            lastWidgetRefreshEvent: store.loadLastWidgetRefreshEvent(),
            lastError: errorMessage ?? store.loadLastError(),
            interfaceRideCount: interfaceRideCount,
            historyPointCount: historyPointCount,
            recordedRideCount: store.recordedRideCount(),
            rideDetailCount: rideDetails.count,
            resolvedAddressCount: resolvedAddresses.count,
            dashboardCacheBytes: store.storedDashboardByteCount()
        )
    }

    private var currentConfiguration: NinebotProxyConfiguration {
        NinebotProxyConfiguration(
            baseURLString: baseURLString,
            bearerToken: bearerToken,
            appSessionToken: dataSourceMode == .platform ? loginResult?.sessionToken : nil
        )
    }

    private var diagnosticsConnectionText: String {
        if dataSourceMode == .official {
            return "九号官方直连"
        }
        return baseURLString.trimmed.isEmpty ? "\(dataSourceMode.shortTitle)未配置" : "\(dataSourceMode.shortTitle) · \(baseURLString.trimmed)"
    }

    private func makeClient() throws -> NinebotProxyClient {
        guard dataSourceMode != .official else {
            throw NinebotInputError.officialReadOnly
        }
        let configuration = currentConfiguration
        guard configuration.isUsable else {
            throw NinebotInputError.missingProxy
        }
        store.saveDataSourceMode(dataSourceMode)
        store.saveConfiguration(configuration)
        return NinebotProxyClient(configuration: configuration)
    }

    private func requireOfficialSession() throws -> NinebotOfficialSession {
        guard let session = officialSessionStore.load(), session.isUsable else {
            throw NinebotOfficialError.missingSession
        }
        return session
    }

    private func fetchDashboard(selectedSN: String?) async throws -> NinebotDashboard {
        if dataSourceMode == .official {
            return try await NinebotOfficialClient().fetchDashboard(
                session: requireOfficialSession(),
                selectedSN: selectedSN
            )
        }
        return try await makeClient().fetchDashboard(selectedSN: selectedSN)
    }

    private func fetchLiveDashboard(from cached: NinebotDashboard) async throws -> NinebotDashboard {
        if dataSourceMode == .official {
            return try await NinebotOfficialClient().fetchLiveDashboard(
                session: requireOfficialSession(),
                from: cached
            )
        }
        return try await makeClient().fetchLiveDashboard(from: cached)
    }

    private func rideDetailKey(vehicleSN: String, rideID: String) -> String {
        "\(vehicleSN)|\(rideID)"
    }

    private func loginWithPassword(client: NinebotProxyClient, account: String, password: String) async throws -> NinebotLoginResult {
        if dataSourceMode == .platform {
            return try await client.platformLogin(account: account, password: password)
        }
        return try await client.login(account: account, password: password)
    }

    private func consumeLoginCode(client: NinebotProxyClient, account: String, code: String) async throws -> NinebotLoginResult {
        if dataSourceMode == .platform {
            return try await client.consumePlatformLoginCode(account: account, code: code)
        }
        return try await client.consumeLoginCode(account: account, code: code)
    }

    @discardableResult
    private func saveDashboard(_ dashboard: NinebotDashboard, reloadWidgets: Bool = true) -> NinebotDashboard {
        let archivedDashboard = store.saveDashboard(dashboard)
        self.dashboard = archivedDashboard
        history = Self.historyMap(for: archivedDashboard, store: store)
        NinebotChargeLiveActivityManager.sync(with: archivedDashboard)
        NinebotPushManager.shared.syncVehicleAlarmNotifications(with: archivedDashboard)

        // The App is the single writer for the App Group snapshot. Explicit
        // refreshes reload WidgetKit after saving; the five-second foreground
        // pulse opts out and uses its rate-limited request below instead.
        if reloadWidgets {
            WidgetCenter.shared.reloadAllTimelines()
        }
        return archivedDashboard
    }

    private func refreshResolvedAddressesIfNeeded(for dashboard: NinebotDashboard) async {
        try? await resolveAddresses(for: dashboard, force: false)
    }

    private func cacheVehicleImages(for dashboard: NinebotDashboard) async {
        for snapshot in dashboard.vehicles {
            guard let urlString = snapshot.vehicle.imageURLString?.trimmed,
                  !urlString.isEmpty,
                  let url = URL(string: urlString) else {
                continue
            }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode),
                      !data.isEmpty,
                      data.count <= 2_500_000 else {
                    continue
                }
                store.saveVehicleImageData(data, sn: snapshot.vehicle.sn)
            } catch {
                continue
            }
        }
    }

    private func resolveAddresses(for dashboard: NinebotDashboard, force: Bool) async throws {
        let geocoder = AppleReverseGeocoder()
        var nextAddresses = resolvedAddresses
        var didResolve = false
        var lastError: Error?
        var sawCoordinate = false

        for snapshot in dashboard.vehicles {
            guard let latitude = snapshot.state.latitude,
                  let longitude = snapshot.state.longitude else {
                continue
            }

            sawCoordinate = true
            if !force, let cached = nextAddresses[snapshot.vehicle.sn],
               isFreshAddress(cached, latitude: latitude, longitude: longitude) {
                continue
            }

            do {
                let geocodeCoordinate = NinebotCoordinateTransform.gcj02Coordinate(latitude: latitude, longitude: longitude)
                let address = try await geocoder.reverseGeocode(
                    latitude: geocodeCoordinate.latitude,
                    longitude: geocodeCoordinate.longitude
                )
                nextAddresses[snapshot.vehicle.sn] = NinebotResolvedAddress(
                    sn: snapshot.vehicle.sn,
                    address: address,
                    latitude: latitude,
                    longitude: longitude,
                    updatedAt: Date(),
                    source: Self.addressGeocodingSource
                )
                didResolve = true
            } catch {
                lastError = error
            }
        }

        resolvedAddresses = nextAddresses
        store.saveResolvedAddresses(nextAddresses)

        if force, !didResolve {
            if let lastError {
                throw lastError
            }
            if !sawCoordinate {
                throw AppleGeocodingError.missingCoordinate
            }
        }
    }

    private func isFreshAddress(
        _ address: NinebotResolvedAddress,
        latitude: Double,
        longitude: Double
    ) -> Bool {
        let sameCoordinate = abs(address.latitude - latitude) < 0.00001
            && abs(address.longitude - longitude) < 0.00001
        return sameCoordinate && Date().timeIntervalSince(address.updatedAt) < 15 * 60
    }

    private func rememberLoginResult(_ result: NinebotLoginResult, fallbackAccount: String) {
        var resolvedResult = result
        if resolvedResult.phone?.trimmed.isEmpty != false {
            resolvedResult.phone = fallbackAccount
        }
        loginResult = resolvedResult
        account = resolvedResult.phone ?? fallbackAccount
        store.saveLoginResult(resolvedResult)
        if dataSourceMode == .platform {
            store.saveConfiguration(currentConfiguration)
        }
    }

    private func runLoadingOperation(message: String, _ operation: () async throws -> Void) async {
        let startedAt = Date()
        loadingMessage = message
        isLoading = true

        do {
            try await operation()
            store.saveLastAppRefreshEvent(NinebotRefreshEvent(
                source: "App",
                operation: message,
                startedAt: startedAt,
                endedAt: Date(),
                success: true,
                message: statusMessage
            ))
        } catch {
            let message = error.localizedDescription
            errorMessage = message
            statusMessage = nil
            store.saveLastError(message)
            store.saveLastAppRefreshEvent(NinebotRefreshEvent(
                source: "App",
                operation: self.loadingMessage ?? "操作",
                startedAt: startedAt,
                endedAt: Date(),
                success: false,
                message: message
            ))
        }

        isLoading = false
        loadingMessage = nil
    }

    private static func displayMonth(_ month: String) -> String {
        guard month.count == 6 else { return month }
        let year = month.prefix(4)
        let monthValue = month.suffix(2)
        return "\(year)年\(monthValue)月"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let addressGeocodingSource = "apple-mapkit"

    private static func historyMap(
        for dashboard: NinebotDashboard,
        store: NinebotSharedStore
    ) -> [String: [NinebotVehicleHistoryPoint]] {
        Dictionary(uniqueKeysWithValues: dashboard.vehicles.map { snapshot in
            (snapshot.vehicle.sn, store.loadHistory(sn: snapshot.vehicle.sn))
        })
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum AppleGeocodingError: LocalizedError {
    case invalidResponse
    case missingCoordinate

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Apple 地址解析返回无效"
        case .missingCoordinate:
            return "车辆暂未返回可解析的坐标"
        }
    }
}

private struct AppleReverseGeocoder {
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> String {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.reverseGeocodeLocation(
            location,
            preferredLocale: Locale(identifier: "zh_CN")
        )
        let address = Self.addressText(from: placemarks.first)
        guard !address.isEmpty else {
            throw AppleGeocodingError.invalidResponse
        }
        return address
    }

    private static func addressText(from placemark: CLPlacemark?) -> String {
        guard let placemark else { return "" }
        let candidates = [
            placemark.name,
            placemark.thoroughfare,
            placemark.locality,
            placemark.administrativeArea,
            placemark.country
        ]

        let parts = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return parts.joined(separator: " · ")
    }
}
