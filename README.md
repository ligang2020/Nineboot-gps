# NineBot+

NineBot+ is a personal iOS app for viewing and managing Ninebot vehicle status, with Home Screen widgets, Lock Screen widgets, Siri Shortcuts, trip history, location views, and local ride recording.

This project is intended for personal builds. It is not configured for App Store distribution by default.

## Features

- Vehicle dashboard with battery, estimated range, status, charging state, and location.
- Home Screen and Lock Screen widgets.
- Siri Shortcuts and App Intents support.
- Trip history, mileage trends, and local ride recording.
- MapKit vehicle location and reverse geocoding.
- Local cache shared between the app and widgets through App Groups.

## Requirements

- macOS with Xcode.
- An Apple Developer account for device signing.
- A configured iOS device.
- A compatible vehicle API proxy endpoint reachable from the iPhone.

## Build

1. Clone the repository.
2. Open `mini-ninebot.xcodeproj` in Xcode.
3. The project is already configured for the signed-in team and uses automatic signing. Keep the same team selected for the app and `NinebotWidgets` targets.
4. Keep the paired App Group enabled on both targets: `group.com.ninebot.live.36K6L4C2YJ`.
5. Build and run on a physical iPhone.

## Setup

1. Open the app on the iPhone.
2. Go to the profile/settings tab.
3. Enter your proxy endpoint and optional Bearer Token.
4. Bind your account.
5. Return to the vehicle dashboard and refresh.
6. Add the Home Screen or Lock Screen widgets after the first successful refresh.

## Widgets

Widgets read the latest cached vehicle snapshot from the shared App Group container. iOS controls widget background refresh frequency, so opening the app and refreshing manually is the fastest way to update widget data immediately.

## Privacy

The app stores configuration, login state, vehicle snapshots, cached addresses, trip records, and local ride records on the device. Do not commit personal tokens, account data, signing certificates, provisioning profiles, or generated build artifacts to this repository.

## 灵动岛骑行实况（NineBot Live）

- **上岛条件**：当前选中的车辆状态为“未上锁”。在 App 内刷新车况、执行“上电”控制或运行相应快捷指令后，App 会创建或刷新实时活动。
- **下岛条件**：车辆状态返回“已上锁”（包括 App 内熄火/锁车后刷新），实时活动会立即结束。
- **展示内容**：车辆名称、锁/上电状态、电量与续航、速度、最近一程用电量、单公里能耗和更新时间。接口返回即时速度时优先显示；否则显示最近一程的速度数据。
- **小组件**：添加到主屏或锁屏后，长按小组件选择“编辑小组件”，即可指定要显示的车辆；未指定时跟随 App 当前车辆。每个已配置小组件是独立的车辆仪表。

> 这是一个独立副本，默认 Bundle ID 为 `com.ninebot.live.36K6L4C2YJ`，默认 App Group 为 `group.com.ninebot.live.36K6L4C2YJ`。首次在 Xcode 中打开后，请为 App 和 Widget Extension 选择同一开发团队，并在两者中创建/启用相同的 App Group。
