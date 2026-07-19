import AppIntents
import Foundation

/// Vehicle picker surfaced in the widget edit sheet.
struct NinebotVehicleEntity: AppEntity, Hashable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "车辆")
    static var defaultQuery = NinebotVehicleEntityQuery()

    let id: String
    let name: String
    let model: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(model)")
    }
}

struct NinebotVehicleEntityQuery: EntityQuery {
    func entities(for identifiers: [NinebotVehicleEntity.ID]) async throws -> [NinebotVehicleEntity] {
        vehicleEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [NinebotVehicleEntity] {
        vehicleEntities()
    }

    private func vehicleEntities() -> [NinebotVehicleEntity] {
        let dashboard = NinebotSharedStore().loadDashboard() ?? .empty
        return dashboard.vehicles.map {
            NinebotVehicleEntity(id: $0.vehicle.sn, name: $0.vehicle.name, model: $0.vehicle.model)
        }
    }
}

struct NinebotWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "选择九号车辆"
    static var description = IntentDescription("选择小组件要显示的车辆；未选择时跟随 App 当前车辆。")

    @Parameter(title: "车辆")
    var vehicle: NinebotVehicleEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("显示 \(\.$vehicle)")
    }
}
