# Beacon — APRS for iPhone

Beacon is a modern, map-first APRS-IS client for iOS. The initial milestone focuses on reliable location beaconing, a clear connection state, nearby station display, and a settings experience that keeps protocol details out of the main workflow.

## Project structure

- `Beacon/App` — app entry point and shared observable state
- `Beacon/Features` — dashboard, station detail, and settings screens
- `Beacon/Models` — source-agnostic station and beacon models
- `Beacon/Services/APRS` — APRS packet formatting, parsing, and APRS-IS transport
- `Beacon/Services/Beaconing` — smart-beacon timing policy
- `Beacon/Services/Location` — Core Location and background update lifecycle

## First implementation slice

- SwiftUI dashboard with MapKit, current position, nearby APRS stations, and a recent trail
- Prominent beaconing on/off control with last/next beacon status
- Station detail sheet
- APRS identity, beaconing, display, and advanced server settings
- APRS-IS TCP connection and TNC2 packet transmission
- Incoming uncompressed APRS position parsing
- Background location configuration
- Speed- and turn-aware SmartBeaconing policy

## Running

Open `Beacon.xcodeproj` in Xcode 16 or newer and select an iOS 17+ simulator or device. Set a unique bundle identifier and Development Team before running on a device.

Location data is simulated in SwiftUI previews and when the app has not yet received a GPS fix. APRS transmission requires a callsign and passcode in Settings.

## APRS symbol artwork

The bundled symbol sprites are from the [aprs.fi high-resolution APRS symbol set](https://github.com/hessu/aprs-symbols) by Heikki Hannikainen, OH7LZB. The set is provided for free use by APRS applications and is compatible with the updated APRS Symbol Set (Rev H). Per-symbol copyright and attribution details are bundled in `Beacon/Resources/APRS-SYMBOLS-COPYRIGHT.md`.
