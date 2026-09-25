import CoreLocation
import Foundation

struct BeaconDecision: Equatable {
    let shouldBeacon: Bool
    let nextBeaconAt: Date?
    let reason: String
}

struct SmartBeaconingPolicy {
    static let minimumInterval: TimeInterval = 30

    func decision(
        current: CLLocation,
        previousBeacon: CLLocation?,
        lastBeaconAt: Date?,
        configuration: AppSettings.Beaconing,
        now: Date = .now
    ) -> BeaconDecision {
        guard configuration.mode != .manual else {
            return BeaconDecision(shouldBeacon: false, nextBeaconAt: nil, reason: "Manual mode")
        }
        guard let previousBeacon, let lastBeaconAt else {
            let dueAt = lastBeaconAt?.addingTimeInterval(Self.minimumInterval) ?? now
            return BeaconDecision(shouldBeacon: now >= dueAt, nextBeaconAt: max(now, dueAt), reason: "First position")
        }

        let interval: TimeInterval
        if configuration.mode == .timed {
            interval = configuration.timedInterval ?? 120
        } else if current.speed < 1 {
            interval = configuration.stoppedInterval
        } else if current.speed >= configuration.fastSpeedMetersPerSecond {
            interval = configuration.fastInterval
        } else {
            let fraction = max(0, min(1, current.speed / configuration.fastSpeedMetersPerSecond))
            interval = configuration.slowInterval - fraction * (configuration.slowInterval - configuration.fastInterval)
        }

        let dueAt = lastBeaconAt.addingTimeInterval(max(Self.minimumInterval, interval))
        if now >= dueAt {
            return BeaconDecision(shouldBeacon: true, nextBeaconAt: now, reason: "Interval elapsed")
        }

        if configuration.mode == .smart,
           current.speed > 2,
           previousBeacon.course >= 0,
           current.course >= 0 {
            let turn = angularDifference(previousBeacon.course, current.course)
            if turn >= configuration.turnThresholdDegrees,
               now.timeIntervalSince(lastBeaconAt) >= Self.minimumInterval {
                return BeaconDecision(shouldBeacon: true, nextBeaconAt: now, reason: "Heading changed")
            }
        }

        return BeaconDecision(shouldBeacon: false, nextBeaconAt: dueAt, reason: "Waiting")
    }

    private func angularDifference(_ first: CLLocationDirection, _ second: CLLocationDirection) -> Double {
        let difference = abs(first - second).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }
}
