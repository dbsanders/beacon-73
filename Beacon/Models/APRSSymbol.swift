import Foundation

enum APRSSymbolTable: String, CaseIterable, Identifiable {
    case primary = "/"
    case alternate = "\\"

    var id: Self { self }
    var title: String { self == .primary ? "Primary" : "Alternate" }
}

struct APRSSymbol: Identifiable, Hashable {
    let table: APRSSymbolTable
    let code: Character
    let name: String
    let supportsOverlay: Bool

    var id: String { table.rawValue + String(code) }
    var packetValue: String { id }
    var codeLabel: String { "\(table.rawValue)\(code)" }

    var systemImage: String {
        switch (table, code) {
        case (_, ">"), (.alternate, "u"): "car.fill"
        case (.primary, "'"), (.primary, "^"): "airplane"
        case (.primary, "-"): "house.fill"
        case (.primary, "["): "figure.run"
        case (.primary, "b"): "bicycle"
        case (.primary, "s"), (.alternate, "s"): "ferry.fill"
        case (.primary, "u"), (.primary, "k"): "truck.box.fill"
        case (.primary, "a"): "cross.case.fill"
        case (.primary, "f"): "firetruck.fill"
        case (.primary, "h"): "cross.fill"
        case (.primary, "Y"): "sailboat.fill"
        case (.alternate, "9"): "fuelpump.fill"
        case (.alternate, "+"): "building.columns.fill"
        case (.alternate, "P"): "parkingsign.circle.fill"
        case (.alternate, "R"): "fork.knife"
        case (.alternate, "X"): "cross.vial.fill"
        case (.alternate, "r"): "figure.dress.line.vertical.figure"
        default: "dot.radiowaves.left.and.right"
        }
    }
}

enum APRSSymbolCatalog {
    static let primary = make(table: .primary, entries: [
        ("!", "Police or Sheriff", false), ("#", "Digipeater", false), ("$", "Telephone", false),
        ("%", "DX Cluster", false), ("&", "HF Gateway", false), ("'", "Small Aircraft", false),
        ("(", "Mobile Satellite Ground Station", false), ("*", "Snowmobile", false),
        ("+", "Red Cross", false), (",", "Boy Scouts", false), ("-", "House / QTH", false),
        (".", "X", false), ("/", "Dot", false),
        ("0", "Numbered Circle 0", false), ("1", "Numbered Circle 1", false),
        ("2", "Numbered Circle 2", false), ("3", "Numbered Circle 3", false),
        ("4", "Numbered Circle 4", false), ("5", "Numbered Circle 5", false),
        ("6", "Numbered Circle 6", false), ("7", "Numbered Circle 7", false),
        ("8", "Numbered Circle 8", false), (":", "Fire", false), (";", "Campground", false),
        ("<", "Motorcycle", false), ("=", "Railroad Engine", false), (">", "Car", false),
        ("?", "File Server", false), ("@", "Hurricane Prediction", false),
        ("A", "Aid Station", false), ("B", "BBS", false), ("C", "Canoe", false),
        ("E", "Eyeball", false), ("G", "Grid Square", false), ("H", "Hotel", false),
        ("I", "TCP/IP", false), ("K", "School", false), ("M", "MacAPRS", false),
        ("N", "NTS Station", false), ("O", "Balloon", false), ("P", "Police", false),
        ("R", "Recreational Vehicle", false), ("S", "Space Shuttle", false),
        ("T", "SSTV", false), ("U", "Bus", false), ("V", "ATV", false),
        ("W", "National Weather Service", false), ("X", "Helicopter", false),
        ("Y", "Yacht / Sailboat", false), ("Z", "WinAPRS", false), ("[", "Jogger", false),
        ("\\", "Triangle / Direction Finding", false), ("]", "PBBS", false),
        ("^", "Large Aircraft", false), ("_", "Weather Station", false),
        ("`", "Dish Antenna", false), ("a", "Ambulance", false), ("b", "Bicycle", false),
        ("d", "Fire Department", false), ("e", "Horse / Equestrian", false),
        ("f", "Fire Truck", false), ("g", "Glider", false), ("h", "Hospital", false),
        ("i", "IOTA", false), ("j", "Jeep", false), ("k", "Truck", false),
        ("m", "Mic-E Repeater", false), ("n", "Node", false),
        ("o", "Emergency Operations Center", false), ("p", "Rover", false),
        ("q", "Grid Square", false), ("r", "Antenna", false), ("s", "Ship / Power Boat", false),
        ("t", "Truck Stop", false), ("u", "18-Wheeler Truck", false), ("v", "Van", false),
        ("w", "Water Station", false), ("x", "X-APRS", false), ("y", "Yagi at QTH", false)
    ])

    static let alternate = make(table: .alternate, entries: [
        ("!", "Emergency", false), ("#", "Digipeater", true), ("$", "Bank or ATM", false),
        ("&", "Gateway", true), ("'", "Crash Site", false), ("(", "Cloudy", false),
        ("*", "Snow", false), ("+", "Church", false), (",", "Girl Scouts", false),
        ("-", "House / HF", false), (".", "Unknown Position", false), ("0", "Circle", true),
        ("9", "Gas Station", false), (":", "Hail", false), (";", "Park / Picnic Area", false),
        ("<", "NWS Advisory", false), (">", "Car", true), ("?", "Information Kiosk", false),
        ("@", "Hurricane / Tropical Storm", false), ("A", "Box", true),
        ("B", "Blowing Snow", false), ("C", "Coast Guard", false), ("D", "Drizzle", false),
        ("E", "Smoke", false), ("F", "Freezing Rain", false), ("G", "Snow Shower", false),
        ("H", "Haze", false), ("I", "Rain Shower", false), ("J", "Lightning", false),
        ("K", "Kenwood", false), ("L", "Lighthouse", false), ("N", "Navigation Buoy", false),
        ("P", "Parking", false), ("Q", "Earthquake", false), ("R", "Restaurant", false),
        ("S", "Satellite / PACsat", false), ("T", "Thunderstorm", false), ("U", "Sunny", false),
        ("V", "VORTAC Navigation Aid", false), ("W", "NWS Site", true),
        ("X", "Pharmacy", false), ("[", "Wall Cloud", false), ("^", "Aircraft", true),
        ("_", "Weather Station with Digi", true), ("`", "Rain", false),
        ("a", "ARRL / RACES", true), ("b", "Blowing Dust / Sand", false),
        ("c", "Civil Defense / RACES", true), ("d", "DX Spot", false), ("e", "Sleet", false),
        ("f", "Funnel Cloud", false), ("g", "Gale Flags", false), ("h", "Ham Store", false),
        ("i", "Indoor Short-Range Digi", true), ("j", "Work Zone", false),
        ("l", "Area Symbol", false), ("m", "Value Signpost", false), ("n", "Triangle", true),
        ("o", "Small Circle", false), ("p", "Partly Cloudy", false), ("r", "Restrooms", false),
        ("s", "Ship / Boat", true), ("t", "Tornado", false), ("u", "Truck", true),
        ("v", "Van", true), ("w", "Flooding", false), ("{", "Fog", false)
    ])

    static let all = primary + alternate

    static func selection(from storedValue: String) -> APRSSymbol {
        let characters = Array(storedValue)
        let table: APRSSymbolTable
        let code: Character
        if characters.count >= 2, let parsedTable = APRSSymbolTable(rawValue: String(characters[0])) {
            table = parsedTable
            code = characters[1]
        } else {
            table = .primary
            code = characters.first ?? ">"
        }
        return all.first { $0.table == table && $0.code == code }
            ?? APRSSymbol(table: table, code: code, name: "Custom", supportsOverlay: false)
    }

    private static func make(
        table: APRSSymbolTable,
        entries: [(Character, String, Bool)]
    ) -> [APRSSymbol] {
        entries.map { APRSSymbol(table: table, code: $0.0, name: $0.1, supportsOverlay: $0.2) }
    }
}
