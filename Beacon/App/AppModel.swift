import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    static let beaconNowCooldown: TimeInterval = 10

    struct APRSDiagnosticEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let isConnectionEvent: Bool
    }

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(verified: Bool)
        case unverified
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: "Offline"
            case .connecting: "Connecting"
            case .connected(true): "Connected · Ready"
            case .connected(false): "Connected · Verifying"
            case .unverified: "Invalid APRS-IS passcode"
            case .failed: "Connection issue"
            }
        }

        var shortLabel: String {
            switch self {
            case .disconnected: "Offline"
            case .connecting: "Connecting"
            case .connected, .unverified: "Online"
            case .failed: "Issue"
            }
        }

        var isConnected: Bool {
            switch self {
            case .connected, .unverified: true
            default: false
            }
        }
    }

    var settings = AppSettings.load()
    var connectionState: ConnectionState = .disconnected
    var isBeaconing = false
    var lastBeaconAt: Date?
    var nextBeaconAt: Date?
    var lastBeaconError: String?
    var beaconAlertMessage: String?
    var stations: [APRSStation] = []
    var receivedPacketCount = 0
    var unsupportedPacketCount = 0
    var lastPacketAt: Date?
    var lastStreamActivityAt: Date?
    var aprsDiagnosticEntries: [APRSDiagnosticEntry] = []
    var trail: [CLLocationCoordinate2D] = []
    var selectedStation: APRSStation?

    var stationsWithinRadius: [APRSStation] {
        guard let currentLocation = locationService.currentLocation else { return stations }
        let radiusMeters = Double(settings.server.filterRadiusKilometers) * 1_000
        return stations.filter { station in
            let stationLocation = CLLocation(
                latitude: station.coordinate.latitude,
                longitude: station.coordinate.longitude
            )
            return currentLocation.distance(from: stationLocation) <= radiusMeters
        }
    }

    var nearbyStations: [APRSStation] {
        stationsWithinRadius.filter(settings.display.shows)
    }

    var hiddenNearbyStationCount: Int {
        stationsWithinRadius.count - nearbyStations.count
    }

    var isAPRSISPasscodeValid: Bool {
        settings.identity.isReady && APRSISClient.passcode(
            settings.identity.passcode,
            isValidFor: settings.identity.fullCallsign
        )
    }

    var invalidPasscodeMessage: String {
        "The APRS-IS passcode does not match \(settings.identity.fullCallsign). Check the call sign and passcode in Settings. Receiving remains available, but transmitting is disabled."
    }

    let locationService = LocationService()
    private let smartBeaconing = SmartBeaconingPolicy()
    private var client: APRSISClient?
    private var clientIdentity: AppSettings.Identity?
    private var clientServer: AppSettings.Server?
    private var beaconTask: Task<Void, Never>?
    private var lastBeaconLocation: CLLocation?
    private var lastManualBeaconAttemptAt: Date?

    init() {
        locationService.onLocation = { [weak self] location in
            Task { @MainActor in
                await self?.received(location)
            }
        }
    }

    func startBeaconing() async {
        guard settings.identity.isReady else {
            let message = "Add your amateur call sign and APRS-IS passcode in Settings."
            lastBeaconError = message
            beaconAlertMessage = message
            return
        }
        guard isAPRSISPasscodeValid else {
            disableTransmittingForInvalidPasscode()
            return
        }

        lastBeaconError = nil
        isBeaconing = true
        locationService.start(background: true)
        await startReceiving()
        scheduleStatusRefresh()

        if let location = locationService.currentLocation {
            await sendBeacon(at: location)
        }
    }

    func stopBeaconing() async {
        isBeaconing = false
        nextBeaconAt = nil
        beaconTask?.cancel()
        beaconTask = nil
        locationService.stop()
        locationService.start(background: false)
        await startReceiving()
    }

    func toggleBeaconing() async {
        if isBeaconing { await stopBeaconing() } else { await startBeaconing() }
    }

    func beaconNow() async {
        beaconAlertMessage = nil
        guard settings.identity.isReady else {
            beaconAlertMessage = "Add your amateur call sign and APRS-IS passcode in Settings first."
            return
        }
        guard isAPRSISPasscodeValid else {
            disableTransmittingForInvalidPasscode()
            return
        }

        locationService.start(background: isBeaconing)
        await startReceiving()
        guard let location = locationService.currentLocation else {
            beaconAlertMessage = "Waiting for a GPS position. Try again when GPS accuracy appears."
            return
        }

        let now = Date()
        guard beaconNowCooldownRemaining(at: now) == 0 else { return }
        lastManualBeaconAttemptAt = now

        await sendBeacon(at: location)
        if let lastBeaconError {
            beaconAlertMessage = lastBeaconError
        }
    }

    func beaconNowCooldownRemaining(at now: Date = .now) -> Int {
        Self.beaconNowCooldownRemaining(
            lastBeaconAt: lastBeaconAt,
            lastManualAttemptAt: lastManualBeaconAttemptAt,
            now: now
        )
    }

    static func beaconNowCooldownRemaining(
        lastBeaconAt: Date?,
        lastManualAttemptAt: Date?,
        now: Date
    ) -> Int {
        let mostRecent = [lastBeaconAt, lastManualAttemptAt].compactMap { $0 }.max()
        guard let mostRecent else { return 0 }
        return max(0, Int(ceil(beaconNowCooldown - now.timeIntervalSince(mostRecent))))
    }

    func saveSettings() {
        settings.save()
        if settings.identity.isReady, !isAPRSISPasscodeValid {
            disableTransmittingForInvalidPasscode()
        }
    }

    func startReceiving() async {
        guard settings.identity.isReady else { return }
        guard let location = locationService.currentLocation else { return }
        if let existingClient = client,
           clientIdentity != settings.identity || clientServer != settings.server {
            client = nil
            await existingClient.disconnect()
            connectionState = .disconnected
        }
        await connectIfNeeded()
        try? await client?.updateFilter(
            center: location.coordinate,
            radiusKilometers: settings.server.filterRadiusKilometers
        )
    }

    func appDidEnterBackground() async {
        guard !isBeaconing else { return }

        locationService.stop()
        let previousClient = client
        client = nil
        if let previousClient {
            await previousClient.disconnect()
        }
        connectionState = .disconnected
        recordDiagnostic(
            "Background activity stopped because auto-beaconing is off",
            isConnectionEvent: true
        )
    }

    func appDidBecomeActive() async {
        locationService.start(background: isBeaconing)
        await startReceiving()
    }

    func reconnectAPRSIS() async {
        recordDiagnostic("Manual reconnect requested", isConnectionEvent: true)
        let previousClient = client
        client = nil
        if let previousClient {
            await previousClient.disconnect()
        }
        connectionState = .disconnected
        await startReceiving()
    }

    func clearAPRSDiagnostics() {
        aprsDiagnosticEntries.removeAll()
    }

    var aprsDiagnosticReport: String {
        let header = [
            "Beacon 73 APRS-IS Diagnostics",
            "Status: \(connectionState.diagnosticLabel)",
            "Server: \(settings.server.host):\(settings.server.port)",
            "Filter: \(aprsFilterDescription)",
            "Packets: \(receivedPacketCount) received, \(stations.count) decoded stations, \(unsupportedPacketCount) unsupported",
            "Display: \(nearbyStations.count) visible, \(hiddenNearbyStationCount) hidden by station-type filters",
            ""
        ]
        let formatter = ISO8601DateFormatter()
        let lines = aprsDiagnosticEntries.map {
            "\(formatter.string(from: $0.timestamp)) \($0.message)"
        }
        return (header + lines).joined(separator: "\n")
    }

    var aprsFilterDescription: String {
        guard let coordinate = locationService.currentLocation?.coordinate else {
            return "Waiting for GPS"
        }
        return String(
            format: "r/%.5f/%.5f/%d km",
            coordinate.latitude,
            coordinate.longitude,
            settings.server.filterRadiusKilometers
        )
    }

    private func connectIfNeeded() async {
        guard client == nil else { return }
        connectionState = .connecting

        let configuration = settings
        let newClient = APRSISClient(
            configuration: configuration,
            filterCenter: locationService.currentLocation?.coordinate
        )
        client = newClient
        clientIdentity = configuration.identity
        clientServer = configuration.server
        newClient.onPacket = { [weak self] line in
            let station = APRSParser.station(from: line)
            Task { @MainActor in
                guard let self, !line.isEmpty else { return }
                self.lastStreamActivityAt = .now
                self.recordDiagnostic("← \(line)")
                guard !line.hasPrefix("#") else { return }
                self.receivedPacketCount += 1
                self.lastPacketAt = .now
                if let station {
                    self.upsert(station)
                } else {
                    self.unsupportedPacketCount += 1
                }
            }
        }
        newClient.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                let stateChanged = self.connectionState != state
                self.connectionState = state
                if stateChanged {
                    self.recordDiagnostic("Connection: \(state.diagnosticLabel)", isConnectionEvent: true)
                }
                if state == .unverified {
                    self.disableTransmittingForInvalidPasscode()
                }
            }
        }
        newClient.onDiagnostic = { [weak self] message in
            Task { @MainActor in
                self?.recordDiagnostic(message, isConnectionEvent: true)
            }
        }
        recordDiagnostic("Opening \(settings.server.host):\(settings.server.port)", isConnectionEvent: true)
        recordDiagnostic("Filter: \(aprsFilterDescription)", isConnectionEvent: true)
        await newClient.connect()
    }

    private func received(_ location: CLLocation) async {
        if settings.identity.isReady {
            await connectIfNeeded()
        }

        try? await client?.updateFilter(
            center: location.coordinate,
            radiusKilometers: settings.server.filterRadiusKilometers
        )

        guard isBeaconing else { return }
        guard location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= settings.beaconing.maximumAccuracyMeters else { return }

        let decision = smartBeaconing.decision(
            current: location,
            previousBeacon: lastBeaconLocation,
            lastBeaconAt: lastBeaconAt,
            configuration: settings.beaconing
        )
        nextBeaconAt = decision.nextBeaconAt
        if decision.shouldBeacon { await sendBeacon(at: location) }
    }

    private func sendBeacon(at location: CLLocation) async {
        guard isAPRSISPasscodeValid else {
            disableTransmittingForInvalidPasscode()
            return
        }
        await connectIfNeeded()
        guard connectionState == .connected(verified: true) else {
            lastBeaconError = connectionState == .unverified
                ? "APRS-IS rejected the passcode for this call sign."
                : "Waiting for APRS-IS to verify the login."
            return
        }
        guard let client else { return }
        let packet = APRSPacket.position(
            callsign: settings.identity.fullCallsign,
            location: location,
            symbol: settings.beaconing.symbol,
            comment: settings.beaconing.comment
        )

        do {
            try await client.send(packet.tnc2)
            lastBeaconAt = .now
            lastBeaconLocation = location
            lastBeaconError = nil
            trail.append(location.coordinate)
            trail = Array(trail.suffix(30))
        } catch {
            lastBeaconError = error.localizedDescription
        }
    }

    private func disableTransmittingForInvalidPasscode() {
        isBeaconing = false
        nextBeaconAt = nil
        beaconTask?.cancel()
        beaconTask = nil
        lastBeaconError = invalidPasscodeMessage
        beaconAlertMessage = invalidPasscodeMessage
        locationService.stop()
        locationService.start(background: false)
    }

    private func upsert(_ station: APRSStation) {
        stations.removeAll { $0.callsign == station.callsign }
        stations.append(station)
        stations.sort { $0.lastHeard > $1.lastHeard }
    }

    private func recordDiagnostic(_ message: String, isConnectionEvent: Bool = false) {
        aprsDiagnosticEntries.append(.init(
            timestamp: .now,
            message: message,
            isConnectionEvent: isConnectionEvent
        ))
        if aprsDiagnosticEntries.count > 300 {
            aprsDiagnosticEntries.removeFirst(aprsDiagnosticEntries.count - 300)
        }
    }

    private func scheduleStatusRefresh() {
        beaconTask?.cancel()
        beaconTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isBeaconing,
                      let current = self.locationService.currentLocation else { continue }
                let decision = self.smartBeaconing.decision(
                    current: current,
                    previousBeacon: self.lastBeaconLocation,
                    lastBeaconAt: self.lastBeaconAt,
                    configuration: self.settings.beaconing
                )
                self.nextBeaconAt = decision.nextBeaconAt
                if decision.shouldBeacon { await self.sendBeacon(at: current) }
            }
        }
    }
}

private extension AppModel.ConnectionState {
    var diagnosticLabel: String {
        switch self {
        case .disconnected: "Offline"
        case .connecting: "Connecting"
        case .connected(true): "Ready"
        case .connected(false): "Verifying server login"
        case .unverified: "Server rejected login"
        case .failed(let reason): "Failed — \(reason)"
        }
    }
}
