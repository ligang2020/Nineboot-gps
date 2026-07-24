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

    @State private var selectedRadius: NinebotGeofenceRadius = .meters300
    @State private var isShowingFenceConfirmation = false
    @State private var isShowingTrack = false

    private var snapshot: NinebotVehicleSnapshot? { model.dashboard.primaryVehicle }
    private var vehicleSN: String? { snapshot?.vehicle.sn }
    private var vehicleName: String { snapshot?.vehicle.displayName ?? "我的车辆" }
    private var location: NinebotVehicleLocation? {
        guard let vehicleSN else { return nil }
        return locationManager.latestLocations[vehicleSN]
            ?? alarmManager.activeAlarm?.location
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
                Picker("安全范围", selection: $selectedRadius) {
                    ForEach(NinebotGeofenceRadius.allCases) { radius in
                        Text(radius.title).tag(radius)
                    }
                }
                .pickerStyle(.segmented)
                .onAppear { selectedRadius = fence?.radius ?? .meters300 }

                if let fence {
                    Toggle("启用电子围栏", isOn: Binding(
                        get: { fence.isEnabled },
                        set: { enabled in if let vehicleSN { geofenceManager.setEnabled(enabled, vehicleSN: vehicleSN) } }
                    ))
                    LabeledContent("围栏中心") {
                        Text(String(format: "%.5f, %.5f", fence.center.latitude, fence.center.longitude))
                            .font(.footnote.monospacedDigit())
                    }
                    Button(role: .destructive) {
                        if let vehicleSN { geofenceManager.removeFence(vehicleSN: vehicleSN) }
                    } label: {
                        Label("移除电子围栏", systemImage: "trash")
                    }
                } else {
                    Button {
                        isShowingFenceConfirmation = true
                    } label: {
                        Label("以当前位置设为安全围栏", systemImage: "scope")
                    }
                    .disabled(location == nil)
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
        .alert("设置电子围栏", isPresented: $isShowingFenceConfirmation) {
            Button("取消", role: .cancel) {}
            Button("设置") {
                guard let vehicleSN, let location else { return }
                geofenceManager.setFence(vehicleSN: vehicleSN, center: location, radius: selectedRadius)
            }
        } message: {
            Text("将以车辆当前定位为中心，设置 \(selectedRadius.title) 安全围栏。车辆进出围栏将发送通知。")
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
                center: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
            ))) {
                Marker(vehicleName, coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude))
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

private struct NinebotVehicleTrackHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let vehicleName: String
    let points: [NinebotVehicleLocation]

    var body: some View {
        NavigationStack {
            Group {
                if let last = points.last {
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude),
                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    ))) {
                        ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                            if index == 0 || index == points.count - 1 {
                                Marker(index == 0 ? "开始" : "结束", coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
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
