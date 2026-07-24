import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// 骑行结束后持久化的完整总结记录。
/// 所有 GPS 采样点会随记录编码保存，因此历史页面和轨迹回放不依赖网络。
struct RideRecord: Codable, Identifiable, Equatable {
    var id: String
    var sourceRecordingID: String?
    var vehicleSN: String?
    var startedAt: Date
    var endedAt: Date
    var distanceMeters: Double
    var averageSpeedKmh: Double
    var maxSpeedKmh: Double
    var startBatteryPercent: Int?
    var endBatteryPercent: Int?
    var remainingRangeKm: Double?
    var points: [NinebotRideTrackPoint]

    init(
        id: String = UUID().uuidString,
        sourceRecordingID: String? = nil,
        vehicleSN: String?,
        startedAt: Date,
        endedAt: Date,
        distanceMeters: Double,
        averageSpeedKmh: Double,
        maxSpeedKmh: Double,
        startBatteryPercent: Int? = nil,
        endBatteryPercent: Int? = nil,
        remainingRangeKm: Double? = nil,
        points: [NinebotRideTrackPoint]
    ) {
        self.id = id
        self.sourceRecordingID = sourceRecordingID
        self.vehicleSN = vehicleSN
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.distanceMeters = distanceMeters
        self.averageSpeedKmh = averageSpeedKmh
        self.maxSpeedKmh = maxSpeedKmh
        self.startBatteryPercent = startBatteryPercent
        self.endBatteryPercent = endBatteryPercent
        self.remainingRangeKm = remainingRangeKm
        self.points = points.sorted { $0.date < $1.date }
    }

    /// 将现有记录页的 GPS 记录无损转换为总结记录，兼容升级前已保存的数据。
    init(
        recordedRide: NinebotRecordedRide,
        startBatteryPercent: Int? = nil,
        endBatteryPercent: Int? = nil,
        remainingRangeKm: Double? = nil
    ) {
        self.init(
            id: recordedRide.id,
            sourceRecordingID: recordedRide.id,
            vehicleSN: recordedRide.vehicleSN,
            startedAt: recordedRide.startedAt,
            endedAt: recordedRide.endedAt,
            distanceMeters: recordedRide.displayDistanceMeters,
            averageSpeedKmh: recordedRide.averageSpeedKmh,
            maxSpeedKmh: recordedRide.maxSpeedKmh,
            startBatteryPercent: startBatteryPercent,
            endBatteryPercent: endBatteryPercent,
            remainingRangeKm: remainingRangeKm,
            points: recordedRide.points
        )
    }

    var duration: TimeInterval { max(endedAt.timeIntervalSince(startedAt), 0) }
    var distanceKilometers: Double { max(distanceMeters, 0) / 1_000 }
    var sampleCount: Int { points.count }

    var coordinates: [CLLocationCoordinate2D] {
        points.compactMap { point in
            guard (-90...90).contains(point.latitude),
                  (-180...180).contains(point.longitude),
                  (point.horizontalAccuracy ?? 0) <= 120 else {
                return nil
            }
            return NinebotCoordinateTransform.mapKitCoordinate(latitude: point.latitude, longitude: point.longitude)
        }
    }

    var startCoordinate: CLLocationCoordinate2D? { coordinates.first }
    var endCoordinate: CLLocationCoordinate2D? { coordinates.last }

    /// 海拔数据由 CoreLocation 保存；旧记录没有海拔时自动隐藏相关信息。
    var totalAscentMeters: Double? {
        let altitudes = points.compactMap(\.altitude).filter(\.isFinite)
        guard altitudes.count > 1 else { return nil }
        var ascent = 0.0
        for index in 1..<altitudes.count {
            let delta = altitudes[index] - altitudes[index - 1]
            // 忽略低于 1 米的 GPS 高度抖动。
            if delta > 1 { ascent += delta }
        }
        return ascent
    }

    var highestAltitudeMeters: Double? {
        points.compactMap(\.altitude).filter(\.isFinite).max()
    }

    var batteryUsedPercent: Int? {
        guard let startBatteryPercent, let endBatteryPercent else { return nil }
        return max(startBatteryPercent - endBatteryPercent, 0)
    }

    /// Preview 与未授权定位时可直接展示的本地示例轨迹。
    static var mock: RideRecord {
        let start = Date().addingTimeInterval(-2_160)
        let center = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let points = (0..<48).map { index -> NinebotRideTrackPoint in
            let progress = Double(index) / 47
            return NinebotRideTrackPoint(
                date: start.addingTimeInterval(progress * 2_160),
                latitude: center.latitude + sin(progress * .pi * 2.2) * 0.010 + progress * 0.002,
                longitude: center.longitude + progress * 0.028 + cos(progress * .pi * 3) * 0.002,
                speedKmh: 19 + sin(progress * .pi * 5) * 7,
                accelerationG: 0.12,
                horizontalAccuracy: 8,
                altitude: 7 + sin(progress * .pi * 3) * 16
            )
        }
        return RideRecord(
            vehicleSN: "PREVIEW",
            startedAt: start,
            endedAt: start.addingTimeInterval(2_160),
            distanceMeters: 18_600,
            averageSpeedKmh: 25,
            maxSpeedKmh: 48,
            startBatteryPercent: 74,
            endBatteryPercent: 62,
            remainingRangeKm: 235,
            points: points
        )
    }
}

/// 骑行历史存储管理器。使用 App Group，主 App、Widget 与未来扩展可读取同一份数据。
@MainActor
final class RideHistoryManager: ObservableObject {
    static let shared = RideHistoryManager()

    @Published private(set) var records: [RideRecord] = []

    private let key = "ninebot.ride.summary.records.v1"
    private let defaults = UserDefaults(suiteName: NinebotAppGroup.identifier) ?? .standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        records = load()
    }

    func records(for vehicleSN: String?) -> [RideRecord] {
        guard let vehicleSN, !vehicleSN.isEmpty else { return records }
        return records.filter { $0.vehicleSN == vehicleSN }
    }

    func upsert(_ record: RideRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id || $0.sourceRecordingID == record.sourceRecordingID }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        persist()
    }

    func delete(id: String) {
        records.removeAll { $0.id == id || $0.sourceRecordingID == id }
        persist()
    }

    private func load() -> [RideRecord] {
        guard let data = defaults.data(forKey: key),
              let stored = try? decoder.decode([RideRecord].self, from: data) else {
            return []
        }
        return stored.sorted { $0.startedAt > $1.startedAt }
    }

    private func persist() {
        records.sort { $0.startedAt > $1.startedAt }
        // 限制历史总量，GPS 轨迹仍保留在每条记录中。
        records = Array(records.prefix(240))
        guard let data = try? encoder.encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}

/// 骑行总结页的状态与回放控制器。CADisplayLink 在主线程刷新，能够贴合屏幕的 60 FPS 刷新节奏。
@MainActor
final class RideSummaryViewModel: NSObject, ObservableObject {
    enum ReplayRate: Double, CaseIterable, Identifiable {
        case normal = 1
        case double = 2
        case quadruple = 4

        var id: Double { rawValue }
        var title: String { rawValue == 1 ? "1×" : "\(Int(rawValue))×" }
    }

    let ride: RideRecord
    @Published var cameraPosition: MapCameraPosition
    @Published private(set) var routeDrawProgress: Double = 0
    @Published private(set) var replayProgress: Double = 0
    @Published private(set) var isPlaying = false
    @Published var replayRate: ReplayRate = .normal
    @Published private(set) var shareImage: UIImage?
    @Published private(set) var isPreparingShare = false

    private var displayLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval?
    private let replayBaseDuration: TimeInterval = 28

    init(ride: RideRecord) {
        self.ride = ride
        self.cameraPosition = .region(Self.region(for: ride.coordinates))
        super.init()
    }

    deinit {
        displayLink?.invalidate()
    }

    var displayedCoordinates: [CLLocationCoordinate2D] {
        let coordinates = ride.coordinates
        guard coordinates.count > 1 else { return coordinates }
        let count = max(2, Int((Double(coordinates.count) * routeDrawProgress).rounded(.up)))
        return Array(coordinates.prefix(min(count, coordinates.count)))
    }

    var replayCoordinate: CLLocationCoordinate2D? {
        coordinate(at: replayProgress)
    }

    var replayPoint: NinebotRideTrackPoint? {
        point(at: replayProgress)
    }

    var replayDistanceMeters: Double {
        ride.distanceMeters * replayProgress
    }

    var replayDate: Date {
        ride.startedAt.addingTimeInterval(ride.duration * replayProgress)
    }

    func appear() {
        cameraPosition = .region(Self.region(for: ride.coordinates))
        withAnimation(.easeOut(duration: 1.35)) {
            routeDrawProgress = 1
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard ride.coordinates.count > 1 else { return }
        if replayProgress >= 1 { replayProgress = 0 }
        isPlaying = true
        lastFrameTimestamp = nil
        startDisplayLinkIfNeeded()
    }

    func pause() {
        isPlaying = false
        lastFrameTimestamp = nil
    }

    func seek(to progress: Double, followsVehicle: Bool = true) {
        replayProgress = min(max(progress, 0), 1)
        if followsVehicle, let coordinate = replayCoordinate {
            withAnimation(.easeInOut(duration: 0.18)) {
                cameraPosition = .region(Self.followRegion(around: coordinate, in: ride.coordinates))
            }
        }
    }

    func prepareShareImage() async {
        guard shareImage == nil, !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        shareImage = await RideShareCardRenderer.render(ride: ride)
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        guard isPlaying else { return }
        defer { lastFrameTimestamp = displayLink.timestamp }
        guard let lastFrameTimestamp else { return }

        let elapsed = displayLink.timestamp - lastFrameTimestamp
        let replayDuration = max(replayBaseDuration / replayRate.rawValue, 1)
        let next = replayProgress + elapsed / replayDuration
        seek(to: next, followsVehicle: true)

        if replayProgress >= 1 {
            pause()
        }
    }

    private func coordinate(at progress: Double) -> CLLocationCoordinate2D? {
        let coordinates = ride.coordinates
        guard let first = coordinates.first else { return nil }
        guard coordinates.count > 1 else { return first }
        let scaled = min(max(progress, 0), 1) * Double(coordinates.count - 1)
        let lower = Int(scaled.rounded(.down))
        let upper = min(lower + 1, coordinates.count - 1)
        let local = scaled - Double(lower)
        return CLLocationCoordinate2D(
            latitude: coordinates[lower].latitude + (coordinates[upper].latitude - coordinates[lower].latitude) * local,
            longitude: coordinates[lower].longitude + (coordinates[upper].longitude - coordinates[lower].longitude) * local
        )
    }

    private func point(at progress: Double) -> NinebotRideTrackPoint? {
        guard !ride.points.isEmpty else { return nil }
        let index = min(Int((Double(ride.points.count - 1) * progress).rounded()), ride.points.count - 1)
        return ride.points[index]
    }

    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737), latitudinalMeters: 1_000, longitudinalMeters: 1_000)
        }
        guard coordinates.count > 1 else {
            return MKCoordinateRegion(center: first, latitudinalMeters: 900, longitudinalMeters: 900)
        }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minLatitude = latitudes.min() ?? first.latitude
        let maxLatitude = latitudes.max() ?? first.latitude
        let minLongitude = longitudes.min() ?? first.longitude
        let maxLongitude = longitudes.max() ?? first.longitude
        let latitudeDelta = max((maxLatitude - minLatitude) * 1.32, 0.008)
        let longitudeDelta = max((maxLongitude - minLongitude) * 1.32, 0.008)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2),
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }

    private static func followRegion(around coordinate: CLLocationCoordinate2D, in coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let overview = region(for: coordinates)
        return MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(
                latitudeDelta: min(max(overview.span.latitudeDelta * 0.45, 0.0045), 0.018),
                longitudeDelta: min(max(overview.span.longitudeDelta * 0.45, 0.0045), 0.018)
            )
        )
    }
}

/// Apple Fitness 风格的骑行结束总结页。
struct RideSummaryView: View {
    let ride: RideRecord
    var onDelete: (() -> Void)?

    @StateObject private var viewModel: RideSummaryViewModel
    @State private var isShowingShareSheet = false
    @State private var isConfirmingDeletion = false
    @Environment(\.dismiss) private var dismiss

    init(ride: RideRecord, onDelete: (() -> Void)? = nil) {
        self.ride = ride
        self.onDelete = onDelete
        _viewModel = StateObject(wrappedValue: RideSummaryViewModel(ride: ride))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                RideSummaryHeader(ride: ride)
                    .padding(.top, 8)

                RideRouteMap(viewModel: viewModel)
                    .frame(height: 330)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(Color.secondary.opacity(0.16), lineWidth: 0.75)
                    }
                    .padding(.horizontal, 16)

                RideReplayControls(viewModel: viewModel)
                    .padding(.horizontal, 16)

                RideMetricGrid(ride: ride)
                    .padding(.horizontal, 16)

                RideRouteInformation(ride: ride)
                    .padding(.horizontal, 16)

                if onDelete != nil {
                    Button(role: .destructive) {
                        isConfirmingDeletion = true
                    } label: {
                        Label("删除此次骑行", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 34)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("本次骑行")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await viewModel.prepareShareImage()
                        isShowingShareSheet = viewModel.shareImage != nil
                    }
                } label: {
                    if viewModel.isPreparingShare {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .accessibilityLabel("生成骑行分享卡片")
            }
        }
        .task {
            viewModel.appear()
            await viewModel.prepareShareImage()
        }
        .onDisappear {
            viewModel.pause()
        }
        .sheet(isPresented: $isShowingShareSheet) {
            if let image = viewModel.shareImage {
                RideActivityShareSheet(items: [image])
            }
        }
        .alert("删除此次骑行？", isPresented: $isConfirmingDeletion) {
            Button("删除", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("骑行轨迹与统计数据将从本机历史中删除。")
        }
    }
}

private struct RideSummaryHeader: View {
    let ride: RideRecord

    var body: some View {
        VStack(spacing: 8) {
            Text("本次骑行")
                .font(.title2.weight(.bold))
            Text(ride.startedAt.formatted(.dateTime.month(.wide).day().weekday(.wide).hour().minute()))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                RideHeroMetric(value: ride.duration.rideDurationText, title: "骑行时长")
                Divider().frame(height: 42)
                RideHeroMetric(value: ride.distanceKilometers.oneDecimalKilometersText, title: "总距离")
                Divider().frame(height: 42)
                RideHeroMetric(value: ride.averageSpeedKmh.speedText, title: "平均速度")
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 20)
    }
}

private struct RideHeroMetric: View {
    let value: String
    let title: String

    var body: some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.headline.monospacedDigit().weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RideRouteMap: View {
    @ObservedObject var viewModel: RideSummaryViewModel

    var body: some View {
        Map(position: $viewModel.cameraPosition, interactionModes: [.pan, .zoom]) {
            let coordinates = viewModel.displayedCoordinates
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(
                        LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                    )
            }

            if let start = viewModel.ride.startCoordinate {
                Annotation("起点", coordinate: start, anchor: .center) {
                    RideEndpointPin(color: .green, symbol: "flag.fill")
                        .scaleEffect(viewModel.routeDrawProgress > 0.03 ? 1 : 0.2)
                        .opacity(viewModel.routeDrawProgress > 0.03 ? 1 : 0)
                        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: viewModel.routeDrawProgress)
                }
            }

            if let end = viewModel.ride.endCoordinate, viewModel.routeDrawProgress > 0.95 {
                Annotation("终点", coordinate: end, anchor: .center) {
                    RideEndpointPin(color: .red, symbol: "flag.checkered")
                        .transition(.scale.combined(with: .opacity))
                }
            }

            if let coordinate = viewModel.replayCoordinate {
                Annotation("车辆", coordinate: coordinate, anchor: .center) {
                    Image(systemName: "scooter")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.blue, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                        .accessibilityLabel("回放中的车辆位置")
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .automatic, pointsOfInterest: .excludingAll, showsTraffic: false))
    }
}

private struct RideEndpointPin: View {
    let color: Color
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}

private struct RideReplayControls: View {
    @ObservedObject var viewModel: RideSummaryViewModel

    var body: some View {
        VStack(spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Label("骑行轨迹回放", systemImage: "play.rectangle.fill")
                    .font(.headline)
                Spacer()
                Text(viewModel.replayDate.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { viewModel.replayProgress },
                    set: { viewModel.seek(to: $0) }
                ),
                in: 0...1
            )
            .tint(.blue)

            HStack(spacing: 18) {
                Button(action: viewModel.togglePlayback) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .clipShape(Circle())

                Picker("回放速度", selection: $viewModel.replayRate) {
                    ForEach(RideSummaryViewModel.ReplayRate.allCases) { rate in
                        Text(rate.title).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 190)

                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                RideReplayStat(title: "当前速度", value: (viewModel.replayPoint?.speedKmh ?? 0).speedText)
                RideReplayStat(title: "累计距离", value: (viewModel.replayDistanceMeters / 1_000).oneDecimalKilometersText)
                RideReplayStat(title: "当前位置", value: viewModel.replayCoordinate?.shortCoordinateText ?? "--")
            }
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct RideReplayStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RideMetricGrid: View {
    let ride: RideRecord

    var body: some View {
        VStack(spacing: 10) {
            RideMetricRow(
                leading: RideMetric(icon: "bicycle", tint: .blue, title: "总距离", value: ride.distanceKilometers.oneDecimalKilometersText),
                trailing: RideMetric(icon: "flag.checkered", tint: .orange, title: "骑行时间", value: ride.duration.rideDurationText)
            )
            RideMetricRow(
                leading: RideMetric(icon: "bolt.fill", tint: .yellow, title: "平均速度", value: ride.averageSpeedKmh.speedText),
                trailing: RideMetric(icon: "speedometer", tint: .red, title: "最高速度", value: ride.maxSpeedKmh.speedText)
            )
            RideMetricRow(
                leading: RideMetric(icon: "battery.75percent", tint: .green, title: "消耗电量", value: ride.batteryUsedPercent.map { "\($0)%" } ?? "--"),
                trailing: RideMetric(icon: "location.fill", tint: .blue, title: "剩余续航", value: ride.remainingRangeKm.map { "\(Int($0.rounded())) km" } ?? "--")
            )
        }
    }
}

private struct RideMetricRow: View {
    let leading: RideMetric
    let trailing: RideMetric

    var body: some View {
        HStack(spacing: 10) {
            RideMetricCard(metric: leading)
            RideMetricCard(metric: trailing)
        }
    }
}

private struct RideMetric {
    let icon: String
    let tint: Color
    let title: String
    let value: String
}

private struct RideMetricCard: View {
    let metric: RideMetric

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: metric.icon)
                .font(.headline)
                .foregroundStyle(metric.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(metric.value)
                    .font(.headline.monospacedDigit().weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(metric.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct RideRouteInformation: View {
    let ride: RideRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("路线信息")
                .font(.headline)

            RideInfoLine(icon: "play.circle.fill", title: "开始", value: ride.startedAt.formatted(date: .abbreviated, time: .shortened), tint: .green)
            RideInfoLine(icon: "stop.circle.fill", title: "结束", value: ride.endedAt.formatted(date: .abbreviated, time: .shortened), tint: .red)
            RideInfoLine(icon: "point.3.connected.trianglepath.dotted", title: "GPS 采样点", value: "\(ride.sampleCount) 个", tint: .blue)

            if let totalAscentMeters = ride.totalAscentMeters {
                RideInfoLine(icon: "arrow.up.right", title: "总爬升", value: "\(Int(totalAscentMeters.rounded())) m", tint: .orange)
            }
            if let highestAltitudeMeters = ride.highestAltitudeMeters {
                RideInfoLine(icon: "mountain.2.fill", title: "最高海拔", value: "\(Int(highestAltitudeMeters.rounded())) m", tint: .brown)
            }
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct RideInfoLine: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.medium))
        }
    }
}

/// 通过系统分享面板共享由 MKMapSnapshotter 绘制的本地骑行卡片。
private struct RideActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 生成分享图：采用 Apple Maps 快照作为底图，并在其上绘制路线、起终点与核心指标。
@MainActor
private enum RideShareCardRenderer {
    static func render(ride: RideRecord) async -> UIImage? {
        let mapSize = CGSize(width: 1_080, height: 700)
        let options = MKMapSnapshotter.Options()
        options.region = snapshotRegion(for: ride.coordinates)
        options.size = mapSize
        options.scale = 1
        options.mapType = .standard
        options.pointOfInterestFilter = .excludingAll

        let snapshot = await withCheckedContinuation { continuation in
            MKMapSnapshotter(options: options).start { snapshot, _ in
                continuation.resume(returning: snapshot)
            }
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_080, height: 1_350))
        return renderer.image { context in
                UIColor.systemBackground.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1_080, height: 1_350))

                if let snapshot {
                    snapshot.image.draw(in: CGRect(x: 0, y: 0, width: 1_080, height: 700))
                    drawRoute(ride.coordinates, snapshot: snapshot, in: context.cgContext)
                }

                let titleStyle: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 50, weight: .bold),
                    .foregroundColor: UIColor.label
                ]
                NSString(string: "本次骑行").draw(at: CGPoint(x: 64, y: 770), withAttributes: titleStyle)

                let dateStyle: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 28, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel
                ]
                NSString(string: ride.startedAt.formatted(.dateTime.year().month().day().hour().minute()))
                    .draw(at: CGPoint(x: 64, y: 838), withAttributes: dateStyle)

                drawMetric(ride.distanceKilometers.oneDecimalKilometersText, title: "总距离", x: 64, y: 930, context: context.cgContext)
                drawMetric(ride.duration.rideDurationText, title: "骑行时间", x: 385, y: 930, context: context.cgContext)
                drawMetric(ride.averageSpeedKmh.speedText, title: "平均速度", x: 704, y: 930, context: context.cgContext)
                drawMetric(ride.maxSpeedKmh.speedText, title: "最高速度", x: 64, y: 1_120, context: context.cgContext)

                let logoStyle: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 27, weight: .semibold),
                    .foregroundColor: UIColor.secondaryLabel
                ]
                NSString(string: "●  Ninebot LiveRide").draw(at: CGPoint(x: 704, y: 1_220), withAttributes: logoStyle)
            }
        }

    private static func drawMetric(_ value: String, title: String, x: CGFloat, y: CGFloat, context: CGContext) {
        let valueStyle: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 38, weight: .bold),
            .foregroundColor: UIColor.label
        ]
        let titleStyle: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24, weight: .regular),
            .foregroundColor: UIColor.secondaryLabel
        ]
        NSString(string: value).draw(at: CGPoint(x: x, y: y), withAttributes: valueStyle)
        NSString(string: title).draw(at: CGPoint(x: x, y: y + 53), withAttributes: titleStyle)
    }

    private static func drawRoute(_ coordinates: [CLLocationCoordinate2D], snapshot: MKMapSnapshotter.Snapshot, in context: CGContext) {
        guard coordinates.count > 1 else { return }
        let path = UIBezierPath()
        path.move(to: snapshot.point(for: coordinates[0]))
        for coordinate in coordinates.dropFirst() {
            path.addLine(to: snapshot.point(for: coordinate))
        }
        context.saveGState()
        context.setLineWidth(13)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.addPath(path.cgPath)
        context.strokePath()

        for (coordinate, color) in [(coordinates.first, UIColor.systemGreen), (coordinates.last, UIColor.systemRed)] {
            guard let coordinate else { continue }
            let point = snapshot.point(for: coordinate)
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26))
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(4)
            context.strokeEllipse(in: CGRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26))
        }
        context.restoreGState()
    }

    private static func snapshotRegion(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737), latitudinalMeters: 1_000, longitudinalMeters: 1_000)
        }
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minLatitude = latitudes.min() ?? first.latitude
        let maxLatitude = latitudes.max() ?? first.latitude
        let minLongitude = longitudes.min() ?? first.longitude
        let maxLongitude = longitudes.max() ?? first.longitude
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLatitude - minLatitude) * 1.34, 0.008),
                longitudeDelta: max((maxLongitude - minLongitude) * 1.34, 0.008)
            )
        )
    }
}

private extension TimeInterval {
    var rideDurationText: String {
        let totalMinutes = Int((self / 60).rounded())
        if totalMinutes >= 60 { return "\(totalMinutes / 60) 小时 \(totalMinutes % 60) 分钟" }
        return "\(max(totalMinutes, 0)) 分钟"
    }
}

private extension Double {
    var oneDecimalKilometersText: String { String(format: "%.1f km", self) }
    var speedText: String { String(format: "%.0f km/h", self) }
}

private extension CLLocationCoordinate2D {
    var shortCoordinateText: String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }
}

#Preview("骑行总结") {
    NavigationStack {
        RideSummaryView(ride: .mock)
    }
}
