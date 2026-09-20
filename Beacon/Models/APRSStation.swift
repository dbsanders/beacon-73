import CoreLocation
import Foundation

struct APRSStation: Identifiable, Equatable {
    enum StationType: String {
        case moving = "Moving"
        case fixed = "Fixed"
        case weather = "Weather"
    }

    var id: String { callsign }
    let callsign: String
    let coordinate: CLLocationCoordinate2D
    let lastHeard: Date
    let comment: String
    let symbolTable: Character
    let symbol: Character
    let course: CLLocationDirection?
    let speedMetersPerSecond: CLLocationSpeed?
    let altitudeMeters: CLLocationDistance?
    let equipment: String?

    var symbolSelection: APRSSymbol {
        let table = symbolTable == "/" ? "/" : "\\"
        return APRSSymbolCatalog.selection(from: table + String(symbol))
    }

    var symbolOverlay: Character? {
        symbolTable == "/" || symbolTable == "\\" ? nil : symbolTable
    }

    var stationType: StationType {
        if symbol == "_" { return .weather }

        let movingSymbols = Set<Character>("$'()*<=>COFRSTUXY[^befjkpsuv")
        if movingSymbols.contains(symbol) || (speedMetersPerSecond ?? 0) > 0.5 {
            return .moving
        }
        return .fixed
    }

    static func == (lhs: APRSStation, rhs: APRSStation) -> Bool {
        lhs.callsign == rhs.callsign &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.lastHeard == rhs.lastHeard
    }
}
