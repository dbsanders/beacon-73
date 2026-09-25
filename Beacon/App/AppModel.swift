import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    static let beaconNowCooldown: TimeInterval = 10

    enum ExperienceMode: String {
        case undecided
        case demo
        case live
    }

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
    var experienceMode: ExperienceMode = .undecided
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

    var isDemoMode: Bool { experienceMode == .demo }

    var displayCoordinate: CLLocationCoordinate2D? {
        isDemoMode ? Self.demoCenterCoordinate : locationService.currentLocation?.coordinate
    }

    var stationsWithinRadius: [APRSStation] {
        if isDemoMode {
            return Self.demoStations(centeredAt: Self.demoCenterCoordinate)
        }
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
    private let liveActivityController = BeaconLiveActivityController()
    private var client: APRSISClient?
    private var clientIdentity: AppSettings.Identity?
    private var clientServer: AppSettings.Server?
    private var beaconTask: Task<Void, Never>?
    private var lastBeaconLocation: CLLocation?
    private var lastManualBeaconAttemptAt: Date?
    private var isSendingBeacon = false
    private var hasPreparedForLaunch = false

    init() {
        experienceMode = Self.initialExperienceMode(
            storedValue: UserDefaults.standard.string(forKey: Self.experienceModeStorageKey),
            hasConfiguredIdentity: settings.identity.isReady
        )
        locationService.onLocation = { [weak self] location in
            Task { @MainActor in
                await self?.received(location)
            }
        }
    }

    func startBeaconing() async {
        guard experienceMode == .live else {
            beaconAlertMessage = "Transmitting is disabled in Demo Mode. Set up your own call sign and APRS-IS passcode first."
            return
        }
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
        await liveActivityController.start(with: liveActivityState())

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
        await endLiveActivity()
    }

    func toggleBeaconing() async {
        if isBeaconing { await stopBeaconing() } else { await startBeaconing() }
    }

    func beaconNow() async {
        beaconAlertMessage = nil
        guard experienceMode == .live else {
            beaconAlertMessage = "Transmitting is disabled in Demo Mode. Set up your own call sign and APRS-IS passcode first."
            return
        }
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

        await sendBeacon(at: location, manually: true)
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
        guard experienceMode == .live else { return }
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

    func prepareForLaunch() async {
        guard !hasPreparedForLaunch else { return }
        hasPreparedForLaunch = true

        // Auto-beaconing is intentionally not restored after the app process ends.
        // ActivityKit can preserve an earlier Live Activity across a restart, so
        // discard any restored activity before starting a fresh app session.
        await endLiveActivity()

        guard experienceMode == .live, settings.identity.isReady else {
            locationService.stop()
            return
        }
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
        guard experienceMode == .live, settings.identity.isReady else {
            locationService.stop()
            await endLiveActivity()
            return
        }
        locationService.start(background: isBeaconing)
        await startReceiving()
    }

    func enterDemoMode() async {
        await stopNetworkActivity()
        experienceMode = .demo
        persistExperienceMode()
    }

    func exitDemoMode() {
        experienceMode = .live
        persistExperienceMode()
        beginLiveLocationSetup()
    }

    func chooseLiveSetup() {
        experienceMode = .live
        persistExperienceMode()
        beginLiveLocationSetup()
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
        guard experienceMode == .live else { return }
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
                } else if self.isBeaconing {
                    await self.updateLiveActivity()
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
        guard experienceMode == .live else { return }
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
        await updateLiveActivity()
        if decision.shouldBeacon { await sendBeacon(at: location) }
    }

    private func sendBeacon(at location: CLLocation, manually: Bool = false) async {
        guard !isSendingBeacon else { return }
        isSendingBeacon = true
        defer { isSendingBeacon = false }
        guard !isDemoMode else {
            beaconAlertMessage = "Transmitting is disabled in Demo Mode."
            return
        }
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
        // Enforce spacing for every send path, including starting beaconing.
        let minimumInterval = manually ? Self.beaconNowCooldown : SmartBeaconingPolicy.minimumInterval
        if let lastBeaconAt, Date().timeIntervalSince(lastBeaconAt) < minimumInterval {
            return
        }
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
        await updateLiveActivity()
    }

    private func disableTransmittingForInvalidPasscode() {
        isBeaconing = false
        nextBeaconAt = nil
        beaconTask?.cancel()
        beaconTask = nil
        lastBeaconError = invalidPasscodeMessage
        beaconAlertMessage = invalidPasscodeMessage
        if experienceMode == .live {
            locationService.stop()
            locationService.start(background: false)
        } else {
            locationService.stop()
        }
        Task { [weak self] in
            await self?.endLiveActivity()
        }
    }

    private func stopNetworkActivity() async {
        isBeaconing = false
        nextBeaconAt = nil
        beaconTask?.cancel()
        beaconTask = nil
        locationService.stop()
        let previousClient = client
        client = nil
        clientIdentity = nil
        clientServer = nil
        if let previousClient {
            await previousClient.disconnect()
        }
        connectionState = .disconnected
        await endLiveActivity()
    }

    private func persistExperienceMode() {
        UserDefaults.standard.set(experienceMode.rawValue, forKey: Self.experienceModeStorageKey)
    }

    private func beginLiveLocationSetup() {
        locationService.requestAlwaysPermission()
        locationService.start(background: false)
    }

    static func initialExperienceMode(
        storedValue: String?,
        hasConfiguredIdentity: Bool
    ) -> ExperienceMode {
        if let storedValue, let storedMode = ExperienceMode(rawValue: storedValue) {
            return storedMode
        }
        return hasConfiguredIdentity ? .live : .undecided
    }

    private static let experienceModeStorageKey = "app.experienceMode.v1"
    nonisolated static let demoCenterCoordinate = CLLocationCoordinate2D(
        latitude: 33.8003,
        longitude: -117.8827
    )

    private static func demoStations(centeredAt center: CLLocationCoordinate2D) -> [APRSStation] {
        let samples: [(String, Double, Double, Character, String, Double?, Double?)] = [
            ("N0DEMO-1", 0.030, -0.035, ">", "Simulated mobile station", 54, 13.4),
            ("N0DEMO-2", -0.045, 0.025, "[", "Simulated pedestrian station", 210, 1.5),
            ("N0DEMO-3", 0.070, 0.055, "R", "Simulated recreational vehicle", 128, 22.0),
            ("N0DEMO-4", -0.090, -0.060, "-", "Simulated home station", nil, nil),
            ("N0DEMO-5", 0.115, -0.025, "_", "Simulated weather station", nil, nil),
            ("N0DEMO-6", -0.130, 0.090, "k", "Simulated utility vehicle", 312, 17.0),
            ("N0DEMO-7", 0.155, 0.035, "Y", "Simulated sailboat", 185, 4.2),
            ("N0DEMO-8", -0.175, -0.110, "O", "Simulated balloon", 45, 8.0)
        ]

        return samples.enumerated().map { index, sample in
            APRSStation(
                callsign: sample.0,
                coordinate: CLLocationCoordinate2D(
                    latitude: center.latitude + sample.1,
                    longitude: center.longitude + sample.2
                ),
                lastHeard: Date().addingTimeInterval(TimeInterval(-30 * index)),
                comment: sample.4,
                symbolTable: "/",
                symbol: sample.3,
                course: sample.5,
                speedMetersPerSecond: sample.6,
                altitudeMeters: index == 7 ? 1_250 : nil,
                equipment: "Beacon 73 Demo"
            )
        }
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
                await self.updateLiveActivity()
                if decision.shouldBeacon { await self.sendBeacon(at: current) }
            }
        }
    }

    private func updateLiveActivity() async {
        guard isBeaconing else { return }
        await liveActivityController.update(with: liveActivityState())
    }

    private func endLiveActivity() async {
        await liveActivityController.end(with: liveActivityState(statusOverride: "Stopped"))
    }

    private func liveActivityState(
        statusOverride: String? = nil
    ) -> BeaconActivityAttributes.ContentState {
        let isReady = connectionState == .connected(verified: true)
        let currentStatus: String = switch connectionState {
        case .connected(true): "Online"
        case .connected(false): "Verifying"
        case .unverified: "Passcode issue"
        case .failed: "Connection issue"
        case .connecting: "Connecting"
        case .disconnected: "Offline"
        }
        let status = statusOverride ?? currentStatus

        return BeaconActivityAttributes.ContentState(
            callsign: settings.identity.fullCallsign,
            connectionStatus: status,
            isConnected: isReady,
            lastBeaconAt: lastBeaconAt,
            nextBeaconAt: nextBeaconAt
        )
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
