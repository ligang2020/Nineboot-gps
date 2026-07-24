import Foundation

/// 当前骑行会话会保存到 App Group。即使 App 被系统终止，重新打开后也能继续使用同一个开始时间，
/// 从而让 Live Activity 的计时不中断。
struct NinebotActiveRideSession: Codable, Hashable {
    var vehicleSN: String
    var vehicleName: String
    var vehicleModel: String
    var startedAt: Date
    var latestSpeedKmh: Double?
    var distanceMeters: Double?
    /// 骑行开始时的总里程，用于计算本次骑行距离。
    var startedTotalMileageKm: Double?
    var updatedAt: Date

    init(
        vehicleSN: String,
        vehicleName: String,
        vehicleModel: String,
        startedAt: Date,
        latestSpeedKmh: Double? = nil,
        distanceMeters: Double? = nil,
        startedTotalMileageKm: Double? = nil,
        updatedAt: Date = .now
    ) {
        self.vehicleSN = vehicleSN
        self.vehicleName = vehicleName
        self.vehicleModel = vehicleModel
        self.startedAt = startedAt
        self.latestSpeedKmh = latestSpeedKmh
        self.distanceMeters = distanceMeters
        self.startedTotalMileageKm = startedTotalMileageKm
        self.updatedAt = updatedAt
    }
}

#if canImport(ActivityKit)
import ActivityKit

/// 骑行模式。使用稳定的 Raw Value，保证 App 与 Widget Extension 解码一致。
enum NinebotRideMode: String, Codable, CaseIterable, Hashable, Sendable {
    case eco = "Eco"
    case drive = "Drive"
    case sport = "Sport"

    var localizedTitle: String { rawValue }

    var symbolName: String {
        switch self {
        case .eco: return "leaf.fill"
        case .drive: return "gauge.with.dots.needle.67percent"
        case .sport: return "flame.fill"
        }
    }
}

/// BLE 遥测的标准化模型。
///
/// 蓝牙层每秒解析完一帧数据后，将其转换为该类型并交给
/// `NinebotViewModel.ingestBLETelemetry(_:)`。协议 UUID、字节序和校验方式
/// 因具体车辆而异，因此刻意与 CoreBluetooth 解耦，避免在 UI 层硬编码私有协议。
struct NinebotBLETelemetry: Sendable, Hashable {
    var vehicleSN: String
    var speedKmh: Double
    var batteryPercent: Int
    var remainingRangeKm: Double
    var todayDistanceKm: Double
    var totalDistanceKm: Double
    var rideDistanceKm: Double
    var mode: NinebotRideMode
    var isBluetoothConnected: Bool
    var isGPSAvailable: Bool
    var isLocked: Bool
    var isCharging: Bool
    var isRiding: Bool
    var receivedAt: Date

    init(
        vehicleSN: String,
        speedKmh: Double,
        batteryPercent: Int,
        remainingRangeKm: Double,
        todayDistanceKm: Double,
        totalDistanceKm: Double,
        rideDistanceKm: Double,
        mode: NinebotRideMode,
        isBluetoothConnected: Bool,
        isGPSAvailable: Bool,
        isLocked: Bool,
        isCharging: Bool,
        isRiding: Bool,
        receivedAt: Date = .now
    ) {
        self.vehicleSN = vehicleSN
        self.speedKmh = speedKmh
        self.batteryPercent = batteryPercent
        self.remainingRangeKm = remainingRangeKm
        self.todayDistanceKm = todayDistanceKm
        self.totalDistanceKm = totalDistanceKm
        self.rideDistanceKm = rideDistanceKm
        self.mode = mode
        self.isBluetoothConnected = isBluetoothConnected
        self.isGPSAvailable = isGPSAvailable
        self.isLocked = isLocked
        self.isCharging = isCharging
        self.isRiding = isRiding
        self.receivedAt = receivedAt
    }
}

/// Live Activity 的可变内容。这里仅放需要由 BLE 刷新的值；骑行时间使用
/// Attributes 中的 `startedAt` 搭配 `Text(_:style: .timer)` 让系统自行计时，
/// 不会为了时钟每秒唤醒 App。
@available(iOS 18.0, *)
struct NinebotRideActivityContentState: Codable, Hashable {
    var speedKmh: Double
    var batteryPercent: Int
    var remainingRangeKm: Double
    var todayDistanceKm: Double
    var totalDistanceKm: Double
    var rideDistanceKm: Double
    var mode: NinebotRideMode
    var isBluetoothConnected: Bool
    var isGPSAvailable: Bool
    var isLocked: Bool
    /// 骑行 Live Activity 不渲染充电信息，但保留该状态用于避免异常的骑行展示。
    var isCharging: Bool
    var updatedAt: Date

    init(
        speedKmh: Double,
        batteryPercent: Int,
        remainingRangeKm: Double,
        todayDistanceKm: Double,
        totalDistanceKm: Double,
        rideDistanceKm: Double,
        mode: NinebotRideMode,
        isBluetoothConnected: Bool,
        isGPSAvailable: Bool,
        isLocked: Bool,
        isCharging: Bool,
        updatedAt: Date = .now
    ) {
        self.speedKmh = max(speedKmh, 0)
        self.batteryPercent = min(max(batteryPercent, 0), 100)
        self.remainingRangeKm = max(remainingRangeKm, 0)
        self.todayDistanceKm = max(todayDistanceKm, 0)
        self.totalDistanceKm = max(totalDistanceKm, 0)
        self.rideDistanceKm = max(rideDistanceKm, 0)
        self.mode = mode
        self.isBluetoothConnected = isBluetoothConnected
        self.isGPSAvailable = isGPSAvailable
        self.isLocked = isLocked
        self.isCharging = isCharging
        self.updatedAt = updatedAt
    }
}

/// Live Activity 的静态属性：一段骑行中不会变化的车辆信息及起始时间。
@available(iOS 18.0, *)
struct NinebotRideActivityAttributes: ActivityAttributes {
    var vehicleSN: String
    var vehicleName: String
    var vehicleModel: String
    var startedAt: Date

    typealias ContentState = NinebotRideActivityContentState
}

@available(iOS 18.0, *)
extension NinebotRideActivityAttributes {
    /// Xcode Canvas / Widget Preview 专用 Mock 数据，不会参与线上 BLE 流。
    static let preview = NinebotRideActivityAttributes(
        vehicleSN: "NPLIVE-2026",
        vehicleName: "Ninebot F2 Pro",
        vehicleModel: "F2 Pro",
        startedAt: .now.addingTimeInterval(-1_567)
    )
}

@available(iOS 18.0, *)
extension NinebotRideActivityContentState {
    /// Xcode Canvas / Widget Preview 专用 Mock 数据。
    static let preview = NinebotRideActivityContentState(
        speedKmh: 24,
        batteryPercent: 68,
        remainingRangeKm: 31,
        todayDistanceKm: 12.6,
        totalDistanceKm: 1_248.3,
        rideDistanceKm: 6.8,
        mode: .drive,
        isBluetoothConnected: true,
        isGPSAvailable: true,
        isLocked: false,
        isCharging: false
    )
}
#endif
