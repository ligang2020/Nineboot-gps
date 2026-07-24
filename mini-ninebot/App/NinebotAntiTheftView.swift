import CoreLocation
import MapKit
import SwiftUI

/// 防盗中心：集中显示实时安全状态、车辆定位、电子围栏、查找车辆和本地轨迹。
struct NinebotAntiTheftView: View {
    @ObservedObject var model: NinebotViewModel
    @ObservedObject private var alarmManager = NinebotAlarmManager.shared
    @ObservedObject private var geofenceManager = NinebotGeofenceManager.shared
    @ObservedObject private var locationManager = NinebotVehicleLocationManager.shared
    @ObservedObject private var findVehicleManager = NinebotFindVehicleManager.shared

    @State private var isShowingFenceEditor = false
    @State private var isShowingTrack = false

    private var snapshot: NinebotVehicleSnapshot? { model.dashboard.primaryVehicle }
    private var vehicleSN: String? { snapshot?.vehicle.sn }
    private var vehicleName: String { snapshot?.vehicle.displayName ?? "我的车辆" }
    private var location: NinebotVehicleLocation? {
        guard let vehicleSN else { return nil }
        // 优先用实时 BLE / 服务端安全帧；仪表盘已有 GPS 时立即回退到仪表盘坐标，
        // 防止安全页错误显示「暂无车辆定位」。
        return locationManager.latestLocations[vehicleSN]
            ?? alarmManager.activeAlarm?.location
            ?? dashboardLocation
    }

    private var dashboardLocation: NinebotVehicleLocation? {
        guard let state = snapshot?.state,
              let latitude = state.latitude,
              let longitude = state.longitude,
              (-90...90).contains(latitude),
              (-180...180).contains(longitude) else {
            return nil
        }
        return NinebotVehicleLocation(
            latitude: latitude,
            longitude: longitude,
            updatedAt: state.updatedAt
        )
    }
    private var fence: NinebotGeofence? {
        guard let vehicleSN else { return nil }
        return geofenceManager.fences[vehicleSN]
    }

    var body: some View {
        List {
            Section {
                securityHero
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)

            Section("实时定位") {
                locationMap
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))

                if let location {
                    LabeledContent("当前位置") {
                        Text(String(format: "%.5f, %.5f", location.latitude, location.longitude))
                            .font(.footnote.monospacedDigit())
                    }
                    LabeledContent("更新时间") {
                        Text(location.updatedAt, style: .relative)
                    }
                    LabeledContent("方向") {
                        Text(location.heading.map { "\(Int($0.rounded()))°" } ?? "--")
                    }
                    LabeledContent("定位精度") {
                        Text(location.horizontalAccuracy.map { "±\(Int($0.rounded())) 米" } ?? "--")
                    }
                    Button {
                        NinebotVehicleLocationManager.shared.mapItem(for: location, name: vehicleName).openInMaps()
                    } label: {
                        Label("导航到车辆", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    }
                } else {
                    ContentUnavailableView("暂无车辆定位", systemImage: "location.slash", description: Text("等待 BLE 或服务端上传车辆 GPS 数据。"))
                }
            }

            Section("电子围栏") {
                if let location {
                    Button {
                        isShowingFenceEditor = true
                    } label: {
                        Label(fence == nil ? "在地图上设置安全区域" : "在地图上调整安全区域", systemImage: "map")
                    }

                    if let fence {
                        Toggle("启用电子围栏", isOn: Binding(
                            get: { fence.isEnabled },
                            set: { enabled in
                                if let vehicleSN { geofenceManager.setEnabled(enabled, vehicleSN: vehicleSN) }
                            }
                        ))
                        LabeledContent("围栏中心") {
                            Text(String(format: "%.5f, %.5f", fence.center.latitude, fence.center.longitude))
                                .font(.footnote.monospacedDigit())
                        }
                        Text("双指缩放地图可调整安全区域。车辆进入或离开该区域时会通知你。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            if let vehicleSN { geofenceManager.removeFence(vehicleSN: vehicleSN) }
                        } label: {
                            Label("移除电子围栏", systemImage: "trash")
                        }
                    } else {
                        Text("以车辆当前位置为中心，双指缩放地图确定安全区域。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("等待车辆定位", systemImage: "location.slash", description: Text("收到车辆 GPS 后即可在地图上设置安全区域。"))
                }

                if geofenceManager.phoneAuthorizationStatus == .notDetermined {
                    Button("允许定位以辅助围栏") {
                        geofenceManager.requestPhoneLocationAuthorization()
                    }
                    .font(.footnote)
                }
            }

            Section("防盗操作") {
                Button {
                    guard let vehicleSN else { return }
                    Task { await findVehicleManager.start(vehicleSN: vehicleSN) }
                } label: {
                    Label("寻找车辆（闪灯并鸣笛 30 秒）", systemImage: "speaker.wave.3.fill")
                }
                .disabled(vehicleSN == nil || findVehicleManager.findingVehicleSN != nil)

                if let until = findVehicleManager.findingUntil {
                    Button(role: .destructive) {
                        Task { await findVehicleManager.stop() }
                    } label: {
                        Label("停止寻找（\(until, style: .timer)）", systemImage: "stop.circle.fill")
                    }
                }

                if let alarm = alarmManager.activeAlarm, alarm.vehicleSN == vehicleSN {
                    Button(role: .destructive) {
                        alarmManager.acknowledgeAlarm(vehicleSN: alarm.vehicleSN)
                    } label: {
                        Label("确认并关闭告警", systemImage: "checkmark.shield.fill")
                    }
                }
            }

            Section("历史轨迹") {
                Button {
                    isShowingTrack = true
                } label: {
                    Label("查看本次/本地记录轨迹", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                }
                if let vehicleSN {
                    let points = locationManager.tracks[vehicleSN] ?? []
                    LabeledContent("记录点") { Text("\(points.count) 个") }
                    LabeledContent("轨迹距离") { Text(trackDistance(points)) }
                    LabeledContent("平均速度") { Text(averageSpeed(points)) }
                }
            }
        }
        .navigationTitle("车辆安全")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $isShowingFenceEditor) {
            if let vehicleSN, let location {
                NinebotGeofenceEditorSheet(
                    vehicleSN: vehicleSN,
                    vehicleName: vehicleName,
                    vehicleLocation: location,
                    initialRadiusMeters: fence?.radiusMeters ?? 300
                ) { radiusMeters in
                    geofenceManager.setFence(
                        vehicleSN: vehicleSN,
                        center: location,
                        radiusMeters: radiusMeters
                    )
                }
            }
        }
        .sheet(isPresented: $isShowingTrack) {
            NinebotVehicleTrackHistoryView(vehicleName: vehicleName, points: vehicleSN.flatMap { locationManager.tracks[$0] } ?? [])
        }
    }

    private var securityHero: some View {
        let activeAlarm = alarmManager.activeAlarm?.vehicleSN == vehicleSN ? alarmManager.activeAlarm : nil
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: activeAlarm == nil ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(activeAlarm == nil ? .green : .red)
                    .symbolEffect(.pulse, options: .repeating, isActive: activeAlarm != nil)
                VStack(alignment: .leading, spacing: 4) {
                    Text(activeAlarm?.isSOS == true ? "SOS 安全报警" : (activeAlarm?.type.title ?? "车辆安全守护中"))
                        .font(.headline)
                    Text(activeAlarm == nil ? "BLE、GPS、电子围栏与车辆报警已联动。" : "报警开始于 \(activeAlarm!.startedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(activeAlarm == nil ? "正常" : "告警")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(activeAlarm == nil ? .green : .red)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background((activeAlarm == nil ? Color.green : Color.red).opacity(0.13), in: Capsule())
            }

            HStack(spacing: 8) {
                securityChip("锁车", isGood: snapshot?.state.isLocked ?? false, symbol: "lock.fill")
                securityChip("蓝牙", isGood: latestTelemetryBluetooth, symbol: "bluetooth")
                securityChip("GPS", isGood: latestTelemetryGPS, symbol: "location.fill")
            }
        }
        .padding(18)
        .background(activeAlarm == nil ? Color(uiColor: .secondarySystemGroupedBackground) : Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var latestTelemetryBluetooth: Bool {
        guard let vehicleSN else { return false }
        return alarmManager.latestTelemetryByVehicle[vehicleSN]?.isBluetoothConnected ?? false
    }

    private var latestTelemetryGPS: Bool {
        location != nil
    }

    private func securityChip(_ title: String, isGood: Bool, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(isGood ? .primary : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.07), in: Capsule())
    }

    @ViewBuilder
    private var locationMap: some View {
        if let location {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: mapCoordinate(for: location),
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
            ))) {
                Marker(vehicleName, coordinate: mapCoordinate(for: location))
                    .tint(alarmManager.activeAlarm?.vehicleSN == vehicleSN ? .red : .green)
            }
        } else {
            ZStack {
                Color(uiColor: .tertiarySystemFill)
                Image(systemName: "map")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Apple 地图使用转换后的坐标显示；围栏距离计算仍使用原始车辆 GPS 坐标。
    private func mapCoordinate(for location: NinebotVehicleLocation) -> CLLocationCoordinate2D {
        NinebotCoordinateTransform.mapKitCoordinate(latitude: location.latitude, longitude: location.longitude)
    }

    private func trackDistance(_ points: [NinebotVehicleLocation]) -> String {
        let meters = zip(points, points.dropFirst()).reduce(0.0) { $0 + NinebotVehicleLocationManager.distanceMeters($1.0, $1.1) }
        return meters >= 1_000 ? String(format: "%.1f km", meters / 1_000) : "\(Int(meters)) 米"
    }

    private func averageSpeed(_ points: [NinebotVehicleLocation]) -> String {
        guard let first = points.first, let last = points.last, last.updatedAt > first.updatedAt else { return "--" }
        let meters = zip(points, points.dropFirst()).reduce(0.0) { $0 + NinebotVehicleLocationManager.distanceMeters($1.0, $1.1) }
        return String(format: "%.1f km/h", (meters / 1_000) / (last.updatedAt.timeIntervalSince(first.updatedAt) / 3_600))
    }
}

/// 围栏中心固定为车辆当前位置；用户只需双指缩放地图，就能以直观的圆形范围调整安全区域。
private struct NinebotGeofenceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let vehicleSN: String
    let vehicleName: String
    let vehicleLocation: NinebotVehicleLocation
    let initialRadiusMeters: CLLocationDistance
    let onSave: (CLLocationDistance) -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var draftRadiusMeters: CLLocationDistance

    init(
        vehicleSN: String,
        vehicleName: String,
        vehicleLocation: NinebotVehicleLocation,
        initialRadiusMeters: CLLocationDistance,
        onSave: @escaping (CLLocationDistance) -> Void
    ) {
        self.vehicleSN = vehicleSN
        self.vehicleName = vehicleName
        self.vehicleLocation = vehicleLocation
        self.initialRadiusMeters = initialRadiusMeters
        self.onSave = onSave

        let coordinate = NinebotCoordinateTransform.mapKitCoordinate(
            latitude: vehicleLocation.latitude,
            longitude: vehicleLocation.longitude
        )
        let radius = initialRadiusMeters.clamped(to: NinebotGeofence.supportedRadiusRange)
        _draftRadiusMeters = State(initialValue: radius)
        _cameraPosition = State(initialValue: .region(Self.region(center: coordinate, radiusMeters: radius)))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(position: $cameraPosition, interactionModes: [.zoom]) {
                    MapCircle(center: displayCoordinate, radius: draftRadiusMeters)
                        .foregroundStyle(.green.opacity(0.14))
                        .stroke(.green, lineWidth: 2)
                    Marker(vehicleName, coordinate: displayCoordinate)
                        .tint(.green)
                }
                .mapStyle(.standard(elevation: .flat))
                .onMapCameraChange(frequency: .continuous) { context in
                    draftRadiusMeters = Self.radius(from: context.region)
                }
                .accessibilityLabel("电子围栏地图")

                VStack(alignment: .leading, spacing: 5) {
                    Label("双指缩放地图以调整安全区域", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                    Text("车辆进入或离开此区域时，App 会发送通知。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.bar)
            }
            .navigationTitle("设置安全区域")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSave(draftRadiusMeters)
                        dismiss()
                    }
                }
            }
        }
    }

    private var displayCoordinate: CLLocationCoordinate2D {
        NinebotCoordinateTransform.mapKitCoordinate(
            latitude: vehicleLocation.latitude,
            longitude: vehicleLocation.longitude
        )
    }

    /// 使用当前可见地图区域估算围栏半径；不把具体米数暴露为固定数字选项。
    private static func radius(from region: MKCoordinateRegion) -> CLLocationDistance {
        let center = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
        let topEdge = CLLocation(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude
        )
        return (center.distance(from: topEdge) * 0.72).clamped(to: NinebotGeofence.supportedRadiusRange)
    }

    private static func region(center: CLLocationCoordinate2D, radiusMeters: CLLocationDistance) -> MKCoordinateRegion {
        // 圆形围栏约占可见区域七成，方便用户在缩放时始终看清边界。
        let halfSpanMeters = radiusMeters / 0.72
        let latitudeDelta = max(0.003, halfSpanMeters * 2 / 111_000)
        let longitudeDelta = max(0.003, latitudeDelta / max(0.25, abs(cos(center.latitude * .pi / 180))))
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}

private struct NinebotVehicleTrackHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let vehicleName: String
    let points: [NinebotVehicleLocation]

    var body: some View {
        NavigationStack {
            Group {
                if let last = points.last {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: NinebotCoordinateTransform.mapKitCoordinate(latitude: last.latitude, longitude: last.longitude),
                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    ))) {
                        ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                            if index == 0 || index == points.count - 1 {
                                Marker(index == 0 ? "开始" : "结束", coordinate: NinebotCoordinateTransform.mapKitCoordinate(latitude: point.latitude, longitude: point.longitude))
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("暂无轨迹", systemImage: "point.topleft.down.curvedto.point.bottomright.up", description: Text("骑行中收到有效车辆 GPS 后，会按节能规则记录轨迹。"))
                }
            }
            .navigationTitle("\(vehicleName) 轨迹")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

#Preview("防盗中心") {
    NavigationStack {
        NinebotAntiTheftView(model: NinebotViewModel())
    }
}
