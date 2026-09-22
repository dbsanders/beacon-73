import ActivityKit
import Foundation

struct BeaconActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let callsign: String
        let connectionStatus: String
        let isConnected: Bool
        let lastBeaconAt: Date?
        let nextBeaconAt: Date?
    }
}
