import Foundation

struct AppSettings: Codable, Equatable {
    var identity = Identity()
    var beaconing = Beaconing()
    var display = Display() {
        didSet {
            if display.distanceUnit != oldValue.distanceUnit {
                normalizeReceiveRadius()
            }
        }
    }
    var server = Server()

    static let receiveRadiusChoices = [1, 5] + Array(stride(from: 10, through: 100, by: 10))

    // APRS-IS uses whole kilometers; the UI selects from a fixed set in its unit.
    var receiveRadius: Int {
        get {
            let kilometers = Double(server.filterRadiusKilometers)
            let value = display.distanceUnit == .miles ? kilometers / 1.609344 : kilometers
            return Self.nearestReceiveRadius(to: value)
        }
        set {
            let value = Self.nearestReceiveRadius(to: Double(newValue))
            server.filterRadiusKilometers = display.distanceUnit == .miles
                ? Int((Double(value) * 1.609344).rounded())
                : value
        }
    }

    var receiveRadiusChoiceIndex: Int {
        get { Self.receiveRadiusChoices.firstIndex(of: receiveRadius) ?? 0 }
        set {
            let index = min(max(newValue, 0), Self.receiveRadiusChoices.count - 1)
            receiveRadius = Self.receiveRadiusChoices[index]
        }
    }

    private static func nearestReceiveRadius(to value: Double) -> Int {
        receiveRadiusChoices.min {
            let first = abs(Double($0) - value)
            let second = abs(Double($1) - value)
            return first == second ? $0 > $1 : first < second
        } ?? 1
    }

    private mutating func normalizeReceiveRadius() {
        let roundedRadius = receiveRadius
        receiveRadius = roundedRadius
    }

    struct Identity: Codable, Equatable {
        var callsign = ""
        var ssid = "5"
        var passcode = ""

        var fullCallsign: String {
            let base = callsign.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !base.isEmpty else { return "" }
            guard let value = Int(ssid), (1...15).contains(value) else { return base }
            return "\(base)-\(value)"
        }

        var isReady: Bool {
            !callsign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !passcode.isEmpty
        }
    }

    struct Beaconing: Codable, Equatable {
        enum Mode: String, Codable, CaseIterable, Identifiable {
            case smart = "Smart"
            case timed = "Timed"
            case manual = "Manual"
            var id: Self { self }

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let storedValue = try container.decode(String.self)
                self = storedValue == "Fixed" ? .timed : (Mode(rawValue: storedValue) ?? .smart)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }
        }

        var mode = Mode.smart
        // Optional so settings saved before Timed mode was added continue to decode.
        var timedInterval: TimeInterval?
        var stoppedInterval: TimeInterval = 900
        var slowInterval: TimeInterval = 180
        var fastInterval: TimeInterval = 30
        var fastSpeedMetersPerSecond = 26.8
        var turnThresholdDegrees = 25.0
        var maximumAccuracyMeters = 100.0
        // Stored as table identifier + symbol code. Legacy one-character values are primary-table symbols.
        var symbol = "/>"
        var comment = "Beacon 73 for iOS"
    }

    struct Display: Codable, Equatable {
        enum SpeedUnit: String, Codable, CaseIterable, Identifiable {
            case mph = "mph"
            case kilometersPerHour = "km/h"
            var id: Self { self }
        }

        enum DistanceUnit: String, Codable, CaseIterable, Identifiable {
            case miles = "Miles"
            case kilometers = "Kilometers"
            var id: Self { self }
        }

        var speedUnit: SpeedUnit {
            distanceUnit == .miles ? .mph : .kilometersPerHour
        }
        var distanceUnit = DistanceUnit.miles
        var showStations = true
        var showMovingStations = true
        var showFixedStations = false
        var showWeatherStations = false

        private enum CodingKeys: String, CodingKey {
            case distanceUnit
            case showStations
            case showMovingStations
            case showFixedStations
            case showWeatherStations
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            distanceUnit = try container.decodeIfPresent(DistanceUnit.self, forKey: .distanceUnit) ?? .miles
            showStations = try container.decodeIfPresent(Bool.self, forKey: .showStations) ?? true
            showMovingStations = try container.decodeIfPresent(Bool.self, forKey: .showMovingStations) ?? true
            showFixedStations = try container.decodeIfPresent(Bool.self, forKey: .showFixedStations) ?? false
            showWeatherStations = try container.decodeIfPresent(Bool.self, forKey: .showWeatherStations) ?? false
        }

        func shows(_ station: APRSStation) -> Bool {
            switch station.stationType {
            case .moving: return showMovingStations
            case .fixed: return showFixedStations
            case .weather: return showWeatherStations
            }
        }
    }

    struct Server: Codable, Equatable {
        var host = "rotate.aprs2.net"
        var port = 14580
        var filterRadiusKilometers = 80

        func hasSameEndpoint(as other: Server) -> Bool {
            host == other.host && port == other.port
        }
    }

    private static let storageKey = "app.settings.v1"

    static func load(defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: storageKey),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            var settings = AppSettings()
            settings.identity.passcode = KeychainStore.aprsPasscode ?? ""
            return settings
        }
        migrateLegacyValues(in: &settings)
        settings.identity.passcode = KeychainStore.aprsPasscode ?? ""
        return settings
    }

    static func migrateLegacyValues(in settings: inout AppSettings) {
        settings.normalizeReceiveRadius()
        if settings.beaconing.comment == "Beacon for iOS" {
            settings.beaconing.comment = "Beacon 73 for iOS"
        }
    }

    func save(defaults: UserDefaults = .standard) {
        var publicSettings = self
        publicSettings.identity.passcode = ""
        guard let data = try? JSONEncoder().encode(publicSettings) else { return }
        defaults.set(data, forKey: Self.storageKey)
        KeychainStore.aprsPasscode = identity.passcode
    }
}
