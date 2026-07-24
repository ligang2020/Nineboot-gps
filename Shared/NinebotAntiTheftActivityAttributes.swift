import Foundation

/// 车辆安全事件。该枚举同时被 App、Widget 与 BLE 适配层使用，Raw Value 保持稳定，
/// 便于服务端推送、App Group 缓存和 Live Activity 之间安全传递。
enum NinebotSecurityEventType: String, Codable, CaseIterable, Hashable, Sendable {
    case vibration
    case unauthorizedPush
    case unauthorizedUnlock
    case unauthorizedStart
    case powerDisconnected
    case batteryRemoved
    case controllerPowerLoss
    case gpsOffline
    case bluetoothDisconnected
    case illegalMovement
    case sos

    var title: String {
        switch self {
        case .vibration: return "异常震动"
        case .unauthorizedPush: return "车辆被推行"
        case .unauthorizedUnlock: return "非法开锁"
        case .unauthorizedStart: return "非法启动"
        case .powerDisconnected: return "电源断开"
        case .batteryRemoved: return "电瓶拆除"
        case .controllerPowerLoss: return "控制器断电"
        case .gpsOffline: return "GPS 离线"
        case .bluetoothDisconnected: return "蓝牙断开"
        case .illegalMovement: return "非法移动"
        case .sos: return "SOS 安全报警"
        }
    }

    var symbolName: String {
        switch self {
        case .vibration: return "waveform.path.ecg"
        case .unauthorizedPush, .illegalMovement: return "figure.walk.motion"
        case .unauthorizedUnlock: return "lock.open.trianglebadge.exclamationmark"
        case .unauthorizedStart: return "power.circle.fill"
        case .powerDisconnected, .controllerPowerLoss: return "powerplug.portrait.fill"
        case .batteryRemoved: return "battery.0percent"
        case .gpsOffline: return "location.slash.fill"
        case .bluetoothDisconnected: return "bluetooth.slash"
        case .sos: return "exclamationmark.triangle.fill"
        }
    }

    var notificationTitle: String {
        switch self {
        case .illegalMovement: return "🚲 检测到车辆移动"
        case .powerDisconnected: return "🔌 电源断开"
        case .batteryRemoved: return "🔋 电瓶拆除"
        case .bluetoothDisconnected: return "📶 蓝牙已断开"
        case .gpsOffline: return "📡 GPS离线"
        case .sos: return "🆘 SOS 车辆报警"
        default: return "🚨 车辆报警"
        }
    }

    var notificationBody: String {
        switch self {
        case .illegalMovement:
            return "车辆在未解锁状态下发生移动。"
        case .unauthorizedPush:
            return "车辆正在被推行，请确认是否本人操作。"
        case .powerDisconnected:
            return "检测到车辆主电源异常断开。"
        case .batteryRemoved:
            return "检测到车辆电瓶可能已被拆除。"
        case .bluetoothDisconnected:
            return "车辆已超出蓝牙连接范围。"
        case .gpsOffline:
            return "暂时无法获取车辆定位。"
        case .sos:
            return "车辆报警持续超过 30 秒，请立即查看定位。"
        default:
            return "检测到车辆异常，请立即查看。"
        }
    }
}

/// 车辆端或服务端上报的定位数据。位置为车辆位置，非手机位置。
struct NinebotVehicleLocation: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var heading: Double?
    var horizontalAccuracy: Double?
    var updatedAt: Date

    init(
        latitude: Double,
        longitude: Double,
        heading: Double? = nil,
        horizontalAccuracy: Double? = nil,
        updatedAt: Date = .now
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.heading = heading
        self.horizontalAccuracy = horizontalAccuracy
        self.updatedAt = updatedAt
    }

    var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

/// 经 BLE 协议层标准化后的安全状态。不同车型可将私有 GATT 字段映射至这一层，
/// UI 与业务规则不直接依赖具体 UUID / 字节序。
struct NinebotVehicleSecurityTelemetry: Codable, Hashable, Sendable {
    var activeAlarm: NinebotSecurityEventType?
    var isBatteryRemoved: Bool
    var isVehicleMoving: Bool
    var isPowerConnected: Bool
    var isControllerPowered: Bool
    var location: NinebotVehicleLocation?

    init(
        activeAlarm: NinebotSecurityEventType? = nil,
        isBatteryRemoved: Bool = false,
        isVehicleMoving: Bool = false,
        isPowerConnected: Bool = true,
        isControllerPowered: Bool = true,
        location: NinebotVehicleLocation? = nil
    ) {
        self.activeAlarm = activeAlarm
        self.isBatteryRemoved = isBatteryRemoved
        self.isVehicleMoving = isVehicleMoving
        self.isPowerConnected = isPowerConnected
        self.isControllerPowered = isControllerPowered
        self.location = location
    }
}

#if canImport(ActivityKit)
import ActivityKit

/// 防盗 Live Activity 的静态信息。
@available(iOS 18.0, *)
struct NinebotAntiTheftActivityAttributes: ActivityAttributes {
    var vehicleSN: String
    var vehicleName: String
    var startedAt: Date

    struct ContentState: Codable, Hashable {
        var alarmType: NinebotSecurityEventType
        var location: NinebotVehicleLocation?
        var isSOS: Bool
        var updatedAt: Date

        init(
            alarmType: NinebotSecurityEventType,
            location: NinebotVehicleLocation?,
            isSOS: Bool = false,
            updatedAt: Date = .now
        ) {
            self.alarmType = alarmType
            self.location = location
            self.isSOS = isSOS
            self.updatedAt = updatedAt
        }
    }
}

@available(iOS 18.0, *)
extension NinebotAntiTheftActivityAttributes {
    static let preview = Self(
        vehicleSN: "NPLIVE-2026",
        vehicleName: "Ninebot F2 Pro",
        startedAt: .now.addingTimeInterval(-48)
    )
}

@available(iOS 18.0, *)
extension NinebotAntiTheftActivityAttributes.ContentState {
    static let preview = Self(
        alarmType: .illegalMovement,
        location: NinebotVehicleLocation(
            latitude: 31.2304,
            longitude: 121.4737,
            heading: 82,
            horizontalAccuracy: 12,
            updatedAt: .now.addingTimeInterval(-8)
        )
    )
}
#endif
