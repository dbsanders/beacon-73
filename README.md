# Beacon 73 — APRS for iPhone and iPad

Beacon 73 is a SwiftUI APRS-IS client for viewing nearby amateur-radio stations and sharing your position over an internet connection. It supports automatic and manual beaconing, a map-first dashboard, and Live Activity status on the Lock Screen and supported iPhones’ Dynamic Island.

App Store release source is tagged by version, including `appstore/1.3.0`, `appstore/1.2.0`, `appstore/1.1.1`, and `appstore/1.1`.

## Features

- Adaptive home-screen map with a shared map and beacon-control card, plus last/next beacon status.
- Full-screen map on tap and a map-only home screen in landscape. Tap a station on either map to see its details, then tap Done to return to the map.
- Nearby station symbols and call signs that adapt to overlap on screen: full labels where space permits, icons where labels crowd, and dots where icons overlap too much.
- Stations list sorted by last heard (newest first), station details, and filters for moving, fixed, and weather stations. Live stations expire from the list and map after 35 minutes without a decoded position update, even when no new packets arrive. Expiration is checked every second while the app is active and when returning to the foreground.
- Track map showing the most recent 30 successfully transmitted positions for the current app session.
- Smart, Timed, and Manual beaconing modes.
- Live Activity showing callsign, connection status, and last/next beacon timing while beaconing is active.
- APRS symbol selection, custom beacon messages, receive radius, and connection diagnostics.
- APRS-IS TCP transport, TNC2 position transmission, and parsing of uncompressed, compressed, and Mic-E positions.
- Demo Mode with simulated stations and transmission disabled.
- Light and Dark themes under Settings → Appearance. Changes apply immediately and are remembered across launches; Dark remains the default.
- English and Simplified Chinese are bundled with the app. iOS picks a supported language from the device's preferences, and users can also choose a language for Beacon 73 in iOS Settings.
- Privacy, support, and optional one-time App Store contribution links near the bottom of Settings.

Settings → Units provides one Miles/Kilometers choice for displayed distances and speeds (mph/km/h). Existing distance preferences are preserved when upgrading. The station receive radius offers 1, 5, and then 10 through 100 in steps of 10, in miles or kilometers. Changing units snaps the converted radius to the nearest allowed value (ties round up), and older saved radii are normalized the same way. APRS-IS receives the selected radius converted to whole kilometers. Leaving Settings applies the final radius with a filter update on the existing connection; callsign/passcode or server host/port changes still reconnect. Changes made while connecting are queued, and connection recovery uses the latest filter.

## Beacon controls

The round power button handles both automatic and manual beaconing:

| Mode | Tap | Hold |
| --- | --- | --- |
| Smart or Timed | Toggle automatic beaconing | Send a manual beacon, whether automatic beaconing is on or off |
| Manual | Send a manual beacon | Send a manual beacon |

The icon is orange when automatic beaconing is off and green with a pulsing ring when it is on. A successful transmission also turns the icon green and shows an outward pulse during the two-second **APRS TX** indication. Taps that toggle automatic beaconing use light haptic feedback; accepted manual-beacon requests use a heavy haptic on supported devices.

Manual transmissions have a **10-second minimum interval**, measured from the last successful transmission, with a cooldown after a manual attempt. Automatic transmissions have a **30-second minimum interval**, including heading changes and restarting beaconing. Overlapping send requests are prevented. Automatic beaconing is not restored after the app process ends.

Callsign setup remains available without location access, but manual and automatic beaconing require location permission. Denying or revoking access stops auto-beaconing, clears its next-beacon timer and cached GPS position, disables background location updates, and dismisses the Live Activity. After restoring permission in iOS Settings, turn auto-beaconing on again explicitly. Settings → iOS Permissions shows both Location Permission and Live Activities status, offers the initial location permission request until a choice has been made, then provides an **Open iOS Settings** button to manage access.

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

Live transmission requires your amateur-radio callsign, a valid APRS-IS passcode, a GPS position, and a verified APRS-IS connection. Settings includes a passcode-request flow with informational U.S. FCC and Canadian ISED callsign lookups. Grant **While Using the App** location access. Starting auto-beaconing enables background location updates so the session can continue while the screen is locked or another app is open; existing **Always** permission also works. Beacon 73 does not request an upgrade to Always. Automatic location pausing is disabled during auto-beaconing so stationary sessions can continue, which uses more battery. Stopping auto-beaconing disables background tracking; foreground map updates remain available. Demo positions and the map’s fallback center are not transmitted.

Use a physical iPhone to evaluate haptics, background location, and Lock Screen/Dynamic Island behavior. The simulator can be used for UI work and simulated location testing.

To preview Simplified Chinese, edit the Beacon run scheme and select **Chinese (Simplified)** under **Run → Options → App Language**. The app and Live Activity have their own `Localizable.xcstrings` catalogs. The system location prompt is in `Beacon/Resources/InfoPlist.xcstrings`, and the App Store listing copy is in [app-store/metadata.zh-Hans.md](app-store/metadata.zh-Hans.md).

The optional contribution sheet loads three consumable StoreKit products: `com.cybersand.beacon73.tip.small`, `com.cybersand.beacon73.tip.medium`, and `com.cybersand.beacon73.tip.large`. Those products must exist in App Store Connect (or a local StoreKit test configuration) before tip options appear.

## Tests

Run **Product → Test** in Xcode with the Beacon scheme and an iOS simulator selected, or use:

```sh
xcodebuild test \
  -project Beacon.xcodeproj \
  -scheme Beacon \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Replace the destination with a simulator installed on your Mac. Tests cover APRS formatting and parsing, identity/passcode handling, beacon timing and cooldowns, location permission and background-update lifecycle, adaptive dashboard sizing, and station-marker overlap decisions.

For background beaconing, test on a physical iPhone with **While Using the App** permission: start Timed mode at 30 seconds, lock the screen, and verify multiple successful transmissions while stationary and while moving. Confirm the Live Activity advances its last/next times. Stop beaconing and verify background location use ends; revoke location access during a session and verify beaconing and the Live Activity stop. Simulator tests verify configuration and state transitions, not iOS background execution or APRS-IS delivery.

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
- `beaconwatch` — privacy-minimized APRS-IS receiver and station map for `k6bat.com/beaconwatch`
- `infra/passcode-api` — passcode service and deployment infrastructure; see its [README](infra/passcode-api/README.md)

## Release bookkeeping

The app’s Version and Build fields come from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project. Beacon and BeaconLiveActivity are synchronized at version 1.3.1, build 1. The `appstore/1.1.1` source includes the extension version correction made after the initial 1.1.1 archive was created; that archive is not an exact build of that tag. The `appstore/1.2.0` tag identifies the 1.2.0 release source. Earlier submitted release tags remain unchanged.

Release tags identify submitted source snapshots. Documentation updates after submission do not move those tags.

## APRS symbol artwork

The bundled symbol sprites are from the [aprs.fi high-resolution APRS symbol set](https://github.com/hessu/aprs-symbols) by Heikki Hannikainen, OH7LZB. The set is provided for free use by APRS applications and is compatible with the updated APRS Symbol Set (Rev H). Per-symbol copyright and attribution details are bundled in `Beacon/Resources/APRS-SYMBOLS-COPYRIGHT.md`.
