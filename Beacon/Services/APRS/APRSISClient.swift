import Foundation
import Network
import CoreLocation

actor APRSISClient {
    enum ClientError: LocalizedError {
        case notConnected
        case sendFailed(NWError)

        var errorDescription: String? {
            switch self {
            case .notConnected: "APRS-IS is not connected."
            case .sendFailed(let error): "APRS-IS send failed: \(error.localizedDescription)"
            }
        }
    }

    nonisolated(unsafe) var onPacket: ((String) -> Void)?
    nonisolated(unsafe) var onStateChange: ((AppModel.ConnectionState) -> Void)?
    nonisolated(unsafe) var onDiagnostic: ((String) -> Void)?

    private let configuration: AppSettings
    private var filterCenter: CLLocationCoordinate2D?
    private var filterRadiusKilometers: Int
    private var isLoggedIn = false
    private var filterSendGeneration: Int?
    private var lastFilterCenter: CLLocationCoordinate2D?
    private var lastFilterRadiusKilometers: Int?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var isReceiving = false
    private var shouldReconnect = false
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var connectionGeneration = 0

    init(configuration: AppSettings, filterCenter: CLLocationCoordinate2D?) {
        self.configuration = configuration
        self.filterCenter = filterCenter
        self.filterRadiusKilometers = configuration.server.filterRadiusKilometers
    }

    func connect() {
        shouldReconnect = true
        openConnection()
    }

    private func openConnection() {
        guard connection == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: UInt16(configuration.server.port)) else {
            onStateChange?(.failed("Invalid server port"))
            return
        }

        reconnectTask?.cancel()
        reconnectTask = nil
        connectionGeneration += 1
        let generation = connectionGeneration
        let connection = NWConnection(host: NWEndpoint.Host(configuration.server.host), port: port, using: .tcp)
        self.connection = connection
        receiveBuffer.removeAll(keepingCapacity: true)
        isReceiving = false
        isLoggedIn = false
        lastFilterCenter = nil
        lastFilterRadiusKilometers = nil
        onStateChange?(.connecting)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handle(state, generation: generation) }
        }
        connection.start(queue: DispatchQueue(label: "app.beacon.aprs-is"))
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionGeneration += 1
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        isReceiving = false
        isLoggedIn = false
        lastFilterCenter = nil
        lastFilterRadiusKilometers = nil
        onStateChange?(.disconnected)
    }

    func send(_ line: String) async throws {
        guard let connection else { throw ClientError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data("\(line)\r\n".utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: ClientError.sendFailed(error)) }
                else { continuation.resume() }
            })
        }
    }

    func updateFilter(center: CLLocationCoordinate2D, radiusKilometers: Int) async throws {
        // Keep the latest requested filter even while connecting or recovering.
        filterCenter = center
        filterRadiusKilometers = radiusKilometers
        try await flushFilter()
    }

    func updateFilterCenter(_ center: CLLocationCoordinate2D) async throws {
        filterCenter = center
        try await flushFilter()
    }

    private func flushFilter() async throws {
        let generation = connectionGeneration
        guard isLoggedIn, filterSendGeneration != generation else { return }
        filterSendGeneration = generation
        defer {
            if filterSendGeneration == generation { filterSendGeneration = nil }
        }

        // Serialize writes so an older completion cannot overwrite a newer filter.
        while isLoggedIn, generation == connectionGeneration, let center = filterCenter {
            let radius = filterRadiusKilometers
            if let lastFilterCenter, lastFilterRadiusKilometers == radius {
                let previous = CLLocation(latitude: lastFilterCenter.latitude, longitude: lastFilterCenter.longitude)
                let current = CLLocation(latitude: center.latitude, longitude: center.longitude)
                guard current.distance(from: previous) >= 5_000 else { return }
            }
            do {
                try await send("#filter r/\(center.latitude)/\(center.longitude)/\(radius)")
            } catch {
                if generation == connectionGeneration {
                    // A broken socket needs reconnecting; its login uses the latest filter.
                    scheduleReconnect(after: error.localizedDescription)
                }
                throw error
            }
            guard generation == connectionGeneration else { return }
            lastFilterCenter = center
            lastFilterRadiusKilometers = radius
            onDiagnostic?("Receive filter sent: radius \(radius) km")
        }
    }

    private func handle(_ state: NWConnection.State, generation: Int) async {
        guard generation == connectionGeneration else { return }
        switch state {
        case .ready:
            onDiagnostic?("TCP connection ready; APRS-IS login sent with credentials redacted")
            onStateChange?(.connected(verified: false))
            startReceivingIfNeeded(generation: generation)
            do {
                let loginCenter = filterCenter
                let loginRadius = filterRadiusKilometers
                try await send(loginLine(center: loginCenter, radiusKilometers: loginRadius))
                guard generation == connectionGeneration else { return }
                lastFilterCenter = loginCenter
                lastFilterRadiusKilometers = loginRadius
                isLoggedIn = true
                try await flushFilter()
                guard generation == connectionGeneration else { return }
                let locallyVerified = Self.passcode(
                    configuration.identity.passcode,
                    isValidFor: configuration.identity.fullCallsign
                )
                onStateChange?(locallyVerified ? .connected(verified: true) : .unverified)
            } catch {
                if generation == connectionGeneration {
                    scheduleReconnect(after: error.localizedDescription)
                }
            }
        case .waiting:
            onStateChange?(.connecting)
        case .failed(let error):
            scheduleReconnect(after: error.localizedDescription)
        case .cancelled:
            if shouldReconnect {
                scheduleReconnect(after: "Connection closed")
            } else {
                onStateChange?(.disconnected)
            }
        default:
            break
        }
    }

    private func loginLine(center: CLLocationCoordinate2D?, radiusKilometers: Int) -> String {
        var line = "user \(configuration.identity.fullCallsign) pass \(configuration.identity.passcode) vers Beacon73 0.1"
        if let center {
            line += " filter r/\(center.latitude)/\(center.longitude)/\(radiusKilometers)"
        } else {
            // Start with a harmless narrow filter until Core Location supplies a center.
            line += " filter r/0/0/1"
        }
        return line
    }

    private func receiveNext(generation: Int) {
        guard generation == connectionGeneration else { return }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty {
                    // APRS comments can contain legacy bytes. Preserve the rest of the stream
                    // instead of dropping a whole receive block when one byte is not UTF-8.
                    await self.process(data)
                }
                if let error {
                    await self.receiveEnded(error.localizedDescription, generation: generation)
                } else if complete {
                    await self.receiveEnded("Server closed the connection", generation: generation)
                } else {
                    await self.receiveNext(generation: generation)
                }
            }
        }
    }

    private func startReceivingIfNeeded(generation: Int) {
        guard !isReceiving else { return }
        isReceiving = true
        receiveNext(generation: generation)
    }

    private func receiveEnded(_ message: String, generation: Int) {
        guard generation == connectionGeneration else { return }
        scheduleReconnect(after: message)
    }

    private func scheduleReconnect(after message: String) {
        guard shouldReconnect, reconnectTask == nil else { return }

        onStateChange?(.failed(message))
        connectionGeneration += 1
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        isReceiving = false
        isLoggedIn = false
        lastFilterCenter = nil
        lastFilterRadiusKilometers = nil
        receiveBuffer.removeAll(keepingCapacity: true)

        let delays = [2, 5, 10, 30, 60]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        onDiagnostic?("Reconnect scheduled in \(delay) seconds — \(message)")
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            await self.clearReconnectTaskAndOpen()
        }
    }

    private func clearReconnectTaskAndOpen() {
        reconnectTask = nil
        guard shouldReconnect else { return }
        openConnection()
    }

    private func process(_ data: Data) {
        for line in Self.extractLines(from: &receiveBuffer, appending: data) {
            if let verified = Self.loginVerification(from: line) {
                if verified {
                    reconnectAttempt = 0
                    onStateChange?(.connected(verified: true))
                } else {
                    onStateChange?(.unverified)
                }
            }
            onPacket?(line)
        }
    }

    nonisolated static func extractLines(from buffer: inout Data, appending data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []

        while let delimiter = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[..<delimiter]
            buffer.removeSubrange(...delimiter)
            while buffer.first == 0x0A || buffer.first == 0x0D {
                buffer.removeFirst()
            }

            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    nonisolated static func loginVerification(from line: String) -> Bool? {
        let lowercaseLine = line.lowercased()
        guard lowercaseLine.contains("logresp") else { return nil }
        if lowercaseLine.contains("unverified") { return false }
        if lowercaseLine.contains("verified") { return true }
        return nil
    }

    nonisolated static func expectedPasscode(for callsign: String) -> Int {
        let baseCallsign = callsign
            .uppercased()
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let bytes = Array(baseCallsign.utf8)
        var hash = 0x73e2
        var index = 0
        while index < bytes.count {
            hash ^= Int(bytes[index]) << 8
            if index + 1 < bytes.count {
                hash ^= Int(bytes[index + 1])
            }
            index += 2
        }
        return hash & 0x7fff
    }

    nonisolated static func passcode(_ passcode: String, isValidFor callsign: String) -> Bool {
        guard let suppliedPasscode = Int(passcode.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return suppliedPasscode == expectedPasscode(for: callsign)
    }
}
