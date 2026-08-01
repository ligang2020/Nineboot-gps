# NineBot+ Live Ride

NineBot+ Live Ride is a personal iOS app for viewing and managing Ninebot vehicle status. It includes refined vehicle cards, Home Screen / Lock Screen widgets, Siri shortcuts, official trip-detail route display, and an ActivityKit Live Activity designed for the Dynamic Island while riding.

This project is intended for personal builds. The bundled GitHub Action produces an **unsigned IPA**; it is not App Store or TestFlight distribution by itself.

## What is included

- Vehicle dashboard: battery, estimated range, locking / power status, location, trip history, mileage trends, and an official trip-detail route display with start/end markers and a maximum-speed label when the interface explicitly provides speed samples.
- Restored on-device **记录** tab: manually record a ride with GPS speed, G-force, route replay, and locally stored summaries. The record is associated with a vehicle only on the device.
- While charging, the dashboard shows distance driven since the last charge when supplied by the vehicle service (with a local history fallback).
- Home Screen and Lock Screen widgets; each widget can be configured for a particular vehicle.
- Dynamic Island / Live Activity for the active selected vehicle, including the Apple Watch Smart Stack charging view on supported systems.
- 3D charging energy animation in the app and vehicle-alarm notifications with an actionable “查看车辆” button.
- Siri Shortcuts and App Intents for vehicle actions.
- MapKit location and reverse-geocoded address display.
- Shared local cache through App Groups for the app and widget extension.
- Friendly vehicle names: the serial number `2PDAA2525A0414` is shown as **B2轰炸机**. Other vehicles can be renamed in **我的 → 车辆名称 → 编辑**.

## Live Activity charging display

### When it appears and ends

- **Start condition:** the selected vehicle is reported as **charging** and is not yet full. Refreshing in the app or running a vehicle shortcut synchronizes the Live Activity.
- **End condition:** the vehicle stops charging, reaches full charge, becomes unavailable, or another vehicle is selected. The activity is ended as soon as the updated state is saved.
- Only one selected vehicle has an active charging display at a time, so the Dynamic Island stays clear and focused.

### Information shown

- Battery percentage and a **0–100% charge progress bar**. Every increase in the returned battery percentage advances the bar.
- Battery voltage and battery temperature.
- Estimated remaining time until full charge, preferring the vehicle API's remaining-charge estimate when it is returned and otherwise using the app's charge-curve estimate.
- Charging power (when returned), update time, and compact / expanded Dynamic Island layouts plus an expanded Lock Screen Live Activity card.

### Apple Watch and in-app charging animation

- On **iOS 18 / watchOS 11 or later**, the charging activity opts into the Apple Watch Smart Stack supplemental activity family. Its wrist layout focuses on vehicle name, live battery ring, percentage, and remaining charge time.
- The in-app charging status card now uses a layered 3D energy orb: animated orbit rings, highlights, glow, and a floating charge bolt make an active charge session immediately recognizable.
- The Dynamic Island expanded header and Lock Screen title have extra top inset so the vehicle name (for example **B2轰炸机**) sits slightly lower and has more breathing room.

### Vehicle alarm notifications

1. In **我的 → 连接与通知**, tap **开启充电与报警通知** and allow notifications. The app registers the APNs token with NinePlus Platform.
2. Server-delivered vehicle alarms are handled with the `NINEBOT_VEHICLE_ALARM` category and include a **查看车辆** action. A silent alarm push is converted into a visible local notification; an APNs alert push is displayed by iOS directly to avoid duplicate banners.
3. During dashboard refreshes, the app also watches the raw status, battery, and trip payloads for active `alarm`, `alert`, `warn`, `fault`, `theft`, `security`, `vibration`, or `exception` fields. It notifies only when a signal first becomes active and re-arms it after the field clears.

> **Server integration:** for remote alarms while the app is not running, NinePlus Platform must send an APNs push with `category: "NINEBOT_VEHICLE_ALARM"` or an alarm-style `event` / `type` value (for example `vehicle_alarm`), plus either a normal `aps.alert` or `content-available: 1`. The app-side APNs registration and notification handling are included here; the platform server remains responsible for detecting and sending remote events.

### Background geofence and charging notifications

- App-side geofence edits are synchronized to NinePlus Platform through `POST /vehicles/{sn}/geofence`; deleting a fence calls `DELETE /vehicles/{sn}/geofence`.
- When the app is not open, geofence and charging notifications require the backend monitor plus APNs credentials on the server. The backend checks vehicle state periodically and sends APNs for charging started, charging disconnected, charging full, geofence entered, and geofence exited.
- Supported remote categories are `NINEBOT_CHARGING_STARTED`, `NINEBOT_CHARGING_INTERRUPTED`, `NINEBOT_CHARGING_FULL`, `NINEBOT_GEOFENCE_ENTERED`, and `NINEBOT_GEOFENCE_EXITED`. Alias values such as `charging_started`, `charging_disconnected`, and `geofence_exited` are normalized by the app.
- Required APNs environment variables on the platform are `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_BUNDLE_ID`, `APNS_AUTH_KEY` or `APNS_AUTH_KEY_PATH`, and `APNS_ENVIRONMENT`. The monitor interval can be tuned with `NINEPLUS_MONITOR_INTERVAL`; the default is 60 seconds.

### Refresh behaviour and iOS limitations

While the app is in the foreground it uses a lightweight vehicle-status refresh:

- **Charging:** every **5 seconds**
- **Not charging / idle:** every **8 seconds**

This refresh updates the dashboard and synchronizes the Live Activity, including battery progress, voltage, temperature, and estimated full-charge time. WidgetKit controls its own timeline budget, so widgets are intentionally reloaded no more often than roughly once per minute.

> **Important iOS limitation:** an ordinary iOS app cannot make a persistent 1–3 second network request while it is suspended or after it has been force-quit. It also cannot reliably learn that a vehicle has just started charging while the app has never been launched. To automatically start a Live Activity from a charging event when the app is not open, a server must implement **APNs + ActivityKit push-to-start / Live Activity update pushes**. The current project has local ActivityKit synchronization and normal device push registration, but it does not include that server-side push service.

## Build on a Mac

1. Open `mini-ninebot.xcodeproj` in Xcode.
2. Choose the same Apple development team for both `mini-ninebot` and `NinebotWidgets` targets.
3. Keep the paired App Group enabled on both targets: `group.com.ninebot.live.36K6L4C2YJ`.
4. Connect an iPhone, choose it as the run destination, then build and run.
5. In the app, configure the proxy endpoint and optional Bearer token, bind the account, and refresh once.

### Create a local unsigned IPA

From the repository root, run:

```bash
scripts/package-unsigned-ipa.sh
```

The command builds the device `Release` app, verifies the App Icon and widget extension, then writes a versioned IPA and its SHA-256 checksum to `build/ipa/`. The exact IPA path is printed after a successful build.

## Set up widgets

1. Long-press the Home Screen or Lock Screen and add a NineBot+ widget.
2. Long-press the widget and choose **编辑小组件**.
3. Select the vehicle to display. If no vehicle is selected, it follows the vehicle currently selected in the app.
4. Refresh the app after binding or renaming a vehicle so the shared App Group cache is populated.

A re-signed / sideloaded build can fail to show widgets if its app and widget extension do not retain the same signing team, bundle identifiers, and App Group entitlement. Verify those three items first if a widget does not appear or cannot list vehicles.

## GitHub Actions unsigned IPA

The workflow at `.github/workflows/build-ipa.yml` runs for pushes to `main` / `master`, version tags, or manual dispatch. It:

1. Builds the device app in `Release` with code signing disabled.
2. Packages the versioned `NinePlus-LiveRide-v<version>-unsigned.ipa`.
3. Verifies the compiled App Icon, main app bundle, and Widget extension before packaging.
4. Uploads the IPA and a SHA-256 checksum as a 30-day workflow artifact.
5. When the matching version tag is pushed (for example source version `1.2.57` with tag `v1.2.57`), creates or updates that GitHub Release and attaches both files. A manual run publishes the current source version by default.

Download the artifact from the GitHub Actions run, or open the GitHub Release for a version tag. Because it is unsigned, it still needs to be signed using your own permitted installation method before an iPhone can install it.

## Privacy

The app stores configuration, login state, vehicle snapshots, cached addresses, and API trip records on the device. It does not create background ride-route recordings or retain local GPS ride trajectories. Do not commit personal tokens, account data, signing certificates, provisioning profiles, or generated build artifacts to this repository.
