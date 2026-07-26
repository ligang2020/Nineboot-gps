import Combine
@preconcurrency import CoreBluetooth
import Foundation

/// 蓝牙传输层的公开连接状态。它只描述本机蓝牙与已授权车辆的连接，不代表
/// 九号账号、车辆所有权或远程服务在线状态。
enum NinebotBLEConnectionState: Equatable, Sendable {
    case idle
    case bluetoothUnavailable(NinebotBLEAvailability)
    case scanning
    case awaitingAuthorizedProfile
    case connecting
    case discoveringServices
    case subscribing
    case connected
    case disconnected(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "蓝牙待命"
        case .bluetoothUnavailable(let availability): return availability.title
        case .scanning: return "正在扫描附近设备"
        case .awaitingAuthorizedProfile: return "等待授权车辆配置"
        case .connecting: return "正在连接已授权车辆"
        case .discoveringServices: return "正在验证车辆服务"
        case .subscribing: return "正在订阅实时数据"
        case .connected: return "车辆蓝牙已连接"
        case .disconnected: return "车辆蓝牙已断开"
        case .failed: return "蓝牙连接失败"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "仅扫描或连接你明确授权的设备"
        case .bluetoothUnavailable(let availability):
            return availability.detail
        case .scanning:
            return "扫描不会自动连接，也不会发送车辆指令"
        case .awaitingAuthorizedProfile:
            return "尚未提供官方 GATT 服务、特征和认证适配器"
        case .connecting:
            return "仅允许连接已信任的外设标识"
        case .discoveringServices:
            return "仅发现授权配置内的只读遥测服务"
        case .subscribing:
            return "仅读取 Notify / Indicate 遥测，不写入任何特征"
        case .connected:
            return "仅实时订阅已授权的只读遥测特征"
        case .disconnected(let reason), .failed(let reason):
            return reason
        }
    }

    var systemImage: String {
        switch self {
        case .idle, .awaitingAuthorizedProfile: return "bluetooth"
        case .bluetoothUnavailable: return "bluetooth.slash"
        case .scanning: return "dot.radiowaves.left.and.right"
        case .connecting, .discoveringServices, .subscribing: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.circle.fill"
        case .disconnected: return "bolt.slash.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var isBusy: Bool {
        switch self {
        case .scanning, .connecting, .discoveringServices, .subscribing:
            return true
        default:
            return false
        }
    }
}

enum NinebotBLEAvailability: Equatable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff

    var title: String {
        switch self {
        case .unknown: return "正在检查蓝牙状态"
        case .resetting: return "蓝牙正在重置"
        case .unsupported: return "此设备不支持蓝牙"
        case .unauthorized: return "未授予蓝牙权限"
        case .poweredOff: return "蓝牙未开启"
        }
    }

    var detail: String {
        switch self {
        case .unknown: return "等待系统蓝牙服务就绪"
        case .resetting: return "请等待系统完成蓝牙重置"
        case .unsupported: return "需要支持 Bluetooth Low Energy 的 iPhone 或 iPad"
        case .unauthorized: return "请在系统设置中允许本 App 使用蓝牙"
        case .poweredOff: return "请开启系统蓝牙后再扫描车辆"
        }
    }
}

/// 由获得厂商授权的适配器提供的只读 GATT 描述。
///
/// 不内置任何官方私有 UUID、命令格式、密钥或认证逻辑。只有调用方显式提供
/// 车辆的服务 UUID、可通知遥测特征 UUID 和受信任外设标识后，传输层才会连接。
struct NinebotBLEReadOnlyProfile: Hashable, Sendable {
    let vehicleSN: String
    let serviceUUIDStrings: [String]
    let telemetryCharacteristicUUIDStrings: [String]
    let trustedPeripheralIdentifier: UUID?
    let advertisedNamePrefixes: [String]
    let automaticallyReconnects: Bool

    init(
        vehicleSN: String,
        serviceUUIDStrings: [String],
        telemetryCharacteristicUUIDStrings: [String],
        trustedPeripheralIdentifier: UUID? = nil,
        advertisedNamePrefixes: [String] = [],
        automaticallyReconnects: Bool = true
    ) {
        self.vehicleSN = vehicleSN.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serviceUUIDStrings = Self.normalizedUUIDStrings(serviceUUIDStrings)
        self.telemetryCharacteristicUUIDStrings = Self.normalizedUUIDStrings(telemetryCharacteristicUUIDStrings)
        self.trustedPeripheralIdentifier = trustedPeripheralIdentifier
        self.advertisedNamePrefixes = advertisedNamePrefixes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.automaticallyReconnects = automaticallyReconnects
    }

    var isReadOnlyTelemetryConfigured: Bool {
        !vehicleSN.isEmpty
            && !serviceUUIDStrings.isEmpty
            && !telemetryCharacteristicUUIDStrings.isEmpty
    }

    var canConnectAutomatically: Bool {
        isReadOnlyTelemetryConfigured && trustedPeripheralIdentifier != nil
    }

    fileprivate var serviceUUIDs: [CBUUID] {
        serviceUUIDStrings.map(CBUUID.init(string:))
    }

    fileprivate var telemetryCharacteristicUUIDs: Set<CBUUID> {
        Set(telemetryCharacteristicUUIDStrings.map(CBUUID.init(string:)))
    }

    fileprivate func matchesAdvertisement(
        peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) -> Bool {
        if let trustedPeripheralIdentifier, peripheral.identifier == trustedPeripheralIdentifier {
            return true
        }

        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        let matchesName = advertisedNamePrefixes.contains { prefix in
            advertisedName.range(
                of: prefix,
                options: [.caseInsensitive, .anchored],
                range: nil,
                locale: .current
            ) != nil
        }
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let matchesService = !Set(advertisedServices).isDisjoint(with: Set(serviceUUIDs))
        return matchesName || matchesService
    }

    private static func normalizedUUIDStrings(_ values: [String]) -> [String] {
        Array(Set(values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }.filter { !$0.isEmpty })).sorted()
    }
}

/// 仅用于扫描结果展示。它不包含配对凭据、蓝牙钥匙或车辆认证材料。
struct NinebotBLEDiscoveredPeripheral: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var rssi: Int
    var advertisedServiceUUIDStrings: [String]
    var lastSeenAt: Date
    var matchesAuthorizedProfile: Bool

    var displayName: String {
        name.isEmpty ? "未命名蓝牙设备" : name
    }

    var signalTitle: String {
        switch rssi {
        case -60...0: return "信号强"
        case -75 ..< -60: return "信号中"
        default: return "信号弱"
        }
    }
}

/// 遥测原始包。适配器必须用厂商授权的格式把它解码为 `NinebotBLETelemetry`。
struct NinebotBLETelemetryPacket: Sendable {
    let vehicleSN: String
    let peripheralIdentifier: UUID
    let serviceUUIDString: String
    let characteristicUUIDString: String
    let payload: Data
    let receivedAt: Date
}

/// 只读、安全优先的 CoreBluetooth 基础层。
///
/// 安全约束：
/// - 绝不写入 Characteristic，也不暴露写指令 API；
/// - 不保存密码、蓝牙钥匙、认证 token 或私有协议数据；
/// - 未提供受信任外设 ID 的配置只可用于扫描候选设备，绝不自动连接；
/// - 仅订阅调用方在授权 profile 中明确列出的 Notify / Indicate 遥测特征。
final class NinebotBLETransport: NSObject, ObservableObject {
    typealias TelemetryDecoder = (NinebotBLETelemetryPacket) -> NinebotBLETelemetry?

    @Published private(set) var connectionState: NinebotBLEConnectionState = .idle
    @Published private(set) var discoveredPeripherals: [NinebotBLEDiscoveredPeripheral] = []
    @Published private(set) var lastTelemetryAt: Date?
    @Published private(set) var lastErrorMessage: String?

    /// 由上层把已授权、已解码的遥测送入 `NinebotViewModel`。
    var onTelemetry: ((NinebotBLETelemetry) -> Void)?

    var hasAuthorizedReadOnlyProfile: Bool {
        profile?.canConnectAutomatically == true
    }

    /// 仅供 UI 显示取消扫描入口；不会向外暴露任何连接或控制能力。
    var isScanning: Bool {
        centralManager.isScanning
    }

    private var centralManager: CBCentralManager!
    private var profile: NinebotBLEReadOnlyProfile?
    private var telemetryDecoder: TelemetryDecoder?
    private var connectedPeripheral: CBPeripheral?
    private var manuallyDisconnected = false
    private var reconnectAttempt = 0
    /// `true` 仅用于用户明确发起的“连接授权车辆”兜底扫描；常规扫描永不连接。
    private var connectsWhenTrustedPeripheralIsDiscovered = false
    private var pendingCharacteristicDiscoveryCount = 0
    private var requestedTelemetryNotificationEndpoints = Set<String>()
    private var pendingTelemetryNotificationEndpoints = Set<String>()
    private var activeTelemetryNotificationEndpoints = Set<String>()
    private var characteristicDiscoveryFailureMessage: String?
    private var notificationSubscriptionFailureMessage: String?
    private var scanStopWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        // 使用主队列，保证 @Published 状态、SwiftUI 和 ViewModel 更新在同一线程。
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    deinit {
        scanStopWorkItem?.cancel()
    }

    /// 安装厂商授权的只读遥测描述和解码器。profile 不完整时会保持断开状态。
    func configureAuthorizedReadOnlyProfile(
        _ profile: NinebotBLEReadOnlyProfile,
        decoder: @escaping TelemetryDecoder
    ) {
        disconnect()
        self.profile = profile
        telemetryDecoder = decoder
        discoveredPeripherals.removeAll()
        reconnectAttempt = 0

        if !profile.isReadOnlyTelemetryConfigured {
            connectionState = .awaitingAuthorizedProfile
            lastErrorMessage = "授权 BLE 配置缺少车辆 SN、服务 UUID 或遥测特征 UUID。"
        } else if profile.trustedPeripheralIdentifier == nil {
            connectionState = .awaitingAuthorizedProfile
            lastErrorMessage = "为保护车辆安全，必须先完成明确的外设信任绑定，才会连接。"
        } else if centralManager.state == .poweredOn {
            connectionState = .idle
            lastErrorMessage = nil
        }
    }

    /// 清除当前授权 profile；不会删除任何外部凭据，因为本模块不保存凭据。
    func clearAuthorizedProfile() {
        disconnect()
        profile = nil
        telemetryDecoder = nil
        discoveredPeripherals.removeAll()
        reconnectAttempt = 0
        connectionState = centralManager.state == .poweredOn ? .idle : unavailableState(for: centralManager.state)
    }

    /// 只扫描附近 BLE 设备，不会自动连接、配对或发送任何车辆命令。
    func startDiscovery(timeout: TimeInterval = 10) {
        beginDiscovery(timeout: timeout, connectsToTrustedPeripheral: false)
    }

    func stopDiscovery() {
        scanStopWorkItem?.cancel()
        scanStopWorkItem = nil
        let wasWaitingForTrustedVehicle = connectsWhenTrustedPeripheralIsDiscovered
        connectsWhenTrustedPeripheralIsDiscovered = false
        if centralManager.isScanning {
            centralManager.stopScan()
        }
        if case .scanning = connectionState {
            connectionState = profile?.canConnectAutomatically == true ? .idle : .awaitingAuthorizedProfile
        } else if wasWaitingForTrustedVehicle, case .connecting = connectionState {
            // 用户取消“连接授权车辆”的兜底扫描时，不能继续保持假连接状态。
            connectionState = .idle
        }
    }

    /// 仅由 `connectTrustedVehicle()` 调用。普通“扫描附近设备”永远不使用这条路径。
    private func beginTrustedVehicleDiscovery(timeout: TimeInterval) {
        beginDiscovery(timeout: timeout, connectsToTrustedPeripheral: true)
    }

    private func beginDiscovery(timeout: TimeInterval, connectsToTrustedPeripheral: Bool) {
        guard centralManager.state == .poweredOn else {
            connectionState = unavailableState(for: centralManager.state)
            return
        }

        scanStopWorkItem?.cancel()
        discoveredPeripherals.removeAll()
        lastErrorMessage = nil
        manuallyDisconnected = false
        connectsWhenTrustedPeripheralIsDiscovered = connectsToTrustedPeripheral

        if centralManager.isScanning {
            centralManager.stopScan()
        }
        let services = profile?.serviceUUIDs
        centralManager.scanForPeripherals(
            withServices: services?.isEmpty == false ? services : nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        connectionState = connectsToTrustedPeripheral ? .connecting : .scanning

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let shouldReportTrustedVehicleTimeout = self.connectsWhenTrustedPeripheralIsDiscovered
                && self.connectedPeripheral == nil
                && self.connectionState == .connecting
            self.stopDiscovery()
            guard shouldReportTrustedVehicleTimeout else { return }
            let message = "未在限定时间内发现已授权的车辆蓝牙设备。"
            self.connectionState = .failed(message)
            self.lastErrorMessage = message
            self.scheduleReconnectIfAllowed()
        }
        scanStopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(3, timeout), execute: workItem)
    }

    /// 连接当前 profile 中已明确授权的外设。没有 trustedPeripheralIdentifier 时拒绝连接。
    func connectTrustedVehicle() {
        guard centralManager.state == .poweredOn else {
            connectionState = unavailableState(for: centralManager.state)
            return
        }
        guard let profile, profile.canConnectAutomatically,
              let trustedID = profile.trustedPeripheralIdentifier else {
            connectionState = .awaitingAuthorizedProfile
            lastErrorMessage = "未配置已信任的车辆外设；基础层不会连接未验证设备。"
            return
        }

        manuallyDisconnected = false
        lastErrorMessage = nil
        stopDiscovery()

        if let existing = connectedPeripheral, existing.identifier == trustedID {
            if existing.state == .connected {
                connectionState = .connected
                return
            }
            centralManager.connect(existing)
            connectionState = .connecting
            return
        }

        if let retrieved = centralManager.retrievePeripherals(withIdentifiers: [trustedID]).first {
            connect(retrieved, using: profile)
            return
        }

        // CoreBluetooth 只能从已缓存的 peripheral 实例发起连接；找不到时进行有限时的
        // 授权服务扫描。仅这条由用户明确发起的连接路径可在匹配 trusted ID 后连接。
        beginTrustedVehicleDiscovery(timeout: 10)
    }

    func disconnect() {
        manuallyDisconnected = true
        stopDiscovery()
        reconnectAttempt = 0
        resetTelemetryNegotiationState()
        if let connectedPeripheral {
            centralManager.cancelPeripheralConnection(connectedPeripheral)
        } else if centralManager.state == .poweredOn {
            connectionState = .idle
        }
    }

    private func connect(_ peripheral: CBPeripheral, using profile: NinebotBLEReadOnlyProfile) {
        guard peripheral.identifier == profile.trustedPeripheralIdentifier else {
            connectionState = .failed("拒绝连接未信任的蓝牙设备。")
            return
        }
        stopDiscovery()
        connectedPeripheral = peripheral
        resetTelemetryNegotiationState()
        peripheral.delegate = self
        centralManager.connect(peripheral)
        connectionState = .connecting
    }

    private func unavailableState(for state: CBManagerState) -> NinebotBLEConnectionState {
        switch state {
        case .unknown: return .bluetoothUnavailable(.unknown)
        case .resetting: return .bluetoothUnavailable(.resetting)
        case .unsupported: return .bluetoothUnavailable(.unsupported)
        case .unauthorized: return .bluetoothUnavailable(.unauthorized)
        case .poweredOff: return .bluetoothUnavailable(.poweredOff)
        case .poweredOn: return .idle
        @unknown default: return .bluetoothUnavailable(.unknown)
        }
    }

    private func resetTelemetryNegotiationState() {
        pendingCharacteristicDiscoveryCount = 0
        requestedTelemetryNotificationEndpoints.removeAll()
        pendingTelemetryNotificationEndpoints.removeAll()
        activeTelemetryNotificationEndpoints.removeAll()
        characteristicDiscoveryFailureMessage = nil
        notificationSubscriptionFailureMessage = nil
    }

    private func telemetryEndpoint(for characteristic: CBCharacteristic) -> String? {
        guard let serviceUUID = characteristic.service?.uuid.uuidString else { return nil }
        return "\(serviceUUID.uppercased())/\(characteristic.uuid.uuidString.uppercased())"
    }

    private func subscribeToTelemetry(
        in service: CBService,
        on peripheral: CBPeripheral,
        profile: NinebotBLEReadOnlyProfile
    ) {
        let requestedUUIDs = profile.telemetryCharacteristicUUIDs
        for characteristic in service.characteristics ?? [] where requestedUUIDs.contains(characteristic.uuid) {
            let properties = characteristic.properties
            guard properties.contains(.notify) || properties.contains(.indicate),
                  let endpoint = telemetryEndpoint(for: characteristic) else {
                continue
            }
            requestedTelemetryNotificationEndpoints.insert(endpoint)
            pendingTelemetryNotificationEndpoints.insert(endpoint)
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    /// 在所有 service 和 notification state 回调完成后，才宣布连接成功。这样任一
    /// 授权 service 或遥测特征的发现/订阅失败，都不会被另一个特征的成功回调掩盖。
    private func finalizeTelemetrySubscription() {
        guard pendingCharacteristicDiscoveryCount == 0 else { return }
        if let characteristicDiscoveryFailureMessage {
            connectionState = .failed(characteristicDiscoveryFailureMessage)
            lastErrorMessage = characteristicDiscoveryFailureMessage
            return
        }
        guard !requestedTelemetryNotificationEndpoints.isEmpty else {
            let message = "授权 profile 中没有可订阅的 Notify / Indicate 遥测特征。"
            connectionState = .failed(message)
            lastErrorMessage = message
            return
        }
        if let notificationSubscriptionFailureMessage {
            connectionState = .failed(notificationSubscriptionFailureMessage)
            lastErrorMessage = notificationSubscriptionFailureMessage
            return
        }
        if !pendingTelemetryNotificationEndpoints.isEmpty {
            connectionState = .subscribing
            return
        }
        if activeTelemetryNotificationEndpoints.isEmpty {
            let message = "系统未能启用任何授权遥测通知。"
            connectionState = .failed(message)
            lastErrorMessage = message
        } else {
            connectionState = .connected
            lastErrorMessage = nil
        }
    }

    private func scheduleReconnectIfAllowed() {
        guard !manuallyDisconnected,
              let profile,
              profile.canConnectAutomatically,
              profile.automaticallyReconnects,
              reconnectAttempt < 3,
              centralManager.state == .poweredOn else {
            return
        }

        reconnectAttempt += 1
        let delay = min(pow(2, Double(reconnectAttempt)), 8)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  !self.manuallyDisconnected,
                  self.centralManager.state == .poweredOn else {
                return
            }
            self.connectTrustedVehicle()
        }
    }
}

extension NinebotBLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            stopDiscovery()
            resetTelemetryNegotiationState()
            connectionState = unavailableState(for: central.state)
            return
        }

        switch connectionState {
        case .bluetoothUnavailable, .idle:
            connectionState = profile?.canConnectAutomatically == true ? .idle : .awaitingAuthorizedProfile
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let serviceUUIDStrings = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? [])
            .map(\.uuidString)
            .sorted()
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        let matchesProfile = profile?.matchesAdvertisement(
            peripheral: peripheral,
            advertisementData: advertisementData
        ) ?? false
        let candidate = NinebotBLEDiscoveredPeripheral(
            id: peripheral.identifier,
            name: advertisedName,
            rssi: RSSI.intValue,
            advertisedServiceUUIDStrings: serviceUUIDStrings,
            lastSeenAt: .now,
            matchesAuthorizedProfile: matchesProfile
        )

        if let index = discoveredPeripherals.firstIndex(where: { $0.id == candidate.id }) {
            discoveredPeripherals[index] = candidate
        } else {
            discoveredPeripherals.append(candidate)
        }
        discoveredPeripherals.sort {
            if $0.matchesAuthorizedProfile != $1.matchesAuthorizedProfile {
                return $0.matchesAuthorizedProfile && !$1.matchesAuthorizedProfile
            }
            return $0.rssi > $1.rssi
        }

        guard let profile,
              profile.canConnectAutomatically,
              connectsWhenTrustedPeripheralIsDiscovered,
              peripheral.identifier == profile.trustedPeripheralIdentifier,
              connectionState == .connecting else {
            return
        }
        connect(peripheral, using: profile)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !manuallyDisconnected,
              let profile,
              peripheral.identifier == profile.trustedPeripheralIdentifier else {
            central.cancelPeripheralConnection(peripheral)
            if manuallyDisconnected {
                connectionState = .idle
            } else {
                connectionState = .failed("已连接的设备不在授权 profile 中。")
            }
            return
        }

        connectedPeripheral = peripheral
        resetTelemetryNegotiationState()
        peripheral.delegate = self
        reconnectAttempt = 0
        connectionState = .discoveringServices
        peripheral.discoverServices(profile.serviceUUIDs)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        resetTelemetryNegotiationState()
        connectedPeripheral = nil
        let message = error?.localizedDescription ?? "系统未能建立 BLE 连接。"
        connectionState = .failed(message)
        lastErrorMessage = message
        scheduleReconnectIfAllowed()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        let message = error?.localizedDescription ?? "连接已断开。"
        resetTelemetryNegotiationState()
        connectedPeripheral = nil
        connectionState = .disconnected(message)
        if error != nil {
            lastErrorMessage = message
        }
        scheduleReconnectIfAllowed()
    }
}

extension NinebotBLETransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !manuallyDisconnected,
              let profile,
              peripheral.identifier == profile.trustedPeripheralIdentifier,
              connectedPeripheral?.identifier == peripheral.identifier else {
            return
        }
        if let error {
            connectionState = .failed(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
            return
        }

        let expectedServices = Set(profile.serviceUUIDs)
        let services = (peripheral.services ?? []).filter { expectedServices.contains($0.uuid) }
        guard !services.isEmpty else {
            connectionState = .failed("连接的设备没有授权 profile 声明的遥测服务。")
            return
        }

        resetTelemetryNegotiationState()
        pendingCharacteristicDiscoveryCount = services.count
        connectionState = .discoveringServices
        for service in services {
            peripheral.discoverCharacteristics(Array(profile.telemetryCharacteristicUUIDs), for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard !manuallyDisconnected,
              let profile,
              peripheral.identifier == profile.trustedPeripheralIdentifier,
              connectedPeripheral?.identifier == peripheral.identifier,
              profile.serviceUUIDs.contains(service.uuid) else {
            return
        }
        defer {
            pendingCharacteristicDiscoveryCount = max(0, pendingCharacteristicDiscoveryCount - 1)
            finalizeTelemetrySubscription()
        }
        if let error {
            let message = error.localizedDescription
            characteristicDiscoveryFailureMessage = characteristicDiscoveryFailureMessage ?? message
            lastErrorMessage = message
            return
        }
        subscribeToTelemetry(in: service, on: peripheral, profile: profile)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard !manuallyDisconnected,
              let profile,
              peripheral.identifier == profile.trustedPeripheralIdentifier,
              connectedPeripheral?.identifier == peripheral.identifier,
              let endpoint = telemetryEndpoint(for: characteristic),
              requestedTelemetryNotificationEndpoints.contains(endpoint) else {
            return
        }

        pendingTelemetryNotificationEndpoints.remove(endpoint)
        if let error {
            let message = error.localizedDescription
            notificationSubscriptionFailureMessage = notificationSubscriptionFailureMessage ?? message
            lastErrorMessage = message
            finalizeTelemetrySubscription()
            return
        }
        guard characteristic.isNotifying else {
            let message = "系统未启用授权遥测特征 \(characteristic.uuid.uuidString) 的通知。"
            notificationSubscriptionFailureMessage = notificationSubscriptionFailureMessage ?? message
            lastErrorMessage = message
            finalizeTelemetrySubscription()
            return
        }

        activeTelemetryNotificationEndpoints.insert(endpoint)
        finalizeTelemetrySubscription()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            lastErrorMessage = error.localizedDescription
            return
        }
        guard case .connected = connectionState else { return }
        guard !manuallyDisconnected,
              let profile,
              peripheral.identifier == profile.trustedPeripheralIdentifier,
              connectedPeripheral?.identifier == peripheral.identifier,
              let payload = characteristic.value,
              profile.telemetryCharacteristicUUIDs.contains(characteristic.uuid),
              let serviceUUID = characteristic.service?.uuid.uuidString,
              profile.serviceUUIDs.contains(CBUUID(string: serviceUUID)) else {
            return
        }

        let packet = NinebotBLETelemetryPacket(
            vehicleSN: profile.vehicleSN,
            peripheralIdentifier: peripheral.identifier,
            serviceUUIDString: serviceUUID,
            characteristicUUIDString: characteristic.uuid.uuidString,
            payload: payload,
            receivedAt: .now
        )
        guard let telemetry = telemetryDecoder?(packet) else { return }
        lastTelemetryAt = telemetry.receivedAt
        onTelemetry?(telemetry)
    }
}
