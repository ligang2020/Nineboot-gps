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

struct NinebotTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NinebotWidgetEntry {
        NinebotWidgetEntry(
            date: Date(),
            configuration: NinebotWidgetConfigurationIntent(),
            dashboard: .preview,
            errorMessage: nil
        )
    }

    func snapshot(for configuration: NinebotWidgetConfigurationIntent, in context: Context) async -> NinebotWidgetEntry {
        let store = NinebotSharedStore()
        let dashboard = dashboardForWidget(store.loadDashboard() ?? .preview, configuration: configuration)
        return NinebotWidgetEntry(
            date: Date(),
            configuration: configuration,
            dashboard: dashboard,
            errorMessage: store.loadLastError(),
            vehicleImages: cachedVehicleImages(for: dashboard, store: store)
        )
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
        if state.isLocked == false || state.isPoweredOn == true { return 5 }
        if state.isCharging == true, !state.isFullyCharged { return 5 }
        if let battery = state.battery, battery < 20 { return 10 }
        return 20
    }

    private func loadEntry(configuration: NinebotWidgetConfigurationIntent) async -> NinebotWidgetEntry {
        let startedAt = Date()
        let store = NinebotSharedStore()
        let cached = store.loadDashboard()
        let proxyConfiguration = store.loadConfiguration() ?? NinebotProxyConfiguration(baseURLString: "", bearerToken: "")

        guard proxyConfiguration.isUsable else {
            store.saveLastWidgetRefreshEvent(NinebotRefreshEvent(
                source: "Widget",
                operation: "刷新小组件",
                startedAt: startedAt,
                endedAt: Date(),
                success: false,
                message: "未配置代理"
            ))
            let dashboard = dashboardForWidget(cached ?? .empty, configuration: configuration)
            return NinebotWidgetEntry(
                date: Date(),
                configuration: configuration,
                dashboard: dashboard,
                errorMessage: store.loadLastError(),
                vehicleImages: cachedVehicleImages(for: dashboard, store: store)
            )
        }

        do {
            // Keep the App's selected vehicle intact in the shared archive.  The widget
            // applies its own selection only to the entry it renders.
            let dashboard = try await NinebotProxyClient(configuration: proxyConfiguration)
                .fetchDashboard(selectedSN: cached?.selectedSN)
            let archivedDashboard = store.saveDashboard(dashboard)
            let widgetDashboard = dashboardForWidget(archivedDashboard, configuration: configuration)
            store.saveLastWidgetRefreshEvent(NinebotRefreshEvent(
                source: "Widget",
                operation: "刷新小组件",
                startedAt: startedAt,
                endedAt: Date(),
                success: true,
                message: widgetDashboard.primaryVehicle?.vehicle.displayName
            ))
            return NinebotWidgetEntry(
                date: Date(),
                configuration: configuration,
                dashboard: widgetDashboard,
                errorMessage: nil,
                vehicleImages: await vehicleImages(for: widgetDashboard, store: store)
            )
        } catch {
            let message = error.localizedDescription
            store.saveLastError(message)
            store.saveLastWidgetRefreshEvent(NinebotRefreshEvent(
                source: "Widget",
                operation: "刷新小组件",
                startedAt: startedAt,
                endedAt: Date(),
                success: false,
                message: message
            ))
            let dashboard = dashboardForWidget(cached ?? .empty, configuration: configuration)
            return NinebotWidgetEntry(
                date: Date(),
                configuration: configuration,
                dashboard: dashboard,
                errorMessage: message,
                vehicleImages: cachedVehicleImages(for: dashboard, store: store)
            )
        }
    }

    private func dashboardForWidget(
        _ dashboard: NinebotDashboard,
        configuration: NinebotWidgetConfigurationIntent
    ) -> NinebotDashboard {
        guard let selectedSN = configuration.vehicle?.id,
              let selectedSnapshot = dashboard.vehicles.first(where: { $0.vehicle.sn == selectedSN }) else {
            return dashboard
        }
        // A configured widget is a dedicated instrument panel, not a vehicle carousel.
        return NinebotDashboard(vehicles: [selectedSnapshot], selectedSN: selectedSN, updatedAt: dashboard.updatedAt)
    }

    private func vehicleImages(for dashboard: NinebotDashboard, store: NinebotSharedStore) async -> [String: Data] {
        var images = cachedVehicleImages(for: dashboard, store: store)

        for snapshot in dashboard.vehicles {
            guard let urlString = snapshot.vehicle.imageURLString,
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
                images[snapshot.vehicle.sn] = data
            } catch {
                continue
            }
        }

        return images
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
