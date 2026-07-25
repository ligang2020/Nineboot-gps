import BackgroundTasks
import Combine
import CoreLocation
import CoreMotion
import MapKit
import SwiftData
import SwiftUI
import UIKit

/// 自动离线骑行保存成功后发出，供已经打开的行程页面立即刷新。
extension Notification.Name {
    static let ninebotOfflineRideSaved = Notification.Name("ninebot.offline.ride.saved")
}

/// 单个本地骑行的可恢复工作草稿。
///
/// 草稿每次写入有效 GPS 点都会落盘；因此因内存压力被系统终止后，下一次由定位或
/// BackgroundTasks 唤醒时可以继续同一条记录，而不是丢失已采样的轨迹。
struct OfflineRideDraft: Codable {
    var id: String
    var vehicleSN: String?
    var startedAt: Date
    var startBatteryPercent: Int?
    var points: [NinebotRideTrackPoint]
    var lastMovingAt: Date
    var lastAcceptedAt: Date
    var lastKnownLatitude: Double
    var lastKnownLongitude: Double

    var lastKnownLocation: CLLocation {
        CLLocation(latitude: lastKnownLatitude, longitude: lastKnownLongitude)
    }
}

/// SwiftData 持久化实体。完整的 RideRecord（包括所有 GPS 点）以 JSON Data 保存在
/// 本地数据库中，同时冗余保存常用索引列，历史查询不需要依赖网络或云端。
@Model
private final class OfflineRideEntity {
    @Attribute(.unique) var id: String
    var startedAt: Date
    var endedAt: Date
    var distanceMeters: Double
    var mapCenterLatitude: Double
    var mapCenterLongitude: Double
    var mapLatitudeDelta: Double
    var mapLongitudeDelta: Double
    var payload: Data

    init(
        id: String,
        startedAt: Date,
        endedAt: Date,
        distanceMeters: Double,
        mapCenterLatitude: Double,
        mapCenterLongitude: Double,
        mapLatitudeDelta: Double,
        mapLongitudeDelta: Double,
        payload: Data
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMeters = distanceMeters
        self.mapCenterLatitude = mapCenterLatitude
        self.mapCenterLongitude = mapCenterLongitude
        self.mapLatitudeDelta = mapLatitudeDelta
        self.mapLongitudeDelta = mapLongitudeDelta
        self.payload = payload
    }
}

/// 本地离线骑行存储。
///
/// - 历史记录：SwiftData（`OfflineRideEntity`），仅存在设备本机。
/// - 进行中的草稿：App Group UserDefaults，用于系统终止后的极快恢复。
/// - 为兼容已有“记录”页，同时把最终记录写入 NinebotSharedStore/RideHistoryManager。
@MainActor
final class RideStorage: ObservableObject {
    static let shared = RideStorage()

    @Published private(set) var records: [RideRecord] = []

    private let draftKey = "ninebot.offline.ride.active.v1"
    private let defaults = UserDefaults(suiteName: NinebotAppGroup.identifier) ?? .standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let container: ModelContainer
    private let context: ModelContext

    private init() {
        let schema = Schema([OfflineRideEntity.self])
        let configuration = ModelConfiguration(
            "NinebotOfflineRides",
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            let resolvedContainer = try ModelContainer(for: schema, configurations: [configuration])
            container = resolvedContainer
            context = ModelContext(resolvedContainer)
        } catch {
            // 磁盘异常时保持功能可用；下次启动仍会重新尝试正常本地数据库。
            let fallback = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration("NinebotOfflineRidesFallback", schema: schema, isStoredInMemoryOnly: true)]
            )
            container = fallback
            context = ModelContext(fallback)
        }
        reload()
    }

    func reload() {
        let descriptor = FetchDescriptor<OfflineRideEntity>(
            sortBy: [SortDescriptor(\OfflineRideEntity.startedAt, order: .reverse)]
        )
        let entities = (try? context.fetch(descriptor)) ?? []
        records = entities.compactMap { try? decoder.decode(RideRecord.self, from: $0.payload) }
    }

    func save(_ record: RideRecord) {
        guard let payload = try? encoder.encode(record) else { return }
        let region = RideSummaryGenerator.mapRegion(for: record.points)
        let descriptor = FetchDescriptor<OfflineRideEntity>(
            predicate: #Predicate { $0.id == record.id }
        )

        if let existing = try? context.fetch(descriptor).first {
            existing.startedAt = record.startedAt
            existing.endedAt = record.endedAt
            existing.distanceMeters = record.distanceMeters
            existing.mapCenterLatitude = region.center.latitude
            existing.mapCenterLongitude = region.center.longitude
            existing.mapLatitudeDelta = region.span.latitudeDelta
            existing.mapLongitudeDelta = region.span.longitudeDelta
            existing.payload = payload
        } else {
            context.insert(
                OfflineRideEntity(
                    id: record.id,
                    startedAt: record.startedAt,
                    endedAt: record.endedAt,
                    distanceMeters: record.distanceMeters,
                    mapCenterLatitude: region.center.latitude,
                    mapCenterLongitude: region.center.longitude,
                    mapLatitudeDelta: region.span.latitudeDelta,
                    mapLongitudeDelta: region.span.longitudeDelta,
                    payload: payload
                )
            )
        }
        try? context.save()
        reload()
    }

    func delete(id: String) {
        let descriptor = FetchDescriptor<OfflineRideEntity>(predicate: #Predicate { $0.id == id })
        if let entity = try? context.fetch(descriptor).first {
            context.delete(entity)
            try? context.save()
        }
        reload()
    }

    func saveDraft(_ draft: OfflineRideDraft) {
        guard let data = try? encoder.encode(draft) else { return }
        defaults.set(data, forKey: draftKey)
    }

    func loadDraft() -> OfflineRideDraft? {
        guard let data = defaults.data(forKey: draftKey) else { return nil }
        return try? decoder.decode(OfflineRideDraft.self, from: data)
    }

    func clearDraft() {
        defaults.removeObject(forKey: draftKey)
    }
}

/// 纯本地的行程统计与地图范围生成器。
/// 所有距离、时长和速度均由记录的 CoreLocation 点计算，不调用任何服务器接口。
enum RideSummaryGenerator {
    static func makeRecord(from draft: OfflineRideDraft, endedAt: Date = .now) -> RideRecord? {
        let points = draft.points.sorted { $0.date < $1.date }
        guard let first = points.first else { return nil }
        let end = max(endedAt, first.date)
        let distanceMeters = NinebotRecordedRide.recalculatedDistanceMeters(from: points)
        let duration = max(end.timeIntervalSince(draft.startedAt), 0)
        let maxSpeed = points.map(\.speedKmh).max() ?? 0
        let averageSpeed = duration > 0 ? distanceMeters / duration * 3.6 : 0
        let recordedRide = NinebotRecordedRide(
            id: draft.id,
            vehicleSN: draft.vehicleSN,
            startedAt: draft.startedAt,
            endedAt: end,
            distanceMeters: distanceMeters,
            maxSpeedKmh: maxSpeed,
            averageSpeedKmh: averageSpeed,
            maxAccelerationG: points.map(\.accelerationG).max() ?? 0,
            points: points
        )
        return RideRecord(
            recordedRide: recordedRide,
            startBatteryPercent: draft.startBatteryPercent
        )
    }

    /// 用轨迹包围盒生成预留边距的区域；Summary View 的 MapKit Polyline 可直接使用。
    static func mapRegion(for points: [NinebotRideTrackPoint]) -> MKCoordinateRegion {
        let coordinates = points.compactMap { point -> CLLocationCoordinate2D? in
            guard (-90...90).contains(point.latitude), (-180...180).contains(point.longitude) else { return nil }
            return NinebotCoordinateTransform.mapKitCoordinate(latitude: point.latitude, longitude: point.longitude)
        }
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
                latitudinalMeters: 1_000,
                longitudinalMeters: 1_000
            )
        }
        guard coordinates.count > 1 else {
            return MKCoordinateRegion(center: first, latitudinalMeters: 850, longitudinalMeters: 850)
        }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: ((latitudes.min() ?? first.latitude) + (latitudes.max() ?? first.latitude)) / 2,
                longitude: ((longitudes.min() ?? first.longitude) + (longitudes.max() ?? first.longitude)) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(((latitudes.max() ?? first.latitude) - (latitudes.min() ?? first.latitude)) * 1.32, 0.008),
                longitudeDelta: max(((longitudes.max() ?? first.longitude) - (longitudes.min() ?? first.longitude)) * 1.32, 0.008)
            )
        )
    }
}

/// 后台本地轨迹自动记录器。
///
/// 设计策略接近 Fitness/Maps：空闲时使用低功耗标准定位 + Significant Change，检测到
/// 行驶后切换 BestForNavigation；静止时降档；结束点和草稿即时落盘。iOS 不承诺固定
/// 秒级回调，因此 1/3/20 秒是“接受点的目标节奏”，不是向系统申请的唤醒保证。
@MainActor
final class RideRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = RideRecorder()

    static let backgroundTaskIdentifier = "com.ninebot.live.offlineRideMaintenance"

    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isArmed = false
    @Published private(set) var isRecording = false
    @Published private(set) var currentSpeedKmh = 0.0
    @Published private(set) var activePointCount = 0
    @Published private(set) var lastStatusText = "正在准备本地轨迹记录"

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    private let storage = RideStorage.shared
    private var draft: OfflineRideDraft?
    private var watchOrigin: CLLocation?
    private var lastLocation: CLLocation?
    private var deferredUpdatesRequested = false
    private var didRegisterBackgroundTask = false

    private let startSpeedKmh = 3.0
    private let startDistanceMeters = 100.0
    private let endInactivity: TimeInterval = 5 * 60

    override init() {
        super.init()
        authorizationStatus = locationManager.authorizationStatus
        locationManager.delegate = self
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.showsBackgroundLocationIndicator = false
    }

    /// App 启动及由 significant-change/后台任务重新唤醒时调用。重复调用是安全的。
    func start() {
        registerBackgroundTaskIfNeeded()
        restoreUnfinishedRideIfNeeded()
        guard CLLocationManager.locationServicesEnabled() else {
            lastStatusText = "系统定位服务未开启"
            return
        }

        authorizationStatus = locationManager.authorizationStatus
        switch authorizationStatus {
        case .notDetermined:
            // 首次流程先请求“使用 App 期间”，回调后继续请求 Always；iOS 由系统展示选择页。
            locationManager.requestWhenInUseAuthorization()
            lastStatusText = "请允许定位，以自动记录骑行轨迹"
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
            armLowPowerMonitoring()
        case .authorizedAlways:
            armLowPowerMonitoring()
        case .denied, .restricted:
            lastStatusText = "请在系统设置中允许“始终”定位，才能后台自动记录"
        @unknown default:
            break
        }
        requestMotionActivityUpdates()
    }

    /// 设置页可显式调用，避免用户必须等待下一次 App 启动。
    func requestPermissions() {
        if authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
        requestMotionActivityUpdates()
    }

    func stopForUserPrivacy() {
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        motionManager.stopActivityUpdates()
        isArmed = false
        lastStatusText = "本地轨迹自动记录已暂停"
    }

    private func armLowPowerMonitoring() {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }
        isArmed = true
        if !isRecording {
            locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            locationManager.distanceFilter = 50
            locationManager.startMonitoringSignificantLocationChanges()
            // 仅 SLC 的典型触发距离远大于 100 米；保留粗粒度标准定位才能满足 100 米启动条件。
            locationManager.startUpdatingLocation()
            lastStatusText = "已开启低功耗自动骑行检测"
        }
    }

    private func configureActiveTracking(speedKmh: Double) {
        locationManager.allowsBackgroundLocationUpdates = authorizationStatus == .authorizedAlways
        locationManager.pausesLocationUpdatesAutomatically = speedKmh < 1
        if speedKmh >= 30 {
            locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            locationManager.distanceFilter = 1
            deferredUpdatesRequested = false
        } else if speedKmh >= 3 {
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = 3
            requestDeferredUpdatesIfAppropriate()
        } else {
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.distanceFilter = 10
            deferredUpdatesRequested = false
        }
        locationManager.startUpdatingLocation()
    }

    private func requestDeferredUpdatesIfAppropriate() {
        guard !deferredUpdatesRequested, CLLocationManager.deferredLocationUpdatesAvailable() else { return }
        // 允许系统在后台批量投递普通速度位置点，降低无线与 CPU 唤醒；高速模式绝不延迟。
        locationManager.allowDeferredLocationUpdates(untilTraveled: 120, timeout: 25)
        deferredUpdatesRequested = true
    }

    private func restoreUnfinishedRideIfNeeded() {
        guard draft == nil, let storedDraft = storage.loadDraft() else { return }
        draft = storedDraft
        isRecording = true
        activePointCount = storedDraft.points.count
        currentSpeedKmh = storedDraft.points.last?.speedKmh ?? 0
        lastStatusText = "已恢复未完成的本地骑行记录"
        configureActiveTracking(speedKmh: currentSpeedKmh)
    }

    private func requestMotionActivityUpdates() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            Task { @MainActor in
                // 车辆/骑行运动时立即提高检测灵敏度；静止状态不单独结束，以 GPS 的五分钟规则为准。
                if activity.automotive || activity.cycling {
                    self?.locationManager.requestLocation()
                }
            }
        }
    }

    private func locationIsUsable(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= 120
            && location.timestamp.timeIntervalSinceNow >= -10
            && location.timestamp.timeIntervalSinceNow <= 60
            && (-90...90).contains(location.coordinate.latitude)
            && (-180...180).contains(location.coordinate.longitude)
    }

    private func process(_ location: CLLocation) {
        guard locationIsUsable(location) else {
            // 差 GPS 不写入轨迹，也不会把“静止五分钟”误判为结束；下一个有效点会自动衔接。
            lastStatusText = "GPS 信号较弱，正在等待更准确的位置"
            return
        }

        let previous = lastLocation
        lastLocation = location
        let computedSpeed = previous.flatMap { prior -> Double? in
            let dt = location.timestamp.timeIntervalSince(prior.timestamp)
            guard dt > 0, dt <= 30 else { return nil }
            return location.distance(from: prior) / dt * 3.6
        } ?? 0
        let gpsSpeed = location.speed >= 0 && location.speedAccuracy >= 0 && location.speedAccuracy <= 10
            ? location.speed * 3.6 : 0
        let speed = min(max(gpsSpeed, computedSpeed), 120)
        currentSpeedKmh = speed

        guard var draft else {
            detectRideStart(location: location, speedKmh: speed)
            return
        }

        let timeSinceLast = location.timestamp.timeIntervalSince(draft.lastAcceptedAt)
        let interval = samplingInterval(for: speed)
        let displacement = location.distance(from: draft.lastKnownLocation)
        let shouldStore = draft.points.isEmpty || timeSinceLast >= interval || displacement >= 20
        guard shouldStore else { return }

        let wasMoving = speed > 1 || displacement >= max(12, location.horizontalAccuracy * 0.75)
        if wasMoving { draft.lastMovingAt = location.timestamp }

        let point = makePoint(location, speedKmh: speed, previous: draft.points.last)
        draft.points.append(point)
        draft.lastAcceptedAt = location.timestamp
        draft.lastKnownLatitude = location.coordinate.latitude
        draft.lastKnownLongitude = location.coordinate.longitude
        self.draft = draft
        activePointCount = draft.points.count
        storage.saveDraft(draft)
        configureActiveTracking(speedKmh: speed)
        updateLocalLiveActivity(with: draft)

        if location.timestamp.timeIntervalSince(draft.lastMovingAt) >= endInactivity {
            finishRide(endedAt: location.timestamp)
        } else {
            scheduleBackgroundMaintenance()
            lastStatusText = "正在本地记录：\(draft.points.count) 个 GPS 点"
        }
    }

    private func detectRideStart(location: CLLocation, speedKmh: Double) {
        if watchOrigin == nil { watchOrigin = location }
        let movedDistance = watchOrigin.map { location.distance(from: $0) } ?? 0
        guard speedKmh > startSpeedKmh || movedDistance >= startDistanceMeters else {
            lastStatusText = "正在低功耗检测骑行"
            return
        }

        let now = location.timestamp
        let firstPoint = makePoint(location, speedKmh: speedKmh, previous: nil)
        let newDraft = OfflineRideDraft(
            id: "offline-\(UUID().uuidString)",
            vehicleSN: nil,
            startedAt: now,
            startBatteryPercent: nil,
            points: [firstPoint],
            lastMovingAt: now,
            lastAcceptedAt: now,
            lastKnownLatitude: location.coordinate.latitude,
            lastKnownLongitude: location.coordinate.longitude
        )
        draft = newDraft
        isRecording = true
        activePointCount = 1
        watchOrigin = nil
        storage.saveDraft(newDraft)
        configureActiveTracking(speedKmh: speedKmh)
        updateLocalLiveActivity(with: newDraft)
        lastStatusText = "已自动开始记录本地骑行"
    }

    private func samplingInterval(for speedKmh: Double) -> TimeInterval {
        switch speedKmh {
        case 30...: return 1
        case 3...: return 3.5
        default: return 20
        }
    }

    private func makePoint(_ location: CLLocation, speedKmh: Double, previous: NinebotRideTrackPoint?) -> NinebotRideTrackPoint {
        let acceleration: Double
        if let previous {
            let dt = location.timestamp.timeIntervalSince(previous.date)
            acceleration = dt > 0 ? max((speedKmh - previous.speedKmh) / 3.6 / dt / 9.80665, 0) : 0
        } else {
            acceleration = 0
        }
        return NinebotRideTrackPoint(
            date: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            speedKmh: speedKmh,
            accelerationG: min(acceleration, 2.5),
            horizontalAccuracy: location.horizontalAccuracy,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            course: location.course >= 0 ? location.course : nil,
            verticalAccuracy: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil
        )
    }

    private func finishRide(endedAt: Date) {
        guard let draft else { return }
        defer {
            self.draft = nil
            isRecording = false
            activePointCount = 0
            currentSpeedKmh = 0
            deferredUpdatesRequested = false
            storage.clearDraft()
            armLowPowerMonitoring()
        }
        guard let record = RideSummaryGenerator.makeRecord(from: draft, endedAt: endedAt) else { return }

        storage.save(record)
        // 兼容原有记录页、详情页、地图轨迹回放和历史列表。
        let legacyRecord = NinebotRecordedRide(
            id: record.id,
            vehicleSN: record.vehicleSN,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            distanceMeters: record.distanceMeters,
            maxSpeedKmh: record.maxSpeedKmh,
            averageSpeedKmh: record.averageSpeedKmh,
            maxAccelerationG: record.points.map(\.accelerationG).max() ?? 0,
            points: record.points
        )
        NinebotSharedStore().upsertRecordedRide(legacyRecord)
        RideHistoryManager.shared.upsert(record)
        NinebotRideLiveActivityManager.endLocalRide(id: draft.id)
        NinebotNotificationManager.shared.sendRideCompletedNotification(for: record)
        NotificationCenter.default.post(name: .ninebotOfflineRideSaved, object: record)
        lastStatusText = "🏁 本次骑行已保存"
    }

    private func updateLocalLiveActivity(with draft: OfflineRideDraft) {
        let distance = NinebotRecordedRide.recalculatedDistanceMeters(from: draft.points)
        NinebotRideLiveActivityManager.syncLocalRide(
            id: draft.id,
            startedAt: draft.startedAt,
            speedKmh: currentSpeedKmh,
            distanceMeters: distance,
            pointCount: draft.points.count
        )
    }

    private func registerBackgroundTaskIfNeeded() {
        guard !didRegisterBackgroundTask else { return }
        didRegisterBackgroundTask = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in
                self?.handleBackgroundMaintenance(task)
            }
        }
    }

    private func scheduleBackgroundMaintenance() {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(endInactivity)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleBackgroundMaintenance(_ task: BGProcessingTask) {
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        defer { task.setTaskCompleted(success: true) }
        restoreUnfinishedRideIfNeeded()
        // BGTask 的运行时间由系统决定；若草稿已静止超过五分钟，在下一次允许执行时收尾。
        if let draft, Date().timeIntervalSince(draft.lastMovingAt) >= endInactivity {
            finishRide(endedAt: Date())
        } else {
            scheduleBackgroundMaintenance()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            self.start()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            locations.forEach { self.process($0) }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFinishDeferredUpdatesWithError error: Error?
    ) {
        Task { @MainActor in
            self.deferredUpdatesRequested = false
            if error != nil { self.lastStatusText = "系统已结束 GPS 批量更新，继续常规记录" }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.lastStatusText = "定位暂不可用：\(error.localizedDescription)"
        }
    }
}

/// 无云端账号时仍可访问的本地历史入口；点击后复用现有 RideSummaryView 的 MapKit Polyline 回放。
struct OfflineRideHistoryView: View {
    @ObservedObject private var storage = RideStorage.shared
    @ObservedObject private var recorder = RideRecorder.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("本地离线骑行", systemImage: "location.north.circle.fill")
                        .font(.title2.bold())
                    Text(recorder.lastStatusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if recorder.isRecording {
                        Text("记录中 · \(recorder.activePointCount) 个 GPS 点")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                if storage.records.isEmpty {
                    ContentUnavailableView(
                        "暂无本地骑行",
                        systemImage: "map",
                        description: Text("允许“始终”定位后，骑行会自动记录在此设备。")
                    )
                    .padding(.top, 60)
                } else {
                    ForEach(storage.records) { ride in
                        NavigationLink {
                            RideSummaryView(ride: ride) {
                                RideStorage.shared.delete(id: ride.id)
                                RideHistoryManager.shared.delete(id: ride.id)
                                NinebotSharedStore().deleteRecordedRide(id: ride.id)
                            }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                                    .font(.title2)
                                    .foregroundStyle(.green)
                                    .frame(width: 36)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ride.startedAt.formatted(.dateTime.year().month().day().hour().minute()))
                                        .font(.headline)
                                    Text("\(String(format: "%.1f km", ride.distanceKilometers)) · \(ride.duration.offlineRideDurationText) · \(ride.points.count) 个 GPS 点")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "play.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.green)
                            }
                            .padding(14)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("行程")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { storage.reload(); recorder.start() }
    }
}

private extension TimeInterval {
    var offlineRideDurationText: String {
        let totalMinutes = max(Int((self / 60).rounded()), 0)
        return totalMinutes >= 60 ? "\(totalMinutes / 60) 小时 \(totalMinutes % 60) 分钟" : "\(totalMinutes) 分钟"
    }
}
