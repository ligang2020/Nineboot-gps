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
        NinebotRideLiveActivity()
        if #available(iOS 18.0, *) {
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

@available(iOS 16.1, *)
struct NinebotRideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NinebotRideActivityAttributes.self) { context in
            RideLiveActivityCard(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color(red: 0.018, green: 0.024, blue: 0.032))
                .activitySystemActionForegroundColor(WidgetTheme.green)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.vehicleName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Label("正在骑行", systemImage: "scooter")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(WidgetTheme.green)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.trailing, 7)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        RideIslandMetric(title: "速度", value: rideSpeedText(context.state.speedKmh))
                        RideIslandMetric(title: "电量", value: rideBatteryText(context.state.battery))
                        RideIslandMetric(title: "续航", value: rideRangeText(context.state.remainingRangeKm))
                        RideIslandMetric(title: "距离", value: rideDistanceText(context.state.distanceMeters))
                    }
                    .padding(.horizontal, 7)
                    .padding(.top, 6)
                }
            } compactLeading: {
                // Keep the compact presentation to a fixed icon. A live timer
                // in the trailing region makes the Dynamic Island expand into
                // an unnecessarily wide pill on the Home Screen.
                Image(systemName: "scooter")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(WidgetTheme.green)
                    .frame(width: 18, height: 18)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: "scooter")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(WidgetTheme.green)
            }
            .keylineTint(WidgetTheme.green)
        }
        .configurationDisplayName("九号骑行实况")
        .description("骑行时自动显示实时计时、速度、电量与距离。")
    }
}

@available(iOS 16.1, *)
private struct RideLiveActivityCard: View {
    var attributes: NinebotRideActivityAttributes
    var state: NinebotRideActivityContentState

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let isCompact = size.height < 126
            let horizontalPadding: CGFloat = isCompact ? 10 : 13

            ZStack {
                RideActivityPremiumBackground(size: size)

                VStack(spacing: isCompact ? 6 : 8) {
                    HStack(spacing: 7) {
                        RideStatusPill(text: "LIVE", icon: "dot.radiowaves.left.and.right")

                        Text(attributes.vehicleName)
                            .font(.system(size: isCompact ? 12 : 14, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        HStack(spacing: 4) {
                            Image(systemName: "timer")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(WidgetTheme.green)
                            Text(attributes.startedAt, style: .timer)
                                .font(.system(size: isCompact ? 11 : 13, weight: .black, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.075), in: Capsule())
                        .overlay { Capsule().stroke(.white.opacity(0.10), lineWidth: 0.6) }
                    }

                    HStack(alignment: .center, spacing: isCompact ? 7 : 9) {
                        RideActivitySpeedDial(speed: state.speedKmh, isCompact: isCompact)
                            .frame(width: min(size.width * (isCompact ? 0.36 : 0.38), CGFloat(isCompact ? 122 : 142)), height: isCompact ? 64 : 76)
                            .layoutPriority(2)

                        VStack(spacing: isCompact ? 5 : 6) {
                            RideActivityFlowMap(updatedAt: state.updatedAt, isCompact: isCompact)
                                .frame(height: isCompact ? 28 : 34)

                            HStack(spacing: 6) {
                                RideActivityMiniMetric(
                                    title: "剩余",
                                    value: rideRangeText(state.remainingRangeKm),
                                    icon: "road.lanes"
                                )
                                RideActivityMiniMetric(
                                    title: "本次",
                                    value: rideDistanceText(state.distanceMeters),
                                    icon: "point.3.connected.trianglepath.dotted"
                                )
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .layoutPriority(1)

                        RideActivityEnergyColumn(battery: state.battery, isCompact: isCompact)
                            .frame(width: isCompact ? 52 : 58)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, isCompact ? 7 : 10)
                .padding(.bottom, isCompact ? 7 : 10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.22), WidgetTheme.green.opacity(0.23), .white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
        }
        .frame(minHeight: 108, idealHeight: 126, maxHeight: 160)
    }
}

@available(iOS 16.1, *)
private struct RideActivitySpeedDial: View {
    var speed: Double?
    var isCompact: Bool

    private var normalizedSpeed: CGFloat {
        guard let speed, speed.isFinite else { return 0 }
        return CGFloat(min(max(speed / 40, 0), 1))
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.10, to: 0.90)
                .stroke(.white.opacity(0.10), style: StrokeStyle(lineWidth: isCompact ? 6 : 7, lineCap: .round))
                .rotationEffect(.degrees(108))

            Circle()
                .trim(from: 0.10, to: 0.10 + normalizedSpeed * 0.80)
                .stroke(
                    LinearGradient(
                        colors: [WidgetTheme.green, Color.cyan.opacity(0.90), .white.opacity(0.92)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: isCompact ? 6 : 7, lineCap: .round)
                )
                .rotationEffect(.degrees(108))
                .shadow(color: WidgetTheme.green.opacity(0.38), radius: 7)

            VStack(spacing: -1) {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(rideSpeedValue(speed))
                        .font(.system(size: isCompact ? 32 : 39, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                    Text("km/h")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.54))
                        .lineLimit(1)
                }
                Text("SPEED")
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(WidgetTheme.green.opacity(0.90))
            }
            .padding(.top, isCompact ? 5 : 7)
        }
        .accessibilityLabel("实时速度 \(rideSpeedText(speed))")
    }
}

@available(iOS 16.1, *)
private struct RideActivityFlowMap: View {
    var updatedAt: Date
    var isCompact: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.10), .white.opacity(0.035)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RideActivityRouteRibbon()
                    .stroke(
                        LinearGradient(colors: [WidgetTheme.green.opacity(0.18), WidgetTheme.green, Color.cyan.opacity(0.82)], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .shadow(color: WidgetTheme.green.opacity(0.25), radius: 5)

                HStack(spacing: 0) {
                    Circle()
                        .fill(WidgetTheme.green)
                        .frame(width: 5, height: 5)
                        .shadow(color: WidgetTheme.green.opacity(0.65), radius: 4)
                    Spacer()
                    Image(systemName: "location.north.line.fill")
                        .font(.system(size: isCompact ? 10 : 11, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: isCompact ? 20 : 22, height: isCompact ? 20 : 22)
                        .background(WidgetTheme.green.opacity(0.85), in: Circle())
                        .shadow(color: WidgetTheme.green.opacity(0.38), radius: 5)
                }
                .padding(.horizontal, 12)

                Text("更新 " + formatWidgetTime(updatedAt))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .position(x: size.width * 0.50, y: size.height - 8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.095), lineWidth: 0.7)
            }
        }
        .accessibilityLabel("骑行路线，" + "更新 " + formatWidgetTime(updatedAt))
    }
}

@available(iOS 16.1, *)
private struct RideActivityRouteRibbon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.20))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.24),
            control1: CGPoint(x: rect.minX + rect.width * 0.20, y: rect.maxY),
            control2: CGPoint(x: rect.minX + rect.width * 0.32, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY + rect.height * 0.10),
            control1: CGPoint(x: rect.minX + rect.width * 0.67, y: rect.maxY),
            control2: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.08)
        )
        return path
    }
}

@available(iOS 16.1, *)
private struct RideActivityEnergyColumn: View {
    var battery: Int?
    var isCompact: Bool

    private var fraction: Double {
        Double(min(max(battery ?? 0, 0), 100)) / 100
    }

    var body: some View {
        let columnHeight: CGFloat = isCompact ? 39 : 45

        VStack(spacing: isCompact ? 4 : 5) {
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(.white.opacity(0.10))
                Capsule()
                    .fill(
                        LinearGradient(colors: [WidgetTheme.green, Color.cyan.opacity(0.85)], startPoint: .bottom, endPoint: .top)
                    )
                    .frame(height: max(CGFloat(5), columnHeight * CGFloat(fraction)))
                    .shadow(color: WidgetTheme.green.opacity(0.35), radius: 5)
            }
            .frame(width: 12, height: columnHeight)
            .overlay { Capsule().stroke(.white.opacity(0.17), lineWidth: 0.7) }

            Text(rideBatteryText(battery))
                .font(.system(size: isCompact ? 10 : 11, weight: .black, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.70)

            Text("ENERGY")
                .font(.system(size: 7, weight: .black, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(WidgetTheme.green.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxHeight: .infinity)
        .padding(.vertical, isCompact ? 4 : 6)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(.white.opacity(0.09), lineWidth: 0.7) }
        .accessibilityLabel("电量 \(rideBatteryText(battery))")
    }
}

@available(iOS 16.1, *)
private struct RideActivityMiniMetric: View {
    var title: String
    var value: String
    var icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(WidgetTheme.green)
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 11, weight: .black, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 0.7) }
    }
}

@available(iOS 16.1, *)
private struct RideActivityPremiumBackground: View {
    var size: CGSize

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.010, green: 0.014, blue: 0.023),
                    Color(red: 0.022, green: 0.052, blue: 0.064),
                    Color(red: 0.009, green: 0.012, blue: 0.020)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(WidgetTheme.green.opacity(0.24))
                .frame(width: size.width * 0.54, height: size.width * 0.54)
                .blur(radius: 34)
                .offset(x: size.width * 0.35, y: -size.height * 0.48)

            Circle()
                .fill(Color.cyan.opacity(0.15))
                .frame(width: size.width * 0.42, height: size.width * 0.42)
                .blur(radius: 30)
                .offset(x: -size.width * 0.36, y: size.height * 0.30)

            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.clear, WidgetTheme.green.opacity(0.16 - Double(index) * 0.025), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: size.width * (0.42 + CGFloat(index) * 0.08), height: 1)
                    .rotationEffect(.degrees(-18))
                    .offset(x: -size.width * 0.18 + CGFloat(index) * size.width * 0.12, y: -size.height * 0.18 + CGFloat(index) * size.height * 0.18)
            }

            RideActivityRoad()
                .opacity(0.46)

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(0.18), WidgetTheme.green.opacity(0.10), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 0.7)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 7)
        }
    }
}

@available(iOS 16.1, *)
private struct RideStatusPill: View {
    var text: String
    var icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(WidgetTheme.green)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(WidgetTheme.green.opacity(0.13), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(WidgetTheme.green.opacity(0.28), lineWidth: 0.7)
            }
    }
}

@available(iOS 16.1, *)
private struct RideActivityVehicleArtwork: View {
    var body: some View {
        Image("RideScooter")
            .resizable()
            .scaledToFill()
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.24), lineWidth: 0.8)
            }
            .shadow(color: WidgetTheme.green.opacity(0.26), radius: 8)
    }
}

@available(iOS 16.1, *)
private struct RideActivityRoad: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, .black.opacity(0.40)], startPoint: .top, endPoint: .bottom))
                HStack(spacing: proxy.size.width * 0.095) {
                    ForEach(0..<5, id: \.self) { _ in
                        Capsule()
                            .fill(.white.opacity(0.42))
                            .frame(width: proxy.size.width * 0.095, height: 2)
                    }
                }
                .padding(.bottom, 13)
            }
        }
        .allowsHitTesting(false)
    }
}

@available(iOS 16.1, *)
private struct RideBatteryBadge: View {
    var battery: Int?

    private var fraction: Double {
        Double(min(max(battery ?? 0, 0), 100)) / 100
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.16), lineWidth: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(WidgetTheme.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: WidgetTheme.green.opacity(0.55), radius: 4)
            VStack(spacing: 0) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(rideBatteryText(battery))
                    .font(.caption2.monospacedDigit().weight(.bold))
            }
            .foregroundStyle(WidgetTheme.green)
        }
        .frame(width: 37, height: 37)
        .accessibilityLabel("电量 \(rideBatteryText(battery))")
    }
}

@available(iOS 16.1, *)
private struct RideActivityMetric: View {
    var value: String
    var title: String
    var icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.50))
            .lineLimit(1)

            Text(value)
                .font(.system(size: 13, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.96))
                .lineLimit(1)
                .minimumScaleFactor(0.58)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            LinearGradient(
                colors: [.white.opacity(0.105), .white.opacity(0.045)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 0.7)
        }
    }
}

@available(iOS 16.1, *)
private struct RideIslandMetric: View {
    var title: String
    var value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.48))
        }
        .frame(maxWidth: .infinity)
    }
}

@available(iOS 16.1, *)
private func rideSpeedValue(_ speed: Double?) -> String {
    guard let speed, speed.isFinite, speed >= 0 else { return "--" }
    return String(format: "%.0f", speed)
}

@available(iOS 16.1, *)
private func rideSpeedText(_ speed: Double?) -> String {
    guard let speed, speed.isFinite, speed >= 0 else { return "-- km/h" }
    return String(format: "%.0f km/h", speed)
}

@available(iOS 16.1, *)
private func rideBatteryText(_ battery: Int?) -> String {
    guard let battery else { return "--%" }
    return "\(min(max(battery, 0), 100))%"
}

@available(iOS 16.1, *)
private func rideRangeText(_ rangeKilometers: Double?) -> String {
    guard let rangeKilometers, rangeKilometers.isFinite, rangeKilometers >= 0 else { return "-- km" }
    return String(format: "%.0f km", rangeKilometers)
}

@available(iOS 16.1, *)
private func rideDistanceText(_ distanceMeters: Double?) -> String {
    guard let distanceMeters, distanceMeters.isFinite, distanceMeters >= 0 else { return "-- km" }
    if distanceMeters < 1_000 {
        return String(format: "%.0f m", distanceMeters)
    }
    return String(format: "%.2f km", distanceMeters / 1_000)
}

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
