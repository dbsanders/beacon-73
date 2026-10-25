import Foundation

struct PasscodeRequestResult: Decodable, Equatable {
    let callsign: String
    let passcode: Int
    let attestationRecorded: Bool
}

struct CallsignRegistryRecord: Decodable, Equatable {
    let callsign: String
    let status: String
    let radioService: String?
    let grantDate: String?
    let expirationDate: String?
    let fccLicenseId: String?
    let operatorClass: String?
    let licenseeName: String?

    var operatorClassDescription: String? {
        switch operatorClass {
        case "E": "Amateur Extra"
        case "G": "General"
        case "T": "Technician"
        case "A": "Advanced"
        case "P": "Technician Plus"
        case "N": "Novice"
        default: operatorClass
        }
    }
}

struct CallsignRegistryLookup: Decodable, Equatable {
    struct Dataset: Decodable, Equatable {
        let sourceUpdatedAt: String
        let recordCount: Int
        let source: String?
        let countryCode: String?
        let registryCode: String?

        var updateDateDescription: String {
            String(sourceUpdatedAt.prefix(10))
        }

        var recordTitle: String {
            registryCode == "ISED" ? "Canadian license record" : "FCC license record"
        }

        var sourceDescription: String {
            registryCode == "ISED" ? "Public Canadian ISED data" : "Public FCC ULS data"
        }
    }

    let callsign: String
    let record: CallsignRegistryRecord?
    let dataset: Dataset
}

enum AmateurCallsignValidator {
    // APRS-IS's published conservative international callsign expression.
    private static let basePattern = #"^(?:[1-9][A-Z][A-Z]?[0-9]|[A-Z][2-9A-Z]?[0-9])[A-Z]{1,4}$"#

    static func normalizedBase(from rawValue: String) -> String? {
        var callsign = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let separator = callsign.lastIndex(of: "-") {
            let suffix = callsign[callsign.index(after: separator)...]
            guard !suffix.isEmpty,
                  suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let ssid = Int(suffix),
                  (0...15).contains(ssid) else {
                return nil
            }
            callsign = String(callsign[..<separator])
        }

        guard callsign.range(of: basePattern, options: .regularExpression) != nil else {
            return nil
        }
        return callsign
    }
}

struct PasscodeRequestClient {
    enum RequestError: LocalizedError {
        case notConfigured
        case invalidCallsign
        case invalidResponse
        case rejected(message: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                "Passcode requests are not configured in this version of Beacon 73."
            case .invalidCallsign:
                "Enter a valid amateur-radio call sign before requesting a passcode."
            case .invalidResponse:
                "The passcode service returned an unexpected response. Please try again."
            case .rejected(let message):
                message
            }
        }
    }

    private struct RequestBody: Encodable {
        let callsign: String
        let attestation = true
    }

    private struct ErrorEnvelope: Decodable {
        struct Details: Decodable {
            let message: String
        }

        let error: Details
    }

    private static let baseURLInfoKey = "BeaconAPIBaseURL"
    private let session: URLSession
    private let baseURL: URL?

    init(session: URLSession = .shared, baseURL: URL? = nil) {
        self.session = session
        self.baseURL = baseURL ?? Self.configuredBaseURL
    }

    func requestPasscode(for callsign: String) async throws -> PasscodeRequestResult {
        guard let baseURL else { throw RequestError.notConfigured }
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("passcode")
        let request = try Self.makeRequest(endpoint: endpoint, callsign: callsign)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RequestError.invalidResponse
        }
        return try Self.decodeResponse(data: data, statusCode: httpResponse.statusCode)
    }

    func lookupCallsign(_ callsign: String) async throws -> CallsignRegistryLookup {
        guard let baseURL else { throw RequestError.notConfigured }
        let request = try Self.makeLookupRequest(baseURL: baseURL, callsign: callsign)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RequestError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw RequestError.rejected(message: envelope.error.message)
            }
            throw RequestError.rejected(message: "The callsign registry lookup is unavailable.")
        }
        guard let lookup = try? JSONDecoder().decode(CallsignRegistryLookup.self, from: data) else {
            throw RequestError.invalidResponse
        }
        return lookup
    }

    static func makeLookupRequest(baseURL: URL, callsign: String) throws -> URLRequest {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw RequestError.notConfigured
        }
        guard let normalizedCallsign = AmateurCallsignValidator.normalizedBase(from: callsign) else {
            throw RequestError.invalidCallsign
        }
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("callsigns")
            .appendingPathComponent(normalizedCallsign)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func makeRequest(endpoint: URL, callsign: String) throws -> URLRequest {
        guard endpoint.scheme?.lowercased() == "https" else {
            throw RequestError.notConfigured
        }
        guard let normalizedCallsign = AmateurCallsignValidator.normalizedBase(from: callsign) else {
            throw RequestError.invalidCallsign
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(RequestBody(callsign: normalizedCallsign))
        return request
    }

    static func decodeResponse(data: Data, statusCode: Int) throws -> PasscodeRequestResult {
        guard (200...299).contains(statusCode) else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw RequestError.rejected(message: envelope.error.message)
            }
            throw RequestError.rejected(
                message: statusCode == 429
                    ? "Too many passcode requests. Please wait and try again."
                    : "The passcode request could not be approved. Please try again."
            )
        }

        guard let result = try? JSONDecoder().decode(PasscodeRequestResult.self, from: data),
              (0...32_767).contains(result.passcode),
              result.attestationRecorded else {
            throw RequestError.invalidResponse
        }
        return result
    }

    private static var configuredBaseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: baseURLInfoKey) as? String else {
            return nil
        }
        return URL(string: value)
    }
}
