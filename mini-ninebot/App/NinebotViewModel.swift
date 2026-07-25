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
    case missingAppToken
    case platformSMSUnsupported
    case platformOnly

    var errorDescription: String? {
        switch self {
        case .missingProxy:
            return "请先填写服务地址"
        case .missingAccount:
            return "请填写九号账号或手机号"
        case .missingPassword:
            return "请填写密码"
        case .missingCode:
            return "请填写验证码"
        case .missingAppToken:
            return "App Bearer Token 仅在你的服务端开启鉴权时才需要填写"
        case .platformSMSUnsupported:
            return "平台服务当前使用手机号密码登录；短信验证码请切换代理模式使用"
        case .platformOnly:
            return "请切换到平台服务后再拉取历史行程"
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
    @Published var dataSourceMode: NinebotDataSourceMode = .proxy
    @Published var baseURLString = ""
    @Published var bearerToken = ""
    @Published var account = ""
    @Published var areaCode = "86"
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
    @Published private(set) var activeRideSession: NinebotActiveRideSession?
    @Published private(set) var rideDetails: [String: NinebotRideDetail] = [:]
    @Published private(set) var loadingRideDetailKeys: Set<String> = []
    @Published private(set) var syncingTravelMonth: String?

    private let store = NinebotSharedStore()
    private var lastAutomaticRefreshAt: Date?
    private var lastWidgetTimelineRefreshAt: Date?
    /// 最近一帧 BLE 遥测；仅用于避免网络轮询覆盖正在进行的本地骑行。
    private var latestBLETelemetry: NinebotBLETelemetry?
    /// 仅用于状态边沿通知（开始充电、低电量等），不会保存原始 BLE 数据。
    private var lastNotificationBLETelemetryByVehicle: [String: NinebotBLETelemetry] = [:]
    private var lastBLERideSessionPersistenceAt: Date = .distantPast
    /// 用户主动结束后，在车辆下一次明确停止前不重新创建骑行 Live Activity。
    private var manuallyEndedRideVehicleSN: String?

    init() {
        let configuration = store.loadConfiguration()
        let loginResult = store.loadLoginResult()
        self.dataSourceMode = store.loadDataSourceMode()
        self.baseURLString = configuration?.baseURLString ?? ""
        self.bearerToken = configuration?.bearerToken ?? ""
        self.loginResult = loginResult
        self.account = loginResult?.phone ?? ""
        self.areaCode = Self.normalizedAreaCode(loginResult?.areaCode) ?? "86"
        self.pushDeviceToken = store.loadPushDeviceToken()
        self.dashboard = store.loadDashboard() ?? .empty
        self.errorMessage = store.loadLastError()
        self.history = Self.historyMap(for: self.dashboard, store: store)
        self.resolvedAddresses = store.loadResolvedAddresses().filter { $0.value.source == Self.addressGeocodingSource }
        self.recordedRides = store.loadRecordedRides()
        self.activeRideSession = store.loadActiveRideSession()
        reconcileRideSession(with: self.dashboard)
    }

    var hasConfiguration: Bool {
        currentConfiguration.isUsable
    }

    var isConnectionInputComplete: Bool {
        !baseURLString.trimmed.isEmpty
    }

    var dataSourceStatusTitle: String {
        hasConfiguration ? "\(dataSourceMode.shortTitle)已配置" : "未配置\(dataSourceMode.shortTitle)"
    }

    var dataSourceStatusDetail: String {
        let value = baseURLString.trimmed
        if !value.isEmpty {
            if dataSourceMode == .platform, bearerToken.trimmed.isEmpty {
                return "\(value) · 连接服务"
            }
            return value
        }
        return dataSourceMode == .platform ? "填写服务地址后读取车辆数据" : "填写代理地址后读取车辆数据"
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
        return hasPhone
    }

    var loginAccountCount: Int {
        dataSourceMode == .platform ? dashboard.vehicles.count : (hasLoginAccount ? 1 : 0)
    }

    var isAddressGeocodingEnabled: Bool {
        true
    }

    /// Foreground dashboard refresh cadence. Riding Lock Screen Live Activity
    /// updates are disabled; charging remains more responsive because battery
    /// progress changes fast.
    var foregroundRefreshInterval: TimeInterval {
        if dashboard.primaryVehicle?.state.isCharging == true { return 5 }
        return 8
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
        guard !isLoading else { return }

        let now = Date()
        if let lastAutomaticRefreshAt, now.timeIntervalSince(lastAutomaticRefreshAt) < foregroundRefreshInterval {
            return
        }

        lastAutomaticRefreshAt = now
        await refreshDashboard()
    }

    func saveConfiguration() {
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
            let client = try makeClient()
            try await client.healthCheck()
            self.errorMessage = nil
            self.statusMessage = "\(self.dataSourceMode.shortTitle)连接正常"
        }
    }

    func refreshLoginToken() async {
        await runLoadingOperation(message: "正在刷新登录状态") {
            let client = try makeClient()
            try await client.refreshAccessToken()
            self.errorMessage = nil
            self.statusMessage = "登录状态已刷新"
        }
    }

    func refreshDashboard() async {
        await runLoadingOperation(message: "正在刷新车况") {
            let client = try makeClient()
            let dashboard = try await client.fetchDashboard(selectedSN: self.dashboard.selectedSN)
            let archivedDashboard = self.saveDashboard(dashboard)
            await self.cacheVehicleImages(for: archivedDashboard)
            await self.refreshResolvedAddressesIfNeeded(for: archivedDashboard)
            self.errorMessage = nil
            self.statusMessage = "已更新 \(Self.timeFormatter.string(from: archivedDashboard.updatedAt))"
        }
    }

    /// Foreground-only fast refresh for the dashboard.
    /// It fetches status and battery endpoints only, does not show a loading
    /// overlay, and keeps the last known values when the network has a blip.
    func refreshDashboardSilently() async {
        guard hasConfiguration, !isLoading else { return }

        do {
            let client = try makeClient()
            let dashboard = try await client.fetchLiveDashboard(from: self.dashboard)
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

            let dashboard = try await client.fetchDashboard(selectedSN: vehicleSN)
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
            guard self.dataSourceMode == .platform, !self.bearerToken.trimmed.isEmpty else {
                throw NinebotInputError.missingAppToken
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
            guard self.dataSourceMode == .platform, !self.bearerToken.trimmed.isEmpty else {
                throw NinebotInputError.missingAppToken
            }
            _ = try await NinebotPushManager.shared.requestAuthorizationRegisterAndWaitForToken()
            self.pushDeviceToken = self.store.loadPushDeviceToken()
            try await NinebotPushManager.shared.registerStoredTokenWithServer()
            self.statusMessage = "设备 Token 已上报"
            self.errorMessage = nil
        }
    }

    func syncPushDeviceTokenIfPossible() async {
        guard dataSourceMode == .platform, hasConfiguration, !bearerToken.trimmed.isEmpty else { return }
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

            saveConfiguration()
            let client = try makeClient()
            let result = try await loginWithPassword(client: client, account: account.trimmed, password: password)
            rememberLoginResult(result, fallbackAccount: account.trimmed)
            password = ""
            await self.syncPushDeviceTokenIfPossible()

            let dashboard = try await makeClient().fetchDashboard(selectedSN: self.dashboard.selectedSN)
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

            saveConfiguration()
            let client = try makeClient()
            if dataSourceMode == .platform {
                throw NinebotInputError.platformSMSUnsupported
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

            saveConfiguration()
            let client = try makeClient()
            let result = try await consumeLoginCode(client: client, account: account.trimmed, code: smsCode.trimmed)
            rememberLoginResult(result, fallbackAccount: account.trimmed)
            smsCode = ""
            await self.syncPushDeviceTokenIfPossible()

            let dashboard = try await makeClient().fetchDashboard(selectedSN: self.dashboard.selectedSN)
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
        reconcileRideSession(with: dashboard)
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

            let dashboard = try await client.fetchDashboard(selectedSN: sn)
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
        baseURLString.trimmed.isEmpty ? "\(dataSourceMode.shortTitle)未配置" : "\(dataSourceMode.shortTitle) · \(baseURLString.trimmed)"
    }

    private func makeClient() throws -> NinebotProxyClient {
        let configuration = currentConfiguration
        guard configuration.isUsable else {
            throw NinebotInputError.missingProxy
        }
        store.saveDataSourceMode(dataSourceMode)
        store.saveConfiguration(configuration)
        return NinebotProxyClient(configuration: configuration)
    }

    private func rideDetailKey(vehicleSN: String, rideID: String) -> String {
        "\(vehicleSN)|\(rideID)"
    }

    private func loginWithPassword(client: NinebotProxyClient, account: String, password: String) async throws -> NinebotLoginResult {
        if dataSourceMode == .platform {
            return try await client.platformLogin(account: account, password: password, areaCode: Self.normalizedAreaCode(areaCode))
        }
        return try await client.login(account: account, password: password)
    }

    private func consumeLoginCode(client: NinebotProxyClient, account: String, code: String) async throws -> NinebotLoginResult {
        if dataSourceMode == .platform {
            throw NinebotInputError.platformSMSUnsupported
        }
        return try await client.consumeLoginCode(account: account, code: code)
    }

    /// 结束当前骑行的 Live Activity 与持久化会话；由“结束骑行”和五分钟自动结束共用。
    func endRideSession(vehicleSN: String?) {
        let resolvedVehicleSN = vehicleSN ?? activeRideSession?.vehicleSN
        manuallyEndedRideVehicleSN = resolvedVehicleSN
        if let session = activeRideSession, session.vehicleSN == resolvedVehicleSN {
            finishRideSession(session, endedAt: .now, telemetry: latestBLETelemetry)
            activeRideSession = nil
            store.clearActiveRideSession()
        }
        NinebotRideLiveActivityManager.end(vehicleSN: resolvedVehicleSN)
    }

    /// BLE 层每秒解析一帧后调用此方法。该方法是 BLE 与 Live Activity 之间的
    /// 唯一桥接点：不依赖某一个车辆型号的 GATT UUID，便于后续替换协议解析器。
    ///
    /// 例：`bleService.onTelemetry = { [weak model] frame in
    ///     Task { @MainActor in model?.ingestBLETelemetry(frame) }
    /// }`
    func ingestBLETelemetry(_ telemetry: NinebotBLETelemetry) {
        let previousTelemetry = lastNotificationBLETelemetryByVehicle[telemetry.vehicleSN]
        latestBLETelemetry = telemetry
        lastNotificationBLETelemetryByVehicle[telemetry.vehicleSN] = telemetry

        let resolvedVehicleName = dashboard.vehicles.first { $0.vehicle.sn == telemetry.vehicleSN }?.vehicle.displayName ?? "Ninebot 电动车"
        NinebotNotificationManager.shared.ingestVehicleTelemetry(telemetry, previous: previousTelemetry)
        NinebotAlarmManager.shared.ingest(telemetry, vehicleName: resolvedVehicleName)

        guard telemetry.isRiding, !telemetry.isCharging else {
            if let session = activeRideSession, session.vehicleSN == telemetry.vehicleSN {
                finishRideSession(session, endedAt: telemetry.receivedAt, telemetry: telemetry)
                store.clearActiveRideSession()
                activeRideSession = nil
            }
            if manuallyEndedRideVehicleSN == telemetry.vehicleSN {
                manuallyEndedRideVehicleSN = nil
            }
            NinebotRideLiveActivityManager.sync(session: nil, telemetry: telemetry)
            return
        }

        // 手动结束后，BLE 仍短暂上报“骑行中”时也不重新展示 Live Activity。
        if manuallyEndedRideVehicleSN == telemetry.vehicleSN {
            NinebotRideLiveActivityManager.end(vehicleSN: telemetry.vehicleSN)
            return
        }

        let snapshot = dashboard.vehicles.first { $0.vehicle.sn == telemetry.vehicleSN }
        let previous = activeRideSession?.vehicleSN == telemetry.vehicleSN
            ? activeRideSession
            : store.loadActiveRideSession().flatMap { $0.vehicleSN == telemetry.vehicleSN ? $0 : nil }
        let startedAt = previous?.startedAt ?? telemetry.receivedAt
        let vehicleName = snapshot?.vehicle.displayName ?? resolvedVehicleName
        let vehicleModel = snapshot?.vehicle.model ?? "电动车"
        let session = NinebotActiveRideSession(
            vehicleSN: telemetry.vehicleSN,
            vehicleName: vehicleName,
            vehicleModel: vehicleModel,
            startedAt: startedAt,
            latestSpeedKmh: telemetry.speedKmh,
            maximumSpeedKmh: max(previous?.maximumSpeedKmh ?? 0, telemetry.speedKmh),
            distanceMeters: telemetry.rideDistanceKm * 1_000,
            startedTotalMileageKm: previous?.startedTotalMileageKm ?? max(telemetry.totalDistanceKm - telemetry.rideDistanceKm, 0),
            updatedAt: telemetry.receivedAt
        )

        activeRideSession = session
        // App Group 写入会触发磁盘 I/O；每 15 秒持久化一次已足够覆盖异常退出，
        // 首帧仍会立即写入，结束骑行则立即清除。
        if previous == nil || telemetry.receivedAt.timeIntervalSince(lastBLERideSessionPersistenceAt) >= 15 {
            store.saveActiveRideSession(session)
            lastBLERideSessionPersistenceAt = telemetry.receivedAt
        }
        NinebotRideLiveActivityManager.sync(session: session, telemetry: telemetry)
    }

    /// Reconciles the persisted riding session from the same remote state that
    /// drives the dashboard scene. Reusing the existing session's `startedAt`
    /// is what prevents the ride clock from resetting after an app relaunch.
    private func reconcileRideSession(with dashboard: NinebotDashboard) {
        // 手动结束只是结束本次会话，不会因下一次常规刷新马上被重新拉起。
        if let manuallyEndedRideVehicleSN,
           let snapshot = dashboard.primaryVehicle,
           snapshot.vehicle.sn == manuallyEndedRideVehicleSN {
            if !isRiding(snapshot) {
                self.manuallyEndedRideVehicleSN = nil
            } else {
                store.clearActiveRideSession()
                activeRideSession = nil
                NinebotRideLiveActivityManager.end(vehicleSN: manuallyEndedRideVehicleSN)
                return
            }
        }

        let freshBLETelemetry: NinebotBLETelemetry? = latestBLETelemetry.flatMap { telemetry in
            guard telemetry.isRiding,
                  !telemetry.isCharging,
                  Date().timeIntervalSince(telemetry.receivedAt) < 5 else {
                return nil
            }
            return telemetry
        }

        guard let snapshot = dashboard.primaryVehicle,
              isRiding(snapshot) || freshBLETelemetry?.vehicleSN == snapshot.vehicle.sn else {
            if let session = activeRideSession {
                finishRideSession(session, endedAt: .now, telemetry: latestBLETelemetry)
                store.clearActiveRideSession()
                activeRideSession = nil
            }
            NinebotRideLiveActivityManager.sync(session: nil, snapshot: nil)
            return
        }

        let previous = activeRideSession ?? store.loadActiveRideSession()
        let isSameVehicle = previous?.vehicleSN == snapshot.vehicle.sn
        let startedAt = isSameVehicle ? previous!.startedAt : Date()
        let startedTotalMileageKm = isSameVehicle
            ? previous?.startedTotalMileageKm
            : snapshot.state.totalMileage
        let liveDistanceMeters = rideDistanceMeters(
            state: snapshot.state,
            startedTotalMileageKm: startedTotalMileageKm
        )
        let session = NinebotActiveRideSession(
            vehicleSN: snapshot.vehicle.sn,
            vehicleName: snapshot.vehicle.displayName,
            vehicleModel: snapshot.vehicle.model,
            startedAt: startedAt,
            latestSpeedKmh: freshBLETelemetry?.speedKmh ?? liveSpeedKmh(from: snapshot.state) ?? previous?.latestSpeedKmh,
            maximumSpeedKmh: max(
                previous?.maximumSpeedKmh ?? 0,
                freshBLETelemetry?.speedKmh ?? liveSpeedKmh(from: snapshot.state) ?? 0
            ),
            distanceMeters: freshBLETelemetry.map { $0.rideDistanceKm * 1_000 } ?? liveDistanceMeters ?? (isSameVehicle ? previous?.distanceMeters : nil),
            startedTotalMileageKm: startedTotalMileageKm,
            updatedAt: freshBLETelemetry?.receivedAt ?? snapshot.state.updatedAt
        )
        store.saveActiveRideSession(session)
        activeRideSession = session
        if let freshBLETelemetry {
            NinebotRideLiveActivityManager.sync(session: session, telemetry: freshBLETelemetry)
        } else {
            NinebotRideLiveActivityManager.sync(session: session, snapshot: snapshot)
        }
    }

    /// 将自动骑行会话转换为与“记录行程”相同的数据模型。车辆定位轨迹从
    /// `NinebotVehicleLocationManager` 读取并随记录持久化，详情页因此可离线回放。
    private func finishRideSession(
        _ session: NinebotActiveRideSession,
        endedAt: Date,
        telemetry: NinebotBLETelemetry?
    ) {
        let telemetry = telemetry?.vehicleSN == session.vehicleSN ? telemetry : nil
        let start = session.startedAt
        let end = max(endedAt, start)
        let recordingID = "live-\(session.vehicleSN)-\(Int(start.timeIntervalSince1970))"
        let alreadySaved = store.loadRecordedRides().contains { $0.id == recordingID }

        let locations = (NinebotVehicleLocationManager.shared.tracks[session.vehicleSN] ?? [])
            .filter { $0.isValid && $0.updatedAt >= start.addingTimeInterval(-10) && $0.updatedAt <= end.addingTimeInterval(10) }
            .sorted { $0.updatedAt < $1.updatedAt }
        let points = locations.enumerated().map { index, location in
            let previous = index > 0 ? locations[index - 1] : nil
            let speed: Double
            if let previous {
                let elapsed = max(location.updatedAt.timeIntervalSince(previous.updatedAt), 1)
                speed = min(NinebotVehicleLocationManager.distanceMeters(previous, location) / elapsed * 3.6, 180)
            } else {
                speed = min(max(session.latestSpeedKmh ?? 0, 0), 180)
            }
            return NinebotRideTrackPoint(
                id: "\(recordingID)-\(Int(location.updatedAt.timeIntervalSince1970))-\(index)",
                date: location.updatedAt,
                latitude: location.latitude,
                longitude: location.longitude,
                speedKmh: speed,
                accelerationG: 0,
                horizontalAccuracy: location.horizontalAccuracy
            )
        }
        let gpsDistanceMeters = zip(locations, locations.dropFirst()).reduce(0.0) { result, pair in
            result + NinebotVehicleLocationManager.distanceMeters(pair.0, pair.1)
        }
        let distanceMeters = max(
            session.distanceMeters ?? 0,
            telemetry.map { $0.rideDistanceKm * 1_000 } ?? 0,
            gpsDistanceMeters
        )
        let duration = max(end.timeIntervalSince(start), 0)
        let averageSpeedKmh = duration > 0 ? distanceMeters / duration * 3.6 : 0
        let maximumSpeedKmh = max(
            session.maximumSpeedKmh ?? 0,
            telemetry?.speedKmh ?? 0,
            points.map(\.speedKmh).max() ?? 0
        )
        let recordedRide = NinebotRecordedRide(
            id: recordingID,
            vehicleSN: session.vehicleSN,
            startedAt: start,
            endedAt: end,
            distanceMeters: distanceMeters,
            maxSpeedKmh: maximumSpeedKmh,
            averageSpeedKmh: averageSpeedKmh,
            maxAccelerationG: 0,
            points: points
        )
        store.upsertRecordedRide(recordedRide)
        recordedRides = store.loadRecordedRides()

        let state = dashboard.vehicles.first { $0.vehicle.sn == session.vehicleSN }?.state
        let summary = RideRecord(
            recordedRide: recordedRide,
            endBatteryPercent: telemetry?.batteryPercent ?? state?.battery,
            remainingRangeKm: telemetry?.remainingRangeKm ?? state?.endurance ?? state?.aiEstimatedMileage
        )
        RideHistoryManager.shared.upsert(summary)
        if !alreadySaved {
            NinebotNotificationManager.shared.sendRideCompletedNotification(for: summary)
        }
    }

    private func isRiding(_ snapshot: NinebotVehicleSnapshot) -> Bool {
        guard snapshot.state.isCharging != true || snapshot.state.isFullyCharged == true else {
            return false
        }
        let movementKeys = ["isRiding", "riding", "isMoving", "moving", "inMotion", "driving"]
        if movementKeys.contains(where: { snapshot.state.rawStatus?[$0]?.boolValue == true }) {
            return true
        }
        return snapshot.state.isPoweredOn == true && snapshot.state.isLocked != true
    }

    /// Calculates the in-progress trip distance from the odometer values the
    /// App already refreshes during a ride. The persisted start reading keeps
    /// the value continuous when the App is relaunched.
    private func rideDistanceMeters(
        state: NinebotVehicleState,
        startedTotalMileageKm: Double?
    ) -> Double? {
        guard let startedTotalMileageKm,
              let totalMileageKm = state.totalMileage,
              totalMileageKm.isFinite,
              startedTotalMileageKm.isFinite,
              totalMileageKm >= startedTotalMileageKm else {
            return nil
        }
        return (totalMileageKm - startedTotalMileageKm) * 1_000
    }

    private func liveSpeedKmh(from state: NinebotVehicleState) -> Double? {
        let keys = ["speed", "currentSpeed", "current_speed", "speedKmh", "speed_kmh", "velocity"]
        for key in keys {
            guard let value = state.rawStatus?[key]?.doubleValue,
                  value.isFinite,
                  (0...180).contains(value) else {
                continue
            }
            return value
        }
        return nil
    }

    @discardableResult
    private func saveDashboard(_ dashboard: NinebotDashboard, reloadWidgets: Bool = true) -> NinebotDashboard {
        let archivedDashboard = store.saveDashboard(dashboard)
        self.dashboard = archivedDashboard
        history = Self.historyMap(for: archivedDashboard, store: store)
        reconcileRideSession(with: archivedDashboard)
        NinebotChargeLiveActivityManager.sync(with: archivedDashboard)
        NinebotPushManager.shared.syncVehicleAlarmNotifications(with: archivedDashboard)
        syncDashboardVehicleLocations(for: archivedDashboard)

        // The App is the single writer for the App Group snapshot. Explicit
        // refreshes reload WidgetKit after saving; the five-second foreground
        // pulse opts out and uses its rate-limited request below instead.
        if reloadWidgets {
            WidgetCenter.shared.reloadAllTimelines()
        }
        return archivedDashboard
    }

    /// 车况接口本身已包含经纬度；即使 BLE 的 security.location 还未上报，
    /// 安全页、围栏和导航也应使用这份已存在的车辆定位。
    private func syncDashboardVehicleLocations(for dashboard: NinebotDashboard) {
        for snapshot in dashboard.vehicles {
            let state = snapshot.state
            guard let latitude = state.latitude,
                  let longitude = state.longitude,
                  (-90...90).contains(latitude),
                  (-180...180).contains(longitude) else {
                continue
            }
            let location = NinebotVehicleLocation(
                latitude: latitude,
                longitude: longitude,
                updatedAt: state.updatedAt
            )
            NinebotVehicleLocationManager.shared.ingest(
                location,
                vehicleSN: snapshot.vehicle.sn,
                isRiding: isRiding(snapshot)
            )
            NinebotGeofenceManager.shared.ingestVehicleLocation(
                location,
                vehicleSN: snapshot.vehicle.sn,
                vehicleName: snapshot.vehicle.displayName
            )
        }
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

    private static func normalizedAreaCode(_ value: String?) -> String? {
        let clean = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "+"))
        return clean.isEmpty ? nil : clean
    }

    private func rememberLoginResult(_ result: NinebotLoginResult, fallbackAccount: String) {
        var resolvedResult = result
        if resolvedResult.phone?.trimmed.isEmpty != false {
            resolvedResult.phone = fallbackAccount
        }
        if resolvedResult.areaCode?.trimmed.isEmpty != false, dataSourceMode == .platform {
            resolvedResult.areaCode = Self.normalizedAreaCode(areaCode)
        }
        loginResult = resolvedResult
        account = resolvedResult.phone ?? fallbackAccount
        if let resolvedAreaCode = Self.normalizedAreaCode(resolvedResult.areaCode) {
            areaCode = resolvedAreaCode
        }
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
