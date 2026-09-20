import CoreLocation
import Foundation

extension Date {
    var relativeLabel: String {
        relativeLabel(at: .now)
    }

    func relativeLabel(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(self)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s ago" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m \(seconds % 60)s ago"
    }

    var countdownLabel: String {
        countdownLabel(at: .now)
    }

    func countdownLabel(at now: Date) -> String {
        let seconds = max(0, Int(timeIntervalSince(now).rounded()))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

extension CLLocation {
    var accuracyLabel: String {
        horizontalAccuracy >= 0 ? String(format: "±%.0f ft", horizontalAccuracy * 3.28084) : "—"
    }

    func speedLabel(unit: AppSettings.Display.SpeedUnit) -> String {
        guard speed >= 0 else { return "—" }
        switch unit {
        case .mph: return String(format: "%.0f mph", speed * 2.23694)
        case .kilometersPerHour: return String(format: "%.0f km/h", speed * 3.6)
        }
    }

    var altitudeLabel: String {
        String(format: "%.0f ft", altitude * 3.28084)
    }

    var headingLabel: String {
        guard course >= 0 else { return "—" }
        let directions = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((course + 22.5) / 45) % directions.count
        return "\(directions[index]) (\(Int(course.rounded()))°)"
    }
}

extension Character {
    var systemImage: String {
        switch self {
        case ">": "car.fill"
        case "-": "house.fill"
        case "[": "figure.walk"
        case "k": "truck.box.fill"
        default: "antenna.radiowaves.left.and.right"
        }
    }
}

extension CLAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined: "Not requested"
        case .restricted: "Restricted"
        case .denied: "Denied"
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While using"
        @unknown default: "Unknown"
        }
    }
}
