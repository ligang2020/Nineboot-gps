import SwiftUI
import UIKit
import MapKit
import CoreLocation
import Combine


private struct DashboardScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct NinebotDashboardView: View {
    @ObservedObject var model: NinebotViewModel
    var onOpenTrips: () -> Void = {}
    @State private var isShowingVehiclePicker = false
    @State private var scrollOffset: CGFloat = 0
    @State private var pullDistance: CGFloat = 0
    @State private var isShowingPullTimestamp = false
    @State private var pullTimestampDismissID = UUID()
    @State private var didTriggerPullRefresh = false
    @State private var isTrackingPullGesture = false
    @State private var pullGestureStartedAtTop = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                dashboardBackground
                    .ignoresSafeArea()

                ScrollView {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: DashboardScrollOffsetPreferenceKey.self,
                            value: geometry.frame(in: .named("dashboardScroll")).minY
                        )
                    }
                    .frame(height: 0)

                    VStack(alignment: .leading, spacing: 18) {
                        if let primary = model.dashboard.primaryVehicle {
                            let activeAction = activeVehicleAction(for: primary.vehicle.sn)

                            VehicleControlHero(
                                snapshot: primary,
                                canSwitchVehicle: model.hasVehicles,
                                resolvedAddress: model.resolvedAddressText(for: primary),
                                showsUpdateTime: !model.isAddressGeocodingEnabled,
                                isLoading: model.isLoading,
                                onRingBell: {
                                    performVehicleAction(.bell, sn: primary.vehicle.sn)
                                }
                            ) {
                                isShowingVehiclePicker = true
                            }
                            VehicleActionPanel(
                                snapshot: primary,
                                isLoading: model.isLoading,
                                activeAction: activeAction
                            ) { action in
                                performVehicleAction(action, sn: primary.vehicle.sn)
                            }
                            .padding(.top, primary.state.isCharging == true && !primary.state.isFullyCharged ? -8 : 0)
                            VehicleLocationRideSummaryPanel(
                                snapshot: primary,
                                resolvedAddress: model.resolvedAddressText(for: primary),
                                isLoading: model.isLoading,
                                onOpenTrips: onOpenTrips,
                                onRingBell: {
                                    performVehicleAction(.bell, sn: primary.vehicle.sn)
                                }
                            )
                                .padding(.horizontal, 16)
                            NavigationLink {
                                NinebotBatteryDetailView(
                                    snapshot: primary,
                                    points: model.history(for: primary.vehicle.sn)
                                )
                            } label: {
                                VehicleHealthPanel(snapshot: primary)
                            }
                            .buttonStyle(.plain)
                                .padding(.horizontal, 16)

                            NavigationLink {
                                NinebotVehicleDetailView(model: model, sn: primary.vehicle.sn)
                            } label: {
                                VehicleBasicsPanel(snapshot: primary)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                        } else {
                            EmptyDashboardView(hasConfiguration: model.hasConfiguration)
                                .padding(.horizontal, 16)
                        }

                        if model.dashboard.vehicles.count > 1 {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("车辆概览")
                                    .font(.headline)
                                    .padding(.horizontal, 16)

                                ForEach(model.dashboard.vehicles) { snapshot in
                                    VehicleRow(
                                        snapshot: snapshot,
                                        isSelected: snapshot.vehicle.sn == (model.dashboard.selectedSN ?? model.dashboard.primaryVehicle?.vehicle.sn)
                                    ) {
                                        model.selectVehicle(sn: snapshot.vehicle.sn)
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                }
                .coordinateSpace(name: "dashboardScroll")
                .onPreferenceChange(DashboardScrollOffsetPreferenceKey.self) { value in
                    scrollOffset = max(0, -value)
                }
                .simultaneousGesture(pullRefreshGesture)

                if let primary = model.dashboard.primaryVehicle, showsRefreshIndicator {
                    PullRefreshTimestampCircle(
                        snapshot: primary,
                        isLoading: isDashboardRefreshLoading,
                        pullDistance: refreshIndicatorDistance,
                        topInset: proxy.safeAreaInsets.top
                    )
                    .zIndex(9)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                if let primary = model.dashboard.primaryVehicle, showsCompactHeader {
                    CompactVehicleHeader(snapshot: primary, topInset: proxy.safeAreaInsets.top)
                        .zIndex(10)
                        .transition(.opacity)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarHidden(true)
        .animation(.easeInOut(duration: 0.18), value: showsCompactHeader)
        .animation(.easeInOut(duration: 0.18), value: showsRefreshIndicator)
        .onAppear {
            if isDashboardRefreshLoading {
                showPullTimestamp(distance: 84, autoDismiss: false)
            }
        }
        .onChange(of: model.isLoading) { _, isLoading in
            if isDashboardRefreshLoading {
                showPullTimestamp(distance: 84, autoDismiss: false)
            } else if !isLoading {
                schedulePullTimestampDismiss()
            }
        }
        .sheet(isPresented: $isShowingVehiclePicker) {
            VehiclePickerSheet(
                dashboard: model.dashboard,
                fallbackAccount: model.currentAccountDisplay
            ) { sn in
                model.selectVehicle(sn: sn)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var showsCompactHeader: Bool {
        scrollOffset > 24
    }

    private func activeVehicleAction(for sn: String) -> NinebotVehicleAction? {
        guard model.activeVehicleActionSN == sn else { return nil }
        return model.activeVehicleAction
    }

    private func performVehicleAction(_ action: NinebotVehicleAction, sn: String) {
        guard !model.isLoading else { return }
        Task {
            await model.perform(action, sn: sn)
        }
    }

    private var isDashboardRefreshLoading: Bool {
        guard model.isLoading else { return false }
        let message = model.loadingMessage ?? ""
        return message.contains("刷新车况") || message.contains("解析车辆位置")
    }

    private var showsRefreshIndicator: Bool {
        isShowingPullTimestamp || isDashboardRefreshLoading
    }

    private var refreshIndicatorDistance: CGFloat {
        isDashboardRefreshLoading ? max(pullDistance, 84) : pullDistance
    }

    private var dashboardBackground: some View {
        Color.teslaPageBackground
    }

    private var pullRefreshGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                if !isTrackingPullGesture {
                    isTrackingPullGesture = true
                    pullGestureStartedAtTop = scrollOffset <= 1 && value.translation.height > 0
                }

                guard pullGestureStartedAtTop, scrollOffset <= 1, value.translation.height > 0, !model.isLoading else { return }
                let distance = min(value.translation.height, 110)
                pullDistance = distance
                if distance > 16 {
                    showPullTimestamp(distance: distance, autoDismiss: false)
                }
            }
            .onEnded { value in
                defer {
                    isTrackingPullGesture = false
                    pullGestureStartedAtTop = false
                }

                guard pullGestureStartedAtTop, scrollOffset <= 1, value.translation.height > 0 else {
                    schedulePullTimestampDismiss(delay: 200_000_000)
                    return
                }

                if value.translation.height > 86 {
                    triggerPullRefreshIfNeeded()
                } else {
                    schedulePullTimestampDismiss(delay: 220_000_000)
                }
            }
    }

    private func showPullTimestamp(distance: CGFloat, autoDismiss: Bool = true) {
        pullDistance = max(pullDistance, distance)
        isShowingPullTimestamp = true
        if autoDismiss, !model.isLoading {
            schedulePullTimestampDismiss(delay: 1_200_000_000)
        }
    }

    private func triggerPullRefreshIfNeeded() {
        guard !didTriggerPullRefresh, !model.isLoading else { return }
        didTriggerPullRefresh = true
        showPullTimestamp(distance: max(pullDistance, 56), autoDismiss: false)

        Task {
            await model.refreshDashboard()
            didTriggerPullRefresh = false
            schedulePullTimestampDismiss(delay: 450_000_000)
        }
    }

    private func schedulePullTimestampDismiss(delay: UInt64 = 900_000_000) {
        let dismissID = UUID()
        pullTimestampDismissID = dismissID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard pullTimestampDismissID == dismissID, !model.isLoading else { return }
            isShowingPullTimestamp = false
            pullDistance = 0
        }
    }
}

private struct PullRefreshTimestampCircle: View {
    var snapshot: NinebotVehicleSnapshot
    var isLoading: Bool
    var pullDistance: CGFloat
    var topInset: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .overlay {
                    Circle()
                        .stroke(Color.teslaHairline, lineWidth: 1)
                }

            VStack(spacing: 2) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.teslaGreen)
                    Text("更新中")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                        .lineLimit(1)
                } else {
                    Text("更新")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                        .lineLimit(1)
                    Text(formatTime(snapshot.state.updatedAt))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.teslaPrimaryText)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 62, height: 62)
        .shadow(color: Color.black.opacity(0.10), radius: 16, x: 0, y: 8)
        .scaleEffect(0.86 + min(1, pullDistance / 84) * 0.14)
        .opacity(min(1, max(0.35, pullDistance / 44)))
        .padding(.top, topInset + 6)
    }
}

private struct NinebotVehicleDetailView: View {
    @ObservedObject var model: NinebotViewModel
    var sn: String
    @State private var copiedMessage: String?

    var body: some View {
        Group {
            if let snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VehicleHeroCard(snapshot: snapshot)
                        VehicleDetailPanel(
                            snapshot: snapshot,
                            resolvedAddress: resolvedAddress,
                            isLoading: model.isLoading,
                            onRingBell: {
                                Task { await model.perform(.bell, sn: snapshot.vehicle.sn) }
                            }
                        )
                        VehicleChargingAnalysisPanel(
                            snapshot: snapshot,
                            points: model.history(for: snapshot.vehicle.sn)
                        )
                        RawPayloadCopyPanel(snapshot: snapshot, copiedMessage: $copiedMessage)
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("车辆数据已失效")
                        .font(.headline)
                    Text("返回车控页后重新选择车辆")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.teslaPageBackground)
        .navigationTitle("车辆详情")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if let copiedMessage {
                Text(copiedMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: copiedMessage)
    }

    private var snapshot: NinebotVehicleSnapshot? {
        model.dashboard.vehicles.first { $0.vehicle.sn == sn } ?? model.dashboard.primaryVehicle
    }

    private var resolvedAddress: String? {
        snapshot.flatMap { model.resolvedAddressText(for: $0) }
    }
}

private struct NinebotBatteryDetailView: View {
    var snapshot: NinebotVehicleSnapshot
    var points: [NinebotVehicleHistoryPoint]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BatteryDetailHeroCard(snapshot: snapshot)
                BatteryDetailMetricsCard(snapshot: snapshot)

                if snapshot.state.isCharging == true || snapshot.state.isFullyCharged {
                    BatteryChargingDetailCard(snapshot: snapshot)
                }

                VehicleChargingAnalysisPanel(snapshot: snapshot, points: points)
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(Color.teslaPageBackground.ignoresSafeArea())
        .navigationTitle("电池")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BatteryDetailHeroCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.state.isFullyCharged ? "已充满" : snapshot.state.chargingStateText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(snapshot.state.isCharging == true || snapshot.state.isFullyCharged ? Color.teslaGreen : Color.teslaSecondaryText)
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(snapshot.state.batteryText)
                            .font(.system(size: 52, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(batteryTextColor(snapshot.state))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text("当前电量")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.teslaSecondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                BatteryGauge(value: snapshot.state.battery)
                    .frame(width: 72, height: 72)
            }

            BatteryProgressBar(value: snapshot.state.batteryFraction)

            HStack(spacing: 10) {
                BatteryDetailMiniMetric(title: "电压", value: snapshot.state.batteryVoltageText, systemImage: "bolt.batteryblock.fill")
                BatteryDetailMiniMetric(title: "温度", value: snapshot.state.batteryTemperatureText, systemImage: "thermometer.medium")
            }
        }
        .padding(18)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
    }
}

private struct BatteryDetailMetricsCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            BasicInfoTile(title: "电压", value: snapshot.state.batteryVoltageText, systemImage: "bolt.batteryblock.fill")
            BasicInfoTile(title: "温度", value: snapshot.state.batteryTemperatureText, systemImage: "thermometer.medium")
            BasicInfoTile(title: "循环次数", value: snapshot.state.batteryCycleCountText, systemImage: "arrow.trianglehead.2.clockwise")
            BasicInfoTile(title: "更新时间", value: formatTime(snapshot.state.updatedAt), systemImage: "clock.fill")
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
    }
}

private struct BatteryChargingDetailCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(snapshot.state.isFullyCharged ? "充电完成" : "正在充电", systemImage: snapshot.state.isFullyCharged ? "checkmark.circle.fill" : "bolt.fill")
                    .font(.headline)
                    .foregroundStyle(Color.teslaGreen)

                Spacer()

                Text(snapshot.state.estimatedFullChargeTimeText)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
            }

            DetailSection(title: "充电信息") {
                DetailRow(title: "充电功率", value: snapshot.state.chargingPowerText, systemImage: "bolt.fill")
                DetailRow(title: "充电速度", value: snapshot.state.estimatedChargingSpeedText, systemImage: "bolt.car.fill")
                DetailRow(title: "预计充满", value: snapshot.state.estimatedFullChargeTimeText, systemImage: "timer")
                DetailRow(title: "满电时间", value: snapshot.state.estimatedFullChargeClockText, systemImage: "clock.badge.checkmark.fill")
                DetailRow(title: "充至 80%", value: snapshot.state.estimatedChargeTo80TimeText, systemImage: "battery.75")
                DetailRow(title: "接口剩余", value: snapshot.state.remainingChargeTimeText, systemImage: "clock.badge.questionmark")
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
    }
}

private struct BatteryDetailMiniMetric: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.teslaGreen)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct VehicleChargingAnalysisPanel: View {
    var snapshot: NinebotVehicleSnapshot
    var points: [NinebotVehicleHistoryPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("充电分析")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text(snapshot.state.isCharging == true ? "当前正在充电" : "按本地快照统计")
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer()

                Text(snapshot.state.chargingStateText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(snapshot.state.isCharging == true ? Color.teslaGreen : Color.teslaSecondaryText)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                BasicInfoTile(title: "功率", value: snapshot.state.chargingPowerText, systemImage: "bolt.fill")
                BasicInfoTile(title: "温度", value: snapshot.state.batteryTemperatureText, systemImage: "thermometer.medium")
                BasicInfoTile(title: "电压", value: snapshot.state.batteryVoltageText, systemImage: "bolt.batteryblock.fill")
                BasicInfoTile(title: "充电速度", value: snapshot.state.estimatedChargingSpeedText, systemImage: "bolt.car.fill")
                BasicInfoTile(title: "充电快照", value: "\(chargingPoints.count) 个", systemImage: "clock.arrow.circlepath")
                BasicInfoTile(title: "电量变化", value: chargingDeltaText, systemImage: "battery.100")
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
    }

    private var chargingPoints: [NinebotVehicleHistoryPoint] {
        points.filter { $0.isCharging == true }.sorted { $0.date < $1.date }
    }

    private var chargingDeltaText: String {
        guard let first = chargingPoints.first?.battery,
              let last = chargingPoints.last?.battery else {
            return "--%"
        }
        let delta = last - first
        return "\(delta >= 0 ? "+" : "")\(delta)%"
    }
}

private struct NinebotVehicleMapView: View {
    var snapshot: NinebotVehicleSnapshot
    var address: String?
    var coordinate: CLLocationCoordinate2D
    var isLoading: Bool
    var onRingBell: () -> Void
    @State private var cameraPosition: MapCameraPosition
    @StateObject private var userLocationProvider = VehicleMapUserLocationProvider()

    init(
        snapshot: NinebotVehicleSnapshot,
        address: String?,
        coordinate: CLLocationCoordinate2D,
        isLoading: Bool,
        onRingBell: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.address = address
        self.coordinate = coordinate
        self.isLoading = isLoading
        self.onRingBell = onRingBell
        _cameraPosition = State(initialValue: .region(Self.region(for: coordinate)))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $cameraPosition) {
                Marker(snapshot.vehicle.displayName, coordinate: coordinate)
                    .tint(Color.teslaGreen)

                if let userCoordinate = userLocationProvider.coordinate {
                    Marker("我的位置", systemImage: "location.fill", coordinate: userCoordinate)
                        .tint(.blue)
                }
            }
            .ignoresSafeArea(edges: .bottom)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(snapshot.vehicle.displayName)
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                        .lineLimit(1)

                    Text(locationTitle)
                        .font(.subheadline)
                        .foregroundStyle(Color.teslaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    ControlMetricPill(title: "纬度", value: formatCoordinate(coordinate.latitude), systemImage: "map")
                    ControlMetricPill(title: "经度", value: formatCoordinate(coordinate.longitude), systemImage: "map.fill")
                }

                if let distanceText = userDistanceText {
                    ControlMetricPill(title: "我的距离", value: distanceText, systemImage: "location.fill")
                }

                HStack(spacing: 10) {
                    Button {
                        onRingBell()
                    } label: {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("寻车鸣笛", systemImage: "bell.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)

                    Button {
                        openInAppleMaps()
                    } label: {
                        Label("Apple 地图", systemImage: "map.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.teslaGreen)
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(16)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(16)
        }
        .navigationTitle("车辆位置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            userLocationProvider.start()
            fitVisibleRegion()
        }
        .onDisappear {
            userLocationProvider.stop()
        }
        .onChange(of: userLocationProvider.locationVersion) { _, _ in
            fitVisibleRegion()
        }
    }

    private var locationTitle: String {
        guard let address = address?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            return coordinateText(coordinate.latitude, coordinate.longitude)
        }
        return address
    }

    private func openInAppleMaps() {
        let placemark = MKPlacemark(coordinate: coordinate)
        let mapItem = MKMapItem(placemark: placemark)
        mapItem.name = snapshot.vehicle.displayName
        mapItem.openInMaps()
    }

    private var userDistanceText: String? {
        guard let userCoordinate = userLocationProvider.coordinate else { return nil }
        let vehicleLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let userLocation = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
        let meters = userLocation.distance(from: vehicleLocation)
        if meters >= 1000 {
            return formatNumber(meters / 1000, unit: " km", maximumFractionDigits: 1)
        }
        return formatNumber(meters, unit: " m", maximumFractionDigits: 0)
    }

    private func fitVisibleRegion() {
        guard let userCoordinate = userLocationProvider.coordinate else {
            cameraPosition = .region(Self.region(for: coordinate))
            return
        }

        cameraPosition = .region(Self.region(for: [coordinate, userCoordinate]))
    }

    private static func region(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
        )
    }

    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
            )
        }

        let minLatitude = coordinates.map(\.latitude).min() ?? coordinates[0].latitude
        let maxLatitude = coordinates.map(\.latitude).max() ?? coordinates[0].latitude
        let minLongitude = coordinates.map(\.longitude).min() ?? coordinates[0].longitude
        let maxLongitude = coordinates.map(\.longitude).max() ?? coordinates[0].longitude
        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
        let latitudeDelta = max((maxLatitude - minLatitude) * 1.8, 0.006)
        let longitudeDelta = max((maxLongitude - minLongitude) * 1.8, 0.006)

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}

@MainActor
private final class VehicleMapUserLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var locationVersion = 0

    private let manager = CLLocationManager()

    override init() {
        super.init()
        authorizationStatus = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    func start() {
        guard CLLocationManager.locationServicesEnabled() else { return }

        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }

        guard isAuthorized else { return }
        manager.startUpdatingLocation()
        manager.requestLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            if isAuthorized {
                start()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last(where: Self.isUsableLocation) else { return }
            coordinate = mapKitCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            locationVersion += 1
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    }

    private static func isUsableLocation(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= 200
            && (-90...90).contains(location.coordinate.latitude)
            && (-180...180).contains(location.coordinate.longitude)
    }
}

struct NinebotTripsTabView: View {
    @ObservedObject var model: NinebotViewModel

    var body: some View {
        if let snapshot = model.dashboard.primaryVehicle {
            NinebotTripsView(model: model, snapshot: snapshot)
        } else {
            ContentUnavailableView(
                "暂无接口行程",
                systemImage: "road.lanes",
                description: Text("登录并刷新车辆数据后可查看服务端行程与官方接口轨迹。")
            )
            .background(Color.teslaPageBackground.ignoresSafeArea())
        }
    }
}

private struct NinebotTripsView: View {
    @ObservedObject var model: NinebotViewModel
    var snapshot: NinebotVehicleSnapshot
    @State private var selectedMonth = tripMonthString(for: Date())

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TripHeroPanel(snapshot: snapshot)
                NavigationLink {
                    TripTrendView(snapshot: snapshot)
                } label: {
                    TripTrendEntryCard(snapshot: snapshot)
                }
                .buttonStyle(.plain)
                TripMonthFilterPanel(
                    months: monthOptions,
                    selectedMonth: selectedMonth,
                    nextFetchMonth: nextFetchMonth,
                    isSyncing: model.syncingTravelMonth != nil,
                    onSelect: { selectedMonth = $0 },
                    onFetchOlder: {
                        let targetMonth = nextFetchMonth
                        selectedMonth = targetMonth
                        Task {
                            await model.syncTravelMonth(vehicleSN: snapshot.vehicle.sn, month: targetMonth)
                        }
                    }
                )
                RideListSection(
                    model: model,
                    records: filteredRecords,
                    vehicleSN: snapshot.vehicle.sn,
                    selectedMonth: selectedMonth
                )
            }
            .padding(16)
        }
        .background(Color.teslaPageBackground.ignoresSafeArea())
        .navigationTitle("行程")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var monthOptions: [String] {
        var months = Set(snapshot.state.rides.compactMap(tripMonthString(for:)))
        months.insert(tripMonthString(for: Date()))
        months.insert(selectedMonth)
        return months.sorted(by: >)
    }

    private var filteredRecords: [NinebotRideRecord] {
        snapshot.state.rides.filter { tripMonthString(for: $0) == selectedMonth }
    }

    private var nextFetchMonth: String {
        previousTripMonth(before: monthOptions.min() ?? selectedMonth)
    }
}

private struct TripMonthFilterPanel: View {
    var months: [String]
    var selectedMonth: String
    var nextFetchMonth: String
    var isSyncing: Bool
    var onSelect: (String) -> Void
    var onFetchOlder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("月份筛选")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text("当前 \(tripMonthDisplayName(selectedMonth))")
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer()

                Button(action: onFetchOlder) {
                    HStack(spacing: 6) {
                        if isSyncing {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        Text("获取 \(tripMonthDisplayName(nextFetchMonth))")
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Color.teslaGreen)
                .disabled(isSyncing)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(months, id: \.self) { month in
                        Button {
                            onSelect(month)
                        } label: {
                            Text(tripMonthDisplayName(month))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(month == selectedMonth ? Color.white : Color.teslaPrimaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(month == selectedMonth ? Color.teslaGreen : Color.teslaCardBackground)
                                .clipShape(Capsule())
                                .overlay {
                                    Capsule()
                                        .stroke(month == selectedMonth ? Color.clear : Color.teslaHairline, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(14)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private func tripMonthString(for record: NinebotRideRecord) -> String? {
    guard let date = record.startedAt ?? record.endedAt else { return nil }
    return tripMonthString(for: date)
}

private func tripMonthString(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    formatter.dateFormat = "yyyyMM"
    return formatter.string(from: date)
}

private func previousTripMonth(before month: String) -> String {
    guard month.count == 6,
          let year = Int(month.prefix(4)),
          let monthValue = Int(month.suffix(2)) else {
        return tripMonthString(for: Date())
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    let date = calendar.date(from: DateComponents(year: year, month: monthValue, day: 1)) ?? Date()
    let previous = calendar.date(byAdding: .month, value: -1, to: date) ?? date
    return tripMonthString(for: previous)
}

private func tripMonthDisplayName(_ month: String) -> String {
    guard month.count == 6 else { return month }
    let year = month.prefix(4)
    let monthValue = month.suffix(2)
    return "\(year).\(monthValue)"
}

private struct VehiclePickerSheet: View {
    var dashboard: NinebotDashboard
    var fallbackAccount: String
    var onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(accountGroups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 2)

                            ForEach(group.vehicles) { snapshot in
                                Button {
                                    onSelect(snapshot.vehicle.sn)
                                    dismiss()
                                } label: {
                                    VehiclePickerRow(
                                        snapshot: snapshot,
                                        isSelected: snapshot.vehicle.sn == selectedSN
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.teslaPageBackground)
            .navigationTitle("切换车辆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var selectedSN: String? {
        dashboard.selectedSN ?? dashboard.primaryVehicle?.vehicle.sn
    }

    private var accountGroups: [VehiclePickerAccountGroup] {
        var groups: [VehiclePickerAccountGroup] = []

        for snapshot in dashboard.vehicles {
            let title = vehicleAccountTitle(for: snapshot, fallback: fallbackAccount)
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].vehicles.append(snapshot)
            } else {
                groups.append(VehiclePickerAccountGroup(title: title, vehicles: [snapshot]))
            }
        }

        return groups
    }
}

private struct VehiclePickerAccountGroup: Identifiable {
    var title: String
    var vehicles: [NinebotVehicleSnapshot]

    var id: String { title }
}

private func vehicleAccountTitle(for snapshot: NinebotVehicleSnapshot, fallback: String) -> String {
    let keys = [
        "account",
        "account_id",
        "accountId",
        "phone",
        "mobile",
        "user_phone",
        "userPhone",
        "owner_phone",
        "ownerPhone",
        "bind_phone",
        "bindPhone",
        "user_id",
        "userId",
        "business_uid",
        "businessUID",
        "uid",
        "uuid"
    ]

    if let raw = snapshot.vehicle.raw {
        for key in keys {
            if let value = raw[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return "\(value) 账号"
            }
        }
    }

    let fallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    if !fallback.isEmpty, fallback != "未绑定账号" {
        return "\(fallback) 账号"
    }
    return "当前代理账号"
}

private struct VehiclePickerRow: View {
    var snapshot: NinebotVehicleSnapshot
    var isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VehicleImage(urlString: snapshot.vehicle.imageURLString, size: 52)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(snapshot.vehicle.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(snapshot.state.batteryText)
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(batteryTextColor(snapshot.state))
                }

                Text(snapshot.vehicle.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Label(snapshot.state.primaryStatusText, systemImage: statusSystemImage(snapshot.state))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor(snapshot.state))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.headline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.teslaGreen : Color(.tertiaryLabel))
                .padding(.top, 2)
        }
        .padding(12)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: 8)
    }
}

private struct CompactVehicleHeader: View {
    var snapshot: NinebotVehicleSnapshot
    var topInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.teslaPageBackground
                .frame(height: topInset)
            Text("\(snapshot.vehicle.displayName)·\(snapshot.state.batteryText)·\(compactVehicleStatusText(snapshot.state))")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color(.label))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 44)
                .padding(.horizontal, 16)
                .background(Color.teslaPageBackground)
        }
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 0.5)
        }
    }
}

private struct VehicleControlHero: View {
    var snapshot: NinebotVehicleSnapshot
    var canSwitchVehicle: Bool
    var resolvedAddress: String?
    var showsUpdateTime: Bool
    var isLoading: Bool
    var onRingBell: () -> Void
    var onSwitchVehicle: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        guard canSwitchVehicle else { return }
                        onSwitchVehicle()
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .center, spacing: 6) {
                                Text(snapshot.vehicle.displayName)
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(Color.teslaPrimaryText)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)

                                if canSwitchVehicle {
                                    Image(systemName: "chevron.down")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(Color.teslaSecondaryText)
                                }
                            }

                            Text(snapshot.vehicle.model)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color.teslaSecondaryText)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(canSwitchVehicle ? "切换车辆" : snapshot.vehicle.displayName)

                    if let resolvedAddress = normalizedResolvedAddress {
                        if let coordinate = vehicleCoordinate(snapshot.state) {
                            NavigationLink {
                                NinebotVehicleMapView(
                                    snapshot: snapshot,
                                    address: resolvedAddress,
                                    coordinate: coordinate,
                                    isLoading: isLoading,
                                    onRingBell: onRingBell
                                )
                            } label: {
                                Text(resolvedAddress)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Color.teslaSecondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(resolvedAddress)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.teslaSecondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    } else if showsUpdateTime {
                        Text("更新 \(formatDate(snapshot.state.updatedAt))")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.teslaSecondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 12)

                StatusChip(
                    title: compactVehicleStatusText(snapshot.state),
                    systemImage: statusSystemImage(snapshot.state),
                    color: statusColor(snapshot.state)
                )
            }

            VStack(spacing: 6) {
                Text(snapshot.state.localEstimatedMileageText)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text("预计可行驶")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
            }

            VehicleMotionScene(snapshot: snapshot)
                .frame(maxWidth: .infinity)
                .frame(height: 218)

            VStack(spacing: 12) {
                BatteryProgressBar(value: snapshot.state.batteryFraction)

                HStack(spacing: 10) {
                    TeslaHeroMetric(title: "电量", value: snapshot.state.batteryText, systemImage: "battery.100")
                    Divider()
                        .frame(height: 34)
                    TeslaHeroMetric(title: "接口续航", value: snapshot.state.enduranceText, systemImage: "road.lanes")
                    Divider()
                        .frame(height: 34)
                    TeslaHeroMetric(title: "最高速度", value: snapshot.state.maximumSpeedText, systemImage: "gauge.with.dots.needle.67percent")
                }
            }

            if snapshot.state.isCharging == true && !snapshot.state.isFullyCharged {
                ChargingStatusView(state: snapshot.state)
                    .padding(.horizontal, -6)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var normalizedResolvedAddress: String? {
        guard let value = resolvedAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}


/// The main vehicle scene uses the approved high-fidelity rider reference
/// instead of a hand-drawn skeletal figure. Lightweight native overlays keep
/// the wheels and roadway visibly moving without altering rider proportions.
private struct VehicleMotionScene: View {
    var snapshot: NinebotVehicleSnapshot

    @State private var isAnimating = false
    @State private var rideStartedAt: Date?
    @StateObject private var rideWeather = RideWeatherProvider()
    @StateObject private var weatherLocation = RideWeatherLocationProvider()

    /// The Ninebot status endpoint used by this app often exposes no live
    /// speed/movement fields. In that payload the reliable active-ride signal
    /// is "powered on + unlocked" (the same state shown by the dashboard's
    /// “滑动关锁” control). Use it as the fallback so the riding 3D scene is
    /// actually visible while a rider has the vehicle active, instead of
    /// incorrectly falling back to the parked card shown in the screenshot.
    private var mode: VehicleMotionSceneMode {
        if snapshot.state.isCharging == true {
            return .charging
        }
        return hasExplicitLiveMovement || isRideSessionActive ? .riding : .parked
    }

    private var isRideSessionActive: Bool {
        snapshot.state.isPoweredOn == true && snapshot.state.isLocked != true
    }

    private var hasExplicitLiveMovement: Bool {
        guard let status = snapshot.state.rawStatus else { return false }
        let movementKeys = ["isRiding", "riding", "isMoving", "moving", "inMotion", "driving"]
        return movementKeys.contains(where: { status[$0]?.boolValue == true })
    }

    private func updateRideTimer(for newMode: VehicleMotionSceneMode) {
        if newMode == .riding {
            // The session is written to the App Group by the view model. Read
            // it here rather than creating a fresh local start date so the HUD
            // retains its original duration after the app is reopened.
            let restoredStart = NinebotSharedStore().loadActiveRideSession()
                .flatMap { $0.vehicleSN == snapshot.vehicle.sn ? $0.startedAt : nil }
            if let restoredStart {
                rideStartedAt = restoredStart
            } else if rideStartedAt == nil {
                rideStartedAt = .now
            }
        } else {
            rideStartedAt = nil
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                switch mode {
                case .charging:
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { timeline in
                        chargingScene(
                            in: proxy.size,
                            phase: timeline.date.timeIntervalSinceReferenceDate,
                            weather: rideWeather.snapshot
                        )
                    }
                case .parked:
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { timeline in
                        parkedScene(
                            in: proxy.size,
                            phase: timeline.date.timeIntervalSinceReferenceDate,
                            weather: rideWeather.snapshot
                        )
                    }
                case .riding:
                    // A TimelineView keeps this scene advancing even when the
                    // dashboard itself receives no new vehicle-state updates.
                    // This avoids the previous one-time state transition where
                    // the riding artwork could look like a still image.
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)) { timeline in
                        ridingScene(
                            in: proxy.size,
                            phase: timeline.date.timeIntervalSinceReferenceDate,
                            now: timeline.date,
                            weather: rideWeather.snapshot
                        )
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySceneLabel)
        }
        .onAppear {
            isAnimating = true
            updateRideTimer(for: mode)
            // The vehicle API does not always include its latest GPS reading.
            // Fall back to the phone's one-shot location so weather data can
            // still be shown instead of permanently rendering placeholders.
            weatherLocation.requestCurrentLocation()
        }
        .onChange(of: mode) { _, newMode in
            updateRideTimer(for: newMode)
        }
        .onDisappear { isAnimating = false }
        .task(id: weatherRequestID) {
            await rideWeather.refresh(
                latitude: weatherCoordinate?.latitude,
                longitude: weatherCoordinate?.longitude
            )
        }
        // Weather observations are refreshed independently of vehicle-state
        // polling. Five minutes keeps the UI current without creating an
        // unnecessary request for every animation frame.
        .onReceive(Timer.publish(every: 300, on: .main, in: .common).autoconnect()) { _ in
            // Keep phone fallback location fresh too. Vehicle GPS remains the
            // priority, but a parked/charging vehicle can have an old GPS fix.
            weatherLocation.requestCurrentLocation()
            Task {
                await rideWeather.refresh(
                    latitude: weatherCoordinate?.latitude,
                    longitude: weatherCoordinate?.longitude,
                    force: true
                )
            }
        }
    }

    private var weatherCoordinate: CLLocationCoordinate2D? {
        if let latitude = snapshot.state.latitude,
           let longitude = snapshot.state.longitude,
           CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) {
            // Send the raw vehicle GPS to the weather providers. MapKit uses
            // its own China-coordinate conversion for display, but Open-Meteo
            // expects WGS-84 values; converting this coordinate for the map
            // here would move the weather lookup away from the vehicle.
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        // Only use the phone as a one-shot fallback while the vehicle endpoint
        // has not returned a coordinate at all.
        return weatherLocation.coordinate
    }

    private var weatherRequestID: String {
        guard let coordinate = weatherCoordinate else { return "weather-awaiting-location" }
        return String(format: "%.3f,%.3f", coordinate.latitude, coordinate.longitude)
    }

    @ViewBuilder
    private func chargingScene(
        in size: CGSize,
        phase: TimeInterval,
        weather: RideWeatherSnapshot
    ) -> some View {
        ZStack {
            // Charging and parked modes share the exact same stationary city,
            // road and live weather. Only the charging equipment and energy
            // flow animate above this environment.
            LiveRideEnvironment(
                weather: weather,
                phase: phase,
                animatesRoadAndCity: false
            )

            Ellipse()
                .fill(Color.black.opacity(weather.isNight ? 0.34 : 0.19))
                .frame(width: size.width * 0.53, height: size.height * 0.065)
                .blur(radius: 7)
                .offset(x: size.width * 0.015, y: size.height * 0.30)

            chargingCable(size: size)

            // Energy must travel in the physical charging direction: from the
            // right-side charging pillar into this vehicle's battery socket.
            ChargingCableEnergyFlow(phase: phase)

            // Always use the selected vehicle artwork from the API. Do not
            // substitute the scooter shown in any visual reference image.
            VehicleImage(urlString: snapshot.vehicle.imageURLString, size: min(size.width * 0.74, 276), showsBackground: false)
                .shadow(color: .black.opacity(weather.isNight ? 0.32 : 0.21), radius: 12, x: 0, y: 8)
                .offset(x: -size.width * 0.045, y: size.height * 0.03)

            // Keep the charging pile visually secondary to the customer's
            // vehicle: a slimmer body and compact illuminated face create a
            // balanced right-side anchor instead of competing with the car.
            ChargePillar(isAnimating: isAnimating)
                .frame(width: min(size.width * 0.15, 56), height: size.height * 0.57)
                .offset(x: size.width * 0.39, y: size.height * 0.14)

            // The charging HUD is intentionally compact, leaving the handlebar
            // and front half of the real vehicle unobstructed.
            ChargeHudCard(state: snapshot.state, isAnimating: isAnimating)
                .frame(width: min(size.width * 0.245, 86))
                .offset(x: size.width * 0.015, y: -size.height * 0.275)

            Circle()
                .stroke(Color.teslaGreen.opacity(0.74), lineWidth: 1.4)
                .frame(width: 12, height: 12)
                .scaleEffect(0.72 + CGFloat((phase * 1.25).truncatingRemainder(dividingBy: 1.0)) * 1.15)
                .opacity(1 - (phase * 1.25).truncatingRemainder(dividingBy: 1.0))
                .shadow(color: Color.teslaGreen.opacity(0.74), radius: 5)
                .position(x: size.width * 0.57, y: size.height * 0.66)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            CityEnvironmentReadout(
                weather: weather,
                rideDurationText: nil,
                sceneSize: size
            )
        }
        .clipped()
    }

    private var accessibilitySceneLabel: String {
        switch mode {
        case .charging:
            return "车辆正在进行三维充电动画"
        case .parked:
            return "车辆已停稳"
        case .riding:
            return "车辆正在进行三维骑行动画"
        }
    }

    @ViewBuilder
    private func parkedScene(
        in size: CGSize,
        phase: TimeInterval,
        weather: RideWeatherSnapshot
    ) -> some View {
        ZStack {
            // Parked and riding views deliberately share one city scene so the
            // vehicle never falls back to a disconnected plain background.
            LiveRideEnvironment(
                weather: weather,
                phase: phase,
                animatesRoadAndCity: false
            )


            Ellipse()
                .fill(Color.black.opacity(weather.isNight ? 0.34 : 0.19))
                .frame(width: size.width * 0.53, height: size.height * 0.065)
                .blur(radius: 7)
                .offset(x: size.width * 0.045, y: size.height * 0.30)

            VehicleImage(
                urlString: snapshot.vehicle.imageURLString,
                size: min(size.width * 0.76, 270),
                showsBackground: false
            )
            .shadow(color: .black.opacity(weather.isNight ? 0.32 : 0.21), radius: 12, x: 0, y: 8)
            .offset(x: size.width * 0.045, y: size.height * 0.03)

            Text(snapshot.state.isPoweredOn == true ? "车辆已停稳 · 已上电" : "车辆已停稳")
                .font(.system(size: min(max(size.width * 0.034, 11), 13), weight: .semibold, design: .rounded))
                .foregroundStyle(weather.isNight ? Color.white.opacity(0.88) : Color.black.opacity(0.68))
                .shadow(color: weather.isNight ? .black.opacity(0.72) : .white.opacity(0.82), radius: 2)
                .lineLimit(1)
                .offset(x: -size.width * 0.27, y: -size.height * 0.315)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            CityEnvironmentReadout(
                weather: weather,
                rideDurationText: nil,
                sceneSize: size
            )
        }
        .clipped()
    }

    @ViewBuilder
    private func ridingScene(
        in size: CGSize,
        phase: TimeInterval,
        now: Date,
        weather: RideWeatherSnapshot
    ) -> some View {
        let vehicleBob = CGFloat(sin(phase * 6.4)) * 0.55
        let vehicleDrift = CGFloat(sin(phase * 1.8)) * 0.42

        ZStack {
            LiveRideEnvironment(
                weather: weather,
                phase: phase
            )
            RideMotionStreaks(phase: phase)

            // Keep the customer vehicle entirely within the road composition.
            Ellipse()
                .fill(Color.black.opacity(weather.isNight ? 0.34 : 0.19))
                .frame(width: size.width * 0.51, height: size.height * 0.062)
                .blur(radius: 6)
                .offset(x: size.width * 0.055, y: size.height * 0.295)

            VehicleImage(
                urlString: snapshot.vehicle.imageURLString,
                size: min(size.width * 0.76, 270),
                showsBackground: false
            )
            .shadow(color: .black.opacity(weather.isNight ? 0.32 : 0.21), radius: 11, x: 0, y: 7)
            .offset(x: size.width * 0.055 + vehicleDrift, y: size.height * 0.025 + vehicleBob)

        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            CityEnvironmentReadout(
                weather: weather,
                rideDurationText: rideDurationText(now: now),
                sceneSize: size
            )
        }
        .clipped()
    }

    private func rideDurationText(now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(rideStartedAt ?? now)))
        let hours = elapsed / 3_600
        let minutes = (elapsed % 3_600) / 60
        let seconds = elapsed % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func chargingCable(size: CGSize) -> some View {
        let chargerPort = CGPoint(x: size.width * 0.87, y: size.height * 0.58)
        let batteryPort = CGPoint(x: size.width * 0.57, y: size.height * 0.66)
        let firstControl = CGPoint(x: size.width * 0.80, y: size.height * 0.84)
        let secondControl = CGPoint(x: size.width * 0.65, y: size.height * 0.54)

        return ZStack {
            Path { path in
                path.move(to: chargerPort)
                path.addCurve(to: batteryPort, control1: firstControl, control2: secondControl)
            }
            .stroke(Color.black.opacity(0.64), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))

            Path { path in
                path.move(to: chargerPort)
                path.addCurve(to: batteryPort, control1: firstControl, control2: secondControl)
            }
            .stroke(Color.teslaGreen.opacity(0.38), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [2, 11]))
            .shadow(color: Color.teslaGreen.opacity(0.42), radius: 2)
        }
    }
}


/// 道路动物的行进方向。动物源图默认面向左侧，因此向右移动时在绘制层镜像。
private enum VehicleMotionSceneMode: Equatable {
    case charging
    case parked
    case riding
}

private struct ChargePillar: View {
    var isAnimating: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.10, green: 0.12, blue: 0.13), Color(red: 0.025, green: 0.04, blue: 0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.26))
                        .frame(width: 1.1)
                        .padding(.vertical, 8)
                        .padding(.leading, 4)
                }
                .shadow(color: .black.opacity(0.20), radius: 8, x: -3, y: 7)

            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.black)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.teslaGreen.opacity(0.8), lineWidth: 1.25)
                        }
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(Color.teslaGreen)
                        .shadow(color: Color.teslaGreen.opacity(0.9), radius: isAnimating ? 8 : 3)
                        .scaleEffect(isAnimating ? 1.08 : 0.92)
                }
                .frame(width: 36, height: 36)

                Capsule()
                    .fill(LinearGradient(colors: [Color.teslaGreen, Color.cyan.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 2.5, height: 25)
                    .shadow(color: Color.teslaGreen.opacity(0.9), radius: 3)

                Spacer(minLength: 0)
            }
            .padding(6)
        }
    }
}

private struct ChargeHudCard: View {
    var state: NinebotVehicleState
    var isAnimating: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text("正在充电")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color.teslaGreen)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(state.battery.map(String.init) ?? "--")
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            Text("约 \(state.estimatedFullChargeTimeText)")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.teslaGreen)
                        .frame(width: 3.5, height: 3.5)
                        .scaleEffect(isAnimating && index == 1 ? 1.25 : 0.78)
                }
            }
            .padding(.top, 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 7)
        .background(
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.17, blue: 0.18).opacity(0.96), Color.black.opacity(0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.teslaGreen.opacity(0.62), lineWidth: 0.9)
        }
        .shadow(color: Color.teslaGreen.opacity(isAnimating ? 0.22 : 0.08), radius: 8)
    }
}

private struct RideWeatherSnapshot: Equatable {
    enum Condition: Equatable {
        case clear
        case cloudy
        case rain
        case snow
        case storm
    }

    var condition: Condition
    var isDay: Bool
    var observedAt: Date
    var temperatureCelsius: Double?
    var ultravioletIndex: Double?
    var airQualityIndex: Int?
    var precipitationMillimeters: Double?
    var windSpeedKPH: Double?
    var windGustsKPH: Double?
    var windDirectionDegrees: Double?
    var isBlizzard: Bool

    var isNight: Bool { !isDay }
    /// Every detected rain code deliberately uses a high-density downpour.
    /// In the small vehicle scene, light rain is otherwise too subtle to read.
    var hasRain: Bool { condition == .rain || condition == .storm }
    /// Product requirement: rain includes a visible lightning effect, while
    /// storm weather intensifies the same effect.
    var hasLightning: Bool { condition == .storm || condition == .rain }
    var hasSnow: Bool { condition == .snow }
    var effectiveWindKPH: Double {
        max(windSpeedKPH ?? 0, windGustsKPH ?? 0)
    }
    var hasWind: Bool { effectiveWindKPH >= 18 }
    var windText: String {
        guard effectiveWindKPH.isFinite, effectiveWindKPH >= 1 else { return "--" }
        return String(format: "%.0f km/h", effectiveWindKPH)
    }

    var temperatureText: String {
        guard let temperatureCelsius,
              temperatureCelsius.isFinite,
              (-80...70).contains(temperatureCelsius) else {
            return "--°"
        }
        return String(format: "%.0f°", temperatureCelsius)
    }

    var ultravioletText: String {
        // The daily maximum UV index is not the live UV value. Even if a stale
        // provider response arrives around sunset, the active night signal must
        // never render a daytime UV number in the city scene.
        guard isDay else { return "0" }
        guard let ultravioletIndex, ultravioletIndex.isFinite else { return "--" }
        return String(format: "%.0f", max(0, ultravioletIndex))
    }

    var airQualityText: String {
        guard let airQualityIndex, (0...500).contains(airQualityIndex) else { return "--" }
        switch airQualityIndex {
        case ...50: return "优 \(airQualityIndex)"
        case 51...100: return "良 \(airQualityIndex)"
        case 101...150: return "轻度 \(airQualityIndex)"
        case 151...200: return "中度 \(airQualityIndex)"
        default: return "较差 \(airQualityIndex)"
        }
    }

    static func fallback(for date: Date = .now) -> RideWeatherSnapshot {
        let hour = Calendar.current.component(.hour, from: date)
        return RideWeatherSnapshot(
            condition: .clear,
            isDay: (6..<19).contains(hour),
            observedAt: date,
            temperatureCelsius: nil,
            ultravioletIndex: nil,
            airQualityIndex: nil,
            precipitationMillimeters: nil,
            windSpeedKPH: nil,
            windGustsKPH: nil,
            windDirectionDegrees: nil,
            isBlizzard: false
        )
    }

    static func openMeteo(
        weatherCode: Int,
        isDay: Int,
        temperatureCelsius: Double?,
        ultravioletIndex: Double?,
        airQualityIndex: Int?,
        precipitationMillimeters: Double?,
        windSpeedKPH: Double?,
        windGustsKPH: Double?,
        windDirectionDegrees: Double?,
        observedAt: Date
    ) -> RideWeatherSnapshot {
        let condition: Condition
        switch weatherCode {
        case 71...77, 85...86:
            condition = .snow
        case 51...67, 80...82:
            condition = .rain
        case 95...99:
            condition = .storm
        case 1...3, 45...48:
            condition = .cloudy
        default:
            condition = .clear
        }
        return RideWeatherSnapshot(
            condition: condition,
            isDay: isDay == 1,
            observedAt: observedAt,
            temperatureCelsius: temperatureCelsius,
            ultravioletIndex: ultravioletIndex,
            airQualityIndex: airQualityIndex,
            precipitationMillimeters: precipitationMillimeters,
            windSpeedKPH: windSpeedKPH,
            windGustsKPH: windGustsKPH,
            windDirectionDegrees: windDirectionDegrees,
            isBlizzard: [75, 77, 86].contains(weatherCode)
        )
    }
}

@MainActor
private final class RideWeatherLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationManager.distanceFilter = 1_000
    }

    /// Requests only a single coarse location fix. Vehicle GPS remains the
    /// preferred source; this is solely the fallback for API responses that
    /// omit location fields.
    func requestCurrentLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last,
              location.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(location.coordinate) else {
            return
        }
        coordinate = location.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // The weather card retains the last successful observation. A failed
        // one-shot location request must not erase data that is already shown.
    }
}


private struct RideWeatherCache: Codable {
    var latitude: Double
    var longitude: Double
    var condition: String
    var isDay: Bool
    var observedAt: Date
    var temperatureCelsius: Double?
    var ultravioletIndex: Double?
    var airQualityIndex: Int?
    // Optional for backwards-compatible decoding of caches produced before
    // the app tracked precipitation and wind measurements.
    var precipitationMillimeters: Double?
    var windSpeedKPH: Double?
    var windGustsKPH: Double?
    var windDirectionDegrees: Double?
    var isBlizzard: Bool

    init(coordinate: CLLocationCoordinate2D, snapshot: RideWeatherSnapshot) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        switch snapshot.condition {
        case .clear: condition = "clear"
        case .cloudy: condition = "cloudy"
        case .rain: condition = "rain"
        case .snow: condition = "snow"
        case .storm: condition = "storm"
        }
        isDay = snapshot.isDay
        observedAt = snapshot.observedAt
        temperatureCelsius = snapshot.temperatureCelsius
        ultravioletIndex = snapshot.ultravioletIndex
        airQualityIndex = snapshot.airQualityIndex
        precipitationMillimeters = snapshot.precipitationMillimeters
        windSpeedKPH = snapshot.windSpeedKPH
        windGustsKPH = snapshot.windGustsKPH
        windDirectionDegrees = snapshot.windDirectionDegrees
        isBlizzard = snapshot.isBlizzard
    }

    var snapshot: RideWeatherSnapshot {
        let resolvedCondition: RideWeatherSnapshot.Condition
        switch condition {
        case "cloudy": resolvedCondition = .cloudy
        case "rain": resolvedCondition = .rain
        case "snow": resolvedCondition = .snow
        case "storm": resolvedCondition = .storm
        default: resolvedCondition = .clear
        }
        return RideWeatherSnapshot(
            condition: resolvedCondition,
            isDay: isDay,
            observedAt: observedAt,
            temperatureCelsius: temperatureCelsius,
            ultravioletIndex: ultravioletIndex,
            airQualityIndex: airQualityIndex,
            precipitationMillimeters: precipitationMillimeters,
            windSpeedKPH: windSpeedKPH,
            windGustsKPH: windGustsKPH,
            windDirectionDegrees: windDirectionDegrees,
            isBlizzard: isBlizzard
        )
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func applies(to coordinate: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) < 25_000
    }
}

@MainActor
private final class RideWeatherProvider: ObservableObject {
    @Published private(set) var snapshot = RideWeatherSnapshot.fallback()

    private var lastCoordinate: CLLocationCoordinate2D?
    private var lastRefreshAt: Date?
    private var currentRequestID = UUID()

    private static let cacheKey = "ninebot.ride-weather.cache.v1"
    private static let cacheLifetime: TimeInterval = 30 * 60
    private static let fallbackCoordinate = CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)

    func refresh(latitude: Double?, longitude: Double?, force: Bool = false) async {
        let coordinate: CLLocationCoordinate2D
        if let latitude, let longitude,
           (-90...90).contains(latitude), (-180...180).contains(longitude) {
            coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        } else if let cache = loadAnyCachedSnapshot() {
            // Vehicle GPS and app location can both be unavailable on first launch
            // or when location permission is denied. Keep showing the last valid
            // observation instead of permanent --° / -- AQI placeholders.
            snapshot = cache.snapshot
            if !force { return }
            coordinate = cache.coordinate
        } else {
            // Final safety net so the ride weather HUD always has real data.
            // Real vehicle GPS or app location overrides this as soon as available.
            coordinate = Self.fallbackCoordinate
        }

        restoreCachedSnapshot(for: coordinate)

        if !force,
           let lastCoordinate,
           let lastRefreshAt,
           CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) < 1_000,
           Date().timeIntervalSince(lastRefreshAt) < 5 * 60 {
            return
        }

        let requestID = UUID()
        currentRequestID = requestID
        do {
            // Open-Meteo deployments have not always exposed `uv_index` as a
            // current-weather variable. Try the richer request first, then fall
            // back to the core current values and finally the legacy
            // `current_weather` response so temperature never disappears just
            // because one optional variable is rejected.
            let payload = try await fetchForecast(latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard currentRequestID == requestID else { return }

            let current = payload.current
            let currentWeather = payload.currentWeather
            guard current != nil || currentWeather != nil else { throw URLError(.cannotParseResponse) }

            let preservedAirQualityIndex = nearbyPreviousAirQualityIndex(for: coordinate)
            snapshot = .openMeteo(
                weatherCode: current?.weatherCode ?? currentWeather?.weatherCode ?? 0,
                isDay: current?.isDay ?? currentWeather?.isDay ?? Self.localDayFlag(),
                temperatureCelsius: current?.temperature2M ?? currentWeather?.temperature,
                ultravioletIndex: current?.uvIndex,
                airQualityIndex: preservedAirQualityIndex,
                precipitationMillimeters: current?.precipitation ?? current?.rain,
                windSpeedKPH: current?.windSpeed10M ?? currentWeather?.windSpeed,
                windGustsKPH: current?.windGusts10M,
                windDirectionDegrees: current?.windDirection10M ?? currentWeather?.windDirection,
                observedAt: .now
            )
            lastCoordinate = coordinate
            lastRefreshAt = .now
            saveCachedSnapshot(for: coordinate)

            if let airQualityIndex = await fetchAirQuality(latitude: coordinate.latitude, longitude: coordinate.longitude),
               currentRequestID == requestID {
                var updatedSnapshot = snapshot
                updatedSnapshot.airQualityIndex = airQualityIndex
                snapshot = updatedSnapshot
                saveCachedSnapshot(for: coordinate)
            }
        } catch {
            // Preserve the last known conditions. The view still falls back to
            // a local day/night city scene before the first successful request.
        }
    }

    private func restoreCachedSnapshot(for coordinate: CLLocationCoordinate2D) {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cache = try? JSONDecoder().decode(RideWeatherCache.self, from: data),
              Date().timeIntervalSince(cache.observedAt) < Self.cacheLifetime,
              cache.applies(to: coordinate) else {
            return
        }
        snapshot = cache.snapshot
    }

    private func loadAnyCachedSnapshot() -> RideWeatherCache? {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cache = try? JSONDecoder().decode(RideWeatherCache.self, from: data),
              Date().timeIntervalSince(cache.observedAt) < Self.cacheLifetime else {
            return nil
        }
        return cache
    }

    private func saveCachedSnapshot(for coordinate: CLLocationCoordinate2D) {
        let cache = RideWeatherCache(coordinate: coordinate, snapshot: snapshot)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }

    private func nearbyPreviousAirQualityIndex(for coordinate: CLLocationCoordinate2D) -> Int? {
        if let lastCoordinate,
           CLLocation(latitude: lastCoordinate.latitude, longitude: lastCoordinate.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) < 25_000 {
            return snapshot.airQualityIndex
        }

        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let cache = try? JSONDecoder().decode(RideWeatherCache.self, from: data),
              Date().timeIntervalSince(cache.observedAt) < Self.cacheLifetime,
              cache.applies(to: coordinate) else {
            return nil
        }
        return cache.airQualityIndex
    }

    private func fetchForecast(latitude: Double, longitude: Double) async throws -> OpenMeteoRideWeatherResponse {
        do {
            return try await fetchForecast(latitude: latitude, longitude: longitude, includesCurrentUV: true)
        } catch {
            do {
                return try await fetchForecast(latitude: latitude, longitude: longitude, includesCurrentUV: false)
            } catch {
                return try await fetchCurrentWeatherFallback(latitude: latitude, longitude: longitude)
            }
        }
    }

    private func fetchForecast(
        latitude: Double,
        longitude: Double,
        includesCurrentUV: Bool
    ) async throws -> OpenMeteoRideWeatherResponse {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        let currentVariables = includesCurrentUV
            ? "weather_code,is_day,temperature_2m,uv_index,precipitation,rain,wind_speed_10m,wind_gusts_10m,wind_direction_10m"
            : "weather_code,is_day,temperature_2m,precipitation,rain,wind_speed_10m,wind_gusts_10m,wind_direction_10m"
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: currentVariables),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let forecastURL = components?.url else { throw URLError(.badURL) }

        let (data, response) = try await URLSession.shared.data(from: forecastURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(OpenMeteoRideWeatherResponse.self, from: data)
    }

    private func fetchCurrentWeatherFallback(latitude: Double, longitude: Double) async throws -> OpenMeteoRideWeatherResponse {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current_weather", value: "true"),
            URLQueryItem(name: "temperature_unit", value: "celsius"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        guard let forecastURL = components?.url else { throw URLError(.badURL) }

        let (data, response) = try await URLSession.shared.data(from: forecastURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(OpenMeteoRideWeatherResponse.self, from: data)
    }

    private func fetchAirQuality(latitude: Double, longitude: Double) async -> Int? {
        if let value = await fetchAirQuality(latitude: latitude, longitude: longitude, includesCurrent: true) {
            return value
        }
        return await fetchAirQuality(latitude: latitude, longitude: longitude, includesCurrent: false)
    }

    private func fetchAirQuality(latitude: Double, longitude: Double, includesCurrent: Bool) async -> Int? {
        var components = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")
        var queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "hourly", value: "us_aqi,european_aqi,pm2_5"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        if includesCurrent {
            queryItems.insert(URLQueryItem(name: "current", value: "us_aqi,european_aqi,pm2_5"), at: 2)
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }
            let payload = try JSONDecoder().decode(OpenMeteoAirQualityResponse.self, from: data)
            return payload.bestAirQualityIndex
        } catch {
            return nil
        }
    }

    private static func localDayFlag(for date: Date = .now) -> Int {
        let hour = Calendar.current.component(.hour, from: date)
        return (6..<19).contains(hour) ? 1 : 0
    }
}

private struct OpenMeteoRideWeatherResponse: Decodable {
    struct Current: Decodable {
        let weatherCode: Int
        let isDay: Int
        let temperature2M: Double?
        let uvIndex: Double?
        let precipitation: Double?
        let rain: Double?
        let windSpeed10M: Double?
        let windGusts10M: Double?
        let windDirection10M: Double?

        enum CodingKeys: String, CodingKey {
            case weatherCode = "weather_code"
            case isDay = "is_day"
            case temperature2M = "temperature_2m"
            case uvIndex = "uv_index"
            case precipitation
            case rain
            case windSpeed10M = "wind_speed_10m"
            case windGusts10M = "wind_gusts_10m"
            case windDirection10M = "wind_direction_10m"
        }
    }

    struct CurrentWeather: Decodable {
        let temperature: Double?
        let weatherCode: Int
        let isDay: Int?
        let windSpeed: Double?
        let windDirection: Double?

        enum CodingKeys: String, CodingKey {
            case temperature
            case weatherCode = "weathercode"
            case isDay = "is_day"
            case windSpeed = "windspeed"
            case windDirection = "winddirection"
        }
    }

    let current: Current?
    let currentWeather: CurrentWeather?

    enum CodingKeys: String, CodingKey {
        case current
        case currentWeather = "current_weather"
    }
}

private struct OpenMeteoAirQualityResponse: Decodable {
    struct Values: Decodable {
        let usAirQualityIndex: Double?
        let europeanAirQualityIndex: Double?
        let pm25: Double?

        enum CodingKeys: String, CodingKey {
            case usAirQualityIndex = "us_aqi"
            case europeanAirQualityIndex = "european_aqi"
            case pm25 = "pm2_5"
        }
    }

    struct Hourly: Decodable {
        let usAirQualityIndex: [Double?]?
        let europeanAirQualityIndex: [Double?]?
        let pm25: [Double?]?

        enum CodingKeys: String, CodingKey {
            case usAirQualityIndex = "us_aqi"
            case europeanAirQualityIndex = "european_aqi"
            case pm25 = "pm2_5"
        }
    }

    let current: Values?
    let hourly: Hourly?

    var bestAirQualityIndex: Int? {
        let directValue = current?.usAirQualityIndex
            ?? hourly?.usAirQualityIndex?.compactMap { $0 }.first
            ?? current?.europeanAirQualityIndex
            ?? hourly?.europeanAirQualityIndex?.compactMap { $0 }.first
        if let directValue, directValue.isFinite, (0...500).contains(directValue) {
            return Int(directValue.rounded())
        }

        let pm25Value = current?.pm25 ?? hourly?.pm25?.compactMap { $0 }.first
        guard let pm25Value, pm25Value.isFinite, pm25Value >= 0 else { return nil }
        return usAQIFromPM25(pm25Value)
    }

    private func usAQIFromPM25(_ value: Double) -> Int? {
        let breakpoints: [(cLow: Double, cHigh: Double, iLow: Double, iHigh: Double)] = [
            (0.0, 12.0, 0, 50),
            (12.1, 35.4, 51, 100),
            (35.5, 55.4, 101, 150),
            (55.5, 150.4, 151, 200),
            (150.5, 250.4, 201, 300),
            (250.5, 350.4, 301, 400),
            (350.5, 500.4, 401, 500)
        ]
        guard let breakpoint = breakpoints.first(where: { value >= $0.cLow && value <= $0.cHigh }) else {
            return nil
        }
        let aqi = (breakpoint.iHigh - breakpoint.iLow) / (breakpoint.cHigh - breakpoint.cLow)
            * (value - breakpoint.cLow) + breakpoint.iLow
        return min(max(Int(aqi.rounded()), 0), 500)
    }
}

private struct LiveRideEnvironment: View {
    var weather: RideWeatherSnapshot
    var phase: TimeInterval
    /// Parked scenes retain weather particles but must not scroll the road or city.
    var animatesRoadAndCity: Bool = true

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // Clouds stay alive even in parked and charging scenes. The prior
            // drift covered only a few on-screen points over a very long cycle;
            // this gives each layer a clearly readable, gentle cross-card glide.
            let cloudDrift = CGFloat(sin(phase * 0.78)) * size.width * 0.30
            let precipitationDrift = CGFloat((phase * (weather.isBlizzard ? 1.42 : 0.82)).truncatingRemainder(dividingBy: 1.0))
            let lightningFlash = weather.hasLightning
                ? pow(max(0, sin(phase * 1.9) + sin(phase * 0.47 + 1.8) - 1.42) / 0.58, 2)
                : 0

            ZStack {
                sky

                if weather.isNight {
                    nightSky(size: size, cloudDrift: cloudDrift, phase: phase)
                } else {
                    daySky(size: size, cloudDrift: cloudDrift, phase: phase)
                }

                citySkyline(size: size, phase: animatesRoadAndCity ? phase : 0)
                road(size: size, phase: animatesRoadAndCity ? phase : 0)
                streetLights(size: size, phase: animatesRoadAndCity ? phase : 0)

                // Weather animation is deliberately independent from road/city
                // motion, so riding, charging, and a stationary vehicle all
                // show the same live wind, rain, snow, and lightning state.
                if weather.hasWind {
                    wind(size: size, phase: phase)
                }

                if weather.hasRain {
                    rain(size: size, drift: precipitationDrift, phase: phase)
                }

                if weather.hasSnow {
                    snow(size: size, drift: precipitationDrift, phase: phase)
                }

                if weather.hasLightning {
                    lightning(size: size, opacity: lightningFlash)
                }
            }
            .overlay {
                if lightningFlash > 0.02 {
                    Color.white.opacity(lightningFlash * 0.28)
                        .blendMode(.screen)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var sky: some View {
        LinearGradient(colors: skyColors, startPoint: .top, endPoint: .bottom)
    }

    private var skyColors: [Color] {
        if weather.isNight {
            switch weather.condition {
            case .storm: return [Color(red: 0.035, green: 0.06, blue: 0.12), Color(red: 0.08, green: 0.12, blue: 0.19), Color(red: 0.15, green: 0.18, blue: 0.22)]
            case .rain: return [Color(red: 0.045, green: 0.08, blue: 0.14), Color(red: 0.10, green: 0.16, blue: 0.22), Color(red: 0.17, green: 0.21, blue: 0.25)]
            case .snow: return [Color(red: 0.10, green: 0.15, blue: 0.22), Color(red: 0.22, green: 0.29, blue: 0.36), Color(red: 0.36, green: 0.41, blue: 0.44)]
            case .cloudy: return [Color(red: 0.07, green: 0.10, blue: 0.16), Color(red: 0.14, green: 0.18, blue: 0.24), Color(red: 0.23, green: 0.25, blue: 0.28)]
            case .clear: return [Color(red: 0.025, green: 0.06, blue: 0.14), Color(red: 0.10, green: 0.18, blue: 0.31), Color(red: 0.29, green: 0.33, blue: 0.38)]
            }
        }

        switch weather.condition {
        case .storm: return [Color(red: 0.36, green: 0.44, blue: 0.53), Color(red: 0.55, green: 0.62, blue: 0.67), Color(red: 0.78, green: 0.82, blue: 0.82)]
        case .rain: return [Color(red: 0.48, green: 0.61, blue: 0.69), Color(red: 0.65, green: 0.74, blue: 0.78), Color(red: 0.84, green: 0.87, blue: 0.87)]
        case .snow: return [Color(red: 0.49, green: 0.60, blue: 0.70), Color(red: 0.73, green: 0.80, blue: 0.86), Color(red: 0.92, green: 0.94, blue: 0.95)]
        case .cloudy: return [Color(red: 0.62, green: 0.74, blue: 0.82), Color(red: 0.77, green: 0.84, blue: 0.87), Color(red: 0.93, green: 0.94, blue: 0.93)]
        case .clear: return [Color(red: 0.35, green: 0.68, blue: 0.96), Color(red: 0.66, green: 0.84, blue: 0.97), Color(red: 0.94, green: 0.95, blue: 0.92)]
        }
    }

    @ViewBuilder
    private func daySky(size: CGSize, cloudDrift: CGFloat, phase: TimeInterval) -> some View {
        if weather.condition == .clear {
            Circle()
                .fill(Color(red: 1.0, green: 0.77, blue: 0.22))
                .frame(width: size.width * 0.11, height: size.width * 0.11)
                .shadow(color: Color.yellow.opacity(0.62), radius: 20)
                .offset(x: size.width * 0.31, y: -size.height * 0.29)
        }

        cloud(
            width: size.width * 0.34,
            height: size.height * 0.15,
            opacity: weather.condition == .clear ? 0.64 : 0.88,
            phase: phase,
            variant: 0
        )
            .offset(x: -size.width * 0.33 + cloudDrift * 0.88, y: -size.height * 0.29)
        cloud(
            width: size.width * 0.42,
            height: size.height * 0.18,
            opacity: weather.condition == .clear ? 0.48 : 0.86,
            phase: phase,
            variant: 1
        )
            .offset(x: size.width * 0.27 - cloudDrift * 0.72, y: -size.height * 0.18)
    }

    @ViewBuilder
    private func nightSky(size: CGSize, cloudDrift: CGFloat, phase: TimeInterval) -> some View {
        if weather.condition == .clear || weather.condition == .cloudy {
            ForEach(0..<28, id: \.self) { index in
                let x = (CGFloat((index * 37) % 100) / 100 - 0.5) * size.width
                let y = (CGFloat((index * 19) % 54) / 100 - 0.41) * size.height
                Circle()
                    .fill(
                        Color.white.opacity(
                            (weather.condition == .cloudy ? 0.13 : 0.32)
                                + (weather.condition == .cloudy ? 0.10 : 0.24) * sin(phase * 1.7 + Double(index))
                        )
                    )
                    .frame(width: index.isMultiple(of: 3) ? 1.6 : 1.0, height: index.isMultiple(of: 3) ? 1.6 : 1.0)
                    .offset(x: x, y: y)
            }

            Circle()
                .fill(Color(red: 0.88, green: 0.93, blue: 1.0))
                .frame(width: size.width * 0.082, height: size.width * 0.082)
                .shadow(color: Color.white.opacity(0.36), radius: 9)
                .offset(x: size.width * 0.30, y: -size.height * 0.29)
                .opacity(weather.condition == .cloudy ? 0.52 : 1)
        }

        if weather.condition != .clear {
            let cloudOpacity = weather.condition == .cloudy ? 0.44 : 0.58
            nightCloud(width: size.width * 0.45, height: size.height * 0.18, opacity: cloudOpacity, phase: phase, variant: 0)
                .offset(x: -size.width * 0.24 + cloudDrift * 0.72, y: -size.height * 0.29)
            nightCloud(width: size.width * 0.52, height: size.height * 0.20, opacity: cloudOpacity + 0.06, phase: phase, variant: 1)
                .offset(x: size.width * 0.26 - cloudDrift * 0.60, y: -size.height * 0.20)
        }
    }

    private func cloud(
        width: CGFloat,
        height: CGFloat,
        opacity: Double,
        phase: TimeInterval,
        variant: Int
    ) -> some View {
        let denseWeather = weather.condition == .rain || weather.condition == .storm || weather.condition == .snow
        let topColor = denseWeather
            ? Color(red: 0.80, green: 0.84, blue: 0.86)
            : Color(red: 0.99, green: 0.995, blue: 1.0)
        let middleColor = denseWeather
            ? Color(red: 0.62, green: 0.68, blue: 0.71)
            : Color(red: 0.85, green: 0.90, blue: 0.93)
        let underside = denseWeather
            ? Color(red: 0.42, green: 0.50, blue: 0.55)
            : Color(red: 0.68, green: 0.76, blue: 0.81)

        return AtmosphericCloudLayer(
            width: width,
            height: height,
            opacity: opacity,
            phase: phase,
            variant: variant,
            highlight: topColor,
            midtone: middleColor,
            shadow: underside,
            isDense: denseWeather
        )
    }

    // Rain and snow should not look like white daytime clouds over a night city.
    private func nightCloud(
        width: CGFloat,
        height: CGFloat,
        opacity: Double,
        phase: TimeInterval,
        variant: Int
    ) -> some View {
        let moonlit = Color(red: 0.30, green: 0.38, blue: 0.48)
        let middle = Color(red: 0.15, green: 0.21, blue: 0.29)
        let shadow = Color(red: 0.055, green: 0.08, blue: 0.13)

        return AtmosphericCloudLayer(
            width: width,
            height: height,
            opacity: opacity,
            phase: phase,
            variant: variant,
            highlight: moonlit,
            midtone: middle,
            shadow: shadow,
            isDense: true
        )
    }

    private func citySkyline(size: CGSize, phase: TimeInterval) -> some View {
        let frontProgress = CGFloat((phase * 0.045).truncatingRemainder(dividingBy: 1.0))
        let rearProgress = CGFloat((phase * 0.028).truncatingRemainder(dividingBy: 1.0))
        // Use a deliberately open rhythm. The former 24-tower front row had
        // narrower gaps than the towers themselves, so it collapsed into a wall.
        let frontSpacing = size.width * 0.205
        let rearSpacing = size.width * 0.34
        let frontScroll = frontProgress * frontSpacing * 8
        let rearScroll = rearProgress * rearSpacing * 5

        return ZStack(alignment: .bottom) {
            // Atmospheric distance and a continuous street-level silhouette give
            // the skyline a believable depth instead of a row of floating cards.
            LinearGradient(
                colors: weather.isNight
                    ? [Color(red: 0.08, green: 0.12, blue: 0.17).opacity(0.04), Color.black.opacity(0.42)]
                    : [Color.white.opacity(0.02), Color(red: 0.12, green: 0.25, blue: 0.31).opacity(0.22)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: size.height * 0.40)
            .offset(y: size.height * 0.08)

            // The distant layer uses only a few tall landmarks, leaving sky
            // clearly visible between them rather than drawing a second wall.
            ForEach(0..<6, id: \.self) { index in
                let pattern = index % 4
                officeTower(
                    index: pattern + 20,
                    width: size.width * (0.12 + CGFloat(pattern % 2) * 0.022),
                    height: size.height * (0.42 + CGFloat(pattern) * 0.055),
                    isRearTower: true,
                    size: size
                )
                .offset(
                    x: -size.width * 0.54 + CGFloat(index) * rearSpacing - rearScroll,
                    y: size.height * 0.055
                )
            }

            // Keep open alleys between foreground towers. At phone size these
            // negative spaces read far better than a large number of tiny façades.
            ForEach(0..<9, id: \.self) { index in
                let pattern = index % 9
                officeTower(
                    index: pattern,
                    width: size.width * (0.085 + CGFloat((pattern * 5) % 4) * 0.014),
                    height: size.height * (0.48 + CGFloat((pattern * 7) % 6) * 0.043),
                    isRearTower: false,
                    size: size
                )
                .offset(
                    x: -size.width * 0.56 + CGFloat(index) * frontSpacing - frontScroll,
                    y: size.height * 0.050
                )
            }

            // A short row of varied low-rise buildings grounds the scene while
            // retaining visible streets and alleys between each building.
            ForEach(0..<7, id: \.self) { index in
                let pattern = index % 6
                lowRiseBuilding(
                    index: pattern,
                    width: size.width * (0.18 + CGFloat((pattern * 3) % 3) * 0.020),
                    height: size.height * (0.12 + CGFloat((pattern * 5) % 4) * 0.020)
                )
                .offset(
                    x: -size.width * 0.57 + CGFloat(index) * size.width * 0.30 - frontScroll * 0.56,
                    y: size.height * 0.270
                )
            }

            Rectangle()
                .fill(Color.black.opacity(weather.isNight ? 0.24 : 0.12))
                .frame(height: 2)
                .offset(y: size.height * 0.32)

            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<9, id: \.self) { index in
                    Rectangle()
                        .fill(weather.isNight ? Color.black.opacity(0.48) : Color(red: 0.16, green: 0.25, blue: 0.28).opacity(0.28))
                        .frame(width: size.width * 0.14, height: size.height * (0.025 + CGFloat((index * 11) % 4) * 0.009))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(y: size.height * 0.335)
        }
    }

    private func lowRiseBuilding(index: Int, width: CGFloat, height: CGFloat) -> some View {
        let façadeTop = weather.isNight
            ? Color(red: 0.11, green: 0.15, blue: 0.20)
            : Color(red: 0.35, green: 0.49, blue: 0.55)
        let façadeBottom = weather.isNight
            ? Color(red: 0.035, green: 0.055, blue: 0.08)
            : Color(red: 0.20, green: 0.34, blue: 0.40)

        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: max(1.5, width * 0.055), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [façadeTop, façadeBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: max(1.5, width * 0.055), style: .continuous)
                        .stroke(Color.white.opacity(weather.isNight ? 0.09 : 0.20), lineWidth: 0.55)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.black.opacity(weather.isNight ? 0.36 : 0.18))
                        .frame(height: max(2, height * 0.18))
                }

            if weather.isNight {
                VStack(spacing: max(1.3, height * 0.11)) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: max(1.4, width * 0.075)) {
                            ForEach(0..<5, id: \.self) { column in
                                RoundedRectangle(cornerRadius: 0.45, style: .continuous)
                                    .fill(
                                        Color(red: 1.0, green: 0.71, blue: 0.28)
                                            .opacity((row * 5 + column + index).isMultiple(of: 3) ? 0.82 : 0.13)
                                    )
                                    .frame(width: max(1.2, width * 0.075), height: max(1.0, height * 0.055))
                            }
                        }
                    }
                }
                .padding(.top, max(3, height * 0.13))
            } else {
                // Daytime has façade seams only: windows must remain unlit.
                VStack(spacing: max(2, height * 0.19)) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle()
                            .fill(Color(red: 0.08, green: 0.22, blue: 0.29).opacity(0.18))
                            .frame(height: 0.5)
                    }
                }
                .padding(.top, max(3, height * 0.13))
                .padding(.horizontal, width * 0.08)
            }

            if index.isMultiple(of: 2) {
                HStack(spacing: width * 0.10) {
                    RoundedRectangle(cornerRadius: 0.8)
                        .fill(Color.black.opacity(weather.isNight ? 0.34 : 0.20))
                        .frame(width: max(3, width * 0.22), height: max(1.5, height * 0.055))
                    RoundedRectangle(cornerRadius: 0.8)
                        .fill(Color.black.opacity(weather.isNight ? 0.34 : 0.20))
                        .frame(width: max(3, width * 0.16), height: max(1.5, height * 0.055))
                }
                .offset(y: -max(2, height * 0.07))
            }
        }
        .frame(width: width, height: height)
        .shadow(color: Color.black.opacity(weather.isNight ? 0.20 : 0.08), radius: 3, y: 1)
    }

    private func officeTower(
        index: Int,
        width: CGFloat,
        height: CGFloat,
        isRearTower: Bool,
        size: CGSize
    ) -> some View {
        let glassTop = weather.isNight
            ? Color(red: 0.10, green: 0.17, blue: 0.26).opacity(isRearTower ? 0.66 : 0.96)
            : Color(red: 0.56, green: 0.76, blue: 0.87).opacity(isRearTower ? 0.36 : 0.72)
        let glassBottom = weather.isNight
            ? Color(red: 0.025, green: 0.05, blue: 0.10).opacity(isRearTower ? 0.70 : 0.98)
            : Color(red: 0.24, green: 0.45, blue: 0.59).opacity(isRearTower ? 0.44 : 0.70)
        // Window illumination belongs strictly to the night scene. Daytime
        // façades retain their glass and structural lines but no lit windows.
        let windowOpacity = weather.isNight ? 0.90 : 0

        return ZStack(alignment: .top) {
            // Narrow side plane, roof parapet and HVAC boxes create the hard
            // edges and tonal variation seen on real urban buildings.
            Path { path in
                path.move(to: CGPoint(x: width * 0.84, y: 2))
                path.addLine(to: CGPoint(x: width, y: height * 0.055))
                path.addLine(to: CGPoint(x: width, y: height))
                path.addLine(to: CGPoint(x: width * 0.84, y: height * 0.96))
                path.closeSubpath()
            }
            .fill(Color.black.opacity(weather.isNight ? (isRearTower ? 0.18 : 0.28) : 0.12))

            RoundedRectangle(cornerRadius: max(2, width * 0.08), style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [glassTop, glassBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: max(2, width * 0.08), style: .continuous)
                        .stroke(Color.white.opacity(weather.isNight ? 0.14 : 0.32), lineWidth: 0.7)
                }
                .overlay(alignment: .top) {
                    if weather.isNight {
                        VStack(spacing: max(1.5, height * 0.045)) {
                            ForEach(0..<9, id: \.self) { row in
                                HStack(spacing: max(1.5, width * 0.10)) {
                                    ForEach(0..<4, id: \.self) { column in
                                        RoundedRectangle(cornerRadius: 0.7, style: .continuous)
                                            .fill(
                                                Color(red: 1.0, green: 0.72, blue: 0.28)
                                                    .opacity((row * 4 + column + index).isMultiple(of: 4) ? windowOpacity : 0.18)
                                            )
                                            .frame(width: max(1.4, width * 0.10), height: max(1.2, height * 0.014))
                                    }
                                }
                            }
                        }
                        .padding(.top, max(5, height * 0.07))
                    } else {
                        // Subtle façade mullions preserve architectural detail
                        // during the day without appearing as illuminated windows.
                        VStack(spacing: max(2.5, height * 0.075)) {
                            ForEach(0..<7, id: \.self) { _ in
                                Rectangle()
                                    .fill(Color(red: 0.10, green: 0.28, blue: 0.39).opacity(0.18))
                                    .frame(height: 0.55)
                            }
                        }
                        .padding(.top, max(5, height * 0.07))
                        .padding(.horizontal, width * 0.08)
                    }
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(weather.isNight ? 0.10 : 0.22))
                        .frame(width: max(1, width * 0.055))
                        .padding(.vertical, 5)
                }

                Rectangle()
                    .fill(Color.white.opacity(weather.isNight ? 0.08 : 0.16))
                    .frame(height: max(1, height * 0.012))
                    .padding(.horizontal, width * 0.05)
                    .offset(y: height * 0.22)

                if index.isMultiple(of: 3) {
                    HStack(spacing: width * 0.08) {
                        ForEach(0..<2, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.black.opacity(weather.isNight ? 0.42 : 0.25))
                                .frame(width: max(2, width * 0.13), height: max(2, height * 0.025))
                        }
                    }
                    .offset(y: -max(2, height * 0.035))
                }

            if index.isMultiple(of: 4) {
                Capsule()
                    .fill(Color(white: weather.isNight ? 0.50 : 0.72))
                    .frame(width: 1, height: max(5, height * 0.12))
                    .offset(y: -max(4, height * 0.10))
            }
        }
        .frame(width: width, height: height)
        .shadow(color: weather.isNight ? Color.black.opacity(0.22) : Color.blue.opacity(0.08), radius: 4, y: 2)
    }

    private func road(size: CGSize, phase: TimeInterval) -> some View {
        let travel = CGFloat((phase * 0.92).truncatingRemainder(dividingBy: 1.0))
        let roadTop = size.height * 0.62
        let roadHeight = size.height - roadTop
        let dashSpacing = size.width * 0.245
        let dashShift = travel * dashSpacing

        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: 0, y: roadTop))
                path.addLine(to: CGPoint(x: size.width, y: roadTop))
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: size.height))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: weather.isNight
                        ? [Color(red: 0.065, green: 0.08, blue: 0.095), Color(red: 0.12, green: 0.14, blue: 0.16)]
                        : [Color(red: 0.22, green: 0.25, blue: 0.26), Color(red: 0.11, green: 0.13, blue: 0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Path { path in
                path.move(to: CGPoint(x: 0, y: roadTop - size.height * 0.035))
                path.addLine(to: CGPoint(x: size.width, y: roadTop - size.height * 0.035))
                path.addLine(to: CGPoint(x: size.width, y: roadTop + size.height * 0.018))
                path.addLine(to: CGPoint(x: 0, y: roadTop + size.height * 0.018))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.52, green: 0.54, blue: 0.53).opacity(weather.isNight ? 0.62 : 0.82),
                        Color(red: 0.25, green: 0.27, blue: 0.27).opacity(weather.isNight ? 0.74 : 0.88)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            // Fixed-width lane dashes move only along the x-axis. This matches
            // the side profile of the vehicle instead of appearing to rush
            // toward the viewer along a perspective road.
            ForEach(0..<7, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(weather.isNight ? 0.74 : 0.82))
                    .frame(width: size.width * 0.135, height: max(2.5, size.height * 0.017))
                    .position(
                        x: -dashSpacing * 0.45 + CGFloat(index) * dashSpacing + dashShift,
                        y: roadTop + roadHeight * 0.58
                    )
            }

            ForEach(0..<12, id: \.self) { index in
                let textureSpacing = size.width * 0.16
                let textureShift = travel * textureSpacing * 3
                Capsule()
                    .fill(Color.white.opacity(weather.isNight ? 0.055 : 0.075))
                    .frame(width: size.width * (0.07 + CGFloat(index % 3) * 0.018), height: 0.8)
                    .position(
                        x: -textureSpacing * 0.4 + CGFloat(index) * textureSpacing + textureShift,
                        y: roadTop + roadHeight * (0.22 + CGFloat(index % 3) * 0.24)
                    )
            }

            if weather.hasRain || weather.isNight {
                ForEach(0..<8, id: \.self) { index in
                    let reflectionSpacing = size.width * 0.22
                    Capsule()
                        .fill((weather.isNight ? Color.orange : Color.white).opacity(weather.isNight ? 0.11 : 0.07))
                        .frame(width: size.width * 0.11, height: 2)
                        .blur(radius: 2.5)
                        .position(
                            x: -reflectionSpacing * 0.35 + CGFloat(index) * reflectionSpacing + travel * reflectionSpacing * 2,
                            y: roadTop + roadHeight * (0.28 + CGFloat(index % 2) * 0.38)
                        )
                }
            }

            Path { path in
                path.move(to: CGPoint(x: 0, y: roadTop + size.height * 0.02))
                path.addLine(to: CGPoint(x: size.width, y: roadTop + size.height * 0.02))
            }
            .stroke(Color.white.opacity(weather.isNight ? 0.48 : 0.62), lineWidth: 1.2)
        }
    }

    private func streetLights(size: CGSize, phase: TimeInterval) -> some View {
        let travel = CGFloat((phase * 0.15).truncatingRemainder(dividingBy: 1.0))
        let spacing = size.width * 0.55

        return ZStack {
            ForEach(0..<4, id: \.self) { index in
                streetLamp(
                    height: size.height * 0.43,
                    isLit: weather.isNight,
                    glow: weather.isNight ? 0.96 : 0
                )
                    .scaleEffect(0.82)
                    .offset(
                        x: -size.width * 0.48 + CGFloat(index) * spacing - travel * spacing,
                        y: size.height * 0.11
                    )
            }
        }
    }

    private func streetLamp(height: CGFloat, isLit: Bool, glow: Double) -> some View {
        ZStack(alignment: .bottom) {
            if glow > 0.4 {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height * 0.18))
                    path.addLine(to: CGPoint(x: -height * 0.22, y: height * 0.58))
                    path.addLine(to: CGPoint(x: height * 0.22, y: height * 0.58))
                    path.closeSubpath()
                }
                .fill(Color.orange.opacity(glow * 0.11))
                .blur(radius: 4)
            }

            VStack(spacing: 0) {
                ZStack {
                    Capsule()
                        .fill(Color(white: 0.12))
                        .frame(width: 4, height: 7)
                    Capsule()
                        .fill(Color(white: 0.22))
                        .frame(width: 18, height: 2.8)
                        .offset(x: 7, y: 1)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            isLit
                                ? Color(red: 1.0, green: 0.78, blue: 0.30).opacity(glow)
                                : Color(white: 0.16)
                        )
                        .frame(width: 9, height: 4)
                        .offset(x: 15, y: 3)
                        .shadow(color: Color.orange.opacity(isLit ? glow : 0), radius: isLit ? 11 : 0)
                }
                Capsule()
                    .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.08)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 3.2, height: height)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(Color(white: 0.06)).frame(width: 10, height: 2.5).offset(y: 1)
                    }
            }
        }
        .frame(width: height * 0.48, height: height + 9)
    }

    private func wind(size: CGSize, phase: TimeInterval) -> some View {
        let normalizedStrength = min(max((weather.effectiveWindKPH - 18) / 42, 0), 1)
        let windStrength = CGFloat(normalizedStrength)
        let directionRadians = (weather.windDirectionDegrees ?? 270) * .pi / 180
        let directionalComponent = CGFloat(sin(directionRadians))
        let travelDirection: CGFloat = abs(directionalComponent) < 0.20
            ? 1
            : (directionalComponent < 0 ? -1 : 1)
        let gust = 0.68 + CGFloat(sin(phase * 2.75) + sin(phase * 1.12 + 0.8)) * 0.16
        let opacity = 0.17 + normalizedStrength * 0.23

        return ZStack {
            Canvas { context, canvasSize in
                for layer in 0..<3 {
                    let count = 7 + layer * 4
                    let speed = (0.13 + Double(layer) * 0.055) * (1 + Double(normalizedStrength) * 1.35)
                    for index in 0..<count {
                        let progress = (phase * speed + Double(index * 31 + layer * 17) / 100.0)
                            .truncatingRemainder(dividingBy: 1.0)
                        let x = (CGFloat(progress) * (canvasSize.width + 130) - 65) * travelDirection
                        let y = canvasSize.height * (0.18 + CGFloat((index * 37 + layer * 11) % 62) / 100.0)
                        let length = (18 + CGFloat(layer) * 11 + windStrength * 22) * gust
                        let arc = CGFloat(sin(phase * 2.1 + Double(index))) * 4

                        var stream = Path()
                        stream.move(to: CGPoint(x: x - travelDirection * length * 0.5, y: y - arc * 0.3))
                        stream.addQuadCurve(
                            to: CGPoint(x: x + travelDirection * length * 0.5, y: y + arc * 0.3),
                            control: CGPoint(x: x, y: y - arc)
                        )
                        context.stroke(
                            stream,
                            with: .color(Color.white.opacity(opacity * (0.45 + Double(layer) * 0.18))),
                            style: StrokeStyle(lineWidth: 0.65 + CGFloat(layer) * 0.22, lineCap: .round)
                        )
                    }
                }
            }

            // A few high-contrast leaves make wind visible even when clouds
            // have little contrast, without covering the vehicle or HUD.
            ForEach(0..<7, id: \.self) { index in
                let progress = (phase * (0.12 + Double(index % 3) * 0.035) + Double(index) * 0.19)
                    .truncatingRemainder(dividingBy: 1.0)
                let x = (CGFloat(progress) * 1.24 - 0.12) * size.width * travelDirection
                let y = size.height * (0.34 + CGFloat((index * 19) % 46) / 100.0)
                let rotation = Double(travelDirection) * (phase * 180 + Double(index) * 51)

                Image(systemName: "leaf.fill")
                    .font(.system(size: 5 + CGFloat(index % 3), weight: .medium))
                    .foregroundStyle(Color(red: 0.66, green: 0.77, blue: 0.48).opacity(0.34 + normalizedStrength * 0.35))
                    .rotationEffect(.degrees(rotation))
                    .offset(x: x, y: y)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func rain(size: CGSize, drift: CGFloat, phase: TimeInterval) -> some View {
        // The compact scene needs a true downpour density for both rain codes;
        // otherwise normal rain becomes nearly invisible behind the vehicle.
        let isStorm = weather.condition == .storm || weather.condition == .rain
        let baseOpacity = weather.isNight ? 0.78 : 0.68
        let windIntensity = min(max((weather.effectiveWindKPH - 8) / 52, 0), 1)
        let directionRadians = (weather.windDirectionDegrees ?? 270) * .pi / 180
        let crossWind = CGFloat(sin(directionRadians)) * CGFloat(windIntensity)
        let verticalSway = CGFloat(sin(phase * 1.35) + sin(phase * 0.41 + 1.2)) * size.width * 0.004
        let splashSpeed = isStorm ? 2.8 : 2.2

        return ZStack {
            // Canvas keeps the dense multi-depth rain smooth at the scene's
            // 30 fps update rate. Near drops are longer, brighter and faster.
            Canvas { context, canvasSize in
                let layerCounts = isStorm ? [54, 46, 36] : [42, 36, 28]
                let layerSpeeds = isStorm ? [1.65, 2.15, 2.85] : [1.35, 1.80, 2.35]
                let layerLengths: [CGFloat] = isStorm ? [10, 17, 28] : [8, 14, 23]
                let layerWidths: [CGFloat] = [0.65, 0.95, 1.35]

                for layer in 0..<3 {
                    for index in 0..<layerCounts[layer] {
                        let seed = Double((index * 47 + layer * 29) % 101) / 101.0
                        let cycle = (seed + phase * layerSpeeds[layer] * 0.34 + Double(drift) * 0.11)
                            .truncatingRemainder(dividingBy: 1.0)
                        let xSeed = CGFloat((index * 67 + layer * 23) % 109) / 109.0
                        let y = CGFloat(cycle) * (canvasSize.height + 90) - 62
                        let length = layerLengths[layer] * max(0.82, size.height / 218)
                        let windOffset = crossWind * (CGFloat(cycle) * 34 + length * 0.86)
                        let x = xSeed * (canvasSize.width + 80) - 40
                            + verticalSway * CGFloat(layer + 1) * 0.42
                            + windOffset
                        let fallWobble = CGFloat(sin(phase * 1.8 + Double(index * 13 + layer * 7))) * min(1.6, length * 0.08)

                        var drop = Path()
                        drop.move(to: CGPoint(x: x, y: y))
                        // Rain always falls toward the road; real live wind
                        // provides the lateral lean and increases its speed.
                        drop.addLine(to: CGPoint(x: x + fallWobble + crossWind * length * 0.42, y: y + length))
                        context.stroke(
                            drop,
                            with: .color(Color.white.opacity(baseOpacity * (0.38 + Double(layer) * 0.24))),
                            style: StrokeStyle(lineWidth: layerWidths[layer], lineCap: .round)
                        )
                    }
                }
            }

            // Wind-driven water haze gathers close to the asphalt during a
            // downpour and visually ties the rain to the road surface.
            LinearGradient(
                colors: [.clear, Color.white.opacity(isStorm ? 0.14 : 0.09), Color(red: 0.72, green: 0.80, blue: 0.84).opacity(isStorm ? 0.22 : 0.13)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: size.height * 0.28)
            .blur(radius: 5)
            .offset(y: size.height * 0.37 + CGFloat(sin(phase * 2.2)) * 2)

            ForEach(0..<(isStorm ? 18 : 12), id: \.self) { index in
                let cycle = (phase * splashSpeed + Double(index) * 0.37)
                    .truncatingRemainder(dividingBy: 1.0)
                let x = size.width * (0.08 + CGFloat((index * 41) % 87) / 100)
                let y = size.height * (0.69 + CGFloat((index * 17) % 25) / 100)

                Ellipse()
                    .stroke(Color.white.opacity((1 - cycle) * (isStorm ? 0.50 : 0.34)), lineWidth: isStorm ? 1.0 : 0.7)
                    .frame(width: 4 + CGFloat(cycle) * 15, height: 1.5 + CGFloat(cycle) * 4)
                    .position(x: x, y: y)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func snow(size: CGSize, drift: CGFloat, phase: TimeInterval) -> some View {
        let isBlizzard = weather.isBlizzard
        let flakeCount = isBlizzard ? 112 : 58
        // Snow also falls mostly top-to-bottom. Blizzard mode increases the
        // density/blur, but lateral movement remains a small float instead of
        // a wind-blown sideways stream.
        let windAmplitude = isBlizzard ? size.width * 0.018 : size.width * 0.007
        let wind = CGFloat(sin(phase * 1.15)) * windAmplitude
        let flakeOpacity = weather.isNight ? 0.82 : 0.76
        let verticalCycle = size.height * 1.25
        let verticalOffset = size.height * 0.30

        return ZStack {
            ForEach(0..<flakeCount, id: \.self) { index in
                let xSeed = (index * 47) % 100
                let ySeed = (index * 29) % 100
                let normalizedX = CGFloat(xSeed) / 100.0 - 0.5
                let normalizedY = CGFloat(ySeed) / 100.0 - 0.5
                let x = normalizedX * size.width
                let y = normalizedY * size.height + drift * size.height * 1.28
                let flakeSize: CGFloat = isBlizzard
                    ? (1.7 + CGFloat(index % 4)) * 0.58
                    : (1.1 + CGFloat(index % 3)) * 0.56
                let windMultiplier = 0.18 + CGFloat(index % 4) * 0.08
                let floatWobble = CGFloat(sin(phase * 1.7 + Double(index) * 0.37)) * size.width * (isBlizzard ? 0.006 : 0.003)
                let animatedY = y.truncatingRemainder(dividingBy: verticalCycle) - verticalOffset

                Circle()
                    .fill(Color.white.opacity(flakeOpacity))
                    .frame(width: flakeSize, height: flakeSize)
                    .blur(radius: isBlizzard && index.isMultiple(of: 5) ? 0.6 : 0)
                    .offset(x: x + wind * windMultiplier + floatWobble, y: animatedY)
            }
        }
    }

    private func lightning(size: CGSize, opacity: Double) -> some View {
        ZStack {
            lightningBolt(
                points: [
                    CGPoint(x: size.width * 0.71, y: size.height * 0.08),
                    CGPoint(x: size.width * 0.62, y: size.height * 0.33),
                    CGPoint(x: size.width * 0.70, y: size.height * 0.32),
                    CGPoint(x: size.width * 0.58, y: size.height * 0.58)
                ],
                opacity: opacity
            )

            if weather.condition == .storm {
                lightningBolt(
                    points: [
                        CGPoint(x: size.width * 0.34, y: size.height * 0.14),
                        CGPoint(x: size.width * 0.39, y: size.height * 0.31),
                        CGPoint(x: size.width * 0.34, y: size.height * 0.30),
                        CGPoint(x: size.width * 0.42, y: size.height * 0.48)
                    ],
                    opacity: opacity * 0.70
                )
            }
        }
    }

    private func lightningBolt(points: [CGPoint], opacity: Double) -> some View {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        .stroke(Color.white.opacity(opacity), style: StrokeStyle(lineWidth: 2.35, lineCap: .round, lineJoin: .round))
        .shadow(color: Color(red: 0.72, green: 0.85, blue: 1.0).opacity(opacity), radius: 12)
    }
}

private struct AtmosphericCloudLayer: View {
    var width: CGFloat
    var height: CGFloat
    var opacity: Double
    var phase: TimeInterval
    var variant: Int
    var highlight: Color
    var midtone: Color
    var shadow: Color
    var isDense: Bool

    var body: some View {
        let breath = 1 + CGFloat(sin(phase * 0.16 + Double(variant) * 1.9)) * 0.009
        let shadowStrength = isDense ? 0.92 : 0.68

        ZStack {
            AtmosphericCloudShape(variant: variant)
                .fill(
                    LinearGradient(
                        colors: [
                            highlight.opacity(opacity * (isDense ? 0.82 : 0.94)),
                            midtone.opacity(opacity * 0.94),
                            shadow.opacity(opacity * shadowStrength)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            AtmosphericCloudShape(variant: variant + 1)
                .fill(shadow.opacity(opacity * (isDense ? 0.44 : 0.28)))
                .scaleEffect(x: 0.93, y: 0.54, anchor: .bottom)
                .offset(y: height * 0.13)
                .blur(radius: max(2.5, height * 0.055))

            ZStack {
                ForEach(0..<5, id: \.self) { index in
                    let seed = index + variant * 3
                    let glowWidth = width * (0.18 + CGFloat((seed * 7) % 4) * 0.035)
                    let glowHeight = height * (0.34 + CGFloat((seed * 5) % 3) * 0.08)
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [
                                    highlight.opacity(opacity * (isDense ? 0.22 : 0.38)),
                                    midtone.opacity(opacity * 0.12),
                                    .clear
                                ],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: max(glowWidth, glowHeight) * 0.62
                            )
                        )
                        .frame(width: glowWidth, height: glowHeight)
                        .offset(
                            x: width * (-0.29 + CGFloat(index) * 0.145),
                            y: height * (-0.10 + CGFloat((seed * 11) % 4) * 0.045)
                        )
                        .blur(radius: max(1.8, height * 0.035))
                }

                Capsule()
                    .fill(highlight.opacity(opacity * (isDense ? 0.10 : 0.20)))
                    .frame(width: width * 0.58, height: height * 0.11)
                    .blur(radius: max(2, height * 0.045))
                    .offset(x: -width * 0.08, y: -height * 0.18)
            }
            .mask(AtmosphericCloudShape(variant: variant))

            Capsule()
                .fill(shadow.opacity(opacity * 0.16))
                .frame(width: width * 0.70, height: height * 0.10)
                .blur(radius: max(3, height * 0.08))
                .offset(x: width * 0.04, y: height * 0.30)
        }
        .frame(width: width, height: height)
        .compositingGroup()
        .shadow(color: shadow.opacity(opacity * 0.18), radius: max(3, height * 0.09), y: height * 0.08)
        .scaleEffect(x: breath, y: 1 / breath)
        .drawingGroup()
    }
}

/// One continuous, asymmetric silhouette avoids the repeated circular lobes
/// that make compact procedural clouds look like icons rather than atmosphere.
private struct AtmosphericCloudShape: Shape {
    var variant: Int

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        path.move(to: point(0.015, 0.70))

        if variant.isMultiple(of: 2) {
            path.addCurve(to: point(0.17, 0.49), control1: point(0.04, 0.60), control2: point(0.09, 0.48))
            path.addCurve(to: point(0.33, 0.43), control1: point(0.21, 0.44), control2: point(0.27, 0.47))
            path.addCurve(to: point(0.48, 0.16), control1: point(0.36, 0.29), control2: point(0.40, 0.15))
            path.addCurve(to: point(0.65, 0.29), control1: point(0.55, 0.14), control2: point(0.60, 0.22))
            path.addCurve(to: point(0.78, 0.34), control1: point(0.69, 0.24), control2: point(0.75, 0.27))
            path.addCurve(to: point(0.975, 0.61), control1: point(0.89, 0.34), control2: point(0.95, 0.48))
        } else {
            path.addCurve(to: point(0.18, 0.55), control1: point(0.06, 0.59), control2: point(0.10, 0.50))
            path.addCurve(to: point(0.35, 0.30), control1: point(0.24, 0.51), control2: point(0.25, 0.34))
            path.addCurve(to: point(0.50, 0.35), control1: point(0.40, 0.23), control2: point(0.46, 0.25))
            path.addCurve(to: point(0.66, 0.18), control1: point(0.54, 0.24), control2: point(0.59, 0.16))
            path.addCurve(to: point(0.81, 0.39), control1: point(0.73, 0.17), control2: point(0.75, 0.31))
            path.addCurve(to: point(0.975, 0.61), control1: point(0.90, 0.37), control2: point(0.95, 0.49))
        }

        path.addCurve(to: point(0.88, 0.75), control1: point(0.99, 0.69), control2: point(0.95, 0.75))
        path.addCurve(to: point(0.61, 0.80), control1: point(0.79, 0.77), control2: point(0.70, 0.78))
        path.addCurve(to: point(0.33, 0.77), control1: point(0.51, 0.83), control2: point(0.42, 0.77))
        path.addCurve(to: point(0.015, 0.70), control1: point(0.19, 0.81), control2: point(0.07, 0.78))
        path.closeSubpath()
        return path
    }
}

private struct CityEnvironmentReadout: View {
    var weather: RideWeatherSnapshot
    var rideDurationText: String?
    /// Supplied by `LiveRideEnvironment` so this overlay shares the exact card
    /// bounds and never receives an unconstrained nested GeometryReader proposal.
    var sceneSize: CGSize

    var body: some View {
        let size = sceneSize
        let foreground = weather.isNight ? Color.white.opacity(0.92) : Color.black.opacity(0.70)
        let secondary = weather.isNight ? Color.white.opacity(0.72) : Color.black.opacity(0.52)
        let labelSize = min(max(size.width * 0.027, 10), 12)
        let timeSize = min(max(size.width * 0.039, 13), 16)
        let topInset = min(max(size.height * 0.075, 18), 24)
        let horizontalInset = min(max(size.width * 0.055, 18), 26)
        let metricsWidth = min(max(size.width * 0.39, 130), 158)
        let rideTimeWidth = max(96, size.width - metricsWidth - horizontalInset * 3)
        let metricsX = max(horizontalInset, size.width - metricsWidth - horizontalInset)

        ZStack(alignment: .topLeading) {
            if let rideDurationText {
                HStack(spacing: 3) {
                    Image(systemName: "figure.outdoor.cycle")
                    Text("骑行 \(rideDurationText)")
                        .monospacedDigit()
                }
                .font(.system(size: timeSize, weight: .bold, design: .rounded))
                .foregroundStyle(foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .shadow(color: weather.isNight ? .black.opacity(0.76) : .white.opacity(0.82), radius: 2)
                .frame(width: rideTimeWidth, alignment: .leading)
                .offset(x: horizontalInset, y: topInset)
            }

            VStack(alignment: .trailing, spacing: 3) {
                metric(icon: "thermometer.medium", title: "气温", value: weather.temperatureText, foreground: foreground, secondary: secondary, fontSize: labelSize)
                metric(icon: "wind", title: "风速", value: weather.windText, foreground: foreground, secondary: secondary, fontSize: labelSize)
                metric(icon: "sun.max", title: "紫外线", value: weather.ultravioletText, foreground: foreground, secondary: secondary, fontSize: labelSize)
                metric(icon: "aqi.medium", title: "空气质量", value: weather.airQualityText, foreground: foreground, secondary: secondary, fontSize: labelSize)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(.black.opacity(weather.isNight ? 0.28 : 0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(width: metricsWidth, alignment: .trailing)
            .offset(x: metricsX, y: topInset)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    private func metric(
        icon: String,
        title: String,
        value: String,
        foreground: Color,
        secondary: Color,
        fontSize: CGFloat
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(secondary)
            Text(title)
                .foregroundStyle(secondary)
            Text(value)
                .foregroundStyle(foreground)
                .monospacedDigit()
        }
        .font(.system(size: fontSize, weight: .medium, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .shadow(color: weather.isNight ? .black.opacity(0.76) : .white.opacity(0.82), radius: 1.5)
    }
}

private struct RideCityBackdrop: View {
    var phase: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let drift = CGFloat((phase * 0.045).truncatingRemainder(dividingBy: 1.0)) * proxy.size.width * 0.15

            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [.white.opacity(0.34), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )

                HStack(alignment: .bottom, spacing: proxy.size.width * 0.035) {
                    cityBuilding(width: proxy.size.width * 0.13, height: proxy.size.height * 0.34)
                    cityBuilding(width: proxy.size.width * 0.17, height: proxy.size.height * 0.52)
                    cityBuilding(width: proxy.size.width * 0.12, height: proxy.size.height * 0.40)
                    cityBuilding(width: proxy.size.width * 0.19, height: proxy.size.height * 0.62)
                    cityBuilding(width: proxy.size.width * 0.14, height: proxy.size.height * 0.45)
                }
                .offset(x: -drift, y: proxy.size.height * 0.03)

                Path { path in
                    path.move(to: CGPoint(x: proxy.size.width * 0.66, y: proxy.size.height * 0.12))
                    path.addLine(to: CGPoint(x: proxy.size.width * 0.66, y: proxy.size.height * 0.67))
                    path.addLine(to: CGPoint(x: proxy.size.width * 0.99, y: proxy.size.height * 0.67))
                }
                .stroke(Color.white.opacity(0.60), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.10), radius: 2)
            }
        }
    }

    private func cityBuilding(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(LinearGradient(colors: [Color.white.opacity(0.64), Color.gray.opacity(0.30)], startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) {
                VStack(spacing: 5) {
                    ForEach(0..<4, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.white.opacity(0.36))
                            .frame(height: 2)
                    }
                }
                .padding(5)
            }
    }
}

private struct RideRoad: View {
    var phase: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let progress = CGFloat((phase * 1.18).truncatingRemainder(dividingBy: 1.0))

            ZStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.12, green: 0.16, blue: 0.18), Color(red: 0.29, green: 0.36, blue: 0.39)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .rotation3DEffect(.degrees(64), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
                    .offset(y: proxy.size.height * 0.36)

                ForEach(0..<6, id: \.self) { index in
                    let travel = (CGFloat(index) + progress) / 6.0
                    Capsule()
                        .fill(Color.white.opacity(0.84 - Double(index) * 0.07))
                        .frame(width: proxy.size.width * (0.07 + travel * 0.13), height: 2.2 + travel * 2.4)
                        .offset(
                            x: -proxy.size.width * 0.48 + travel * proxy.size.width * 1.32,
                            y: proxy.size.height * (0.22 + travel * 0.18)
                        )
                }
            }
        }
    }
}

private struct RideDurationHud: View {
    var startedAt: Date
    var now: Date
    var phase: TimeInterval

    private var durationText: String {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        let hours = elapsed / 3_600
        let minutes = (elapsed % 3_600) / 60
        let seconds = elapsed % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    var body: some View {
        let glow = 0.68 + 0.22 * sin(phase * 2.2)

        VStack(spacing: 5) {
            Text("骑行时间")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.76))

            Text(durationText)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .minimumScaleFactor(0.72)
                .lineLimit(1)

            Text("本次骑行")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.68))

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.teslaGreen.opacity(0.55), Color.teslaGreen, .cyan.opacity(0.55)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 54, height: 3)
                .shadow(color: Color.teslaGreen.opacity(glow), radius: 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(7)
        .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.36), Color.teslaGreen.opacity(0.48)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: Color.teslaGreen.opacity(0.23), radius: 12)
    }
}

private struct ChargingCableEnergyFlow: View {
    var phase: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let travel = CGFloat((phase * 0.68).truncatingRemainder(dividingBy: 1.0))

            ZStack {
                energyParticle(progress: travel, size: proxy.size)
                energyParticle(progress: (travel + 0.34).truncatingRemainder(dividingBy: 1.0), size: proxy.size)
                energyParticle(progress: (travel + 0.68).truncatingRemainder(dividingBy: 1.0), size: proxy.size)
            }
        }
        .allowsHitTesting(false)
    }

    private func energyParticle(progress: CGFloat, size: CGSize) -> some View {
        // Cubic Bezier follows the cable from the right charging pile to the
        // vehicle-side battery socket. Splitting the coefficients prevents the
        // SwiftUI type checker from timing out in a Release build.
        let start = CGPoint(x: size.width * 0.87, y: size.height * 0.58)
        let control1 = CGPoint(x: size.width * 0.80, y: size.height * 0.84)
        let control2 = CGPoint(x: size.width * 0.65, y: size.height * 0.54)
        let end = CGPoint(x: size.width * 0.57, y: size.height * 0.66)
        let inverse = 1 - progress
        let startCoefficient = inverse * inverse * inverse
        let control1Coefficient = 3 * inverse * inverse * progress
        let control2Coefficient = 3 * inverse * progress * progress
        let endCoefficient = progress * progress * progress
        let x = startCoefficient * start.x
            + control1Coefficient * control1.x
            + control2Coefficient * control2.x
            + endCoefficient * end.x
        let y = startCoefficient * start.y
            + control1Coefficient * control1.y
            + control2Coefficient * control2.y
            + endCoefficient * end.y
        let diameter = max(3, size.width * 0.012)

        return Circle()
            .fill(Color.teslaGreen)
            .frame(width: diameter, height: diameter)
            .shadow(color: Color.teslaGreen.opacity(0.96), radius: 6)
            .position(x: x, y: y)
    }
}

private struct RideWheelGlints: View {
    var phase: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let rotation = Angle.degrees((phase * 520).truncatingRemainder(dividingBy: 360))

            HStack(spacing: proxy.size.width * 0.28) {
                wheelGlint(rotation: rotation)
                wheelGlint(rotation: rotation)
            }
            .frame(maxWidth: .infinity)
            .offset(y: proxy.size.height * 0.22)
        }
        .allowsHitTesting(false)
    }

    private func wheelGlint(rotation: Angle) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.28), lineWidth: 1.1)
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.teslaGreen.opacity(0.58))
                    .frame(width: 1.5, height: 21)
                    .rotationEffect(rotation + .degrees(Double(index) * 60))
            }
        }
        .frame(width: 36, height: 36)
        .blur(radius: 0.15)
        .opacity(0.70)
    }
}

private struct RideMotionStreaks: View {
    var phase: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                ForEach(0..<5, id: \.self) { index in
                    RideMotionStreak(index: index, phase: phase, size: proxy.size)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct RideMotionStreak: View {
    var index: Int
    var phase: TimeInterval
    var size: CGSize

    private var progress: CGFloat {
        let speed = 1.08 + Double(index) * 0.13
        let offset = Double(index) * 0.19
        return CGFloat((phase * speed + offset).truncatingRemainder(dividingBy: 1.0))
    }

    var body: some View {
        let width = size.width * (0.17 + CGFloat(index) * 0.032)
        let height = max(10, size.height * (0.030 + CGFloat(index % 2) * 0.006))
        // Positive progress now travels from the left edge to the right edge,
        // matching the requested left-to-right airflow.
        let x = (-0.30 + progress * 1.58) * size.width
        let y = size.height * (0.49 + CGFloat(index) * 0.071)
        let opacity = 0.50 - Double(index) * 0.055

        CurvedRideWindRibbon(variant: index)
            .stroke(
                LinearGradient(
                    colors: [
                        .clear,
                        Color.white.opacity(opacity * 0.68),
                        Color.teslaGreen.opacity(opacity * 0.62),
                        Color.white.opacity(opacity * 0.20)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round)
            )
            .frame(width: width, height: height)
            .shadow(color: Color.teslaGreen.opacity(opacity * 0.20), radius: 3)
            .offset(x: x, y: y)
    }
}

private struct CurvedRideWindRibbon: Shape {
    var variant: Int

    func path(in rect: CGRect) -> Path {
        let bend = rect.height * (variant.isMultiple(of: 2) ? 0.32 : -0.28)
        let secondaryBend = rect.height * (variant.isMultiple(of: 3) ? -0.18 : 0.16)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + secondaryBend))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.midY - bend),
            control1: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.midY + bend),
            control2: CGPoint(x: rect.minX + rect.width * 0.33, y: rect.midY - bend * 1.15)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY + bend * 0.25),
            control1: CGPoint(x: rect.minX + rect.width * 0.68, y: rect.midY + bend * 0.55),
            control2: CGPoint(x: rect.minX + rect.width * 0.84, y: rect.midY - secondaryBend)
        )
        return path
    }
}

private struct TeslaHeroMetric: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.teslaSecondaryText)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.teslaPrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.teslaSecondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct BatteryProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.teslaControlBackground)

                Capsule()
                    .fill(Color.teslaGreen)
                    .frame(width: max(proxy.size.width * value, 8))
            }
        }
        .frame(height: 5)
        .accessibilityLabel("电量进度 \(Int(value * 100))%")
    }
}

private struct StatusChip: View {
    var title: String
    var systemImage: String
    var color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.teslaCardBackground)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            }
    }
}

/// A layered, perspective-like energy orb. The rotating rings, highlights and
/// pulse make the charging state read as a compact 3D animation rather than a
/// static charging badge.
private struct ChargingEnergyOrb: View {
    var isAnimating: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.98), Color.teslaGreen.opacity(0.90), Color.teslaGreen.opacity(0.28)],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: 34
                    )
                )
                .shadow(color: Color.teslaGreen.opacity(isAnimating ? 0.60 : 0.28), radius: isAnimating ? 14 : 7)
                .scaleEffect(isAnimating ? 1.02 : 0.94)

            Circle()
                .stroke(
                    AngularGradient(
                        colors: [.white.opacity(0.95), .clear, Color.cyan.opacity(0.74), .clear, .white.opacity(0.78)],
                        center: .center
                    ),
                    lineWidth: 2.6
                )
                .rotation3DEffect(.degrees(64), axis: (x: 1, y: 0, z: 0))
                .rotationEffect(.degrees(isAnimating ? 360 : 0))

            Ellipse()
                .stroke(Color.white.opacity(0.54), lineWidth: 1.1)
                .frame(width: 41, height: 14)
                .rotation3DEffect(.degrees(65), axis: (x: 1, y: 0, z: 0))
                .rotationEffect(.degrees(isAnimating ? -360 : 0))

            Image(systemName: "bolt.fill")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(Color(red: 0.01, green: 0.26, blue: 0.17))
                .shadow(color: .white.opacity(0.68), radius: 1, y: -1)
                .offset(y: isAnimating ? -2 : 2)

            Circle()
                .fill(Color.white.opacity(0.88))
                .frame(width: 7, height: 7)
                .blur(radius: 0.3)
                .offset(x: -12, y: -13)
        }
        .drawingGroup()
        .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: isAnimating)
    }
}

private struct ChargingStatusView: View {
    var state: NinebotVehicleState
    @State private var isAnimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ChargingEnergyOrb(isAnimating: isAnimating)
                    .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 2) {
                    Text("正在充电")
                        .font(.subheadline.weight(.semibold))
                    Text("约 \(state.estimatedFullChargeTimeText) 充满")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            if !metrics.isEmpty {
                HStack(spacing: 8) {
                    ForEach(metrics) { metric in
                        ChargingMetricChip(metric: metric)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            GeometryReader { proxy in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.teslaGreen.opacity(0.9), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * 0.42, height: 2)
                    .offset(x: isAnimating ? proxy.size.width : -proxy.size.width * 0.42)
                    .animation(.linear(duration: 1.35).repeatForever(autoreverses: false), value: isAnimating)
            }
            .frame(height: 2)
        }
        .clipped()
        .onAppear {
            isAnimating = true
        }
    }

    private var metrics: [ChargingMetric] {
        [
            state.chargingPower.map {
                ChargingMetric(title: "功率", value: formatNumber($0, unit: " W", maximumFractionDigits: 0), systemImage: "bolt.fill")
            },
            state.batteryVoltage.map {
                ChargingMetric(title: "电压", value: formatNumber($0, unit: " V", maximumFractionDigits: 1), systemImage: "bolt.batteryblock.fill")
            },
            state.batteryTemperature.map {
                ChargingMetric(title: "温度", value: formatNumber($0, unit: "°C", maximumFractionDigits: 1), systemImage: "thermometer.medium")
            }
        ].compactMap { $0 }
    }
}

private struct ChargingMetric: Identifiable {
    var title: String
    var value: String
    var systemImage: String

    var id: String {
        title
    }
}

private struct ChargingMetricChip: View {
    var metric: ChargingMetric

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: metric.systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.teslaGreen)
            VStack(alignment: .leading, spacing: 1) {
                Text(metric.value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(metric.title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.teslaCardBackground.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ControlMetricPill: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.teslaSecondaryText)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.teslaPrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct VehicleLocationRideSummaryPanel: View {
    var snapshot: NinebotVehicleSnapshot
    var resolvedAddress: String?
    var isLoading: Bool
    var onOpenTrips: () -> Void
    var onRingBell: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VehicleLocationSummaryCard(
                snapshot: snapshot,
                resolvedAddress: resolvedAddress,
                isLoading: isLoading,
                onRingBell: onRingBell
            )
            .frame(maxWidth: .infinity)

            Button(action: onOpenTrips) {
                VehicleRideSummaryGroupCard(snapshot: snapshot)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 198)
    }
}

private struct VehicleLocationSummaryCard: View {
    var snapshot: NinebotVehicleSnapshot
    var resolvedAddress: String?
    var isLoading: Bool
    var onRingBell: () -> Void

    var body: some View {
        if let coordinate = vehicleCoordinate(snapshot.state) {
            NavigationLink {
                NinebotVehicleMapView(
                    snapshot: snapshot,
                    address: normalizedLocationText,
                    coordinate: coordinate,
                    isLoading: isLoading,
                    onRingBell: onRingBell
                )
            } label: {
                content(coordinate: coordinate)
            }
            .buttonStyle(.plain)
        } else {
            content(coordinate: nil)
        }
    }

    private func content(coordinate: CLLocationCoordinate2D?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("车辆位置")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text("更新自\(formatTime(snapshot.state.updatedAt))")
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            ZStack(alignment: .bottomLeading) {
                if let coordinate {
                    VehicleLocationPreviewMap(coordinate: coordinate)
                } else {
                    ZStack {
                        Color.teslaControlBackground
                        Image(systemName: "map")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Color.teslaSecondaryText)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(locationTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.teslaPrimaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.top, 28)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    LinearGradient(
                        colors: [
                            Color.teslaCardBackground.opacity(0.98),
                            Color.teslaCardBackground.opacity(0.82),
                            Color.teslaCardBackground.opacity(0)
                        ],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 18,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 24,
                topTrailingRadius: 18,
                style: .continuous
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var normalizedLocationText: String? {
        guard let value = resolvedAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private var locationTitle: String {
        if let normalizedLocationText {
            return normalizedLocationText
        }
        if let description = snapshot.state.locationDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return description
        }
        if let coordinate = vehicleCoordinate(snapshot.state) {
            return coordinateText(coordinate.latitude, coordinate.longitude)
        }
        return "暂无车辆位置"
    }
}

private struct VehicleLocationPreviewMap: View {
    var coordinate: CLLocationCoordinate2D
    @State private var cameraPosition: MapCameraPosition

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        _cameraPosition = State(initialValue: .region(Self.region(for: coordinate)))
    }

    var body: some View {
        Map(position: $cameraPosition) {
            Marker("车辆", systemImage: "scooter", coordinate: coordinate)
                .tint(Color.teslaGreen)
        }
        .allowsHitTesting(false)
    }

    private static func region(for coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.0048, longitudeDelta: 0.0048)
        )
    }
}

private struct VehicleRideSummaryGroupCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label("行程", systemImage: "road.lanes")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.teslaSecondaryText)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 8) {
                VehicleRideSummaryTile(
                    title: "最近骑行",
                    value: formatDistanceNumber(snapshot.state.lastMileage),
                    unit: "km",
                    systemImage: "arrow.left.arrow.right",
                    isPrimary: true
                )

                VehicleRideSummaryTile(
                    title: "总行程",
                    value: formatDistanceNumber(snapshot.state.totalMileage),
                    unit: "km",
                    systemImage: "calendar",
                    isPrimary: false
                )
            }
            .frame(maxHeight: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct VehicleRideSummaryTile: View {
    var title: String
    var value: String
    var unit: String
    var systemImage: String
    var isPrimary: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: systemImage)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: isPrimary ? 30 : 25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.52)
                Text(unit)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: 112, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(isPrimary ? Color.teslaGreen.opacity(0.10) : Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct VehicleRideMetricCard: View {
    var title: String
    var value: String
    var unit: String
    var systemImage: String
    var isProminent: Bool

    var body: some View {
        Group {
            if isProminent {
                prominentContent
            } else {
                compactContent
            }
        }
        .padding(14)
        .frame(height: isProminent ? 110 : 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.02), radius: 10, x: 0, y: 4)
    }

    private var prominentContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.teslaSecondaryText)
            }

            Spacer(minLength: 0)

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)

                Text(unit)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
            }
        }
    }

    private var compactContent: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.teslaSecondaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(value)
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.teslaPrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.68)

            Text(unit)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.teslaPrimaryText)
                .lineLimit(1)
        }
    }
}

private struct VehicleRangeEstimatePanel: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("预估可行驶")
                        .font(.headline)
                    Text(snapshot.state.localEstimateBasisText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text(snapshot.state.localEstimatedMileageText)
                    .font(.title2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            RangeEstimateBar(batteryFraction: snapshot.state.batteryFraction)

            HStack(spacing: 10) {
                BasicInfoTile(title: "本地模型", value: snapshot.state.localEstimatedMileageText, systemImage: "function")
                BasicInfoTile(title: "最高速度", value: snapshot.state.maximumSpeedText, systemImage: "gauge.with.dots.needle.67percent")
                BasicInfoTile(title: "接口续航", value: snapshot.state.enduranceText, systemImage: "road.lanes")
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.02), radius: 10, x: 0, y: 4)
    }
}

private struct RangeEstimateBar: View {
    var batteryFraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.teslaControlBackground)

                Capsule()
                    .fill(Color.teslaGreen.opacity(0.9))
                    .frame(width: max(proxy.size.width * batteryFraction, 8))
            }
        }
        .frame(height: 8)
        .accessibilityLabel("剩余电量 \(Int(batteryFraction * 100))%")
    }
}

private struct VehicleHealthPanel: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        let warnings = snapshot.state.warningTexts
        let health = snapshot.state.health

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(healthColor(health.level).opacity(0.14))
                    Image(systemName: snapshot.state.isCharging == true ? "bolt.fill" : "battery.100")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(snapshot.state.isCharging == true ? Color.teslaGreen : batteryTextColor(snapshot.state))
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text("电池")
                        .font(.headline)
                    Text(snapshot.state.isCharging == true ? snapshot.state.chargeSummaryText : "查看电压、温度和充电信息")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    Text(snapshot.state.batteryText)
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle(batteryTextColor(snapshot.state))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.teslaSecondaryText)
                }
                .frame(alignment: .center)
            }

            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(18)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct VehicleUsagePanel: View {
    var snapshot: NinebotVehicleSnapshot
    var showsDisclosure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("用车统计")
                        .font(.headline)
                    Text("完整行程和能耗进详情查看")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if showsDisclosure {
                    HStack(spacing: 4) {
                        Text("行程")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                BasicInfoTile(title: "本月日均", value: snapshot.state.dailyAverageMileageText, systemImage: "calendar")
                BasicInfoTile(title: "最近骑行", value: snapshot.state.lastRideSummaryText, systemImage: "clock.arrow.circlepath")
                BasicInfoTile(title: "最高速度", value: snapshot.state.maximumSpeedText, systemImage: "gauge.with.dots.needle.67percent")
                BasicInfoTile(title: "本月能耗", value: snapshot.state.monthEnergyPerKmText, systemImage: "bolt.horizontal.fill")
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct TripHeroPanel: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("行程概要")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text(snapshot.vehicle.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(snapshot.state.rangeEstimateAccuracyText)
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color.teslaGreen)
                    Text("预估准确率")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(snapshot.state.localEstimatedMileageText)
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text("预计可行驶")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                BasicInfoTile(title: "今日里程", value: snapshot.state.todayMileageText, systemImage: "sun.max.fill")
                BasicInfoTile(title: "最高速度", value: snapshot.state.maximumSpeedText, systemImage: "gauge.with.dots.needle.67percent")
                BasicInfoTile(title: "有效样本", value: "\(snapshot.state.observedRangeSampleCount) 次", systemImage: "scope")
                BasicInfoTile(title: "本月日均", value: snapshot.state.dailyAverageMileageText, systemImage: "calendar")
            }

            Label(snapshot.state.rangeEstimateAccuracyDetailText, systemImage: "target")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.teslaSecondaryText)
                .lineLimit(1)
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct TripTrendEntryCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.teslaGreen.opacity(0.14))
                Image(systemName: "chart.xyaxis.line")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.teslaGreen)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text("查看趋势")
                    .font(.headline)
                    .foregroundStyle(Color.teslaPrimaryText)
                Text("里程、用电、速度和续航估算表现")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(snapshot.state.monthMileageText)
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.teslaSecondaryText)
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct TripTrendView: View {
    var snapshot: NinebotVehicleSnapshot

    private var analysis: TripTrendAnalysis {
        TripTrendAnalysis(snapshot: snapshot)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TripTrendHeroCard(snapshot: snapshot, analysis: analysis)
                TripTrendRangeModelCard(snapshot: snapshot)
                TripTrendDailyCard(records: analysis.dailyRecords)
                TripTrendRideCard(analysis: analysis)
                TripTrendInsightCard(analysis: analysis)
            }
            .padding(16)
            .padding(.bottom, 12)
        }
        .background(Color.teslaPageBackground.ignoresSafeArea())
        .navigationTitle("趋势分析")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TripTrendRangeModelCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("本地续航模型")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text(snapshot.state.rangeModelInsightText)
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer(minLength: 8)

                Text(snapshot.state.localEstimatedMileageText)
                    .font(.title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                BasicInfoTile(title: "准确率", value: snapshot.state.rangeEstimateAccuracyText, systemImage: "target")
                BasicInfoTile(title: "有效样本", value: "\(snapshot.state.observedRangeSampleCount) 次", systemImage: "scope")
                BasicInfoTile(title: "近期效率", value: snapshot.state.rangePerBatteryPercentText, systemImage: "gauge.with.dots.needle.33percent")
                BasicInfoTile(title: "接口续航", value: snapshot.state.enduranceText, systemImage: "road.lanes")
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct TripTrendHeroCard: View {
    var snapshot: NinebotVehicleSnapshot
    var analysis: TripTrendAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.vehicle.displayName)
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                        .lineLimit(1)
                    Text("趋势分析")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(snapshot.state.rangeEstimateAccuracyText)
                        .font(.headline.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color.teslaGreen)
                    Text("预估准确率")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(formatDistance(analysis.monthMileage))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text("当月行程")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
            }

            HStack(spacing: 10) {
                TrendHeroMetric(title: "骑行次数", value: "\(analysis.rideCount)", suffix: "次", systemImage: "list.number")
                TrendHeroMetric(title: "活跃天数", value: "\(analysis.activeDayCount)", suffix: "天", systemImage: "calendar")
                TrendHeroMetric(title: "单公里耗电", value: analysis.energyPerKmShortText, suffix: "Wh/km", systemImage: "bolt.horizontal.fill")
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct TrendHeroMetric: View {
    var title: String
    var value: String
    var suffix: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.teslaSecondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(suffix)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
            }
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.teslaSecondaryText)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct TripTrendDailyCard: View {
    var records: [NinebotDailyMileageRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("每日里程趋势")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text(records.isEmpty ? "等待接口返回本月 detail" : "最近 \(visibleRecords.count) 天")
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer()

                Text(formatDistance(records.map(\.mileage).max()))
                    .font(.headline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.teslaGreen)
            }

            if records.isEmpty {
                EmptyTrendState(text: "暂无每日里程趋势")
            } else {
                TrendBarChart(values: visibleRecords.map { record in
                    TrendBarValue(
                        id: record.id,
                        label: "\(record.day)",
                        value: record.mileage,
                        tint: Color.teslaGreen
                    )
                })
                .frame(height: 176)

                HStack(spacing: 10) {
                    ControlMetricPill(title: "日均", value: formatDistance(averageMileage), systemImage: "chart.bar.xaxis")
                    ControlMetricPill(title: "最高", value: formatDistance(peakMileage), systemImage: "arrow.up.right")
                    ControlMetricPill(title: "活跃", value: "\(records.count) 天", systemImage: "calendar")
                }
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }

    private var visibleRecords: [NinebotDailyMileageRecord] {
        Array(records.suffix(14))
    }

    private var averageMileage: Double? {
        guard !records.isEmpty else { return nil }
        return records.reduce(0) { $0 + $1.mileage } / Double(records.count)
    }

    private var peakMileage: Double? {
        records.map(\.mileage).max()
    }
}

private struct TripTrendRideCard: View {
    var analysis: TripTrendAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最近骑行表现")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text(analysis.recentRides.isEmpty ? "等待行程列表" : "最近 \(analysis.recentRides.count) 次")
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer()

                Text(formatSpeed(analysis.highestSpeed))
                    .font(.headline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.teslaGreen)
            }

            if analysis.recentRides.isEmpty {
                EmptyTrendState(text: "暂无最近骑行数据")
            } else {
                TripRecentRideBars(records: analysis.recentRides)
                    .frame(height: 168)

                HStack(spacing: 10) {
                    ControlMetricPill(title: "最高速度", value: formatSpeed(analysis.highestSpeed), systemImage: "gauge.with.dots.needle.67percent")
                    ControlMetricPill(title: "平均用电", value: formatPercent(analysis.averageUsedElectricity), systemImage: "powerplug.fill")
                    ControlMetricPill(title: "最高里程", value: formatDistance(analysis.peakRideMileage), systemImage: "arrow.up.right")
                }
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct TripTrendInsightCard: View {
    var analysis: TripTrendAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地模型提示")
                .font(.headline)
                .foregroundStyle(Color.teslaPrimaryText)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(analysis.insights, id: \.self) { insight in
                    Label(insight, systemImage: "sparkle.magnifyingglass")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.teslaSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}


private struct TrendBarValue: Identifiable {
    var id: String
    var label: String
    var value: Double
    var tint: Color
}

private struct TrendBarChart: View {
    var values: [TrendBarValue]

    var body: some View {
        GeometryReader { proxy in
            let maxValue = max(values.map(\.value).max() ?? 0, 1)
            let chartHeight = max(proxy.size.height - 42, 1)
            let barWidth = min(max(proxy.size.width / CGFloat(max(values.count, 1)) * 0.24, 4), 11)

            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { _ in
                        Divider()
                            .opacity(0.55)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 20)

                HStack(alignment: .bottom, spacing: values.count > 10 ? 7 : 10) {
                    ForEach(values) { item in
                        VStack(spacing: 6) {
                            Text(shortTrendValue(item.value))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(Color.teslaSecondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)

                            ZStack(alignment: .bottom) {
                                Capsule()
                                    .fill(Color.teslaSecondaryText.opacity(0.10))
                                    .frame(width: barWidth, height: chartHeight)
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [item.tint.opacity(0.72), item.tint],
                                            startPoint: .bottom,
                                            endPoint: .top
                                        )
                                    )
                                    .frame(width: barWidth, height: max(6, chartHeight * CGFloat(item.value / maxValue)))
                            }

                            Text(item.label)
                                .font(.caption2.monospacedDigit().weight(.medium))
                                .foregroundStyle(Color.teslaSecondaryText)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct TripRecentRideBars: View {
    var records: [NinebotRideRecord]

    var body: some View {
        TrendBarChart(values: Array(records.enumerated()).map { index, ride in
            TrendBarValue(
                id: ride.id,
                label: "\(index + 1)",
                value: ride.mileage ?? 0,
                tint: ride.energyPerKmWh.map { $0 > 45 ? Color.orange : Color.teslaGreen } ?? Color.teslaGreen
            )
        })
    }
}

private struct EmptyTrendState: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Color.teslaSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.teslaControlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct TripTrendAnalysis {
    var snapshot: NinebotVehicleSnapshot

    var dailyRecords: [NinebotDailyMileageRecord] {
        snapshot.state.dailyMileages.sorted {
            if let left = $0.date, let right = $1.date {
                return left < right
            }
            return $0.day < $1.day
        }
    }

    var rides: [NinebotRideRecord] {
        snapshot.state.rides
    }

    var recentRides: [NinebotRideRecord] {
        Array(rides.prefix(8))
    }

    var rideCount: Int {
        rides.count
    }

    var activeDayCount: Int {
        dailyRecords.count
    }

    var monthMileage: Double? {
        if let monthMileage = snapshot.state.monthMileage {
            return monthMileage
        }
        guard !dailyRecords.isEmpty else { return nil }
        return dailyRecords.reduce(0) { $0 + $1.mileage }
    }

    var averageDailyMileage: Double? {
        guard let monthMileage, !dailyRecords.isEmpty else { return nil }
        return monthMileage / Double(dailyRecords.count)
    }

    var highestSpeed: Double? {
        rides.compactMap(\.maximumSpeed).max()
    }

    var averageUsedElectricity: Double? {
        let samples = rides.compactMap(\.consumedEnergyWh).filter { $0 > 0 }
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    var peakRideMileage: Double? {
        rides.compactMap(\.mileage).max()
    }

    var energyPerKm: Double? {
        if let value = snapshot.state.monthEnergyPerKm {
            return value
        }

        let samples = rides.compactMap(\.energyPerKmWh)
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / Double(samples.count)
    }

    var energyPerKmText: String {
        guard let energyPerKm else { return "-- Wh/km" }
        return "\(formatNumber(energyPerKm, unit: " Wh/km", maximumFractionDigits: 1))"
    }

    var energyPerKmShortText: String {
        guard let energyPerKm else { return "--" }
        return formatNumber(energyPerKm, unit: "", maximumFractionDigits: 1)
    }

    var insights: [String] {
        var result: [String] = []

        if let peak = peakRideMileage, let averageDailyMileage, peak > averageDailyMileage * 1.8 {
            result.append("有长距离单次骑行，续航预估会更依赖最近行程样本。")
        }

        if let averageUsedElectricity, averageUsedElectricity > 12 {
            result.append("最近单次平均用电偏高，可以关注胎压、载重和急加速。")
        }

        if let energyPerKm, energyPerKm > 35 {
            result.append("单公里耗电偏高，后续可以结合温度和速度继续校准。")
        }

        if snapshot.state.observedRangeSampleCount < 5 {
            result.append("有效续航样本还不多，多记录几次后准确率会更稳定。")
        }

        if result.isEmpty {
            result.append("当前趋势正常，继续积累行程后可以看到更稳定的变化。")
        }

        return result
    }
}

private struct DailyMileagePanel: View {
    var records: [NinebotDailyMileageRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("每日里程")
                        .font(.headline)
                    Text(records.isEmpty ? "等待行程接口返回 detail" : "按每日总里程生成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(formatDistance(totalMileage))
                    .font(.headline.monospacedDigit().weight(.semibold))
            }

            if records.isEmpty {
                Text("暂无每日里程数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                DailyMileageLineChart(records: records)
                    .frame(height: 128)

                HStack(spacing: 10) {
                    ControlMetricPill(title: "最高", value: formatDistance(peakMileage), systemImage: "arrow.up.right")
                    ControlMetricPill(title: "平均", value: formatDistance(averageMileage), systemImage: "chart.bar.xaxis")
                    ControlMetricPill(title: "天数", value: "\(records.count) 天", systemImage: "calendar")
                }
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: 8)
    }

    private var totalMileage: Double? {
        guard !records.isEmpty else { return nil }
        return records.reduce(0) { $0 + $1.mileage }
    }

    private var averageMileage: Double? {
        guard let totalMileage, !records.isEmpty else { return nil }
        return totalMileage / Double(records.count)
    }

    private var peakMileage: Double? {
        records.map(\.mileage).max()
    }
}

private struct DailyMileageLineChart: View {
    var records: [NinebotDailyMileageRecord]

    var body: some View {
        GeometryReader { proxy in
            let points = chartPoints(in: proxy.size)

            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { _ in
                        Divider()
                        Spacer(minLength: 0)
                    }
                    Divider()
                }
                .opacity(0.45)

                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(
                    LinearGradient(
                        colors: [Color.teslaGreen.opacity(0.65), Color.teslaGreen],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )

                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Circle()
                        .fill(Color(.systemBackground))
                        .overlay {
                            Circle()
                                .stroke(Color.teslaGreen, lineWidth: 2)
                        }
                        .frame(width: index == points.count - 1 ? 8 : 6, height: index == points.count - 1 ? 8 : 6)
                        .position(point)
                }
            }
        }
        .padding(12)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel("每日里程折线图")
    }

    private func chartPoints(in size: CGSize) -> [CGPoint] {
        guard !records.isEmpty else { return [] }
        let maxMileage = max(records.map(\.mileage).max() ?? 0, 1)
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let count = records.count

        return records.enumerated().map { index, record in
            let x = count == 1 ? width / 2 : width * CGFloat(index) / CGFloat(count - 1)
            let y = height - height * CGFloat(record.mileage / maxMileage)
            return CGPoint(x: x, y: min(max(y, 0), height))
        }
    }
}

private struct VehicleHistoryPanel: View {
    var points: [NinebotVehicleHistoryPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("历史记录")
                        .font(.headline)
                    Text("每次刷新后自动记录本地快照")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let summary = NinebotVehicleHistorySummary(points: points) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    BasicInfoTile(title: "记录周期", value: summary.periodText, systemImage: "clock")
                    BasicInfoTile(title: "样本数", value: "\(summary.sampleCount)", systemImage: "list.bullet.rectangle")
                    BasicInfoTile(title: "电量变化", value: summary.batteryDeltaText, systemImage: "battery.100")
                    BasicInfoTile(title: "里程变化", value: summary.mileageDeltaText, systemImage: "road.lanes")
                }
            } else {
                Text("刷新一次车况后开始记录趋势")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: 8)
    }
}

private struct VehicleHeroCard: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                VehicleImage(urlString: snapshot.vehicle.imageURLString, size: 78)

                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.vehicle.displayName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    Text(snapshot.vehicle.model)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(snapshot.vehicle.sn)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                BatteryGauge(value: snapshot.state.battery)
                    .frame(width: 62, height: 62)
            }

            HStack(spacing: 22) {
                MetricView(title: "续航", value: snapshot.state.enduranceText, systemImage: "road.lanes")
                MetricView(title: "锁车", value: snapshot.state.lockText, systemImage: snapshot.state.isLocked == true ? "lock.fill" : "lock.open.fill")
                MetricView(title: "电源", value: snapshot.state.powerText, systemImage: "power")
            }

            if snapshot.state.isCharging == true && !snapshot.state.isFullyCharged {
                VehicleChargingHologram(snapshot: snapshot)
            }

            Divider()

            Label("更新 \(formatDate(snapshot.state.updatedAt))", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: 8)
    }
}


/// Premium in-vehicle charging scene used on the vehicle details screen. It
/// combines the actual vehicle image with the animated energy orb so charging
/// feels tied to the selected vehicle, not merely shown as a dashboard badge.
private struct VehicleChargingHologram: View {
    var snapshot: NinebotVehicleSnapshot
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.teslaGreen.opacity(0.16))
                        .frame(width: 102, height: 102)
                        .blur(radius: isAnimating ? 10 : 5)

                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [.clear, Color.cyan.opacity(0.72), Color.teslaGreen, .clear],
                                center: .center
                            ),
                            lineWidth: 1.2
                        )
                        .frame(width: 92, height: 92)
                        .rotationEffect(.degrees(isAnimating ? 360 : 0))

                    VehicleImage(urlString: snapshot.vehicle.imageURLString, size: 100, showsBackground: false)
                        .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 8)

                    ChargingEnergyOrb(isAnimating: isAnimating)
                        .frame(width: 54, height: 54)
                        .offset(x: 34, y: -27)
                }
                .frame(width: 108, height: 96)

                VStack(alignment: .leading, spacing: 5) {
                    Label("3D 充电舱", systemImage: "bolt.horizontal.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.teslaGreen)
                    Text("能量正在注入车辆")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.60))

                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        Text(snapshot.state.battery.map(String.init) ?? "--")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text("%")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white.opacity(0.62))
                    }

                    Text("预计 \(snapshot.state.estimatedFullChargeTimeText) 充满")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.teslaGreen)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 5) {
                HStack {
                    Text("当前 \(snapshot.state.batteryText)")
                    Spacer()
                    Text("满电 100%")
                }
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.70))

                GeometryReader { proxy in
                    let width = max(proxy.size.width, 0)
                    let progress = min(max(snapshot.state.batteryFraction, 0), 1)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule()
                            .fill(LinearGradient(colors: [Color.teslaGreen, Color.cyan], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(width * progress, progress > 0 ? 8 : 0))
                            .shadow(color: Color.teslaGreen.opacity(isAnimating ? 0.75 : 0.30), radius: 7)
                    }
                }
                .frame(height: 6)
            }

            HStack(spacing: 7) {
                VehicleChargingHologramMetric(title: "电池电压", value: snapshot.state.batteryVoltageText, systemImage: "bolt.batteryblock.fill")
                VehicleChargingHologramMetric(title: "电池温度", value: snapshot.state.batteryTemperatureText, systemImage: "thermometer.medium")
                VehicleChargingHologramMetric(title: "充电功率", value: snapshot.state.chargingPowerText, systemImage: "bolt.fill")
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [Color(red: 0.015, green: 0.10, blue: 0.075), Color(red: 0.015, green: 0.045, blue: 0.075)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(colors: [Color.teslaGreen.opacity(0.52), Color.cyan.opacity(0.18), .white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .bottomLeading) {
            GeometryReader { proxy in
                Capsule()
                    .fill(LinearGradient(colors: [.clear, Color.teslaGreen, .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * 0.34, height: 2)
                    .offset(x: isAnimating ? proxy.size.width : -proxy.size.width * 0.34)
                    .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: isAnimating)
            }
            .frame(height: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear { isAnimating = true }
    }
}

private struct VehicleChargingHologramMetric: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.50))
                .lineLimit(1)
            Text(value)
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 7)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct VehicleActionPanel: View {
    var snapshot: NinebotVehicleSnapshot
    var isLoading: Bool
    var activeAction: NinebotVehicleAction?
    var onAction: (NinebotVehicleAction) -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let activeAction {
                VehicleControlLoadingStrip(action: activeAction)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            HStack(alignment: .center, spacing: 12) {
                CommandPadButton(
                    title: "寻车",
                    systemImage: "bell.fill",
                    tint: Color.teslaPrimaryText,
                    isLoading: activeAction == .bell,
                    isDisabled: isLoading
                ) {
                    onAction(.bell)
                }

                SlideActionControl(
                    title: isLocked ? "滑动开锁" : "滑动关锁",
                    completedTitle: isLocked ? "正在开锁" : "正在关锁",
                    systemImage: isLocked ? "lock.fill" : "lock.open.fill",
                    color: Color.teslaGreen,
                    isLoading: activeAction == slideAction,
                    isDisabled: isLoading
                ) {
                    onAction(slideAction)
                }
                .id(isLocked ? "unlock" : "lock")

                CommandPadButton(
                    title: "座桶",
                    systemImage: "shippingbox.fill",
                    tint: Color.teslaPrimaryText,
                    isLoading: activeAction == .openBucket,
                    isDisabled: isLoading
                ) {
                    onAction(.openBucket)
                }
            }
        }
        .padding(12)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
        .padding(.horizontal, 16)
    }

    private var isLocked: Bool {
        snapshot.state.isLocked != false
    }

    private var slideAction: NinebotVehicleAction {
        isLocked ? .engineStart : .engineStop
    }
}

private struct VehicleControlLoadingStrip: View {
    var action: NinebotVehicleAction

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.teslaGreen)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.loadingTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                Text("发送完成后自动刷新车况")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.teslaGreen.opacity(0.24), lineWidth: 1)
        }
    }
}

private struct CommandPadButton: View {
    var title: String
    var systemImage: String
    var tint: Color
    var isLoading: Bool
    var isDisabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(Color.teslaControlBackground)
                        .overlay {
                            Circle()
                                .stroke(Color.black.opacity(0.05), lineWidth: 1)
                        }
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.teslaGreen)
                    } else {
                        Image(systemName: systemImage)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(tint)
                    }
                }
                .frame(width: 44, height: 44)

                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
            }
            .frame(width: 70, height: 64)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled && !isLoading ? 0.45 : 1)
    }
}

private struct SlideActionControl: View {
    var title: String
    var completedTitle: String
    var systemImage: String
    var color: Color
    var isLoading: Bool
    var isDisabled: Bool
    var onCommit: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isCommitted = false
    @State private var isDragging = false

    private let height: CGFloat = 64
    private let thumbSize: CGFloat = 52

    var body: some View {
        GeometryReader { proxy in
            let maxOffset = max(proxy.size.width - thumbSize - 10, 0)
            let isBusy = isLoading || isCommitted

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.teslaControlBackground)
                    .overlay {
                        Capsule()
                            .stroke(Color.teslaHairline, lineWidth: 1)
                    }

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.42), color.opacity(0.16)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(thumbSize + dragOffset, thumbSize))
                    .opacity(isDragging || isCommitted ? 1 : 0)

                HStack(spacing: 8) {
                    Spacer(minLength: thumbSize + 8)

                    HStack(spacing: 8) {
                        Text(isBusy ? completedTitle : title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)

                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(color)
                        } else if !isCommitted {
                            HStack(spacing: -2) {
                                Image(systemName: "chevron.right")
                                Image(systemName: "chevron.right")
                            }
                            .font(.caption.weight(.bold))
                            .foregroundStyle(color)
                        }
                    }
                    .offset(x: 10)

                    Spacer(minLength: 12)
                }
                .foregroundStyle(isDisabled && !isLoading ? Color.teslaSecondaryText : Color.teslaPrimaryText)
                .padding(.horizontal, 12)

                ZStack {
                    Circle()
                        .fill(Color.teslaActionThumb)
                        .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 4)
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: systemImage)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: thumbSize, height: thumbSize)
                .padding(5)
                .offset(x: dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            guard !isDisabled, !isCommitted else { return }
                            isDragging = true
                            dragOffset = min(max(value.translation.width, 0), maxOffset)
                        }
                        .onEnded { _ in
                            guard !isDisabled, !isCommitted else { return }
                            if dragOffset >= maxOffset * 0.72 {
                                isCommitted = true
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                    dragOffset = maxOffset
                                }
                                onCommit()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                        dragOffset = 0
                                        isCommitted = false
                                        isDragging = false
                                    }
                                }
                            } else {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                    dragOffset = 0
                                    isDragging = false
                                }
                            }
                        }
                )
            }
        }
        .frame(height: height)
        .opacity(isDisabled && !isLoading ? 0.55 : 1)
        .accessibilityLabel(title)
    }
}

private struct VehicleBasicsPanel: View {
    var snapshot: NinebotVehicleSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.teslaControlBackground)
                Image(systemName: "info.circle.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text("查看信息")
                    .font(.headline)
                    .foregroundStyle(Color.teslaPrimaryText)
                Text("\(snapshot.vehicle.model) · 更新 \(formatTime(snapshot.state.updatedAt))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.teslaSecondaryText)
        }
        .padding(18)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

private struct BasicInfoTile: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.teslaSecondaryText)
                .frame(width: 22, height: 22, alignment: .leading)

            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.teslaPrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.teslaSecondaryText)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct VehicleDetailPanel: View {
    var snapshot: NinebotVehicleSnapshot
    var resolvedAddress: String?
    var isLoading: Bool
    var onRingBell: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("详细信息")
                .font(.headline)

            DetailSection(title: "车况") {
                DetailRow(title: "健康状态", value: snapshot.state.health.title, systemImage: snapshot.state.health.systemImage)
                DetailRow(title: "状态说明", value: snapshot.state.health.message, systemImage: "text.bubble.fill")
                DetailRow(title: "电量", value: snapshot.state.batteryText, systemImage: "battery.100")
                DetailRow(title: "电池电压", value: snapshot.state.batteryVoltageText, systemImage: "bolt.batteryblock.fill")
                DetailRow(title: "电池温度", value: snapshot.state.batteryTemperatureText, systemImage: "thermometer.medium")
                DetailRow(title: "循环次数", value: snapshot.state.batteryCycleCountText, systemImage: "arrow.trianglehead.2.clockwise")
                DetailRow(title: "充电功率", value: snapshot.state.chargingPowerText, systemImage: "bolt.fill")
                DetailRow(title: "预估续航", value: snapshot.state.enduranceText, systemImage: "road.lanes")
                DetailRow(title: "AI 预估", value: snapshot.state.aiEstimatedMileageText, systemImage: "sparkles")
                DetailRow(title: "本地预估", value: snapshot.state.localEstimatedMileageText, systemImage: "function")
                DetailRow(title: "本地模型", value: snapshot.state.rangeModelSummaryText, systemImage: "target")
                DetailRow(title: "续航可信", value: snapshot.state.rangePerBatteryPercentText, systemImage: "speedometer")
                DetailRow(title: "充电状态", value: snapshot.state.chargingStateText, systemImage: "bolt.fill")
                DetailRow(title: "充电速度", value: snapshot.state.estimatedChargingSpeedText, systemImage: "bolt.car.fill")
                DetailRow(title: "充至 80%", value: snapshot.state.estimatedChargeTo80TimeText, systemImage: "battery.75")
                DetailRow(title: "80% 时间", value: snapshot.state.estimatedChargeTo80ClockText, systemImage: "clock.badge.checkmark")
                DetailRow(title: "预计充满", value: snapshot.state.estimatedFullChargeTimeText, systemImage: "timer")
                DetailRow(title: "满电时间", value: snapshot.state.estimatedFullChargeClockText, systemImage: "clock.badge.checkmark.fill")
                DetailRow(title: "接口剩余", value: snapshot.state.remainingChargeTimeText, systemImage: "clock.badge.questionmark")
                DetailRow(title: "电源状态", value: snapshot.state.powerText, systemImage: "power")
                DetailRow(title: "锁车状态", value: snapshot.state.lockText, systemImage: snapshot.state.isLocked == true ? "lock.fill" : "lock.open.fill")
                DetailRow(title: "更新时间", value: formatDate(snapshot.state.updatedAt), systemImage: "clock")
            }

            DetailSection(title: "定位") {
                if let coordinate = vehicleCoordinate(snapshot.state) {
                    NavigationLink {
                        NinebotVehicleMapView(
                            snapshot: snapshot,
                            address: locationText,
                            coordinate: coordinate,
                            isLoading: isLoading,
                            onRingBell: onRingBell
                        )
                    } label: {
                        DetailRow(title: "位置", value: locationText, systemImage: "map")
                    }
                    .buttonStyle(.plain)
                } else {
                    DetailRow(title: "位置", value: locationText, systemImage: "map")
                }
                if hasResolvedAddress {
                    DetailRow(title: "地址来源", value: "Apple 地图解析", systemImage: "map.fill")
                }
                DetailRow(title: "纬度", value: formatCoordinate(snapshot.state.latitude), systemImage: "map")
                DetailRow(title: "经度", value: formatCoordinate(snapshot.state.longitude), systemImage: "map.fill")
                DetailRow(title: "坐标", value: coordinateText(snapshot.state.latitude, snapshot.state.longitude), systemImage: "location.fill")
            }

            DetailSection(title: "车辆资料") {
                DetailRow(title: "名称", value: snapshot.vehicle.displayName, systemImage: "tag.fill")
                DetailRow(title: "车型", value: snapshot.vehicle.model, systemImage: "bolt.car.fill")
                DetailRow(title: "图片", value: snapshot.vehicle.imageURLString ?? "--", systemImage: "photo")
            }

            RawFieldSection(title: "车辆原始字段", fields: snapshot.vehicle.raw)
            RawFieldSection(title: "状态原始字段", fields: snapshot.state.rawStatus)
            RawFieldSection(title: "电池原始字段", fields: snapshot.state.rawBattery)
            RawFieldSection(title: "行程原始字段", fields: snapshot.state.rawTravel)
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var locationText: String {
        guard let resolvedAddress = normalizedResolvedAddress else {
            return snapshot.state.locationText
        }
        return resolvedAddress
    }

    private var hasResolvedAddress: Bool {
        normalizedResolvedAddress != nil
    }

    private var normalizedResolvedAddress: String? {
        guard let value = resolvedAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct DetailSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                content
            }
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

private struct DetailRow: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)

            Text(value.isEmpty ? "--" : value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct RideListSection: View {
    @ObservedObject var model: NinebotViewModel
    var records: [NinebotRideRecord]
    var vehicleSN: String?
    var selectedMonth: String
    @State private var visibleLimit = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("行程列表")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text("点击行程查看接口详情与官方轨迹")
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer()

                Text("\(records.count)")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.teslaSecondaryText)
            }

            if records.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(tripMonthDisplayName(selectedMonth)) 暂无行程")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text("可以切换已有月份，或继续向前获取服务器归档。")
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.teslaCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.teslaHairline, lineWidth: 1)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(records.prefix(visibleLimit).enumerated()), id: \.element.id) { index, record in
                        NavigationLink {
                            NinebotRideDetailView(model: model, vehicleSN: vehicleSN, record: record)
                        } label: {
                            RideRecordRow(record: record, index: index)
                        }
                        .buttonStyle(.plain)
                    }

                    if records.count > visibleLimit {
                        Button("显示更多") {
                            visibleLimit += 30
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

private struct RideRecordRow: View {
    var record: NinebotRideRecord
    var index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.teslaGreen.opacity(0.14))
                    Image(systemName: "road.lanes")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.teslaGreen)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(record.startedAt.map(formatRideDate) ?? "行程 \(index + 1)")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.teslaPrimaryText)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(record.endedAt.map { "结束 \($0.formatted(.dateTime.hour().minute()))" } ?? "结束时间未知")
                        Text("·")
                        Text(formatDuration(record.durationMinutes))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(formatDistance(record.mileage))
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle(Color.teslaPrimaryText)
                        .lineLimit(1)
                }
            }

            if !metrics.isEmpty {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 8
                ) {
                    ForEach(metrics) { metric in
                        RideMetric(title: metric.title, value: metric.value, systemImage: metric.systemImage)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.teslaCardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 12, x: 0, y: 6)
    }

    private var metrics: [RideDisplayMetric] {
        [
            record.consumedEnergyWh.map { RideDisplayMetric(title: "本次用电", value: formatEnergyWh($0), systemImage: "bolt.fill") },
            record.energyPerKmWh.map { RideDisplayMetric(title: "能耗", value: formatEnergyPerKm($0), systemImage: "leaf.fill") },
            record.maximumSpeed.map { RideDisplayMetric(title: "最高速度", value: formatSpeed($0), systemImage: "gauge.with.dots.needle.67percent") },
            record.resolvedDurationMinutes.map { RideDisplayMetric(title: "骑行时间", value: formatDuration($0), systemImage: "timer") }
        ].compactMap { $0 }
    }
}

private struct RideDisplayMetric: Identifiable {
    var title: String
    var value: String
    var systemImage: String

    var id: String {
        "\(title)-\(value)-\(systemImage)"
    }
}

private struct NinebotRideDetailView: View {
    @ObservedObject var model: NinebotViewModel
    var vehicleSN: String?
    var record: NinebotRideRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RideDetailHero(record: effectiveRecord)

                if !interfaceTrackPoints.isEmpty {
                    InterfaceRideTrackMapPanel(points: interfaceTrackPoints)
                } else if remoteDetail != nil {
                    RideTrackUnavailableNotice()
                } else if isLoadingRemoteDetail {
                    RideDetailLoadingNotice()
                }

                DetailSection(title: "接口行程") {
                    DetailRow(title: "开始时间", value: effectiveRecord.startedAt.map(formatDate) ?? "--", systemImage: "play.fill")
                    DetailRow(title: "结束时间", value: effectiveRecord.endedAt.map(formatDate) ?? "--", systemImage: "stop.fill")
                    DetailRow(title: "里程", value: formatDistance(effectiveRecord.mileage), systemImage: "road.lanes")
                    DetailRow(title: "骑行时间", value: formatDuration(effectiveRecord.resolvedDurationMinutes), systemImage: "timer")
                    DetailRow(title: "最高速度", value: formatSpeed(effectiveRecord.maximumSpeed), systemImage: "gauge.with.dots.needle.67percent")
                    DetailRow(title: "本次用电", value: formatEnergyWh(effectiveRecord.consumedEnergyWh), systemImage: "bolt.fill")
                    DetailRow(title: "能耗", value: formatEnergyPerKm(effectiveRecord.energyPerKmWh), systemImage: "leaf.fill")
                    DetailRow(title: "行程 ID", value: record.id, systemImage: "number")
                }

                if let remoteDetail {
                    DetailSection(title: "加载诊断") {
                        DetailRow(title: "接口响应", value: formatElapsedTime(remoteDetail.responseDuration), systemImage: "network")
                        DetailRow(title: "路线准备", value: formatElapsedTime(remoteDetail.trackPreparationDuration), systemImage: "cpu")
                    }
                }

                RawJSONSection(title: "行程详情完整返回值", value: remoteDetail?.raw)
                RawFieldSection(title: "列表原始字段", fields: record.raw)
            }
            .padding(16)
        }
        .background(Color.teslaPageBackground.ignoresSafeArea())
        .navigationTitle("行程详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(vehicleSN ?? "")|\(record.id)") {
            await loadRemoteDetailIfNeeded()
        }
    }

    private var canLoadRemoteDetail: Bool {
        vehicleSN?.isEmpty == false && !record.id.isEmpty
    }

    private var remoteDetail: NinebotRideDetail? {
        guard let vehicleSN else { return nil }
        return model.rideDetail(vehicleSN: vehicleSN, rideID: record.id)
    }

    private var effectiveRecord: NinebotRideRecord {
        remoteDetail?.parsedRecord ?? record
    }

    private var interfaceTrackPoints: [NinebotInterfaceTrackPoint] {
        remoteDetail?.interfaceTrackPoints ?? []
    }

    private var isLoadingRemoteDetail: Bool {
        guard let vehicleSN else { return false }
        return model.isLoadingRideDetail(vehicleSN: vehicleSN, rideID: record.id)
    }

    private func loadRemoteDetailIfNeeded() async {
        guard let vehicleSN, canLoadRemoteDetail else { return }
        await model.refreshRideDetail(vehicleSN: vehicleSN, rideID: record.id)
    }
}

private struct RideDetailLoadingNotice: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.teslaGreen)
            VStack(alignment: .leading, spacing: 3) {
                Text("正在读取行程详情")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                Text("正在等待行程服务返回路线；长路线会在返回后一次性完成本地解析。")
                    .font(.caption)
                    .foregroundStyle(Color.teslaSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
    }
}

private struct RideTrackUnavailableNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "map.slash")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.teslaSecondaryText)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text("官方行程未返回轨迹")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                Text("本应用不会记录或保存本机 GPS 轨迹。只有接口详情返回路线点时，才会显示官方轨迹、起点和终点。")
                    .font(.caption)
                    .foregroundStyle(Color.teslaSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
    }
}

private struct RideDetailHero: View {
    var record: NinebotRideRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.startedAt.map(formatRideDate) ?? "行程详情")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text(record.endedAt.map { "结束 \($0.formatted(.dateTime.hour().minute()))" } ?? "结束时间未知")
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }
                Spacer()
                Image(systemName: "road.lanes")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.teslaGreen)
            }

            Text(formatDistance(record.mileage))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.teslaPrimaryText)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                RideMetric(title: "骑行时间", value: formatDuration(record.resolvedDurationMinutes), systemImage: "timer")
                RideMetric(title: "最高速度", value: formatSpeed(record.maximumSpeed), systemImage: "speedometer")
                RideMetric(title: "本次用电", value: formatEnergyWh(record.consumedEnergyWh), systemImage: "bolt.fill")
                RideMetric(title: "能耗", value: formatEnergyPerKm(record.energyPerKmWh), systemImage: "leaf.fill")
            }
        }
        .padding(18)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.teslaHairline, lineWidth: 1)
        }
    }
}

private struct InterfaceRideTrackMapPanel: View {
    /// The map is a static rendering of the official trip-detail route. A
    /// bounded, deterministic sample keeps MapKit responsive for long routes
    /// while preserving the official start, end, and speed variation.
    var points: [NinebotInterfaceTrackPoint]
    var sourcePointCount: Int
    @State private var cameraPosition: MapCameraPosition

    init(points: [NinebotInterfaceTrackPoint]) {
        self.sourcePointCount = points.count
        self.points = Self.sampledForMap(points)
        _cameraPosition = State(initialValue: MapCameraPosition.region(Self.region(for: self.points.map(\.coordinate))))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("官方接口轨迹")
                        .font(.headline)
                        .foregroundStyle(Color.teslaPrimaryText)
                    Text(routePointSummary)
                        .font(.caption)
                        .foregroundStyle(Color.teslaSecondaryText)
                }

                Spacer(minLength: 12)

                Label("速度着色", systemImage: "paintpalette.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.teslaGreen)
            }

            Map(position: $cameraPosition) {
                // Render each official route segment independently so its
                // color describes that part of the journey: green is slower,
                // yellow is medium, and red is faster.
                ForEach(routeSegments) { segment in
                    MapPolyline(coordinates: segment.coordinates)
                        .stroke(
                            speedColor(for: segment.speedKmh),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                        )
                }

                if let start = coordinates.first {
                    Marker("起点", systemImage: "flag.fill", coordinate: start)
                        .tint(.green)
                }
                if coordinates.count > 1, let end = coordinates.last {
                    Marker("终点", systemImage: "mappin.and.ellipse", coordinate: end)
                        .tint(.red)
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(spacing: 8) {
                Image(systemName: "flag.checkered")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.teslaSecondaryText)
                Text(speedColorDescription)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                Spacer(minLength: 8)
                SpeedRouteLegend(hasSpeedData: !validSpeeds.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.teslaControlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: 8)
    }

    private var routePointSummary: String {
        if sourcePointCount == points.count {
            return "起点 → 终点 · 官方接口返回 \(points.count) 个路线点"
        }
        return "起点 → 终点 · 官方接口返回 \(sourcePointCount) 个路线点（地图显示 \(points.count) 个）"
    }

    private var coordinates: [CLLocationCoordinate2D] { points.map(\.coordinate) }

    private var speedColorDescription: String {
        validSpeeds.isEmpty
            ? "轨迹未返回可用速度，路线显示为灰色"
            : "路线按速度由慢到快着色"
    }

    private var routeSegments: [RideTrackSpeedSegment] {
        guard points.count > 1 else { return [] }
        return (0..<(points.count - 1)).map { index in
            let start = points[index]
            let end = points[index + 1]
            let speeds = [start.speedKmh, end.speedKmh].compactMap { speed -> Double? in
                guard let speed, speed.isFinite, speed >= 0 else { return nil }
                return speed
            }
            return RideTrackSpeedSegment(
                index: index,
                coordinates: [start.coordinate, end.coordinate],
                speedKmh: speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)
            )
        }
    }

    private var validSpeeds: [Double] {
        routeSegments.compactMap { segment in
            guard let speed = segment.speedKmh, speed.isFinite, speed >= 0 else { return nil }
            return speed
        }
    }

    private func speedColor(for speed: Double?) -> Color {
        guard let speed, speed.isFinite, speed >= 0 else {
            return Color.teslaSecondaryText.opacity(0.45)
        }
        let progress = normalizedSpeedProgress(for: speed)
        // Hue 0.333 is green, 0.167 is yellow and 0 is red.
        return Color(hue: 0.333 * (1 - progress), saturation: 0.88, brightness: 0.9)
    }

    private func normalizedSpeedProgress(for speed: Double) -> Double {
        guard let minimum = validSpeeds.min(), let maximum = validSpeeds.max() else { return 0 }
        let range = maximum - minimum
        if range > 0.1 {
            return min(max((speed - minimum) / range, 0), 1)
        }
        // If each official point has the same speed, keep a useful color
        // instead of always describing the entire route as slow.
        return min(max(speed / 45, 0), 1)
    }

    private static func sampledForMap(
        _ source: [NinebotInterfaceTrackPoint],
        maximumPointCount: Int = 480
    ) -> [NinebotInterfaceTrackPoint] {
        guard source.count > maximumPointCount, maximumPointCount >= 2 else { return source }

        let lastIndex = source.count - 1
        let interval = Double(lastIndex) / Double(maximumPointCount - 1)
        var sampled: [NinebotInterfaceTrackPoint] = []
        sampled.reserveCapacity(maximumPointCount)
        var previousIndex = -1

        for sampleIndex in 0..<maximumPointCount {
            let index = min(Int((Double(sampleIndex) * interval).rounded()), lastIndex)
            guard index != previousIndex else { continue }
            sampled.append(source[index])
            previousIndex = index
        }

        if sampled.last?.id != source.last?.id, let last = source.last {
            sampled.append(last)
        }
        return recomputingDisplaySpeeds(in: sampled)
    }

    /// Sampling can skip raw official points. Recalculate each retained
    /// segment from its own timestamp interval so its displayed color remains
    /// tied to the segment shown on the map.
    private static func recomputingDisplaySpeeds(in source: [NinebotInterfaceTrackPoint]) -> [NinebotInterfaceTrackPoint] {
        guard source.count > 1 else { return source }

        var points = source
        for index in points.indices {
            let segmentIndex = index == 0 ? 0 : index - 1
            guard segmentIndex < source.count - 1,
                  let startElapsed = source[segmentIndex].elapsedSeconds,
                  let endElapsed = source[segmentIndex + 1].elapsedSeconds else {
                // Some official response shapes provide a named speed but no
                // timestamps; retain that explicit value.
                continue
            }

            let elapsed = endElapsed - startElapsed
            let start = source[segmentIndex]
            let end = source[segmentIndex + 1]
            let distanceMeters = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            let speedKmh = elapsed > 0 && elapsed <= 15 * 60 ? distanceMeters / elapsed * 3.6 : .nan
            points[index].speedKmh = speedKmh.isFinite && speedKmh >= 0 && speedKmh <= 120 ? speedKmh : nil
        }
        return points
    }

    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737), span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03))
        }
        let minLatitude = coordinates.map(\.latitude).min() ?? coordinates[0].latitude
        let maxLatitude = coordinates.map(\.latitude).max() ?? coordinates[0].latitude
        let minLongitude = coordinates.map(\.longitude).min() ?? coordinates[0].longitude
        let maxLongitude = coordinates.map(\.longitude).max() ?? coordinates[0].longitude
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLatitude - minLatitude) * 1.5, 0.006), longitudeDelta: max((maxLongitude - minLongitude) * 1.5, 0.006))
        )
    }
}

private struct RideTrackSpeedSegment: Identifiable {
    var index: Int
    var coordinates: [CLLocationCoordinate2D]
    var speedKmh: Double?

    var id: Int { index }
}

private struct SpeedRouteLegend: View {
    var hasSpeedData: Bool

    var body: some View {
        Group {
            if hasSpeedData {
                HStack(spacing: 4) {
                    Text("慢")
                        .foregroundStyle(Color.teslaSecondaryText)
                    LinearGradient(
                        colors: [.green, .yellow, .red],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 52, height: 5)
                    .clipShape(Capsule())
                    Text("快")
                        .foregroundStyle(Color.teslaSecondaryText)
                }
            } else {
                Text("无可用速度")
                    .foregroundStyle(Color.teslaSecondaryText)
            }
        }
        .font(.caption2.weight(.medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasSpeedData ? "路线按速度从慢到快着色：绿色表示慢，红色表示快" : "官方轨迹未返回可用速度，路线不按速度着色")
    }
}


private struct RideMetric: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.teslaSecondaryText)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.teslaPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.teslaSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.teslaControlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RawFieldSection: View {
    var title: String
    var fields: [String: JSONValue]?
    @State private var didCopy = false

    var body: some View {
        DisclosureGroup {
            if let fields, !fields.isEmpty {
                let rows = fields.sorted { lhs, rhs in
                    lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                }

                VStack(spacing: 0) {
                    ForEach(rows, id: \.key) { key, value in
                        RawFieldRow(key: key, value: value.displayText)
                    }
                }
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                Text("暂无数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if didCopy {
                    Label("已复制", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.teslaGreen)
                } else if let copyText {
                    Button {
                        copyRawText(copyText)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var copyText: String? {
        guard let fields, !fields.isEmpty else { return nil }
        return formattedJSON(.object(fields))
    }

    private func copyRawText(_ text: String) {
        UIPasteboard.general.string = text
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            didCopy = false
        }
    }
}

private struct RawJSONSection: View {
    var title: String
    var value: JSONValue?
    @State private var didCopy = false

    var body: some View {
        DisclosureGroup {
            if let value {
                if let object = value.objectValue, !object.isEmpty {
                    let rows = object.sorted { lhs, rhs in
                        lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
                    }

                    VStack(spacing: 0) {
                        ForEach(rows, id: \.key) { key, value in
                            RawFieldRow(key: key, value: value.displayText)
                        }
                    }
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Text(value.displayText)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Color.teslaPrimaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(.tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .textSelection(.enabled)
                }
            } else {
                Text("详情返回后会显示完整字段")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if didCopy {
                    Label("已复制", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.teslaGreen)
                } else if let copyText {
                    Button {
                        copyRawText(copyText)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var copyText: String? {
        guard let value else { return nil }
        return formattedJSON(value)
    }

    private func copyRawText(_ text: String) {
        UIPasteboard.general.string = text
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            didCopy = false
        }
    }
}

private struct RawFieldRow: View {
    var key: String
    var value: String

    var body: some View {
        let displayName = friendlyRawFieldName(key)

        VStack(alignment: .leading, spacing: 5) {
            Text(displayName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)

            if displayName != key {
                Text(key)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Text(value.isEmpty ? "--" : value)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

private struct RawPayloadCopyPanel: View {
    var snapshot: NinebotVehicleSnapshot
    @Binding var copiedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.teslaGreen)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("原始返回值")
                        .font(.headline)
                    Text("复制车辆、状态、行程接口的完整 JSON，方便排查新字段。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }

            Button {
                UIPasteboard.general.string = fullPayloadText
                copiedMessage = "已复制完整返回值"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    copiedMessage = nil
                }
            } label: {
                Label("复制完整返回值", systemImage: "doc.on.doc.fill")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var fullPayloadText: String {
        formattedJSON(
            .object([
                "vehicle": .object(snapshot.vehicle.raw ?? [:]),
                "status": .object(snapshot.state.rawStatus ?? [:]),
                "travel": .object(snapshot.state.rawTravel ?? [:])
            ])
        )
    }
}

extension Color {
    static let teslaPageBackground = dynamic(
        light: UIColor(red: 0.945, green: 0.952, blue: 0.96, alpha: 1),
        dark: UIColor(red: 0.025, green: 0.029, blue: 0.035, alpha: 1)
    )
    static let teslaCardBackground = dynamic(
        light: UIColor(red: 0.995, green: 0.995, blue: 1.0, alpha: 1),
        dark: UIColor(red: 0.075, green: 0.08, blue: 0.092, alpha: 1)
    )
    static let teslaControlBackground = dynamic(
        light: UIColor(red: 0.91, green: 0.925, blue: 0.94, alpha: 1),
        dark: UIColor(red: 0.125, green: 0.135, blue: 0.152, alpha: 1)
    )
    static let teslaPrimaryText = dynamic(
        light: UIColor(red: 0.055, green: 0.065, blue: 0.08, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.95, blue: 0.965, alpha: 1)
    )
    static let teslaSecondaryText = dynamic(
        light: UIColor(red: 0.42, green: 0.45, blue: 0.49, alpha: 1),
        dark: UIColor(red: 0.62, green: 0.65, blue: 0.69, alpha: 1)
    )
    static let teslaGreen = dynamic(
        light: UIColor(red: 0.13, green: 0.82, blue: 0.28, alpha: 1),
        dark: UIColor(red: 0.20, green: 0.93, blue: 0.38, alpha: 1)
    )
    static let teslaActionThumb = dynamic(
        light: UIColor(red: 0.055, green: 0.065, blue: 0.08, alpha: 1),
        dark: UIColor(red: 0.13, green: 0.82, blue: 0.28, alpha: 1)
    )
    static let teslaHairline = dynamic(
        light: UIColor(red: 0, green: 0, blue: 0, alpha: 0.06),
        dark: UIColor(red: 1, green: 1, blue: 1, alpha: 0.10)
    )

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

struct NinePlusCardStyle: ViewModifier {
    var cornerRadius: CGFloat = 24
    var padding: CGFloat? = nil
    var shadowOpacity: Double = 0.05

    func body(content: Content) -> some View {
        let card = content
            .background(Color.teslaCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.teslaHairline, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(shadowOpacity), radius: 14, x: 0, y: 8)

        if let padding {
            card.padding(padding)
        } else {
            card
        }
    }
}

extension View {
    func ninePlusCard(
        cornerRadius: CGFloat = 24,
        padding: CGFloat? = nil,
        shadowOpacity: Double = 0.05
    ) -> some View {
        modifier(NinePlusCardStyle(cornerRadius: cornerRadius, padding: padding, shadowOpacity: shadowOpacity))
    }
}

private struct VehicleRow: View {
    var snapshot: NinebotVehicleSnapshot
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VehicleImage(urlString: snapshot.vehicle.imageURLString, size: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.vehicle.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(snapshot.state.enduranceText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(snapshot.state.batteryText)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(batteryTextColor(snapshot.state))
                    Text(snapshot.state.primaryStatusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor(snapshot.state))
                        .lineLimit(1)
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.teslaGreen : Color(.tertiaryLabel))
            }
            .padding(12)
            .background(Color.teslaCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func vehicleCoordinate(_ state: NinebotVehicleState) -> CLLocationCoordinate2D? {
    guard let latitude = state.latitude,
          let longitude = state.longitude,
          (-90...90).contains(latitude),
          (-180...180).contains(longitude) else {
        return nil
    }

    return mapKitCoordinate(latitude: latitude, longitude: longitude)
}

private func mapKitCoordinate(latitude: Double, longitude: Double) -> CLLocationCoordinate2D {
    NinebotCoordinateTransform.mapKitCoordinate(latitude: latitude, longitude: longitude)
}

private func formatDistance(_ value: Double?) -> String {
    formatNumber(value, unit: " km", maximumFractionDigits: 1)
}

private func formatDistanceNumber(_ value: Double?) -> String {
    formatNumber(value, unit: "", maximumFractionDigits: 1)
}

private func formatEnergyWh(_ value: Double?) -> String {
    formatNumber(value, unit: " Wh", maximumFractionDigits: 0)
}

private func formatEnergyPerKm(_ value: Double?) -> String {
    formatNumber(value, unit: " Wh/km", maximumFractionDigits: 1)
}

private func formatPercent(_ value: Double?) -> String {
    formatNumber(value, unit: "%", maximumFractionDigits: 1)
}

private func formatSpeed(_ value: Double?) -> String {
    formatNumber(value, unit: " km/h", maximumFractionDigits: 1)
}

private func formatElapsedTime(_ value: TimeInterval?) -> String {
    guard let value, value.isFinite, value >= 0 else { return "--" }
    if value < 1 {
        return String(format: "%.0f ms", value * 1_000)
    }
    return String(format: "%.2f 秒", value)
}

private func formatAccelerationG(_ value: Double?) -> String {
    formatNumber(value, unit: " G", maximumFractionDigits: 2, minimumFractionDigits: 2)
}

private func shortTrendValue(_ value: Double) -> String {
    if value >= 100 {
        return formatNumber(value, unit: "", maximumFractionDigits: 0)
    }
    if value >= 10 {
        return formatNumber(value, unit: "", maximumFractionDigits: 1)
    }
    return formatNumber(value, unit: "", maximumFractionDigits: 1)
}

private func formatDuration(_ minutes: Double?) -> String {
    guard let minutes else { return "--" }
    if minutes >= 60 {
        return formatNumber(minutes / 60, unit: " 小时", maximumFractionDigits: 1)
    }
    return formatNumber(minutes, unit: " 分钟", maximumFractionDigits: 0)
}

private func formatRideDate(_ date: Date) -> String {
    formatDate(date)
}

private func formattedJSON(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
          let text = String(data: data, encoding: .utf8) else {
        return value.displayText
    }
    return text
}

private func formatNumber(
    _ value: Double?,
    unit: String,
    maximumFractionDigits: Int = 6,
    minimumFractionDigits: Int = 0
) -> String {
    guard let value else { return "--\(unit)" }
    let formatter = NumberFormatter()
    formatter.maximumFractionDigits = maximumFractionDigits
    formatter.minimumFractionDigits = minimumFractionDigits
    let text = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    return "\(text)\(unit)"
}

private func boolText(_ value: Bool?, trueText: String, falseText: String) -> String {
    guard let value else { return "未知" }
    return value ? trueText : falseText
}

private func coordinateText(_ latitude: Double?, _ longitude: Double?) -> String {
    guard let latitude, let longitude else { return "--" }
    return "\(formatCoordinate(latitude)), \(formatCoordinate(longitude))"
}

private func formatCoordinate(_ value: Double?) -> String {
    formatNumber(value, unit: "", maximumFractionDigits: 8)
}

private func healthColor(_ level: NinebotVehicleHealthLevel) -> Color {
    switch level {
    case .good:
        return Color.teslaGreen
    case .attention:
        return .orange
    case .critical:
        return .red
    case .charging:
        return Color.teslaGreen
    case .unknown:
        return .secondary
    }
}

private func statusColor(_ state: NinebotVehicleState) -> Color {
    healthColor(state.health.level)
}

private func statusSystemImage(_ state: NinebotVehicleState) -> String {
    state.health.systemImage
}

private func compactVehicleStatusText(_ state: NinebotVehicleState) -> String {
    if state.isFullyCharged {
        return "已充满"
    }
    if state.isCharging == true {
        return "充电中"
    }
    if state.isPoweredOn == true {
        return "已上电"
    }
    if state.isLocked == true {
        return "已上锁"
    }
    if state.isLocked == false {
        return "未上锁"
    }
    return state.primaryStatusText
}

private func batteryTextColor(_ state: NinebotVehicleState) -> Color {
    if state.isFullyCharged { return Color.teslaGreen }
    if state.isCharging == true { return Color.teslaGreen }
    guard let battery = state.battery else { return .primary }
    if battery < 15 { return .red }
    if battery < 50 { return .orange }
    return .primary
}

private func friendlyRawFieldName(_ key: String) -> String {
    let names: [String: String] = [
        "ai_estimate_mileage": "AI 预估续航",
        "aiEstimateMileage": "AI 预估续航",
        "ai_estimated_mileage": "AI 预估续航",
        "aiEstimatedMileage": "AI 预估续航",
        "and_mac": "Android MAC",
        "battery": "电量",
        "battery_exist": "电池存在",
        "battery_list": "电池列表",
        "batteryList": "电池列表",
        "battery_main": "主电池",
        "batteryMain": "主电池",
        "battery_voltage": "电池电压",
        "batteryVoltage": "电池电压",
        "battery_vol": "电池电压",
        "batteryVol": "电池电压",
        "battery_temperature": "电池温度",
        "batteryTemperature": "电池温度",
        "battery_temp": "电池温度",
        "batteryTemp": "电池温度",
        "barrel_lock_status": "座桶锁状态",
        "ble_name": "蓝牙名称",
        "bat_voltage": "电池电压",
        "batVoltage": "电池电压",
        "bat_temperature": "电池温度",
        "batTemperature": "电池温度",
        "bat_temp": "电池温度",
        "batTemp": "电池温度",
        "batt_voltage": "电池电压",
        "battVoltage": "电池电压",
        "batt_temperature": "电池温度",
        "battTemperature": "电池温度",
        "batt_temp": "电池温度",
        "battTemp": "电池温度",
        "bms": "电池管理",
        "bms_cycle": "循环次数",
        "bmsCycle": "循环次数",
        "bmsInfo": "电池管理",
        "bms_info": "电池管理",
        "bms_volt": "电池电压",
        "bmsVolt": "电池电压",
        "bms_voltage": "电池电压",
        "bmsVoltage": "电池电压",
        "bms_temperature": "电池温度",
        "bmsTemperature": "电池温度",
        "bms_temp": "电池温度",
        "bmsTemp": "电池温度",
        "buck": "座桶",
        "business_uid": "业务用户 ID",
        "businessUID": "业务用户 ID",
        "begin_time": "开始时间",
        "beginTime": "开始时间",
        "charging": "充电状态",
        "charging_power": "充电功率",
        "chargingPower": "充电功率",
        "chargingState": "充电状态",
        "charging_protection": "充电保护",
        "color": "颜色",
        "cost_time": "用时",
        "costTime": "用时",
        "create_time": "创建时间",
        "createTime": "创建时间",
        "device_name": "设备名称",
        "distance": "里程",
        "day_total_mileage": "当日总里程",
        "detail": "每日里程",
        "dump_energy": "剩余电量",
        "dumpEnergy": "剩余电量",
        "duration": "时长",
        "ec": "能耗",
        "end_time": "结束时间",
        "endTime": "结束时间",
        "estimateMileage": "预估续航",
        "estimate_mileage": "预估续航",
        "id": "ID",
        "image": "车辆图片",
        "last_ec": "最近能耗",
        "last_mileages": "最近里程",
        "last_used_electricity": "最近用电",
        "lat": "纬度",
        "latitude": "纬度",
        "left_mileage_user_choose": "剩余里程选择",
        "list": "行程列表",
        "loc": "定位信息",
        "locationDesc": "位置描述",
        "locationInfo": "定位信息",
        "lock": "锁车状态",
        "lon": "经度",
        "longitude": "经度",
        "mileages": "里程",
        "mileage": "里程",
        "month": "月份",
        "model": "车型",
        "name": "名称",
        "pwr": "电源状态",
        "powerStatus": "电源状态",
        "precise_estimate_mileage": "精确预估续航",
        "precise_mileage_user_choose": "精确里程选择",
        "remainChargeTime": "剩余充电时间",
        "remain_charge_time": "剩余充电时间",
        "remain_charge_timestamp": "剩余充电时间戳",
        "remainingChargeTime": "剩余充电时间",
        "speed": "速度",
        "sn": "SN",
        "total_mileage": "总里程",
        "totalMileage": "总里程",
        "total_mileages": "本月里程",
        "times": "骑行次数",
        "track": "接口轨迹",
        "trail": "接口轨迹",
        "trial": "接口轨迹",
        "travel_id": "行程 ID",
        "used_electricity": "已用电量",
        "vehicle_name": "车辆名称",
        "vehicle_vin": "VIN",
        "vehicleVin": "VIN",
        "vin": "VIN",
        "VIN": "VIN",
        "volt": "电压",
        "voltage": "电压",
        "temp": "温度",
        "temperature": "温度",
        "wnumber": "车辆编号"
    ]
    return names[key] ?? key
}

private struct EmptyDashboardView: View {
    var hasConfiguration: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: hasConfiguration ? "antenna.radiowaves.left.and.right.slash" : "link.badge.plus")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(hasConfiguration ? "暂无车辆数据" : "未配置代理")
                .font(.headline)

            Text(hasConfiguration ? "刷新后会显示九号车辆状态" : "到“我的”填写代理地址并登录后即可读取车辆")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
        .padding(.horizontal, 20)
        .background(Color.teslaCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct VehicleImage: View {
    var urlString: String?
    var size: CGFloat
    var showsBackground = true

    var body: some View {
        ZStack {
            if showsBackground {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.tertiarySystemGroupedBackground))
            }

            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                    case .failure:
                        fallbackImage
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                    @unknown default:
                        fallbackImage
                    }
                }
            } else {
                fallbackImage
            }
        }
        .frame(width: size, height: size)
    }

    private var fallbackImage: some View {
        Image(systemName: "bolt.car.fill")
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

private struct MetricView: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BatteryGauge: View {
    var value: Int?

    var body: some View {
        Gauge(value: Double(value ?? 0), in: 0...100) {
            Text("电量")
        } currentValueLabel: {
            Text(value.map { "\($0)" } ?? "--")
                .font(.caption.weight(.bold))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(gaugeColor)
    }

    private var gaugeColor: Color {
        guard let value else { return .gray }
        if value < 20 { return .red }
        if value < 50 { return .orange }
        return Color.teslaGreen
    }
}

struct NinebotDashboardView_Previews: PreviewProvider {
    static var previews: some View {
        NinebotDashboardView(model: NinebotViewModel())
    }
}
