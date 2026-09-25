# Beacon 73 — APRS for iPhone and iPad

Beacon 73 is a SwiftUI APRS-IS client for viewing nearby amateur-radio stations and sharing your position over an internet connection. It supports automatic and manual beaconing, a map-first dashboard, and Live Activity status on the Lock Screen and supported iPhones’ Dynamic Island.

Version **1.1** has been submitted for App Store review. The submitted source snapshot is tagged `appstore/1.1`.

## Features

- Adaptive home-screen map with a shared map and beacon-control card, plus last/next beacon status.
- Full-screen map on tap and a map-only home screen in landscape.
- Nearby station symbols and call signs that adapt to overlap on screen: full labels where space permits, icons where labels crowd, and dots where icons overlap too much.
- Stations list, station details, and filters for moving, fixed, and weather stations.
- Track map showing the most recent 30 successfully transmitted positions for the current app session.
- Smart, Timed, and Manual beaconing modes.
- Live Activity showing callsign, connection status, and last/next beacon timing while beaconing is active.
- APRS symbol selection, custom beacon messages, receive radius, and connection diagnostics.
- APRS-IS TCP transport, TNC2 position transmission, and parsing of uncompressed, compressed, and Mic-E positions.
- Demo Mode with simulated stations and transmission disabled.

## Beacon controls

The round power button handles both automatic and manual beaconing:

| Mode | Tap | Hold |
| --- | --- | --- |
| Smart or Timed | Toggle automatic beaconing | Send a manual beacon, whether automatic beaconing is on or off |
| Manual | Send a manual beacon | Send a manual beacon |

The icon is orange when automatic beaconing is off and green with a pulsing ring when it is on. A successful transmission also turns the icon green and shows an outward pulse during the two-second **APRS TX** indication. Taps that toggle automatic beaconing use light haptic feedback; accepted manual-beacon requests use a heavy haptic on supported devices.

Manual transmissions have a **10-second minimum interval**, measured from the last successful transmission, with a cooldown after a manual attempt. Automatic transmissions have a **30-second minimum interval**, including heading changes and restarting beaconing. Overlapping send requests are prevented. Automatic beaconing is not restored after the app process ends.

### Timing

- **Smart:** With the default configuration, speeds below 1 m/s use a 15-minute interval. From 1 to 26.8 m/s (about 60 mph), the interval decreases linearly toward 30 seconds using `180 − (speed / 26.8) × 150`. At or above 26.8 m/s, it is 30 seconds. A heading change of at least 25° can trigger an earlier beacon when moving faster than 2 m/s, subject to the 30-second minimum.
- **Timed:** Uses the interval selected in Settings, from 30 seconds to 30 minutes; the default is 120 seconds.
- **Manual:** Sends only when requested with the beacon button.

Smart timing is recalculated from the latest location and last successful transmission, so the next-beacon countdown can change as speed or heading changes.

## Running locally

1. Open `Beacon.xcodeproj` in Xcode and select the **Beacon** scheme.
2. Choose an iOS/iPadOS 17+ simulator or device. The project uses Swift 6; use Xcode 16 or newer.
3. For a physical device, configure your Development Team for both **Beacon** and **BeaconLiveActivity**. If using different bundle identifiers, keep the extension identifier under the app’s identifier.
4. Build and run. Choose **Explore Demo** to browse simulated stations, or **Set Up My Callsign** for live use.

Live transmission requires your amateur-radio callsign, a valid APRS-IS passcode, a GPS position, and a verified APRS-IS connection. Settings includes a passcode-request flow with an FCC callsign lookup. Grant location access; background beaconing uses **Always** location permission. Demo positions and the map’s fallback center are not transmitted.

Use a physical iPhone to evaluate haptics, background location, and Lock Screen/Dynamic Island behavior. The simulator can be used for UI work and simulated location testing.

## Tests

Run **Product → Test** in Xcode with the Beacon scheme and an iOS simulator selected, or use:

```sh
xcodebuild test \
  -project Beacon.xcodeproj \
  -scheme Beacon \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Replace the destination with a simulator installed on your Mac. Tests cover APRS formatting and parsing, identity/passcode handling, beacon timing and cooldowns, adaptive dashboard sizing, and station-marker overlap decisions.

## Project structure

- `Beacon/App` — app entry point and shared observable state
- `Beacon/Features` — home dashboard, stations, track, onboarding, and settings
- `Beacon/Models` — settings and station models
- `Beacon/Services/APRS` — APRS formatting, parsing, passcode requests, and APRS-IS transport
- `Beacon/Services/Beaconing` — timing policy and Live Activity management
- `Beacon/Services/Location` — Core Location and background update lifecycle
- `BeaconLiveActivity` — Lock Screen and Dynamic Island presentation
- `BeaconTests` — automated tests
- `website` — public landing, support, and privacy pages
- `infra/passcode-api` — passcode service and deployment infrastructure; see its [README](infra/passcode-api/README.md)

## Release bookkeeping

The app’s Version and Build fields come from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project. For future release preparation, keep these values synchronized across Beacon and BeaconLiveActivity. The `appstore/1.1` snapshot preserves the archived configuration, including the extension’s older version value; align that value before the next upload.

Release tags identify submitted source snapshots. Documentation updates after submission do not move those tags.

## APRS symbol artwork

The bundled symbol sprites are from the [aprs.fi high-resolution APRS symbol set](https://github.com/hessu/aprs-symbols) by Heikki Hannikainen, OH7LZB. The set is provided for free use by APRS applications and is compatible with the updated APRS Symbol Set (Rev H). Per-symbol copyright and attribution details are bundled in `Beacon/Resources/APRS-SYMBOLS-COPYRIGHT.md`.
