# NineBot+ Live Ride

NineBot+ Live Ride is a personal iOS app for viewing and managing Ninebot vehicle status. It includes refined vehicle cards, Home Screen / Lock Screen widgets, Siri shortcuts, local ride recording, and an ActivityKit Live Activity designed for the Dynamic Island while riding.

This project is intended for personal builds. The bundled GitHub Action produces an **unsigned IPA**; it is not App Store or TestFlight distribution by itself.

## What is included

- Vehicle dashboard: battery, estimated range, locking / power status, location, trip history, mileage trends, and local ride recording.
- Home Screen and Lock Screen widgets; each widget can be configured for a particular vehicle.
- Dynamic Island / Live Activity for the active selected vehicle.
- Siri Shortcuts and App Intents for vehicle actions.
- MapKit location and reverse-geocoded address display.
- Shared local cache through App Groups for the app and widget extension.
- Friendly vehicle names: the serial number `2PDAA2525A0414` is shown as **B2轰炸机**. Other vehicles can be renamed in **我的 → 车辆名称 → 编辑**.

## Live Activity riding display

### When it appears and ends

- **Start condition:** the selected vehicle is reported as **unlocked**. Refreshing in the app, powering on, or running the related shortcut synchronizes the Live Activity.
- **End condition:** the vehicle is reported as **locked**. The activity is ended as soon as the app receives and saves that state.
- Only one selected vehicle has an active ride display at a time, so the Island stays clear and focused.

### Information shown

- Speed in **km/h**
- Battery percentage, estimated range, and **battery temperature**
- Ride electricity used and energy consumption per kilometre
- GPS address or coordinates when returned by the vehicle API
- Continuous ride timer, distance, electricity used, average energy consumption, and battery temperature
- A calm adaptive distance-progress bar: its target grows with the ride rather than showing fixed, confusing segments
- Compact and expanded Dynamic Island layouts, plus an expanded Lock Screen Live Activity card

### Refresh behaviour and iOS limitations

While the app is in the foreground it uses a lightweight vehicle-status refresh:

- **Unlocked / riding:** every **5 seconds**
- **Locked / idle:** every **8 seconds**

This refresh updates the dashboard and synchronizes the Live Activity, including battery, speed, temperature, GPS, and ride progress. WidgetKit controls its own timeline budget, so widgets are intentionally reloaded no more often than roughly once per minute.

> **Important iOS limitation:** an ordinary iOS app cannot make a persistent 1–3 second network request while it is suspended or after it has been force-quit. It also cannot reliably learn that a vehicle was just unlocked while the app has never been launched. To automatically start a Live Activity from a vehicle unlock when the app is not open, a server must implement **APNs + ActivityKit push-to-start / Live Activity update pushes**. The current project has local ActivityKit synchronization and normal device push registration, but it does not include that server-side push service.

## Build on a Mac

1. Open `mini-ninebot.xcodeproj` in Xcode.
2. Choose the same Apple development team for both `mini-ninebot` and `NinebotWidgets` targets.
3. Keep the paired App Group enabled on both targets: `group.com.ninebot.live.36K6L4C2YJ`.
4. Connect an iPhone, choose it as the run destination, then build and run.
5. In the app, configure the proxy endpoint and optional Bearer token, bind the account, and refresh once.

## Set up widgets

1. Long-press the Home Screen or Lock Screen and add a NineBot+ widget.
2. Long-press the widget and choose **编辑小组件**.
3. Select the vehicle to display. If no vehicle is selected, it follows the vehicle currently selected in the app.
4. Refresh the app after binding or renaming a vehicle so the shared App Group cache is populated.

A re-signed / sideloaded build can fail to show widgets if its app and widget extension do not retain the same signing team, bundle identifiers, and App Group entitlement. Verify those three items first if a widget does not appear or cannot list vehicles.

## GitHub Actions unsigned IPA

The workflow at `.github/workflows/build-ipa.yml` runs for pushes to `main` / `master`, version tags, or manual dispatch. It:

1. Builds the device app in `Release` with code signing disabled.
2. Packages `NinePlus-LiveRide-unsigned.ipa`.
3. Verifies the compiled App Icon, main app bundle, and Widget extension before packaging.
4. Uploads the IPA and a SHA-256 checksum as a 30-day workflow artifact.
5. When a tag beginning with `v` is pushed (for example `v1.2.1`), creates or updates the matching GitHub Release and attaches both files.

Download the artifact from the GitHub Actions run, or open the GitHub Release for a version tag. Because it is unsigned, it still needs to be signed using your own permitted installation method before an iPhone can install it.

## Privacy

The app stores configuration, login state, vehicle snapshots, cached addresses, trip records, and local ride records on the device. Do not commit personal tokens, account data, signing certificates, provisioning profiles, or generated build artifacts to this repository.
