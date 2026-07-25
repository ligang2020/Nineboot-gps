import AppIntents
import SwiftUI
import UIKit
import WidgetKit

#if canImport(ActivityKit)
import ActivityKit
#endif

@main
struct NinebotWidgetBundle: WidgetBundle {
    var body: some Widget {
        NinebotStatusWidget()
        NinebotLockScreenWidget()
        #if canImport(ActivityKit)
        NinebotChargeLiveActivity()
        if #available(iOS 18.0, *) {
            NinebotRideLiveActivity()
            NinebotAntiTheftLiveActivity()
            NinebotWatchChargeLiveActivity()
        }
        #endif
    }
}

struct NinebotStatusWidget: Widget {
    private let kind = "NinebotStatusWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: NinebotWidgetConfigurationIntent.self, provider: NinebotTimelineProvider()) { entry in
            NinebotHomeWidgetView(entry: entry)
        }
        .configurationDisplayName("九号智驾仪表")
        .description("选择车辆后，查看电量、续航、能耗和安全状态。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct NinebotLockScreenWidget: Widget {
    private let kind = "NinebotLockScreenWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: NinebotWidgetConfigurationIntent.self, provider: NinebotTimelineProvider()) { entry in
            NinebotAccessoryWidgetView(entry: entry)
        }
        .configurationDisplayName("九号锁屏仪表")
        .description("选择一台车辆，在锁屏持续关注车况。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

#if canImport(ActivityKit)
@available(iOS 16.1, *)
struct NinebotChargeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NinebotChargeActivityAttributes.self) { context in
            chargeActivityContent(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color(red: 0.025, green: 0.07, blue: 0.06))
                .activitySystemActionForegroundColor(WidgetTheme.green)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ChargeIslandVehicleHeader(attributes: context.attributes)
                        .padding(.leading, 4)
                        .padding(.top, 7)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ChargeIslandBattery(state: context.state)
                        .padding(.trailing, 8)
                        .padding(.top, 3)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ChargeIslandMetrics(state: context.state)
                        .padding(.horizontal, 5)
                        .padding(.top, 6)
                }
            } compactLeading: {
                Image(systemName: "bolt.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WidgetTheme.green)
                    .frame(width: 18, height: 18)
            } compactTrailing: {
                Text(chargeBatteryText(context.state))
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            } minimal: {
                Image(systemName: "bolt.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WidgetTheme.green)
            }
            .keylineTint(WidgetTheme.green)
        }
        .configurationDisplayName("九号充电实况")
        .description("车辆充电时自动上岛，实时显示电量进度、电压、温度和预计充满时间。")
    }
}

/// A separate ActivityAttributes type is used on iOS 18 so the Apple Watch
/// Smart Stack configuration does not replace iOS 17's Live Activity support.
@available(iOS 18.0, *)
struct NinebotWatchChargeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NinebotWatchChargeActivityAttributes.self) { context in
            chargeActivityContent(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color(red: 0.025, green: 0.07, blue: 0.06))
                .activitySystemActionForegroundColor(WidgetTheme.green)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ChargeIslandVehicleHeader(attributes: context.attributes)
                        .padding(.leading, 4)
                        .padding(.top, 7)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ChargeIslandBattery(state: context.state)
                        .padding(.trailing, 8)
                        .padding(.top, 3)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ChargeIslandMetrics(state: context.state)
                        .padding(.horizontal, 5)
                        .padding(.top, 6)
                }
            } compactLeading: {
                Image(systemName: "bolt.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WidgetTheme.green)
                    .frame(width: 18, height: 18)
            } compactTrailing: {
                Text(chargeBatteryText(context.state))
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            } minimal: {
                Image(systemName: "bolt.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WidgetTheme.green)
            }
            .keylineTint(WidgetTheme.green)
        }
        // `supplementalActivityFamilies` is provided by the newer watchOS
        // Live Activity SDK. Keep the IPA workflow compatible with Xcode 15
        // while enabling the Watch Smart Stack when built with a newer SDK.
        #if compiler(>=6.0)
        .supplementalActivityFamilies([.small])
        #endif
        .configurationDisplayName("九号充电实况")
        .description("车辆充电时自动上岛，并在 Apple Watch 智能叠放中显示充电进度。")
    }
}

@ViewBuilder
private func chargeActivityContent<Attributes: NinebotChargeActivityVehicleAttributes>(
    attributes: Attributes,
    state: NinebotChargeActivityContentState
) -> some View {
    #if compiler(>=6.0)
    if #available(iOS 18.0, *) {
        ChargeLiveActivityAdaptiveCard(attributes: attributes, state: state)
    } else {
        ChargeLiveActivityCard(attributes: attributes, state: state)
    }
    #else
    ChargeLiveActivityCard(attributes: attributes, state: state)
    #endif
}

#if compiler(>=6.0)
/// watchOS 11 presents the `.small` supplemental Activity family in Smart
/// Stack. Keep the glance compact: vehicle, percentage, and the live charge
/// ring remain legible from the wrist.
@available(iOS 18.0, *)
private struct ChargeLiveActivityAdaptiveCard<Attributes: NinebotChargeActivityVehicleAttributes>: View {
    @Environment(\.activityFamily) private var activityFamily

    var attributes: Attributes
    var state: NinebotChargeActivityContentState

    var body: some View {
        if activityFamily == .small {
            ChargeWatchLiveActivityCard(attributes: attributes, state: state)
        } else {
            ChargeLiveActivityCard(attributes: attributes, state: state)
        }
    }
}

@available(iOS 18.0, *)
private struct ChargeWatchLiveActivityCard<Attributes: NinebotChargeActivityVehicleAttributes>: View {
    var attributes: Attributes
    var state: NinebotChargeActivityContentState

    var body: some View {
        VStack(spacing: 3) {
            Text(attributes.vehicleName)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.60)
                .frame(maxWidth: .infinity)

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(max(Double(state.battery ?? 0) / 100, 0), 1))
                    .stroke(WidgetTheme.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(chargeBatteryText(state))
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.65)
            }
            .frame(width: 42, height: 42)

            Text("充电中 · \(chargeFullTimeText(state))")
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .minimumScaleFactor(0.56)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            LinearGradient(
                colors: [Color(red: 0.025, green: 0.14, blue: 0.105), Color(red: 0.015, green: 0.06, blue: 0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}
#endif

@available(iOS 16.1, *)
private struct ChargeLiveActivityCard<Attributes: NinebotChargeActivityVehicleAttributes>: View {
    var attributes: Attributes
    var state: NinebotChargeActivityContentState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.055, blue: 0.045),
                    Color(red: 0.025, green: 0.14, blue: 0.105),
                    Color(red: 0.015, green: 0.08, blue: 0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(WidgetTheme.green.opacity(0.14))
                .frame(width: 150, height: 150)
                .blur(radius: 20)
                .offset(x: 130, y: -66)

            // Keep the vehicle name in an explicit top safe inset. The
            // lock-screen activity has a fixed height and previously clipped
            // this first line when the card's content became too tall.
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .center, spacing: 8) {
                    Text(attributes.vehicleName)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 6)
                    Label("充电中", systemImage: "bolt.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WidgetTheme.green)
                        .lineLimit(1)
                }

                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text(chargeBatteryValue(state))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("%")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white.opacity(0.62))
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(chargeFullTimeText(state))
                            .font(.headline.monospacedDigit().weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                        Text("预计充满")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(WidgetTheme.green)
                    }
                }
                .frame(maxWidth: .infinity)

                ChargeBatteryProgress(battery: state.battery, compact: true)

                HStack(spacing: 6) {
                    ChargeActivityMetric(value: chargeVoltageText(state), title: "电池电压", icon: "bolt.circle.fill")
                    ChargeActivityMetric(value: chargeTemperatureText(state), title: "电池温度", icon: "thermometer.medium")
                    ChargeActivityMetric(value: chargePowerText(state), title: "充电功率", icon: "bolt.fill")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
@available(iOS 16.1, *)
private struct ChargeIslandVehicleHeader<Attributes: NinebotChargeActivityVehicleAttributes>: View {
    var attributes: Attributes

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(attributes.vehicleName)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Label("充电中", systemImage: "bolt.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(WidgetTheme.green)
                .lineLimit(1)
        }
    }
}

@available(iOS 16.1, *)
private struct ChargeIslandBattery: View {
    var state: NinebotChargeActivityContentState

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(chargeBatteryText(state))
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(WidgetTheme.green)
            Text(chargeFullTimeText(state))
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.58))
        }
    }
}

@available(iOS 16.1, *)
private struct ChargeIslandMetrics: View {
    var state: NinebotChargeActivityContentState

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ChargeIslandMetric(value: chargeVoltageText(state), title: "电压")
                ChargeIslandMetric(value: chargeTemperatureText(state), title: "温度")
                ChargeIslandMetric(value: chargePowerText(state), title: "功率")
            }
            ChargeBatteryProgress(battery: state.battery, compact: true)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 7)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

@available(iOS 16.1, *)
private struct ChargeBatteryBadge: View {
    var battery: Int?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "battery.75percent")
            Text(chargeBatteryText(battery))
                .monospacedDigit()
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(WidgetTheme.green)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(WidgetTheme.green.opacity(0.12), in: Capsule())
    }
}

@available(iOS 16.1, *)
private struct ChargeActivityMetric: View {
    var value: String
    var title: String
    var icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
            Text(value)
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

@available(iOS 16.1, *)
private struct ChargeIslandMetric: View {
    var value: String
    var title: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.60)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A 0–100% charge bar. Its fill is tied directly to battery percentage, so
/// every reported battery increase advances the Live Activity progress bar.
@available(iOS 16.1, *)
private struct ChargeBatteryProgress: View {
    var battery: Int?
    var compact = false

    var body: some View {
        let progress = min(max(Double(battery ?? 0), 0), 100) / 100

        VStack(spacing: compact ? 4 : 5) {
            HStack(spacing: 6) {
                Text("当前 \(chargeBatteryText(battery))")
                    .foregroundStyle(.white.opacity(0.82))
                Spacer(minLength: 6)
                Text("满电 100%")
                    .foregroundStyle(WidgetTheme.green)
            }
            .font(.caption2.monospacedDigit().weight(.medium))
            .lineLimit(1)

            GeometryReader { proxy in
                let width = max(proxy.size.width, 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule()
                        .fill(LinearGradient(colors: [WidgetTheme.green, Color.cyan], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(width * progress, progress > 0 ? 8 : 0))
                }
            }
            .frame(height: compact ? 5 : 7)
        }
    }
}

@available(iOS 16.1, *)
private func chargeBatteryValue(_ state: NinebotChargeActivityContentState) -> String {
    state.battery.map(String.init) ?? "--"
}

@available(iOS 16.1, *)
private func chargeBatteryText(_ state: NinebotChargeActivityContentState) -> String {
    chargeBatteryText(state.battery)
}

@available(iOS 16.1, *)
private func chargeBatteryText(_ battery: Int?) -> String {
    battery.map { "\($0)%" } ?? "--%"
}

@available(iOS 16.1, *)
private func chargeVoltageText(_ state: NinebotChargeActivityContentState) -> String {
    guard let voltage = state.batteryVoltage else { return "-- V" }
    return "\(formatWidgetNumber(voltage, maximumFractionDigits: 1)) V"
}

@available(iOS 16.1, *)
private func chargeTemperatureText(_ state: NinebotChargeActivityContentState) -> String {
    guard let temperature = state.batteryTemperatureCelsius else { return "-- °C" }
    return "\(formatWidgetNumber(temperature, maximumFractionDigits: 1)) °C"
}

@available(iOS 16.1, *)
private func chargePowerText(_ state: NinebotChargeActivityContentState) -> String {
    guard let power = state.chargingPowerWatts, power > 0 else { return "-- W" }
    return "\(formatWidgetNumber(power, maximumFractionDigits: 0)) W"
}

@available(iOS 16.1, *)
private func chargeFullTimeText(_ state: NinebotChargeActivityContentState) -> String {
    guard let minutes = state.estimatedFullChargeMinutes else { return "计算中" }
    guard minutes > 0 else { return "已充满" }

    let totalMinutes = Int(minutes.rounded(.up))
    let hours = totalMinutes / 60
    let remainder = totalMinutes % 60
    return hours > 0 ? "\(hours)小时\(remainder)分" : "\(remainder)分"
}

@available(iOS 16.1, *)
private func chargeUpdatedText(_ date: Date) -> String {
    formatWidgetTime(date)
}

@available(iOS 18.0, *)
struct NinebotRideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NinebotRideActivityAttributes.self) { context in
            // 锁屏 / StandBy：只呈现正在骑行时最关键的速度、电量和续航，
            // 以系统分隔线组织信息，避免 Dashboard 化的大量卡片。
            RideLockScreenLiveActivityView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(.green)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RideIslandVehicleLocation(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RideBatteryLabel(percent: context.state.batteryPercent, compact: false)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RideIslandSummary(attributes: context.attributes, state: context.state)
                }
            } compactLeading: {
                Image(systemName: "location.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityLabel("车辆位置")
            } compactTrailing: {
                Text(rideCompactLocationText(context.state.vehicleLocationText))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: 74, alignment: .trailing)
                    .accessibilityLabel("车辆位置：\(context.state.vehicleLocationText)")
            } minimal: {
                Image(systemName: "location.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
                    .accessibilityLabel("车辆位置")
            }
            .keylineTint(.green)
        }
        .configurationDisplayName("九号骑行实况")
        .description("以简洁层级显示速度、模式、电量、续航与骑行数据。")
    }
}

/// 锁屏与 StandBy 主视图。控制在紧凑高度内，不使用 Dashboard 式卡片。
@available(iOS 18.0, *)
private struct RideLockScreenLiveActivityView: View {
    var attributes: NinebotRideActivityAttributes
    var state: NinebotRideActivityContentState

    var body: some View {
        // 位置文本在不同锁屏容器的可用宽度差异很大；控制为两行并保留缩放余量，
        // 防止长地址挤压下方的骑行数据或被实时活动容器裁切。
        VStack(spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "location.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(width: 20, alignment: .center)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text("车辆位置")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(state.vehicleLocationText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("车辆位置：\(state.vehicleLocationText)")

            RideModeBadge(mode: state.mode)

            Divider()

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], alignment: .leading, spacing: 5) {
                RideMetricCell(title: "电量", value: "\(state.batteryPercent)%", symbol: RideActivityTheme.batterySymbol(for: state.batteryPercent), tint: RideActivityTheme.batteryColor(for: state.batteryPercent))
                RideMetricCell(title: "续航", value: rideDistanceText(state.remainingRangeKm), symbol: "road.lanes", tint: .secondary)
                RideMetricCell(title: "本次骑行", value: rideDistanceText(state.rideDistanceKm), symbol: "bicycle", tint: .secondary)
                RideTimerMetricCell(startedAt: attributes.startedAt)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

@available(iOS 18.0, *)
private struct RideModeBadge: View {
    var mode: NinebotRideMode

    var body: some View {
        Label(mode.localizedTitle, systemImage: mode.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.green.opacity(0.14), in: Capsule())
            .accessibilityLabel("当前模式 \(mode.localizedTitle)")
    }
}

@available(iOS 18.0, *)
private struct RideMetricCell: View {
    var title: String
    var value: String
    var symbol: String
    var tint: Color

    var body: some View {
        // 指标保持单行「图标 + 文字 + 数值」：既保留可读文字，也避免两层卡片造成锁屏裁切。
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 13)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Spacer(minLength: 2)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)")
    }
}

@available(iOS 18.0, *)
private struct RideTimerMetricCell: View {
    var startedAt: Date

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "timer")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 13)
            Text("骑行时间")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Spacer(minLength: 2)
            Text(startedAt, style: .timer)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("骑行时间")
    }
}

@available(iOS 18.0, *)
private struct RideIslandVehicleLocation: View {
    var state: NinebotRideActivityContentState

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "location.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 1) {
                Text("车辆位置")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(state.vehicleLocationText)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("车辆位置：\(state.vehicleLocationText)")
    }
}

@available(iOS 18.0, *)
private struct RideIslandSummary: View {
    var attributes: NinebotRideActivityAttributes
    var state: NinebotRideActivityContentState

    var body: some View {
        // Expanded Bottom 使用两行双列的短标签，保留文字同时避免 iPhone 15 / 16 灵动岛底部裁切。
        VStack(spacing: 5) {
            RideModeBadge(mode: state.mode)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: state.mode)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], alignment: .leading, spacing: 5) {
                RideIslandMetric(
                    title: "电量",
                    value: "\(state.batteryPercent)%",
                    symbol: RideActivityTheme.batterySymbol(for: state.batteryPercent),
                    tint: RideActivityTheme.batteryColor(for: state.batteryPercent)
                )
                RideIslandMetric(title: "续航", value: rideDistanceText(state.remainingRangeKm), symbol: "location.fill", tint: .secondary)
                RideIslandMetric(title: "骑行", value: rideDistanceText(state.rideDistanceKm), symbol: "bicycle", tint: .secondary)
                RideIslandTimer(start: attributes.startedAt)
            }
        }
        .padding(.horizontal, 3)
        .padding(.top, 2)
        .padding(.bottom, 1)
    }
}

@available(iOS 18.0, *)
private struct RideIslandMetric: View {
    var title: String
    var value: String
    var symbol: String
    var tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 1)
            Text(value)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.64)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value)")
    }
}

@available(iOS 18.0, *)
private struct RideIslandTimer: View {
    var start: Date

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "timer")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("时间")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 1)
            Text(start, style: .timer)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.64)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("骑行时间")
    }
}

@available(iOS 18.0, *)
private struct RideBatteryLabel: View {
    var percent: Int
    var compact: Bool

    var body: some View {
        Label {
            Text("\(percent)%")
                .contentTransition(.numericText(value: Double(percent)))
                .monospacedDigit()
        } icon: {
            Image(systemName: RideActivityTheme.batterySymbol(for: percent))
        }
        .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
        .foregroundStyle(RideActivityTheme.batteryColor(for: percent))
        .animation(.easeInOut(duration: 0.3), value: percent)
    }
}

@available(iOS 18.0, *)
private enum RideActivityTheme {
    static func batteryColor(for percent: Int) -> Color {
        switch percent {
        case 51...100: return .green
        case 21...50: return .orange
        default: return .red
        }
    }

    static func batterySymbol(for percent: Int) -> String {
        switch percent {
        case 76...100: return "battery.100percent"
        case 51...75: return "battery.75percent"
        case 26...50: return "battery.50percent"
        case 1...25: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

@available(iOS 18.0, *)
private func rideDistanceText(_ kilometers: Double) -> String {
    if kilometers < 1 {
        return "\(Int((kilometers * 1_000).rounded())) m"
    }
    return String(format: "%.0f km", kilometers)
}

@available(iOS 18.0, *)
private func rideCompactLocationText(_ location: String) -> String {
    let text = location.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "定位中" }
    return String(text.prefix(10))
}

/// 车辆触发安全事件时展示的独立 Live Activity。
/// 红色仅用于明确的报警语义，平时骑行实况保持中性、克制的系统风格。
@available(iOS 18.0, *)
struct NinebotAntiTheftLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NinebotAntiTheftActivityAttributes.self) { context in
            AntiTheftLockScreenLiveActivityView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(.red.opacity(0.12))
                .activitySystemActionForegroundColor(.red)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("车辆报警", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.alarmType.symbolName)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.red)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Image(systemName: context.state.alarmType.symbolName)
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.state.isSOS ? "SOS 安全报警" : context.state.alarmType.title)
                                .font(.subheadline.weight(.semibold))
                            Text(antiTheftLocationText(context.state.location))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(context.attributes.startedAt, style: .timer)
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 5)
                }
            } compactLeading: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
            } compactTrailing: {
                Image(systemName: context.state.alarmType.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            } minimal: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
            }
            .keylineTint(.red)
        }
        .configurationDisplayName("九号车辆报警")
        .description("车辆发生安全异常时，显示报警类型、定位和持续时间。")
    }
}

/// 防盗锁屏视图只保留报警类型、车辆定位与报警时间，便于用户在锁屏快速判断情况。
@available(iOS 18.0, *)
private struct AntiTheftLockScreenLiveActivityView: View {
    var attributes: NinebotAntiTheftActivityAttributes
    var state: NinebotAntiTheftActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.isSOS ? "exclamationmark.triangle.fill" : state.alarmType.symbolName)
                .font(.title2.weight(.bold))
                .foregroundStyle(.red)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.isSOS ? "SOS 车辆报警" : "车辆报警")
                    .font(.headline.weight(.bold))
                Text(state.alarmType.title)
                    .font(.subheadline.weight(.semibold))
                Label(antiTheftLocationText(state.location), systemImage: "location.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                Text("报警时间")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(attributes.startedAt, style: .timer)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .widgetURL(URL(string: "ninebot://security"))
    }
}

@available(iOS 18.0, *)
private func antiTheftLocationText(_ location: NinebotVehicleLocation?) -> String {
    guard let location, location.isValid else { return "正在获取车辆定位" }
    return String(format: "%.4f, %.4f", location.latitude, location.longitude)
}

#if DEBUG
@available(iOS 18.0, *)
#Preview("防盗锁屏", as: .content, using: NinebotAntiTheftActivityAttributes.preview) {
    NinebotAntiTheftLiveActivity()
} contentStates: {
    NinebotAntiTheftActivityAttributes.ContentState.preview
}

@available(iOS 18.0, *)
#Preview("防盗灵动岛", as: .dynamicIsland(.expanded), using: NinebotAntiTheftActivityAttributes.preview) {
    NinebotAntiTheftLiveActivity()
} contentStates: {
    NinebotAntiTheftActivityAttributes.ContentState.preview
}
#endif

#if DEBUG
@available(iOS 18.0, *)
#Preview("锁屏", as: .content, using: NinebotRideActivityAttributes.preview) {
    NinebotRideLiveActivity()
} contentStates: {
    NinebotRideActivityContentState.preview
}

@available(iOS 18.0, *)
#Preview("Dynamic Island Expanded", as: .dynamicIsland(.expanded), using: NinebotRideActivityAttributes.preview) {
    NinebotRideLiveActivity()
} contentStates: {
    NinebotRideActivityContentState.preview
}

@available(iOS 18.0, *)
#Preview("Dynamic Island Compact", as: .dynamicIsland(.compact), using: NinebotRideActivityAttributes.preview) {
    NinebotRideLiveActivity()
} contentStates: {
    NinebotRideActivityContentState.preview
}
#endif
#endif

private struct NinebotHomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: NinebotWidgetEntry

    var body: some View {
        Group {
            if let snapshot = entry.dashboard.primaryVehicle {
                switch family {
                case .systemSmall:
                    SmallStatusWidget(
                        snapshot: snapshot,
                        vehicleImageData: entry.vehicleImages[snapshot.vehicle.sn]
                    )
                case .systemLarge:
                    LargeStatusWidget(
                        dashboard: entry.dashboard,
                        vehicleImages: entry.vehicleImages
                    )
                default:
                    MediumStatusWidget(dashboard: entry.dashboard)
                }
            } else {
                EmptyWidgetView(message: entry.errorMessage ?? "暂无车辆")
            }
        }
        .containerBackground(WidgetTheme.pageBackground, for: .widget)
    }
}

private struct SmallStatusWidget: View {
    var snapshot: NinebotVehicleSnapshot
    var vehicleImageData: Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(WidgetTheme.smallVehicleBackground)

            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: 20)
                .frame(width: 128, height: 128)
                .offset(x: 54, y: 40)

            WidgetVehicleImage(imageData: vehicleImageData)
                .frame(width: 154, height: 94)
                .offset(x: 48, y: 42)

            VStack(alignment: .leading, spacing: 12) {
                Text(snapshot.vehicle.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                HStack(alignment: .center, spacing: 8) {
                    SmallWidgetBatteryRing(
                        value: snapshot.state.batteryFraction,
                        battery: snapshot.state.battery,
                        isCharging: snapshot.state.isCharging == true
                    )
                    .frame(width: 30, height: 30)

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(estimatedRangeDigits(snapshot.state))
                            .font(.system(size: 35, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.58)
                        Text("km")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.84))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 34)

                if snapshot.state.isCharging == true {
                    Label("充电中", systemImage: "bolt.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WidgetTheme.green)
                        .lineLimit(1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct SmallWidgetBatteryRing: View {
    var value: Double
    var battery: Int?
    var isCharging: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.20), lineWidth: 5)

            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(activeColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Circle()
                .fill(WidgetTheme.smallVehicleBackground)
                .frame(width: 12, height: 12)
        }
    }

    private var activeColor: Color {
        if isCharging { return WidgetTheme.green }
        guard let battery else { return WidgetTheme.green }
        return battery < 20 ? .red : WidgetTheme.green
    }
}

private struct MediumStatusWidget: View {
    var dashboard: NinebotDashboard

    var body: some View {
        if let primary = dashboard.primaryVehicle {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(primary.vehicle.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(WidgetTheme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)

                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(estimatedRangeDigits(primary.state))
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(WidgetTheme.primaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.58)

                            Text("km")
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundStyle(WidgetTheme.primaryText)

                            Text("预估")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(WidgetTheme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 5) {
                        Text("\(formatWidgetTime(primary.state.updatedAt)) 更新")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(WidgetTheme.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        Text(primary.state.batteryText)
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(batteryColor(primary.state.battery, isCharging: primary.state.isCharging == true))
                            .lineLimit(1)

                        MediumWidgetStatusPill(state: primary.state)
                    }
                    .frame(width: 112, alignment: .trailing)
                }

                MediumBatteryProgressBar(
                    value: primary.state.batteryFraction,
                    battery: primary.state.battery,
                    isCharging: primary.state.isCharging == true
                )
                .frame(height: 7)

                MediumWidgetControlStrip(state: primary.state)
                    .frame(height: 44)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        } else {
            EmptyWidgetView(message: "暂无车辆")
        }
    }
}

private struct MediumBatteryProgressBar: View {
    var value: Double
    var battery: Int?
    var isCharging: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(WidgetTheme.secondaryText.opacity(0.18))
                Capsule()
                    .fill(activeColor)
                    .frame(width: max(proxy.size.width * min(max(value, 0), 1), 5))
            }
        }
    }

    private var activeColor: Color {
        if isCharging { return WidgetTheme.green }
        guard let battery else { return WidgetTheme.green }
        return battery < 20 ? .red : WidgetTheme.green
    }
}

private struct MediumWidgetInlineStatus: View {
    var state: NinebotVehicleState

    var body: some View {
        Label(widgetStatusText(state), systemImage: widgetStatusImage(state))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor(state))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }
}

private struct MediumWidgetStatusPill: View {
    var state: NinebotVehicleState

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 7, height: 7)

            Text(statusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(WidgetTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(WidgetTheme.cardBackground.opacity(0.86))
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 3)
    }

    private var statusText: String {
        if state.isFullyCharged { return "电量已充满" }
        if state.isCharging == true { return "正在充电" }
        if state.isLocked == true { return "守卫模式已开启" }
        if state.isLocked == false { return "车辆未上锁" }
        return widgetStatusText(state)
    }

    private var statusDotColor: Color {
        if state.isLocked == false { return .orange }
        if state.isCharging == true || state.isFullyCharged { return WidgetTheme.green }
        return WidgetTheme.primaryText
    }
}

private struct MediumWidgetControlStrip: View {
    var state: NinebotVehicleState

    var body: some View {
        HStack(spacing: 0) {
            MediumWidgetControlIcon(systemImage: state.isFullyCharged ? "battery.100" : (state.isCharging == true ? "bolt.fill" : "power"))
            MediumWidgetControlIcon(systemImage: "shippingbox.fill")
            MediumWidgetControlIcon(systemImage: "speaker.wave.2.fill")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WidgetTheme.cardBackground.opacity(0.90))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 12, x: 0, y: 5)
    }
}

private struct MediumWidgetControlIcon: View {
    var systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(WidgetTheme.primaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .minimumScaleFactor(0.78)
    }
}

private struct LargeStatusWidget: View {
    var dashboard: NinebotDashboard
    var vehicleImages: [String: Data] = [:]

    var body: some View {
        if let primary = dashboard.primaryVehicle {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(primary.vehicle.displayName)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(WidgetTheme.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)
                        Text("\(formatWidgetTime(primary.state.updatedAt)) 更新")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(WidgetTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    WidgetVehicleImage(imageData: vehicleImages[primary.vehicle.sn])
                        .frame(width: 142, height: 72)
                }

                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(estimatedRangeText(primary.state))
                        .font(.system(size: 39, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WidgetTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.52)

                    Spacer(minLength: 8)

                    Text(primary.state.batteryText)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(batteryColor(primary.state.battery, isCharging: primary.state.isCharging == true))
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                }

                WidgetBatteryBar(value: primary.state.batteryFraction, isCharging: primary.state.isCharging == true, height: 7)

                HStack(spacing: 8) {
                    WidgetInfoTile(title: "本月日均", value: primary.state.dailyAverageMileageText, systemImage: "calendar")
                    WidgetInfoTile(title: "最高速度", value: primary.state.maximumSpeedText, systemImage: "gauge.with.dots.needle.67percent")
                    WidgetInfoTile(title: "最近骑行", value: primary.state.lastRideSummaryText, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                }
                .frame(height: 60)

                WidgetLargeControlStrip(state: primary.state)
                    .frame(height: 44)
            }
            .padding(14)
        } else {
            EmptyWidgetView(message: "暂无车辆")
        }
    }
}

private struct NinebotAccessoryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: NinebotWidgetEntry

    var body: some View {
        let snapshot = entry.dashboard.primaryVehicle

        Group {
            switch family {
            case .accessoryCircular:
                AccessoryCircularStatus(snapshot: snapshot)
            case .accessoryInline:
                if let snapshot {
                    Label("\(snapshot.vehicle.displayName) \(snapshot.state.batteryText) \(compactWidgetStatus(snapshot.state))", systemImage: widgetStatusImage(snapshot.state))
                } else {
                    Label("九号暂无数据", systemImage: "bolt.car.fill")
                }
            default:
                AccessoryRectangularStatus(snapshot: snapshot)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct AccessoryRectangularStatus: View {
    var snapshot: NinebotVehicleSnapshot?

    var body: some View {
        if let snapshot {
            HStack(spacing: 8) {
                Image(systemName: widgetStatusImage(snapshot.state))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(statusColor(snapshot.state))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.vehicle.displayName)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(accessoryRectangularText(snapshot))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Spacer(minLength: 4)

                Text(snapshot.state.batteryText)
                    .font(.headline.monospacedDigit().weight(.bold))
                    .foregroundStyle(batteryColor(snapshot.state.battery, isCharging: snapshot.state.isCharging == true))
                    .lineLimit(1)
            }
        } else {
            Label("九号暂无数据", systemImage: "bolt.car.fill")
                .font(.headline)
                .lineLimit(1)
        }
    }
}

private struct AccessoryCircularStatus: View {
    var snapshot: NinebotVehicleSnapshot?

    var body: some View {
        let state = snapshot?.state
        let fraction = max(0.04, min(state?.batteryFraction ?? 0, 1))

        ZStack {
            AccessoryWidgetBackground()

            Circle()
                .stroke(.primary.opacity(0.24), lineWidth: 7)
                .padding(2)

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.primary, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(2)

            Text(accessoryCircularPercentText(state))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.54)
                .padding(.horizontal, 7)
            .foregroundStyle(.primary)
            .widgetAccentable()
        }
    }
}

private struct EmptyWidgetView: View {
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "link.badge.plus")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .foregroundStyle(.secondary)
        .padding()
    }
}

private struct WidgetLargeControlStrip: View {
    var state: NinebotVehicleState

    var body: some View {
        HStack(spacing: 8) {
            WidgetLargeControlItem(
                title: state.isFullyCharged ? "已满" : (state.isCharging == true ? "充电" : "电源"),
                systemImage: state.isFullyCharged ? "battery.100" : (state.isCharging == true ? "bolt.fill" : "power"),
                accent: (state.isFullyCharged || state.isCharging == true) ? WidgetTheme.green : WidgetTheme.primaryText
            )
            WidgetLargeControlItem(title: "座桶", systemImage: "shippingbox.fill", accent: WidgetTheme.primaryText)
            WidgetLargeControlItem(title: "寻车", systemImage: "bell.fill", accent: WidgetTheme.primaryText)
        }
    }
}

private struct WidgetLargeControlItem: View {
    var title: String
    var systemImage: String
    var accent: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WidgetTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WidgetTheme.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct WidgetControlGrid: View {
    var state: NinebotVehicleState
    var padding: CGFloat = 18
    var spacing: CGFloat = 18
    var cornerRadius: CGFloat = 30
    var glyphSize: CGFloat = 34

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            spacing: spacing
        ) {
            WidgetControlGlyph(systemImage: state.isFullyCharged ? "battery.100" : (state.isCharging == true ? "bolt.fill" : "power"), size: glyphSize)
            WidgetControlGlyph(systemImage: "shippingbox.fill", size: glyphSize)
            WidgetControlGlyph(systemImage: "bell.fill", size: glyphSize)
        }
        .padding(padding)
        .background(WidgetTheme.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct WidgetControlGlyph: View {
    var systemImage: String
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: max(17, size * 0.68), weight: .semibold))
            .foregroundStyle(WidgetTheme.primaryText)
            .frame(width: size, height: size)
    }
}

private struct WidgetRoundControlIcon: View {
    var systemImage: String

    var body: some View {
        ZStack {
            Circle()
                .fill(WidgetTheme.cardBackground)
            Image(systemName: systemImage)
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(WidgetTheme.primaryText)
        }
    }
}

private struct WidgetVehicleImage: View {
    var imageData: Data?

    var body: some View {
        Group {
            if let imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
            } else {
                fallback
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fallback: some View {
        Image(systemName: "bicycle")
            .font(.system(size: 42, weight: .medium))
            .foregroundStyle(WidgetTheme.secondaryText.opacity(0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WidgetBatteryBar: View {
    var value: Double
    var isCharging: Bool
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(WidgetTheme.controlBackground)
                Capsule()
                    .fill(batteryAccent(isCharging: isCharging))
                    .frame(width: max(proxy.size.width * value, 8))
            }
        }
        .frame(height: height)
    }
}

private struct WidgetStatusLine: View {
    var state: NinebotVehicleState

    var body: some View {
        Label(widgetStatusText(state), systemImage: widgetStatusImage(state))
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor(state))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }
}

private struct WidgetStatusPill: View {
    var state: NinebotVehicleState

    var body: some View {
        Label(widgetStatusText(state), systemImage: widgetStatusImage(state))
            .font(.caption.weight(.semibold))
            .foregroundStyle(WidgetTheme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(WidgetTheme.controlBackground)
            .clipShape(Capsule())
    }
}

private struct WidgetInfoTile: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(WidgetTheme.secondaryText)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(WidgetTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(WidgetTheme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(WidgetTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private func batteryColor(_ value: Int?, isCharging: Bool = false) -> Color {
    if isCharging { return WidgetTheme.green }
    guard let value else { return .gray }
    if value < 15 { return .red }
    if value < 50 { return .orange }
    return WidgetTheme.green
}

private func healthColor(_ level: NinebotVehicleHealthLevel) -> Color {
    switch level {
    case .good:
        return WidgetTheme.green
    case .attention:
        return .orange
    case .critical:
        return .red
    case .charging:
        return WidgetTheme.green
    case .unknown:
        return .secondary
    }
}

private func statusColor(_ state: NinebotVehicleState) -> Color {
    healthColor(state.health.level)
}

private func batteryAccent(isCharging: Bool) -> Color {
    isCharging ? WidgetTheme.green : WidgetTheme.green
}

private func estimatedRangeText(_ state: NinebotVehicleState) -> String {
    "\(estimatedRangeShortText(state))(预估)"
}

private func estimatedRangeShortText(_ state: NinebotVehicleState) -> String {
    guard let mileage = state.localEstimatedMileage else { return "--km" }
    return "\(formatWidgetNumber(mileage, maximumFractionDigits: 0))km"
}

private func estimatedRangeDigits(_ state: NinebotVehicleState) -> String {
    guard let mileage = state.localEstimatedMileage else { return "--" }
    return formatWidgetNumber(mileage, maximumFractionDigits: 0)
}

private func formatWidgetNumber(_ value: Double, maximumFractionDigits: Int) -> String {
    let formatter = NumberFormatter()
    formatter.maximumFractionDigits = maximumFractionDigits
    formatter.minimumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

private func formatWidgetDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

private func formatWidgetTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func primaryWidgetStatus(_ state: NinebotVehicleState) -> String {
    state.health.message
}

private func compactWidgetStatus(_ state: NinebotVehicleState) -> String {
    if state.isFullyCharged {
        return "已充满"
    }
    if state.isCharging == true {
        return "充电 \(state.estimatedFullChargeTimeText)"
    }
    return state.health.title
}

private func accessoryRectangularText(_ snapshot: NinebotVehicleSnapshot?) -> String {
    guard let snapshot else { return "-- km · 未连接" }
    if snapshot.state.isFullyCharged {
        return "\(estimatedRangeText(snapshot.state)) · 已充满"
    }
    if snapshot.state.isCharging == true {
        return "充电中 · \(snapshot.state.estimatedFullChargeTimeText)充满"
    }
    return "\(estimatedRangeText(snapshot.state)) · \(widgetStatusText(snapshot.state))"
}

private func widgetStatusText(_ state: NinebotVehicleState) -> String {
    if state.isFullyCharged { return "已充满" }
    if state.isCharging == true { return "充电中" }
    if state.isPoweredOn == true { return "已上电" }
    if state.isLocked == true { return "已上锁" }
    if state.isLocked == false { return "未上锁" }
    return state.health.title
}

private func widgetStatusImage(_ state: NinebotVehicleState) -> String {
    if state.isFullyCharged { return "battery.100" }
    if state.isCharging == true { return "bolt.fill" }
    if state.isPoweredOn == true { return "power" }
    if state.isLocked == true { return "lock.fill" }
    if state.isLocked == false { return "lock.open.fill" }
    return state.health.systemImage
}

private func accessoryCircularPercentText(_ state: NinebotVehicleState?) -> String {
    guard let battery = state?.battery else { return "--" }
    return "\(battery)%"
}

private enum WidgetTheme {
    static let pageBackground = dynamic(
        light: UIColor(red: 0.945, green: 0.952, blue: 0.96, alpha: 1),
        dark: UIColor(red: 0.025, green: 0.029, blue: 0.035, alpha: 1)
    )
    static let cardBackground = dynamic(
        light: UIColor(red: 0.995, green: 0.995, blue: 1.0, alpha: 1),
        dark: UIColor(red: 0.075, green: 0.08, blue: 0.092, alpha: 1)
    )
    static let controlBackground = dynamic(
        light: UIColor(red: 0.91, green: 0.925, blue: 0.94, alpha: 1),
        dark: UIColor(red: 0.125, green: 0.135, blue: 0.152, alpha: 1)
    )
    static let smallVehicleBackground = dynamic(
        light: UIColor(red: 0.105, green: 0.108, blue: 0.112, alpha: 1),
        dark: UIColor(red: 0.045, green: 0.048, blue: 0.054, alpha: 1)
    )
    static let chargingActivityBackground = dynamic(
        light: UIColor(red: 0.91, green: 0.97, blue: 0.96, alpha: 1),
        dark: UIColor(red: 0.035, green: 0.045, blue: 0.055, alpha: 1)
    )
    static let primaryText = dynamic(
        light: UIColor(red: 0.055, green: 0.065, blue: 0.08, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.95, blue: 0.965, alpha: 1)
    )
    static let secondaryText = dynamic(
        light: UIColor(red: 0.42, green: 0.45, blue: 0.49, alpha: 1),
        dark: UIColor(red: 0.62, green: 0.65, blue: 0.69, alpha: 1)
    )
    static let green = dynamic(
        light: UIColor(red: 0.13, green: 0.82, blue: 0.28, alpha: 1),
        dark: UIColor(red: 0.20, green: 0.93, blue: 0.38, alpha: 1)
    )

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}
