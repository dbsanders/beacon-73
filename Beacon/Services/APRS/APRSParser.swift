import CoreLocation
import Foundation

enum APRSParser {
    private typealias ParsedPosition = (
        coordinate: CLLocationCoordinate2D,
        symbolTable: Character,
        symbol: Character,
        course: Double?,
        speed: Double?,
        altitude: Double?,
        equipment: String?,
        comment: String
    )

    static func station(from line: String, now: Date = .now) -> APRSStation? {
        guard !line.hasPrefix("#"),
              let headerEnd = line.firstIndex(of: ":"),
              let sourceEnd = line.firstIndex(of: ">") else { return nil }

        let callsign = String(line[..<sourceEnd])
        let destinationAndPath = line[line.index(after: sourceEnd)..<headerEnd]
        let destination = String(destinationAndPath.split(separator: ",", maxSplits: 1).first ?? "")
        let information = String(line[line.index(after: headerEnd)...])
        let parsed: ParsedPosition?
        if let payload = positionPayload(from: information) {
            parsed = parseUncompressedPosition(payload) ?? parseCompressedPosition(payload)
        } else {
            parsed = parseMicEPosition(information, destination: destination)
        }
        guard let parsed else { return nil }

        return APRSStation(
            callsign: callsign,
            coordinate: parsed.coordinate,
            lastHeard: now,
            comment: parsed.comment,
            symbolTable: parsed.symbolTable,
            symbol: parsed.symbol,
            course: parsed.course,
            speedMetersPerSecond: parsed.speed,
            altitudeMeters: parsed.altitude,
            equipment: parsed.equipment
        )
    }

    private static func positionPayload(from information: String) -> Substring? {
        if information.first == "!" || information.first == "=" {
            return information.dropFirst()
        } else if information.first == "/" || information.first == "@" {
            guard information.count >= 8 else { return nil }
            return information.dropFirst(8)
        }
        return nil
    }

    private static func parseUncompressedPosition(_ payload: Substring) -> ParsedPosition? {
        guard payload.count >= 19 else { return nil }
        let latitudeText = String(payload.prefix(8))
        let tableIndex = payload.index(payload.startIndex, offsetBy: 8)
        let symbolTable = payload[tableIndex]
        let longitudeStart = payload.index(after: tableIndex)
        let longitudeEnd = payload.index(longitudeStart, offsetBy: 9)
        let longitudeText = String(payload[longitudeStart..<longitudeEnd])
        let symbol = payload[longitudeEnd]
        var remainder = String(payload[payload.index(after: longitudeEnd)...])

        guard let latitude = coordinate(latitudeText, degreeDigits: 2),
              let longitude = coordinate(longitudeText, degreeDigits: 3) else { return nil }

        var course: Double?
        var speed: Double?
        if remainder.count >= 7 {
            let candidate = String(remainder.prefix(7))
            let parts = candidate.split(separator: "/")
            if parts.count == 2, let parsedCourse = Double(parts[0]), let knots = Double(parts[1]) {
                course = parsedCourse
                speed = knots / 1.94384
                remainder.removeFirst(7)
            }
        }

        var altitude: Double?
        if let range = remainder.range(of: #"/A=\d{6}"#, options: .regularExpression) {
            let feetText = remainder[range].dropFirst(3)
            altitude = (Double(feetText) ?? 0) * 0.3048
        }

        return (
            .init(latitude: latitude, longitude: longitude),
            symbolTable,
            symbol,
            course,
            speed,
            altitude,
            nil,
            displayComment(from: remainder, symbol: symbol)
        )
    }

    private static func parseCompressedPosition(_ payload: Substring) -> ParsedPosition? {
        // APRS compressed positions are 13 characters: table + YYYY + XXXX + symbol + csT.
        guard payload.count >= 13 else { return nil }
        let characters = Array(payload.prefix(13))
        guard let latitudeValue = base91Value(characters[1...4]),
              let longitudeValue = base91Value(characters[5...8]) else { return nil }

        let latitude = 90 - Double(latitudeValue) / 380_926
        let longitude = -180 + Double(longitudeValue) / 190_463
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }

        var course: Double?
        var speed: Double?
        if let courseValue = base91Digit(characters[10]),
           let speedValue = base91Digit(characters[11]),
           courseValue <= 89,
           speedValue <= 89 {
            course = Double(courseValue * 4)
            let knots = pow(1.08, Double(speedValue)) - 1
            speed = knots / 1.94384
        }

        let comment = displayComment(from: String(payload.dropFirst(13)), symbol: characters[9])
        return (
            .init(latitude: latitude, longitude: longitude),
            characters[0],
            characters[9],
            course,
            speed,
            nil,
            nil,
            comment
        )
    }

    private static func parseMicEPosition(_ information: String, destination: String) -> ParsedPosition? {
        guard information.first == "`" || information.first == "'",
              destination.count >= 6,
              information.count >= 9 else { return nil }

        let destinationCharacters = Array(destination.prefix(6))
        let digits = destinationCharacters.map(micEDigit)
        let ambiguity = digits.reversed().prefix { $0 == nil }.count
        guard ambiguity <= 4,
              digits.dropLast(ambiguity).allSatisfy({ $0 != nil }) else { return nil }
        let latitudeDigits = digits.map { $0 ?? 0 }
        let latitudeDegrees = Double(latitudeDigits[0] * 10 + latitudeDigits[1])
        let latitudeMinutes = Double(latitudeDigits[2] * 10 + latitudeDigits[3])
            + Double(latitudeDigits[4]) / 10
            + Double(latitudeDigits[5]) / 100
            + ambiguityCenterMinutes(for: ambiguity)
        var latitude = latitudeDegrees + latitudeMinutes / 60
        if !micEFlag(destinationCharacters[3]) { latitude.negate() }

        let bytes = Array(information.utf8)
        var longitudeDegrees = Int(bytes[1]) - 28
        if micEFlag(destinationCharacters[4]) { longitudeDegrees += 100 }
        if longitudeDegrees >= 180 { longitudeDegrees -= 80 }

        var longitudeMinutes = Int(bytes[2]) - 28
        if longitudeMinutes >= 60 { longitudeMinutes -= 60 }
        var longitudeHundredths = Int(bytes[3]) - 28
        if longitudeHundredths >= 60 { longitudeHundredths -= 60 }
        guard (0..<180).contains(longitudeDegrees),
              (0..<60).contains(longitudeMinutes),
              (0..<100).contains(longitudeHundredths) else { return nil }

        var longitude = Double(longitudeDegrees)
            + (Double(longitudeMinutes) + Double(longitudeHundredths) / 100
                + ambiguityCenterMinutes(for: ambiguity)) / 60
        if micEFlag(destinationCharacters[5]) { longitude.negate() }

        var speedTens = Int(bytes[4]) - 28
        if speedTens >= 80 { speedTens -= 80 }
        let directionAndSpeed = Int(bytes[5]) - 28
        let courseRemainder = Int(bytes[6]) - 28
        var speedKnots = speedTens * 10 + directionAndSpeed / 10
        if speedKnots >= 800 { speedKnots -= 800 }
        var courseDegrees = (directionAndSpeed % 10) * 100 + courseRemainder
        if courseDegrees >= 400 { courseDegrees -= 400 }

        let characters = Array(information)
        let micEStatus = parseMicEStatus(Array(characters.dropFirst(9)))
        return (
            .init(latitude: latitude, longitude: longitude),
            characters[8],
            characters[7],
            (0..<360).contains(courseDegrees) ? Double(courseDegrees) : nil,
            speedKnots >= 0 ? Double(speedKnots) / 1.94384 : nil,
            micEStatus.altitude,
            micEStatus.equipment,
            displayComment(from: micEStatus.comment, symbol: characters[7])
        )
    }

    private static func parseMicEStatus(_ rawCharacters: [Character]) -> (
        altitude: Double?,
        equipment: String?,
        comment: String
    ) {
        var characters = rawCharacters
        let hasNewStyleDeviceIdentifier = characters.first == "`" || characters.first == "'"
        var equipment: String?
        if hasNewStyleDeviceIdentifier {
            characters.removeFirst()
        } else if let prefix = characters.first, prefix == ">" || prefix == "]" {
            let exactIdentifier = characters.last.map { String([prefix, $0]) }
            equipment = exactIdentifier.flatMap { micELegacyEquipment[$0] }
                ?? micELegacyEquipment[String(prefix)]
            characters.removeFirst()
            if let exactIdentifier, micELegacyEquipment[exactIdentifier] != nil, !characters.isEmpty {
                characters.removeLast()
            }
        }

        var altitude: Double?
        if let closingIndex = characters.firstIndex(of: "}"), closingIndex >= 3 {
            let altitudeStart = closingIndex - 3
            if let encodedAltitude = base91Value(characters[altitudeStart..<closingIndex]) {
                altitude = Double(encodedAltitude - 10_000)
                characters.removeSubrange(altitudeStart...closingIndex)
            }
        }

        // New-style Mic-E devices place a two-character equipment ID at the end.
        // It is metadata (for example "_%" means Yaesu FTM-400DR), not a comment.
        if hasNewStyleDeviceIdentifier, characters.count >= 2 {
            let suffix = String(characters.suffix(2))
            equipment = micENewStyleEquipment[suffix]
            characters.removeLast(2)
        }

        var comment = String(characters)
        if comment == "&" { comment = "" }
        return (altitude, equipment, comment)
    }

    // APRS device identifiers maintained by aprsorg/aprs-deviceid (CC BY-SA 2.0).
    private static let micENewStyleEquipment: [String: String] = [
        "_ ": "Yaesu VX-8",
        "_\"": "Yaesu FTM-350",
        "_#": "Yaesu VX-8G",
        "_$": "Yaesu FT1D",
        "_(": "Yaesu FT2D",
        "_0": "Yaesu FT3D",
        "_3": "Yaesu FT5D",
        "_1": "Yaesu FTM-300D",
        "_2": "Yaesu FTM-200D",
        "_4": "Yaesu FTM-500D",
        "_5": "Yaesu FTM-510D",
        "_6": "Yaesu FTX-1",
        "_7": "Yaesu FTM-310D",
        "_)": "Yaesu FTM-100D",
        "_%": "Yaesu FTM-400DR",
        "(5": "AnyTone D578UV",
        "(8": "AnyTone D878UV",
        "|3": "Byonics TinyTrak3",
        "|4": "Byonics TinyTrak4",
        "^A": "APRS Connect",
        "[1": "APRSdroid"
    ]

    private static let micELegacyEquipment: [String: String] = [
        ">": "Kenwood TH-D7A",
        ">=": "Kenwood TH-D72",
        ">^": "Kenwood TH-D74",
        ">&": "Kenwood TH-D75",
        "]": "Kenwood TM-D700 family",
        "]=": "Kenwood TM-D710"
    ]

    private static func displayComment(from rawComment: String, symbol: Character) -> String {
        var comment = rawComment
        let weather = symbol == "_" ? weatherSummary(from: rawComment) : nil

        let machineFields = [
            #"/A=-?\d{5,6}"#,
            #"PHG[0-9A-Z]{4}"#,
            #"RNG\d{4}"#,
            #"\|[!-{]*\|"#,
            #"![Ww][!-{]{2}!"#,
            #"(?:c\d{3}|s\d{3}|g\d{3}|t-?\d{2,3}|r\d{3}|p\d{3}|P\d{3}|h\d{2}|b\d{5}|L\d{3})"#
        ]
        for pattern in machineFields {
            comment = comment.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }

        comment = comment
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " /,;-"))

        return [weather, comment]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    private static func weatherSummary(from comment: String) -> String? {
        var values: [String] = []
        if let temperature = weatherValue(in: comment, prefix: "t", digits: #"-?\d{2,3}"#) {
            values.append("\(Int(temperature))°F")
        }
        if let gust = weatherValue(in: comment, prefix: "g", digits: #"\d{3}"#), gust > 0 {
            values.append("Gust \(Int(gust)) mph")
        }
        if let humidityValue = weatherValue(in: comment, prefix: "h", digits: #"\d{2}"#) {
            let humidity = humidityValue == 0 ? 100 : Int(humidityValue)
            values.append("Humidity \(humidity)%")
        }
        if let pressure = weatherValue(in: comment, prefix: "b", digits: #"\d{5}"#) {
            values.append(String(format: "%.1f hPa", pressure / 10))
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private static func weatherValue(in comment: String, prefix: Character, digits: String) -> Double? {
        let pattern = "\(prefix)(\(digits))"
        guard let range = comment.range(of: pattern, options: .regularExpression) else { return nil }
        return Double(comment[range].dropFirst())
    }

    private static func micEDigit(_ character: Character) -> Int? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 48...57: return Int(ascii - 48)
        case 65...74: return Int(ascii - 65)
        case 80...89: return Int(ascii - 80)
        default: return nil
        }
    }

    private static func ambiguityCenterMinutes(for digitCount: Int) -> Double {
        switch digitCount {
        case 1: 0.05
        case 2: 0.5
        case 3: 5
        case 4: 30
        default: 0
        }
    }

    private static func micEFlag(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        return (80...90).contains(ascii)
    }

    private static func base91Value(_ characters: ArraySlice<Character>) -> Int? {
        var value = 0
        for character in characters {
            guard let digit = base91Digit(character) else { return nil }
            value = value * 91 + digit
        }
        return value
    }

    private static func base91Digit(_ character: Character) -> Int? {
        guard let ascii = character.asciiValue, (33...123).contains(ascii) else { return nil }
        return Int(ascii) - 33
    }

    private static func coordinate(_ text: String, degreeDigits: Int) -> Double? {
        guard text.count >= degreeDigits + 6 else { return nil }
        let hemisphere = text.last!
        let degreesEnd = text.index(text.startIndex, offsetBy: degreeDigits)
        guard let degrees = Double(text[..<degreesEnd]),
              let minutes = Double(text[degreesEnd..<text.index(before: text.endIndex)]) else { return nil }
        let value = degrees + minutes / 60
        return hemisphere == "S" || hemisphere == "W" ? -value : value
    }
}
