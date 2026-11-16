import ActivityKit
import Foundation

struct BeaconActivityAttributes: ActivityAttributes {
    enum ConnectionStatus: String, Codable {
        case online = "Online"
        case verifying = "Verifying"
        case passcodeIssue = "Passcode issue"
        case connectionIssue = "Connection issue"
        case connecting = "Connecting"
        case offline = "Offline"
        case stopped = "Stopped"
    }

    struct ContentState: Codable, Hashable {
        let callsign: String
        let connectionStatus: ConnectionStatus
        let isConnected: Bool
        let lastBeaconAt: Date?
        let nextBeaconAt: Date?
    }
}
