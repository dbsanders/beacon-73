import CoreLocation
import XCTest
import Network
@testable import Beacon

final class BeaconCoreTests: XCTestCase {
    func testThemeDefaultsToDarkForExistingSettings() throws {
        let display = try JSONDecoder().decode(AppSettings.Display.self, from: Data("{}".utf8))
        XCTAssertEqual(display.theme, .dark)
        XCTAssertEqual(AppSettings.Display().theme, .dark)
    }

    func testThemePersistsAlongsideOtherSettings() throws {
        for theme in AppSettings.Display.Theme.allCases {
            var settings = AppSettings()
            settings.display.theme = theme
            settings.display.showFixedStations = true
            settings.identity.callsign = "N0TEST"
            let restored = try JSONDecoder().decode(
                AppSettings.self, from: JSONEncoder().encode(settings)
            )
            XCTAssertEqual(restored, settings)
            XCTAssertEqual(restored.display.theme, theme)
        }
    }

    @MainActor
    func testStationsExpireAt35MinutesWithoutNewPackets() throws {
        let model = AppModel()
        model.experienceMode = .live
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func station(_ callsign: String, age: TimeInterval) throws -> APRSStation {
            try XCTUnwrap(APRSParser.station(
                from: "\(callsign)>APRS:!3348.00N/11753.00W-Test",
                now: now.addingTimeInterval(-age)
            ))
        }
        model.stations = try [
            station("RECENT", age: 60),
            station("JUSTIN", age: 35 * 60 - 1),
            station("BOUNDARY", age: 35 * 60),
            station("EXPIRED", age: 35 * 60 + 1)
        ]

        model.expireStations(at: now)
        XCTAssertEqual(model.stations.map(\.callsign), ["RECENT", "JUSTIN"])
        XCTAssertEqual(model.stationsWithinRadius.map(\.callsign), ["RECENT", "JUSTIN"])

        // Expiration proceeds while receiving and beaconing are both inactive.
        model.expireStations(at: now.addingTimeInterval(1))
        XCTAssertEqual(model.stations.map(\.callsign), ["RECENT"])
        model.expireStations(at: now.addingTimeInterval(35 * 60))
        XCTAssertTrue(model.nearbyStations.isEmpty)
        XCTAssertEqual(model.hiddenNearbyStationCount, 0)
    }

    @MainActor
    func testStationUpdatesRefreshExpirationAndKeepNewestFirst() throws {
        let model = AppModel()
        model.experienceMode = .live
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func station(_ callsign: String, heardAt: Date) throws -> APRSStation {
            try XCTUnwrap(APRSParser.station(
                from: "\(callsign)>APRS:!3348.00N/11753.00W-Test", now: heardAt
            ))
        }
        model.upsert(try station("OLDER", heardAt: now.addingTimeInterval(-2_000)), at: now)
        model.upsert(try station("NEWER", heardAt: now.addingTimeInterval(-100)), at: now)
        XCTAssertEqual(model.stations.map(\.callsign), ["NEWER", "OLDER"])

        model.upsert(try station("OLDER", heardAt: now), at: now)
        XCTAssertEqual(model.stations.map(\.callsign), ["OLDER", "NEWER"])
        model.expireStations(at: now.addingTimeInterval(2_000))
        XCTAssertEqual(model.stations.map(\.callsign), ["OLDER"])

        // A station that expired can reappear on its next position report.
        let later = now.addingTimeInterval(2_100)
        model.upsert(try station("NEWER", heardAt: later), at: later)
        XCTAssertEqual(model.stations.map(\.callsign), ["NEWER"])
    }

    @MainActor
    func testFirstLaunchExperienceChoice() {
        XCTAssertEqual(
            AppModel.initialExperienceMode(storedValue: nil, hasConfiguredIdentity: false),
            .undecided
        )
        XCTAssertEqual(
            AppModel.initialExperienceMode(storedValue: nil, hasConfiguredIdentity: true),
            .live
        )
        XCTAssertEqual(
            AppModel.initialExperienceMode(storedValue: "demo", hasConfiguredIdentity: true),
            .demo
        )
    }

    @MainActor
    func testDemoModeNeverUsesTheDeviceLocation() {
        let model = AppModel()
        model.experienceMode = .demo
        model.locationService.currentLocation = CLLocation(
            latitude: 33.7089,
            longitude: -117.7641
        )

        let coordinate = model.displayCoordinate!
        XCTAssertEqual(coordinate.latitude, 33.8003, accuracy: 0.000_001)
        XCTAssertEqual(coordinate.longitude, -117.8827, accuracy: 0.000_001)
    }

    @MainActor
    func testBeaconRequestsRequireLocationPermissionEvenWithCachedPosition() async {
        for status: CLAuthorizationStatus in [.notDetermined, .denied, .restricted] {
            let model = AppModel()
            model.experienceMode = .live
            model.settings.identity.callsign = "K6BAT"
            model.settings.identity.passcode = "11925"
            model.locationService.authorizationDidChange(to: status)
            // A previously obtained fix must never bypass the permission gate.
            model.locationService.currentLocation = CLLocation(latitude: 33.7, longitude: -117.7)

            await model.startBeaconing()
            XCTAssertFalse(model.isBeaconing)
            XCTAssertNil(model.nextBeaconAt)
            XCTAssertEqual(model.beaconAlertMessage, LocationService.permissionRequiredMessage)

            await model.beaconNow()
            XCTAssertNil(model.lastBeaconAt)
            XCTAssertTrue(model.trail.isEmpty)
            XCTAssertEqual(model.connectionState, .disconnected)
            XCTAssertEqual(model.beaconAlertMessage, LocationService.permissionRequiredMessage)
        }
    }

    @MainActor
    func testRevokingLocationStopsBeaconingAndRestoringDoesNotResume() {
        for status: CLAuthorizationStatus in [.denied, .restricted] {
            let model = AppModel()
            model.experienceMode = .live
            model.locationService.authorizationDidChange(to: .authorizedAlways)
            model.locationService.currentLocation = CLLocation(latitude: 33.7, longitude: -117.7)
            model.isBeaconing = true
            model.nextBeaconAt = .now.addingTimeInterval(60)

            model.locationService.authorizationDidChange(to: status)
            XCTAssertFalse(model.isBeaconing)
            XCTAssertNil(model.nextBeaconAt)
            XCTAssertNil(model.locationService.currentLocation)
            XCTAssertEqual(model.beaconAlertMessage, LocationService.permissionRequiredMessage)

            model.locationService.authorizationDidChange(to: .authorizedAlways)
            XCTAssertFalse(model.isBeaconing)
            XCTAssertNil(model.nextBeaconAt)
            XCTAssertNil(model.locationService.currentLocation)
        }
    }

    @MainActor
    func testLocationPermissionStates() {
        let service = LocationService()
        for status: CLAuthorizationStatus in [.notDetermined, .denied, .restricted] {
            service.authorizationDidChange(to: status)
            XCTAssertFalse(service.hasLocationPermission)
        }
        for status: CLAuthorizationStatus in [.authorizedWhenInUse, .authorizedAlways] {
            service.authorizationDidChange(to: status)
            XCTAssertTrue(service.hasLocationPermission)
            XCTAssertNil(service.errorMessage)
        }
    }

    @MainActor
    func testLateLocationCallbackAfterDenialIsIgnored() {
        let service = LocationService()
        service.authorizationDidChange(to: .denied)
        var receivedLocation = false
        service.onLocation = { _ in receivedLocation = true }
        service.locationManager(CLLocationManager(), didUpdateLocations: [
            CLLocation(latitude: 33.7, longitude: -117.7)
        ])
        XCTAssertNil(service.currentLocation)
        XCTAssertFalse(receivedLocation)
    }

    @MainActor
    func testBackgroundTrackingWithEitherGrantedPermission() {
        for status: CLAuthorizationStatus in [.authorizedWhenInUse, .authorizedAlways] {
            let manager = TestLocationManager()
            manager.testAuthorizationStatus = status
            let service = LocationService(manager: manager)

            service.start(background: true)
            XCTAssertTrue(manager.isUpdating)
            XCTAssertTrue(manager.allowsBackgroundLocationUpdates)
            XCTAssertTrue(manager.showsBackgroundLocationIndicator)
            XCTAssertFalse(manager.pausesLocationUpdatesAutomatically)
            XCTAssertEqual(manager.alwaysRequests, 0)

            service.stop()
            XCTAssertFalse(manager.isUpdating)
            XCTAssertFalse(manager.allowsBackgroundLocationUpdates)
            XCTAssertFalse(manager.showsBackgroundLocationIndicator)
            XCTAssertTrue(manager.pausesLocationUpdatesAutomatically)

            service.start(background: false)
            XCTAssertTrue(manager.isUpdating)
            XCTAssertFalse(manager.allowsBackgroundLocationUpdates)
            XCTAssertFalse(manager.showsBackgroundLocationIndicator)
            XCTAssertTrue(manager.pausesLocationUpdatesAutomatically)
        }
    }

    @MainActor
    func testPermissionRequestDoesNotEscalateToAlways() {
        let manager = TestLocationManager()
        let service = LocationService(manager: manager)
        service.requestPermission()
        XCTAssertEqual(manager.whenInUseRequests, 1)
        XCTAssertFalse(manager.isUpdating)

        manager.testAuthorizationStatus = .authorizedWhenInUse
        service.locationManagerDidChangeAuthorization(manager)
        XCTAssertTrue(manager.isUpdating)
        XCTAssertFalse(manager.allowsBackgroundLocationUpdates)
        service.requestPermission()
        XCTAssertEqual(manager.alwaysRequests, 0)
    }

    @MainActor
    func testRevocationStopsBackgroundTrackingWithoutRestartOnRestoration() {
        let manager = TestLocationManager()
        manager.testAuthorizationStatus = .authorizedWhenInUse
        let service = LocationService(manager: manager)
        service.start(background: true)
        service.currentLocation = CLLocation(latitude: 33.7, longitude: -117.7)

        manager.testAuthorizationStatus = .denied
        service.locationManagerDidChangeAuthorization(manager)
        XCTAssertFalse(manager.isUpdating)
        XCTAssertFalse(manager.allowsBackgroundLocationUpdates)
        XCTAssertFalse(manager.showsBackgroundLocationIndicator)
        XCTAssertNil(service.currentLocation)

        manager.testAuthorizationStatus = .authorizedWhenInUse
        service.locationManagerDidChangeAuthorization(manager)
        XCTAssertFalse(manager.isUpdating)
        XCTAssertFalse(manager.allowsBackgroundLocationUpdates)
    }

    func testReceiveRadiusStepsInSelectedUnits() throws {
        var settings = AppSettings()
        settings.display.distanceUnit = .miles
        settings.receiveRadius = 50
        XCTAssertEqual(settings.server.filterRadiusKilometers, 80)
        for expected in stride(from: 60, through: 100, by: 10) {
            settings.receiveRadius += 10
            XCTAssertEqual(settings.receiveRadius, expected)
        }
        for expected in stride(from: 90, through: 10, by: -10) {
            settings.receiveRadius -= 10
            XCTAssertEqual(settings.receiveRadius, expected)
        }
        settings.display.distanceUnit = .kilometers
        XCTAssertEqual(settings.receiveRadius, 20)
        XCTAssertEqual(settings.server.filterRadiusKilometers, 20)
        settings.receiveRadius = 80
        settings.receiveRadius += 10
        XCTAssertEqual(settings.server.filterRadiusKilometers, 90)
        settings.receiveRadius -= 10
        XCTAssertEqual(settings.server.filterRadiusKilometers, 80)
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.receiveRadius, 80)
    }

    func testReceiveRadiusChoicesIncludeSmallRadiiInBothDirections() {
        for unit in AppSettings.Display.DistanceUnit.allCases {
            var settings = AppSettings()
            settings.display.distanceUnit = unit
            settings.receiveRadiusChoiceIndex = 0
            for radius in AppSettings.receiveRadiusChoices {
                XCTAssertEqual(settings.receiveRadius, radius)
                settings.receiveRadiusChoiceIndex += 1
            }
            XCTAssertEqual(settings.receiveRadius, 100)
            for radius in AppSettings.receiveRadiusChoices.reversed() {
                XCTAssertEqual(settings.receiveRadius, radius)
                settings.receiveRadiusChoiceIndex -= 1
            }
            XCTAssertEqual(settings.receiveRadius, 1)
        }
    }

    func testUnitChangeSnapsActualFilterToNearestAllowedRadius() {
        var settings = AppSettings()
        settings.display.distanceUnit = .kilometers
        settings.receiveRadius = 90
        settings.display.distanceUnit = .miles
        XCTAssertEqual(settings.receiveRadius, 60)
        XCTAssertEqual(settings.server.filterRadiusKilometers, 97)
        settings.display.distanceUnit = .kilometers
        XCTAssertEqual(settings.receiveRadius, 100)
        XCTAssertEqual(settings.server.filterRadiusKilometers, 100)

        settings.receiveRadius = 1
        settings.display.distanceUnit = .miles
        XCTAssertEqual(settings.receiveRadius, 1)
        XCTAssertEqual(settings.server.filterRadiusKilometers, 2)
        settings.receiveRadius = 500
        settings.display.distanceUnit = .kilometers
        XCTAssertEqual(settings.receiveRadius, 100)
        XCTAssertEqual(settings.server.filterRadiusKilometers, 100)
    }

    func testLegacyReceiveRadiusIsNormalizedOnLoad() {
        var settings = AppSettings()
        settings.display.distanceUnit = .kilometers
        settings.server.filterRadiusKilometers = 85
        AppSettings.migrateLegacyValues(in: &settings)
        XCTAssertEqual(settings.receiveRadius, 90)
        XCTAssertEqual(settings.server.filterRadiusKilometers, 90)
        for unit in AppSettings.Display.DistanceUnit.allCases {
            settings.display.distanceUnit = unit
            settings.server.filterRadiusKilometers = 500
            AppSettings.migrateLegacyValues(in: &settings)
            XCTAssertEqual(settings.receiveRadius, 100)
            XCTAssertEqual(settings.server.filterRadiusKilometers, unit == .miles ? 161 : 100)
        }
    }

    func testUnifiedUnitsPreserveLegacyDistancePreference() throws {
        var display = try JSONDecoder().decode(
            AppSettings.Display.self,
            from: Data(#"{"speedUnit":"mph","distanceUnit":"Kilometers"}"#.utf8)
        )
        XCTAssertEqual(display.distanceUnit, .kilometers)
        XCTAssertEqual(display.speedUnit, .kilometersPerHour)
        let restored = try JSONDecoder().decode(
            AppSettings.Display.self, from: JSONEncoder().encode(display)
        )
        XCTAssertEqual(restored, display)
        display.distanceUnit = .miles
        XCTAssertEqual(display.speedUnit, .mph)
    }

    @MainActor
    func testRadiusEditsAreDeferredUntilLeavingSettings() {
        let model = AppModel()
        model.settings.display.distanceUnit = .kilometers
        model.settings.receiveRadiusChoiceIndex = 0
        model.beginEditingSettings()
        for _ in 0..<10 {
            model.settings.receiveRadiusChoiceIndex += 1
            XCTAssertEqual(model.activeReceiveRadiusKilometers, 1)
        }
        XCTAssertEqual(model.settings.receiveRadius, 90)
        model.endEditingSettings()
        XCTAssertEqual(model.activeReceiveRadiusKilometers, 90)
    }

    func testReceiveRadiusDoesNotChangeServerEndpoint() {
        let original = AppSettings.Server()
        var changed = original
        changed.filterRadiusKilometers = 10
        XCTAssertTrue(original.hasSameEndpoint(as: changed))
        changed.host = "localhost"
        XCTAssertFalse(original.hasSameEndpoint(as: changed))
        changed = original
        changed.port += 1
        XCTAssertFalse(original.hasSameEndpoint(as: changed))
    }

    func testReceiveFilterUpdatesOnSameConnectionAndSurvivesReconnect() async throws {
        let server = try LocalAPRSServer()
        let port = try await server.start()
        var settings = AppSettings()
        settings.identity.callsign = "N0CALL"
        settings.identity.passcode = "-1"
        settings.server.host = "127.0.0.1"
        settings.server.port = Int(port)
        let center = CLLocationCoordinate2D(latitude: 33, longitude: -117)
        let client = APRSISClient(configuration: settings, filterCenter: center)
        do {
            // A pending edit must be in the first login, not sent before login.
            try await client.updateFilter(center: center, radiusKilometers: 30)
            await client.connect()
            var lines = try await server.waitForLines(1)
            XCTAssertTrue(lines[0].hasPrefix("user "))
            XCTAssertTrue(lines[0].hasSuffix(" filter r/33.0/-117.0/30"))
            try await client.updateFilter(center: center, radiusKilometers: 40)
            lines = try await server.waitForLines(2)
            XCTAssertEqual(lines[1], "#filter r/33.0/-117.0/40")
            try await client.updateFilter(center: center, radiusKilometers: 50)
            lines = try await server.waitForLines(3)
            XCTAssertEqual(lines[2], "#filter r/33.0/-117.0/50")
            let connectionsBeforeDrop = await server.connectionCount
            XCTAssertEqual(connectionsBeforeDrop, 1)

            await server.closeConnections()
            let newCenter = CLLocationCoordinate2D(latitude: 34, longitude: -118)
            // May race socket failure; either way recovery must use this filter.
            try? await client.updateFilter(center: newCenter, radiusKilometers: 60)
            lines = try await server.waitForLogins(2)
            XCTAssertTrue(lines.last(where: { $0.hasPrefix("user ") })?.hasSuffix(" filter r/34.0/-118.0/60") == true)
            let connectionsAfterDrop = await server.connectionCount
            XCTAssertEqual(connectionsAfterDrop, 2)
            await client.disconnect()
            await server.stop()
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
    }

    func testInternationalAmateurCallsignValidation() {
        for callsign in ["K6BAT", "W1AW", "VE3ABC", "DL1ABC", "2E0ABC", "3DA0RS"] {
            XCTAssertNotNil(AmateurCallsignValidator.normalizedBase(from: callsign), callsign)
        }

        for callsign in ["", "NOTACALL", "K6BAT-16", "K6BAT/P", "12345"] {
            XCTAssertNil(AmateurCallsignValidator.normalizedBase(from: callsign), callsign)
        }
    }

    func testCallsignValidationNormalizesCaseAndSSID() {
        XCTAssertEqual(AmateurCallsignValidator.normalizedBase(from: " k6bat-5 "), "K6BAT")
    }

    func testPasscodeRequestIncludesCallsignAndAttestation() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.com/v1/passcode"))
        let request = try PasscodeRequestClient.makeRequest(endpoint: endpoint, callsign: "K6BAT")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(json["callsign"] as? String, "K6BAT")
        XCTAssertEqual(json["attestation"] as? Bool, true)
    }

    func testFccLookupRequestNormalizesCallsign() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://example.com"))
        let request = try PasscodeRequestClient.makeLookupRequest(
            baseURL: baseURL,
            callsign: " k6bat-5 "
        )

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/callsigns/K6BAT")
    }


    func testPasscodeRequestDecodesApprovedResponse() throws {
        let data = Data(
            #"{"callsign":"K6BAT","passcode":11925,"attestationRecorded":true}"#.utf8
        )

        let result = try PasscodeRequestClient.decodeResponse(data: data, statusCode: 200)

        XCTAssertEqual(result, PasscodeRequestResult(
            callsign: "K6BAT",
            passcode: 11925,
            attestationRecorded: true
        ))
    }

    func testReceiveConnectionUsesOnlineStatusRegardlessOfTransmitValidation() {
        XCTAssertEqual(AppModel.ConnectionState.connected(verified: true).shortLabel, "Online")
        XCTAssertEqual(AppModel.ConnectionState.connected(verified: false).shortLabel, "Online")
        XCTAssertEqual(AppModel.ConnectionState.unverified.shortLabel, "Online")
    }

    @MainActor
    func testInvalidPasscodeIsReportedByAppModel() {
        let model = AppModel()
        model.settings.identity.callsign = "K6BAT"
        model.settings.identity.ssid = "5"
        model.settings.identity.passcode = "12345"
        XCTAssertFalse(model.isAPRSISPasscodeValid)

        model.settings.identity.passcode = "11925"
        XCTAssertTrue(model.isAPRSISPasscodeValid)
    }

    func testLegacyDefaultBeaconMessageMigratesWithoutChangingCustomMessage() {
        var legacy = AppSettings()
        legacy.beaconing.comment = "Beacon for iOS"
        AppSettings.migrateLegacyValues(in: &legacy)
        XCTAssertEqual(legacy.beaconing.comment, "Beacon 73 for iOS")

        var customized = AppSettings()
        customized.beaconing.comment = "Mobile station"
        AppSettings.migrateLegacyValues(in: &customized)
        XCTAssertEqual(customized.beaconing.comment, "Mobile station")
    }

    func testSeparatedStationsKeepLabelsRegardlessOfCount() {
        var candidates: [StationAnnotationLayout.Candidate] = []
        for index in 0..<100 {
            let x = CGFloat(50 + (index % 10) * 100)
            let y = CGFloat(60 + (index / 10) * 70)
            candidates.append(.init(id: String(index), point: CGPoint(x: x, y: y),
                                    fullSize: CGSize(width: 80, height: 50)))
        }
        let result = StationAnnotationLayout.presentations(candidates: candidates, viewport: CGRect(x: 0, y: 0, width: 1_000, height: 800))
        XCTAssertEqual(result.count, 100)
        XCTAssertTrue(result.values.allSatisfy { $0 == .full })
    }

    func testMarkerOverlapHidesLabelsBeforeIconsAndLeavesIsolatedStationsFull() {
        let candidates: [StationAnnotationLayout.Candidate] = [
            .init(id: "A", point: CGPoint(x: 100, y: 100), fullSize: CGSize(width: 100, height: 50)),
            .init(id: "B", point: CGPoint(x: 170, y: 100), fullSize: CGSize(width: 100, height: 50)),
            .init(id: "C", point: CGPoint(x: 171, y: 100), fullSize: CGSize(width: 100, height: 50)),
            .init(id: "D", point: CGPoint(x: 300, y: 200), fullSize: CGSize(width: 100, height: 50))
        ]
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 300)
        let result = StationAnnotationLayout.presentations(candidates: candidates, viewport: viewport)
        XCTAssertEqual(result["A"], .full)
        XCTAssertEqual(result["B"], .icon)
        XCTAssertEqual(result["C"], .dot)
        XCTAssertEqual(result["D"], .full)
        XCTAssertEqual(result, StationAnnotationLayout.presentations(candidates: candidates.reversed(), viewport: viewport))
        let selected = StationAnnotationLayout.presentations(candidates: candidates, viewport: viewport, selectedID: "C")
        XCTAssertEqual(selected["C"], .full)
    }

    func testMarkerLayoutIgnoresOffscreenStationsAndReservesOwnMarker() {
        let result = StationAnnotationLayout.presentations(candidates: [
            .init(id: "Nearby", point: CGPoint(x: 100, y: 100), fullSize: CGSize(width: 80, height: 50)),
            .init(id: "Offscreen", point: CGPoint(x: -100, y: 100), fullSize: CGSize(width: 80, height: 50))
        ], viewport: CGRect(x: 0, y: 0, width: 400, height: 300),
           reserved: [CGRect(x: 60, y: 50, width: 80, height: 50)])
        XCTAssertEqual(result["Nearby"], .dot)
        XCTAssertNil(result["Offscreen"])
    }

    func testDefaultMapSpanIncludesTheConfiguredStationRadius() {
        XCTAssertEqual(
            NearbyStationMapLayout.defaultSpanMeters(radiusKilometers: 80),
            160_000
        )
    }

    func testDashboardMapGrowsWhileReservingVisibleControls() {
        let heights: [CGFloat] = [400, 600, 900, 1_200]
        var previous: CGFloat = 0
        for height in heights {
            let map = DashboardLayout.mapHeight(availableHeight: height, headerHeight: 64, controlsHeight: 182)
            XCTAssertGreaterThan(map, previous)
            XCTAssertLessThanOrEqual(map + 64 + 12 + 182 + 32, height)
            previous = map
        }
        let normal = DashboardLayout.mapHeight(availableHeight: 600, headerHeight: 64, controlsHeight: 182)
        let largeText = DashboardLayout.mapHeight(availableHeight: 600, headerHeight: 90, controlsHeight: 240)
        XCTAssertLessThan(largeText, normal)
        XCTAssertGreaterThanOrEqual(DashboardLayout.mapHeight(availableHeight: 100, headerHeight: 64, controlsHeight: 182), 0)
    }

    @MainActor
    func testBeaconNowUsesTenSecondCooldown() {
        let now = Date()

        XCTAssertEqual(
            AppModel.beaconNowCooldownRemaining(
                lastBeaconAt: now.addingTimeInterval(-2.2),
                lastManualAttemptAt: nil,
                now: now
            ),
            8
        )
        XCTAssertEqual(
            AppModel.beaconNowCooldownRemaining(
                lastBeaconAt: now.addingTimeInterval(-12),
                lastManualAttemptAt: now.addingTimeInterval(-4),
                now: now
            ),
            6
        )
        XCTAssertEqual(
            AppModel.beaconNowCooldownRemaining(
                lastBeaconAt: now.addingTimeInterval(-10),
                lastManualAttemptAt: nil,
                now: now
            ),
            0
        )
    }

    func testAPRSISVerifiedLoginResponse() {
        XCTAssertEqual(
            APRSISClient.loginVerification(from: "# logresp K6BAT-5 verified, server T2CHILE"),
            true
        )
        XCTAssertEqual(
            APRSISClient.loginVerification(from: "# logresp K6BAT-5 unverified, server T2TEST"),
            false
        )
    }

    func testAPRSISStreamFramingHandlesSplitCRLFChunks() {
        var buffer = Data()
        let first = APRSISClient.extractLines(
            from: &buffer,
            appending: Data("# logresp K6BAT-5 verified\r".utf8)
        )
        let second = APRSISClient.extractLines(
            from: &buffer,
            appending: Data("\nK4NSY-R>APRS:!3339.29N/11745.23Wr".utf8)
        )
        let third = APRSISClient.extractLines(
            from: &buffer,
            appending: Data("\r\n".utf8)
        )

        XCTAssertEqual(first, ["# logresp K6BAT-5 verified"])
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(third, ["K4NSY-R>APRS:!3339.29N/11745.23Wr"])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testK6BATPasscodeValidationIgnoresSSID() {
        XCTAssertEqual(APRSISClient.expectedPasscode(for: "K6BAT"), 11925)
        XCTAssertEqual(APRSISClient.expectedPasscode(for: "K6BAT-5"), 11925)
        XCTAssertTrue(APRSISClient.passcode("11925", isValidFor: "K6BAT-5"))
        XCTAssertFalse(APRSISClient.passcode("11924", isValidFor: "K6BAT-5"))
    }

    func testAPRSSymbolSpritesAreBundled() {
        XCTAssertNotNil(Bundle.main.url(forResource: "aprs-symbols-64-0", withExtension: "png"))
        XCTAssertNotNil(Bundle.main.url(forResource: "aprs-symbols-64-1", withExtension: "png"))
        XCTAssertNotNil(Bundle.main.url(forResource: "APRS-SYMBOLS-COPYRIGHT", withExtension: "md"))
    }

    func testEmptyIdentityDoesNotRenderSSIDByItself() {
        let identity = AppSettings.Identity()

        XCTAssertEqual(identity.fullCallsign, "")
        XCTAssertFalse(identity.isReady)
    }

    func testIdentityEnforcesValidSSIDRange() {
        var identity = AppSettings.Identity()
        identity.callsign = "k6bat"

        identity.ssid = "0"
        XCTAssertEqual(identity.fullCallsign, "K6BAT")

        identity.ssid = "15"
        XCTAssertEqual(identity.fullCallsign, "K6BAT-15")

        identity.ssid = "16"
        XCTAssertEqual(identity.fullCallsign, "K6BAT")
    }

    func testLegacyFixedModeMigratesToTimed() throws {
        let mode = try JSONDecoder().decode(
            AppSettings.Beaconing.Mode.self,
            from: Data("\"Fixed\"".utf8)
        )

        XCTAssertEqual(mode, .timed)
    }

    func testTimedModeUsesSelectedInterval() {
        let now = Date()
        let previous = CLLocation(latitude: 33.7, longitude: -117.7)
        let current = CLLocation(latitude: 33.8, longitude: -117.8)
        var configuration = AppSettings.Beaconing()
        configuration.mode = .timed
        configuration.timedInterval = 90

        let decision = SmartBeaconingPolicy().decision(
            current: current,
            previousBeacon: previous,
            lastBeaconAt: now.addingTimeInterval(-90),
            configuration: configuration,
            now: now
        )

        XCTAssertTrue(decision.shouldBeacon)
        XCTAssertEqual(decision.reason, "Interval elapsed")
    }

    func testPositionPacketUsesTNC2AndUncompressedCoordinates() {
        let location = CLLocation(
            coordinate: .init(latitude: 33.708865, longitude: -117.764063),
            altitude: 62,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 128,
            speed: 15.2,
            timestamp: .now
        )

        let packet = APRSPacket.position(callsign: "K6BAT-5", location: location, symbol: "/>", comment: "Beacon")

        XCTAssertEqual(packet.source, "K6BAT-5")
        XCTAssertEqual(packet.destination, "APB730")
        XCTAssertTrue(packet.tnc2.hasPrefix("K6BAT-5>APB730,TCPIP*:!3342.53N/11745.84W>128/030"))
        XCTAssertTrue(packet.tnc2.hasSuffix("Beacon"))
    }

    func testAlternateSymbolTableIsEncodedInPosition() {
        let location = CLLocation(latitude: 33.708865, longitude: -117.764063)

        let packet = APRSPacket.position(callsign: "K6BAT-5", location: location, symbol: "\\>", comment: "")

        XCTAssertTrue(packet.information.hasPrefix("!3342.53N\\11745.84W>"))
    }

    func testParserReadsPositionCourseAndSpeed() {
        let station = APRSParser.station(from: "K6BAT-5>APRS,TCPIP*:!3342.53N/11745.84W>128/030Mobile")

        XCTAssertEqual(station?.callsign, "K6BAT-5")
        XCTAssertEqual(station?.coordinate.latitude ?? 0, 33.708833, accuracy: 0.00001)
        XCTAssertEqual(station?.coordinate.longitude ?? 0, -117.764, accuracy: 0.00001)
        XCTAssertEqual(station?.course, 128)
        XCTAssertEqual(station?.comment, "Mobile")
        XCTAssertEqual(station?.symbolTable, "/")
        XCTAssertEqual(station?.symbol, ">")
    }

    func testParserReadsLiveUncompressedPackets() {
        let station = APRSParser.station(
            from: "K4NSY-R>APDG03,TCPIP*,qAC,K4NSY-RS:!3339.29N/11745.23Wr/A=00000070cm MMDVM"
        )

        XCTAssertEqual(station?.callsign, "K4NSY-R")
        XCTAssertEqual(station?.coordinate.latitude ?? 0, 33.654833, accuracy: 0.00001)
        XCTAssertEqual(station?.coordinate.longitude ?? 0, -117.753833, accuracy: 0.00001)
        XCTAssertEqual(station?.symbolTable, "/")
        XCTAssertEqual(station?.symbol, "r")
        XCTAssertEqual(station?.comment, "70cm MMDVM")
    }

    func testParserReadsCompressedPositionPackets() {
        let station = APRSParser.station(
            from: "KO6DSS-10>APLRG1,TCPIP*,qAC,T2FRANCE:=L=Y7v0o6ca !GLoRa APRS"
        )

        XCTAssertEqual(station?.callsign, "KO6DSS-10")
        XCTAssertEqual(station?.coordinate.latitude ?? 0, 33.386, accuracy: 0.001)
        XCTAssertEqual(station?.coordinate.longitude ?? 0, -117.25, accuracy: 0.01)
        XCTAssertEqual(station?.symbolTable, "L")
        XCTAssertEqual(station?.symbol, "a")
        XCTAssertEqual(station?.comment, "LoRa APRS")
    }

    func testParserCleansMachineFieldsFromStationComments() {
        let station = APRSParser.station(
            from: "K6NTE-7>APDW18,TCPIP*:!3411.61NR11820.62W&PHG2000Burbank"
        )
        let altitudeStation = APRSParser.station(
            from: "KE6UAF>APRS:!3342.95N/11708.77W[/A=000271via APRS"
        )

        XCTAssertEqual(station?.comment, "Burbank")
        XCTAssertEqual(altitudeStation?.comment, "via APRS")
    }

    func testParserRemovesDAOExtensionsWithoutRemovingHumanPunctuation() {
        let daoStation = APRSParser.station(
            from: "K6BAT-5>APRS:!3342.53N/11745.84W>!wAB!Heading home!"
        )
        let humanComment = APRSParser.station(
            from: "K6BAT-5>APRS:!3342.53N/11745.84W>Great signal!"
        )

        XCTAssertEqual(daoStation?.comment, "Heading home!")
        XCTAssertEqual(humanComment?.comment, "Great signal!")
    }

    func testParserFormatsWeatherCommentForDisplay() {
        let station = APRSParser.station(
            from: "K6CED>APRS:@182322z3332.32N/11706.70W_261/000g005t080r000p000P000h50b10174L339AmbientCWOP.com"
        )

        XCTAssertEqual(
            station?.comment,
            "80°F · Gust 5 mph · Humidity 50% · 1017.4 hPa · AmbientCWOP.com"
        )
    }

    func testStationTypeClassification() {
        let moving = APRSParser.station(from: "MOBILE>APRS:!3342.53N/11745.84W>000/000Car")
        let fixed = APRSParser.station(from: "REPEATER>APRS:!3342.53N/11745.84WrRepeater")
        let weather = APRSParser.station(from: "WEATHER>APRS:!3342.53N/11745.84W_000/000t080")

        XCTAssertEqual(moving?.stationType, .moving)
        XCTAssertEqual(fixed?.stationType, .fixed)
        XCTAssertEqual(weather?.stationType, .weather)
    }

    func testLegacyDisplaySettingsDefaultToMovingStationsOnly() throws {
        let display = try JSONDecoder().decode(
            AppSettings.Display.self,
            from: Data(#"{"speedUnit":"mph","distanceUnit":"Miles","showStations":true,"showTrail":true}"#.utf8)
        )

        XCTAssertTrue(display.showMovingStations)
        XCTAssertFalse(display.showFixedStations)
        XCTAssertFalse(display.showWeatherStations)
    }

    func testParserReadsMicEPositionPackets() {
        let station = APRSParser.station(
            from: "K6EYE-9>SWTUVY,WR6ABD,K6FGA-1*,WIDE2:`26SmJ`E/]\"4V}="
        )

        XCTAssertEqual(station?.callsign, "K6EYE-9")
        XCTAssertEqual(station?.coordinate.latitude ?? 0, 37.7615, accuracy: 0.0001)
        XCTAssertEqual(station?.coordinate.longitude ?? 0, -122.4425, accuracy: 0.0001)
        XCTAssertEqual(station?.course, 268)
        XCTAssertEqual(station?.speedMetersPerSecond ?? 0, 7.202, accuracy: 0.01)
        XCTAssertEqual(station?.symbolTable, "/")
        XCTAssertEqual(station?.symbol, "E")
    }

    func testParserExtractsMicEAltitudeAndRemovesDeviceIdentifier() {
        let station = APRSParser.station(
            from: "KJ6SVN-7>STPQRR,WIDE1-1,WIDE2-1,qAR,N6KMA:`-J:m4/>/`\"7+}_%"
        )

        XCTAssertEqual(station?.symbol, ">")
        XCTAssertEqual(station?.symbolTable, "/")
        XCTAssertEqual(station?.altitudeMeters, 293)
        XCTAssertEqual(station?.comment, "")
        XCTAssertEqual(station?.equipment, "Yaesu FTM-400DR")
    }

    func testParserDecodesLegacyMicEEquipmentIdentifiers() {
        let thd75 = APRSParser.station(
            from: "KO6KWA-9>STPQRR,WIDE1-1:`-J:m4/>/>&"
        )
        let tmD700 = APRSParser.station(
            from: "KI6NAZ>STPQRR,WIDE1-1:`-J:m4/>/]&"
        )

        XCTAssertEqual(thd75?.equipment, "Kenwood TH-D75")
        XCTAssertEqual(thd75?.comment, "")
        XCTAssertEqual(tmD700?.equipment, "Kenwood TM-D700 family")
        XCTAssertEqual(tmD700?.comment, "")
    }

    func testParserReadsMicEPositionWithAmbiguity() {
        let station = APRSParser.station(
            from: "AJ6EE-2>S3UQZZ,WIDE1-1,WIDE2-1,qAO,W6MFB:`-P\u{001C}l!*YY`\"4n}_5"
        )

        XCTAssertEqual(station?.coordinate.latitude ?? 0, 33.858333, accuracy: 0.00001)
        XCTAssertEqual(station?.coordinate.longitude ?? 0, -117.875, accuracy: 0.00001)
        XCTAssertEqual(station?.stationType, .moving)
        XCTAssertEqual(station?.equipment, "Yaesu FTM-510D")
    }

    func testAutomaticBeaconsWaitThirtySecondsEvenWithShortConfiguredIntervals() {
        let sentAt = Date()
        let location = CLLocation(latitude: 33.7, longitude: -117.7)
        for mode in [AppSettings.Beaconing.Mode.smart, .timed] {
            var configuration = AppSettings.Beaconing()
            configuration.mode = mode
            configuration.timedInterval = 5
            configuration.stoppedInterval = 5
            for elapsed: TimeInterval in [10, 29.9, 30] {
                let decision = SmartBeaconingPolicy().decision(
                    current: location, previousBeacon: location, lastBeaconAt: sentAt,
                    configuration: configuration, now: sentAt.addingTimeInterval(elapsed)
                )
                XCTAssertEqual(decision.shouldBeacon, elapsed >= 30)
                XCTAssertEqual(decision.nextBeaconAt, sentAt.addingTimeInterval(30))
            }
        }
    }

    func testTurnBeaconWaitsThirtySeconds() {
        let sentAt = Date()
        func location(course: Double) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 33.7, longitude: -117.7),
                       altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                       course: course, speed: 10, timestamp: sentAt)
        }
        for elapsed: TimeInterval in [15, 29.9, 30] {
            let decision = SmartBeaconingPolicy().decision(
                current: location(course: 90), previousBeacon: location(course: 0),
                lastBeaconAt: sentAt, configuration: .init(),
                now: sentAt.addingTimeInterval(elapsed)
            )
            XCTAssertEqual(decision.shouldBeacon, elapsed >= 30)
            if elapsed >= 30 { XCTAssertEqual(decision.reason, "Heading changed") }
        }
    }

    func testSmartBeaconingSendsFirstPosition() {
        let location = CLLocation(latitude: 33.7, longitude: -117.7)
        let decision = SmartBeaconingPolicy().decision(
            current: location,
            previousBeacon: nil,
            lastBeaconAt: nil,
            configuration: .init()
        )
        XCTAssertTrue(decision.shouldBeacon)
        XCTAssertEqual(decision.reason, "First position")
    }
}

private final class TestLocationManager: CLLocationManager {
    var testAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    var isUpdating = false
    var whenInUseRequests = 0
    var alwaysRequests = 0

    override var authorizationStatus: CLAuthorizationStatus { testAuthorizationStatus }
    override var allowsBackgroundLocationUpdates: Bool {
        get { backgroundUpdates }
        set { backgroundUpdates = newValue }
    }
    override var showsBackgroundLocationIndicator: Bool {
        get { backgroundIndicator }
        set { backgroundIndicator = newValue }
    }
    override var pausesLocationUpdatesAutomatically: Bool {
        get { automaticPausing }
        set { automaticPausing = newValue }
    }
    private var automaticPausing = true
    private var backgroundUpdates = false
    private var backgroundIndicator = false

    override func startUpdatingLocation() { isUpdating = true }
    override func stopUpdatingLocation() { isUpdating = false }
    override func requestWhenInUseAuthorization() { whenInUseRequests += 1 }
    override func requestAlwaysAuthorization() { alwaysRequests += 1 }
}

// Local TCP peer: exercises real socket ordering and recovery without APRS-IS traffic.
private actor LocalAPRSServer {
    enum Failure: Error { case timedOut(String) }
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var buffers: [Int: Data] = [:]
    private var lines: [String] = []
    private(set) var connectionCount = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: DispatchQueue(label: "BeaconTests.listener"))
        for _ in 0..<200 {
            if let port = listener.port, port.rawValue > 0 { return port.rawValue }
            try await Task.sleep(for: .milliseconds(25))
        }
        listener.cancel()
        throw Failure.timedOut("Local peer did not become ready")
    }

    private func accept(_ connection: NWConnection) {
        let id = connectionCount
        connectionCount += 1
        connections.append(connection)
        connection.start(queue: DispatchQueue(label: "BeaconTests.peer"))
        receive(connection, id: id)
    }

    private func receive(_ connection: NWConnection, id: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { await self?.received(data, connection: connection, id: id, ended: complete || error != nil) }
        }
    }

    private func received(_ data: Data?, connection: NWConnection, id: Int, ended: Bool) {
        if let data {
            var buffer = buffers[id] ?? Data()
            lines += APRSISClient.extractLines(from: &buffer, appending: data)
            buffers[id] = buffer
        }
        if !ended { receive(connection, id: id) }
    }

    func waitForLines(_ count: Int) async throws -> [String] {
        for _ in 0..<400 {
            if lines.count >= count { return lines }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure.timedOut("Expected \(count) lines; got \(lines.count), connections \(connectionCount)")
    }

    func waitForLogins(_ count: Int) async throws -> [String] {
        for _ in 0..<400 {
            if lines.filter({ $0.hasPrefix("user ") }).count >= count { return lines }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure.timedOut("Expected \(count) logins; got \(lines.filter { $0.hasPrefix("user ") }.count), total lines \(lines.count), connections \(connectionCount)")
    }

    func closeConnections() {
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }

    func stop() {
        listener.cancel()
        closeConnections()
    }
}
