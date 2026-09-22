import CoreLocation
import Foundation

enum APRSApplicationIdentity {
    static let tocall = "APB730"
}

struct APRSPacket: Equatable {
    let source: String
    let destination: String
    let path: String
    let information: String

    var tnc2: String { "\(source)>\(destination),\(path):\(information)" }

    static func position(
        callsign: String,
        location: CLLocation,
        symbol: String,
        comment: String
    ) -> APRSPacket {
        let latitude = aprsCoordinate(location.coordinate.latitude, positive: "N", negative: "S", degreeDigits: 2)
        let longitude = aprsCoordinate(location.coordinate.longitude, positive: "E", negative: "W", degreeDigits: 3)
        let selection = APRSSymbolCatalog.selection(from: symbol)
        let information = "!\(latitude)\(selection.table.rawValue)\(longitude)\(selection.code)\(courseAndSpeed(location))\(comment)"
        return APRSPacket(
            source: callsign,
            destination: APRSApplicationIdentity.tocall,
            path: "TCPIP*",
            information: information
        )
    }

    private static func aprsCoordinate(
        _ value: Double,
        positive: Character,
        negative: Character,
        degreeDigits: Int
    ) -> String {
        let absolute = abs(value)
        let degrees = Int(absolute)
        let minutes = (absolute - Double(degrees)) * 60
        let hemisphere = value >= 0 ? positive : negative
        return String(format: "%0*d%05.2f%@", degreeDigits, degrees, minutes, String(hemisphere))
    }

    private static func courseAndSpeed(_ location: CLLocation) -> String {
        guard location.course >= 0, location.speed >= 0 else { return "" }
        let course = Int(location.course.rounded()).clamped(to: 0...360)
        let knots = Int((location.speed * 1.94384).rounded()).clamped(to: 0...999)
        return String(format: "%03d/%03d", course, knots)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
