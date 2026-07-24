//
//  ContentView.swift
//  mini-ninebot
//

import SwiftUI

private enum NinebotRootTab: Hashable {
    case dashboard
    case trips
    case recording
    case security
    case settings
}

struct ContentView: View {
    @StateObject private var model = NinebotViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: NinebotRootTab = .dashboard
    /// 同一轮前台展示只轮换一次动物；切换后台后下一次打开 App 才进入下一组。
    @State private var didRegisterRoadAnimalPresentation = false
    @ObservedObject private var notificationRouter = NinebotNotificationRouter.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                NinebotDashboardView(model: model) {
                    selectedTab = .trips
                }
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.hidden, for: .navigationBar)
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
            .tabItem {
                Label("车控", systemImage: "dot.circle.and.cursorarrow")
            }
            .tag(NinebotRootTab.dashboard)

            NavigationStack {
                NinebotTripsTabView(model: model)
            }
            .tabItem {
                Label("行程", systemImage: "road.lanes")
            }
            .tag(NinebotRootTab.trips)

            NavigationStack {
                NinebotRecordingView(model: model)
            }
            .tabItem {
                Label("记录", systemImage: "gauge.with.dots.needle.67percent")
            }
            .tag(NinebotRootTab.recording)

            NavigationStack {
                NinebotAntiTheftView(model: model)
            }
            .tabItem {
                Label("安全", systemImage: "checkmark.shield")
            }
            .tag(NinebotRootTab.security)

            NavigationStack {
                NinebotSettingsView(model: model)
                    .navigationTitle(model.hasLoginAccount ? "我的" : "")
                    .toolbar(model.hasLoginAccount ? .visible : .hidden, for: .navigationBar)
            }
            .tabItem {
                Label("我的", systemImage: "person.crop.circle")
            }
            .tag(NinebotRootTab.settings)
        }
        .tint(Color(red: 0.13, green: 0.82, blue: 0.28))
        .onChange(of: notificationRouter.routeToken) { _, _ in
            switch notificationRouter.destination {
            case .map, .location, .vehicleStatus:
                selectedTab = .security
            case .charging, .chargingDetail, .vehicle:
                selectedTab = .dashboard
            case nil:
                break
            }
            notificationRouter.consume()
        }
        .task {
            registerRoadAnimalPresentationIfNeeded()
            await model.refreshOnLaunchIfPossible()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else {
                didRegisterRoadAnimalPresentation = false
                return
            }
            registerRoadAnimalPresentationIfNeeded()
            Task { await model.refreshWhenActiveIfPossible() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }

            // SwiftUI cancels this task as soon as the App backgrounds. iOS does
            // not permit a client App to poll every few seconds after background;
            // foreground data therefore stays responsive without draining battery.
            while !Task.isCancelled {
                await model.refreshDashboardSilently()
                do {
                    try await Task.sleep(nanoseconds: UInt64(model.foregroundRefreshInterval * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    /// 车辆场景只在「已停稳」时真正显示动物；此处仅负责按每次打开 App 轮换主题。
    private func registerRoadAnimalPresentationIfNeeded() {
        guard !didRegisterRoadAnimalPresentation else { return }
        didRegisterRoadAnimalPresentation = true
        RoadAnimalEncounterManager.shared.beginNewAppPresentation()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
