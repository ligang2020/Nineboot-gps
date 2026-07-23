import AppIntents
import Foundation
import WidgetKit

struct NinebotWidgetEntry: TimelineEntry {
    var date: Date
    var configuration: NinebotWidgetConfigurationIntent
    var dashboard: NinebotDashboard
    var errorMessage: String?
    var vehicleImages: [String: Data] = [:]
}

/// The App is the primary data owner.  The widget renders its App Group cache
/// immediately after every App refresh, then performs a conservative fallback
/// refresh only when that cache is old.  This prevents the widget and App from
/// showing conflicting vehicle states or repeatedly competing for the API.
struct NinebotTimelineProvider: AppIntentTimelineProvider {
    private let cacheFreshness: TimeInterval = 12 * 60

    func placeholder(in context: Context) -> NinebotWidgetEntry {
        NinebotWidgetEntry(
            date: Date(),
            configuration: NinebotWidgetConfigurationIntent(),
            dashboard: .preview,
            errorMessage: nil
        )
    }

    func snapshot(for configuration: NinebotWidgetConfigurationIntent, in context: Context) async -> NinebotWidgetEntry {
        entry(from: NinebotSharedStore().loadDashboard() ?? .preview, configuration: configuration, errorMessage: nil)
    }

    func timeline(for configuration: NinebotWidgetConfigurationIntent, in context: Context) async -> Timeline<NinebotWidgetEntry> {
        let entry = await loadEntry(configuration: configuration)
        let refreshMinutes = refreshIntervalMinutes(for: entry.dashboard.primaryVehicle?.state)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: refreshMinutes, to: Date())
            ?? Date().addingTimeInterval(TimeInterval(refreshMinutes * 60))
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    private func refreshIntervalMinutes(for state: NinebotVehicleState?) -> Int {
        guard let state else { return 30 }
        if state.isCharging == true, !state.isFullyCharged { return 5 }
        if state.isLocked == false || state.isPoweredOn == true { return 10 }
        if let battery = state.battery, battery < 20 { return 15 }
        return 30
    }

    private func loadEntry(configuration: NinebotWidgetConfigurationIntent) async -> NinebotWidgetEntry {
        let startedAt = Date()
        let store = NinebotSharedStore()
        let cached = store.loadDashboard()

        // Keep the widget visually in lockstep with the App while the shared
        // snapshot is fresh.  The App calls WidgetCenter after every explicit
        // refresh, vehicle switch and vehicle action.
        if let cached, !cached.vehicles.isEmpty, Date().timeIntervalSince(cached.updatedAt) < cacheFreshness {
            return entry(from: cached, configuration: configuration, errorMessage: nil, store: store)
        }

        let proxyConfiguration = store.loadConfiguration() ?? NinebotProxyConfiguration(baseURLString: "", bearerToken: "")
        guard proxyConfiguration.isUsable else {
            let fallback = cached ?? .empty
            store.saveLastWidgetRefreshEvent(NinebotRefreshEvent(
                source: "Widget",
                operation: "读取 App 同步数据",
                startedAt: startedAt,
                endedAt: Date(),
                success: !fallback.vehicles.isEmpty,
                message: fallback.vehicles.isEmpty ? "请先在 App 完成配置并刷新车辆" : "使用 App 最近同步的数据"
            ))
            return entry(
                from: fallback,
                configuration: configuration,
                errorMessage: fallback.vehicles.isEmpty ? "请先在 App 刷新车辆" : nil,
                store: store
            )
        }

        do {
            let client = NinebotProxyClient(configuration: proxyConfiguration)
            let refreshed: NinebotDashboard
            if let cached, !cached.vehicles.isEmpty {
                refreshed = try await client.fetchLiveDashboard(from: cached)
            } else {
                refreshed = try await client.fetchDashboard(selectedSN: cached?.selectedSN)
            }
            let archivedDashboard = store.saveDashboard(refreshed)
            store.saveLastWidgetRefreshEvent(NinebotRefreshEvent(
                source: "Widget",
                operation: "后台补充刷新",
                startedAt: startedAt,
                endedAt: Date(),
                success: true,
                message: archivedDashboard.primaryVehicle?.vehicle.displayName
            ))
            return entry(from: archivedDashboard, configuration: configuration, errorMessage: nil, store: store)
        } catch {
            let fallback = cached ?? .empty
            store.saveLastWidgetRefreshEvent(NinebotRefreshEvent(
                source: "Widget",
                operation: "后台补充刷新",
                startedAt: startedAt,
                endedAt: Date(),
                success: false,
                message: error.localizedDescription
            ))
            // Retain a valid App snapshot rather than replacing a working
            // dashboard with a transient network error.
            return entry(
                from: fallback,
                configuration: configuration,
                errorMessage: fallback.vehicles.isEmpty ? "暂时无法刷新，请稍后重试" : nil,
                store: store
            )
        }
    }

    private func entry(
        from dashboard: NinebotDashboard,
        configuration: NinebotWidgetConfigurationIntent,
        errorMessage: String?,
        store: NinebotSharedStore = NinebotSharedStore()
    ) -> NinebotWidgetEntry {
        let selected = dashboardForWidget(dashboard, configuration: configuration)
        return NinebotWidgetEntry(
            date: Date(),
            configuration: configuration,
            dashboard: selected,
            errorMessage: errorMessage,
            vehicleImages: cachedVehicleImages(for: selected, store: store)
        )
    }

    private func dashboardForWidget(
        _ dashboard: NinebotDashboard,
        configuration: NinebotWidgetConfigurationIntent
    ) -> NinebotDashboard {
        guard let selectedSN = configuration.vehicle?.id,
              let selectedSnapshot = dashboard.vehicles.first(where: { $0.vehicle.sn == selectedSN }) else {
            return dashboard
        }
        return NinebotDashboard(vehicles: [selectedSnapshot], selectedSN: selectedSN, updatedAt: dashboard.updatedAt)
    }

    private func cachedVehicleImages(for dashboard: NinebotDashboard, store: NinebotSharedStore) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: dashboard.vehicles.compactMap { snapshot in
            guard let data = store.loadVehicleImageData(sn: snapshot.vehicle.sn) else {
                return nil
            }
            return (snapshot.vehicle.sn, data)
        })
    }
}
