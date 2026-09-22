import MapKit
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var mapPosition: MapCameraPosition = .region(.preview)
    @State private var visibleMapRegion = MKCoordinateRegion.preview
    @State private var expandedMapPosition: MapCameraPosition = .region(.preview)
    @State private var expandedMapRegion = MKCoordinateRegion.preview
    @State private var expandedMapRegionBeforeStationDetail: MKCoordinateRegion?
    @State private var didCenterOnUser = false
    @State private var isShowingExpandedMap = false
    let showSettings: () -> Void

    private var userCoordinate: CLLocationCoordinate2D {
        model.displayCoordinate ?? .preview
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let portraitMapHeight = DashboardLayout.mapHeight(for: geometry.size)

            NavigationStack {
                Group {
                    if isLandscape {
                        landscapeMap
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                dashboardHeader
                                compactMap(height: portraitMapHeight)
                                BeaconControlCard(showSettings: showSettings)
                                beaconNowButton
                                TelemetryGrid()
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                        }
                        .background(Color(uiColor: .systemBackground))
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(isLandscape ? .hidden : .visible, for: .tabBar)
                .sheet(item: Bindable(model).selectedStation, onDismiss: restoreExpandedMapAfterStationDetail) { station in
                    StationDetailView(station: station, from: userCoordinate)
                        .presentationDetents([.medium])
                }
                .fullScreenCover(isPresented: $isShowingExpandedMap) {
                    expandedMap
                }
                .alert("Beaconing unavailable", isPresented: Binding(
                    get: { model.beaconAlertMessage != nil },
                    set: { if !$0 { model.beaconAlertMessage = nil } }
                )) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text(model.beaconAlertMessage ?? "Unknown error")
                }
            }
        }
    }

    private var dashboardHeader: some View {
        HStack(alignment: .center, spacing: 9) {
            HStack(spacing: 4) {
                Text("Beacon").foregroundStyle(.primary)
                Text("73").foregroundStyle(.orange)
            }
            .font(.title.bold())

            Spacer()

            APRSConnectionIndicator()

            Button(action: showSettings) {
                Image(systemName: "gearshape")
                    .font(.title2)
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.top, 6)
    }

    private var beaconNowButton: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let remaining = model.beaconNowCooldownRemaining(at: timeline.date)
            Button {
                Task { await model.beaconNow() }
            } label: {
                Label(
                    remaining > 0 ? "Send Beacon in \(remaining)s" : "Send Beacon Now",
                    systemImage: "paperplane.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isDemoMode || remaining > 0)
            .accessibilityHint(
                remaining > 0
                    ? "Available again in \(remaining) seconds"
                    : "Immediately sends your current position to APRS-IS"
            )
        }
    }

    private func compactMap(height: CGFloat) -> some View {
        aprsMap(position: $mapPosition, visibleRegion: $visibleMapRegion, centersOnUser: true)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .topLeading) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(10)
                    .allowsHitTesting(false)
            }
            .simultaneousGesture(
                TapGesture().onEnded { showExpandedMap() }
            )
            .accessibilityAction(named: "Open full-screen map") {
                showExpandedMap()
            }
    }

    private var expandedMap: some View {
        NavigationStack {
            aprsMap(
                position: $expandedMapPosition,
                visibleRegion: $expandedMapRegion,
                centersOnUser: false
            )
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Map")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismissExpandedMap() }
                    }
                }
        }
    }

    private var landscapeMap: some View {
        aprsMap(position: $mapPosition, visibleRegion: $visibleMapRegion, centersOnUser: true)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                APRSConnectionIndicator()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: showSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.headline)
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("Settings")
                .padding(12)
            }
    }

    private func aprsMap(
        position: Binding<MapCameraPosition>,
        visibleRegion: Binding<MKCoordinateRegion>,
        centersOnUser: Bool
    ) -> some View {
        GeometryReader { geometry in
            let region = visibleRegion.wrappedValue
            let visibleStationCount = StationAnnotationLayout.visibleStationCount(
                in: region,
                stations: model.nearbyStations
            )
            let usesCompactMarkers = StationAnnotationLayout.isCompact(
                latitudeDelta: region.span.latitudeDelta,
                viewportSize: geometry.size,
                visibleStationCount: visibleStationCount
            )

            Map(position: position, selection: Binding(
                get: { model.selectedStation?.id },
                set: { id in
                    if id != nil, model.selectedStation == nil, isShowingExpandedMap {
                        expandedMapRegionBeforeStationDetail = expandedMapRegion
                    }
                    model.selectedStation = model.nearbyStations.first { $0.id == id }
                }
            )) {
                if !model.isDemoMode {
                    Annotation(
                        "",
                        coordinate: userCoordinate
                    ) {
                        APRSSymbolMapMarker(
                            symbol: APRSSymbolCatalog.selection(from: model.settings.beaconing.symbol),
                            callsign: model.settings.identity.fullCallsign,
                            isActive: model.isBeaconing
                        )
                    }
                }

                ForEach(model.nearbyStations) { station in
                    Annotation("", coordinate: station.coordinate, anchor: .bottom) {
                        APRSSymbolMapMarker(
                            symbol: station.symbolSelection,
                            overlay: station.symbolOverlay,
                            callsign: station.callsign,
                            isActive: false,
                            isCompact: usesCompactMarkers
                        )
                    }
                    .tag(station.id)
                }

            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted))
            .mapControls {
                MapCompass()
                MapUserLocationButton()
            }
            .onAppear {
                if centersOnUser { centerOnUserIfAvailable() }
            }
            .onChange(of: model.locationService.currentLocation?.timestamp) { _, _ in
                if centersOnUser { centerOnUserIfAvailable() }
            }
            .onChange(of: model.settings.server.filterRadiusKilometers) { _, _ in
                if centersOnUser { resetMapToNearbyStationRadius() }
            }
            .onMapCameraChange(frequency: .continuous) { context in
                visibleRegion.wrappedValue = context.region
            }
        }
    }

    private func centerOnUserIfAvailable() {
        guard !didCenterOnUser,
              model.locationService.currentLocation != nil || model.isDemoMode else { return }
        resetMapToNearbyStationRadius()
        didCenterOnUser = true
    }

    private func resetMapToNearbyStationRadius() {
        guard model.locationService.currentLocation != nil || model.isDemoMode else { return }
        let region = NearbyStationMapLayout.defaultRegion(
            center: userCoordinate,
            radiusKilometers: model.settings.server.filterRadiusKilometers
        )
        visibleMapRegion = region
        mapPosition = .region(region)
    }

    private func showExpandedMap() {
        expandedMapRegion = visibleMapRegion
        expandedMapPosition = .region(visibleMapRegion)
        expandedMapRegionBeforeStationDetail = nil
        isShowingExpandedMap = true
    }

    private func dismissExpandedMap() {
        visibleMapRegion = expandedMapRegion
        mapPosition = .region(expandedMapRegion)
        isShowingExpandedMap = false
    }

    private func restoreExpandedMapAfterStationDetail() {
        guard isShowingExpandedMap,
              let savedRegion = expandedMapRegionBeforeStationDetail else { return }
        expandedMapRegion = savedRegion
        expandedMapPosition = .region(savedRegion)
        expandedMapRegionBeforeStationDetail = nil
    }

}

enum DashboardLayout {
    static func mapHeight(for viewportSize: CGSize) -> CGFloat {
        guard viewportSize.width >= 700 else { return 225 }
        return min(max(viewportSize.height * 0.46, 360), 640)
    }
}

private struct APRSConnectionIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let isTransmitting = model.lastBeaconAt.map {
                timeline.date.timeIntervalSince($0) >= 0 && timeline.date.timeIntervalSince($0) < 2
            } ?? false

            HStack(spacing: 5) {
                Circle()
                    .fill(model.isDemoMode
                          ? .orange
                          : (isTransmitting ? .orange : (model.connectionState.isConnected ? .green : .secondary)))
                    .frame(width: 8, height: 8)
                Text(model.isDemoMode
                     ? "Demo"
                     : (isTransmitting ? "APRS TX" : model.connectionState.shortLabel))
                    .font(.caption.weight(.medium))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.isDemoMode
                                ? "Demo Mode"
                                : (isTransmitting ? "APRS transmitting" : model.connectionState.shortLabel))
        }
    }
}

private struct BeaconControlCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let showSettings: () -> Void

    private var hasCallsign: Bool {
        !model.settings.identity.fullCallsign.isEmpty
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !model.isBeaconing || reduceMotion)) { timeline in
            let pulse = glowIntensity(at: timeline.date)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    if model.isDemoMode {
                        Text("DEMO")
                            .font(.title2.bold().monospaced())
                    } else if hasCallsign {
                        Text(model.settings.identity.fullCallsign)
                            .font(.title2.bold().monospaced())
                    } else {
                        Button(action: showSettings) {
                            HStack(spacing: 5) {
                                Text("Set your callsign")
                                Image(systemName: "chevron.right")
                                    .font(.subheadline.bold())
                            }
                            .font(.title2.bold())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        .accessibilityHint("Opens amateur identity settings")
                    }
                    Text(model.isDemoMode
                         ? "Transmitting is disabled"
                         : (model.isBeaconing ? "Auto-beaconing is ON" : "Auto-beaconing is off"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Auto-beaconing", isOn: Binding(
                    get: { model.isBeaconing },
                    set: { _ in Task { await model.toggleBeaconing() } }
                ))
                .labelsHidden()
                .tint(.green)
                .disabled(model.isDemoMode || !hasCallsign)
            }
            .padding(16)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.green.opacity(model.isBeaconing ? 0.3 + (0.6 * pulse) : 0), lineWidth: 1.5)
            }
            .shadow(
                color: .green.opacity(model.isBeaconing ? 0.18 + (0.47 * pulse) : 0),
                radius: model.isBeaconing ? 4 + (9 * pulse) : 0
            )
        }
    }

    private func glowIntensity(at date: Date) -> Double {
        guard model.isBeaconing else { return 0 }
        guard !reduceMotion else { return 0.35 }
        let cycle = date.timeIntervalSinceReferenceDate * (.pi / 1.15)
        return (sin(cycle) + 1) / 2
    }
}

private struct TelemetryGrid: View {
    @Environment(AppModel.self) private var model
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            tiles(at: timeline.date)
        }
    }

    private func tiles(at now: Date) -> some View {
        LazyVGrid(columns: columns, spacing: 6) {
            TelemetryTile(title: "Last Beacon", value: model.lastBeaconAt?.relativeLabel(at: now) ?? "Not yet", detail: model.lastBeaconAt?.formatted(date: .omitted, time: .shortened), icon: "circle.fill", tint: model.lastBeaconAt == nil ? .secondary : .green)
            TelemetryTile(title: "Next Beacon", value: model.nextBeaconAt?.countdownLabel(at: now) ?? "—", detail: model.settings.beaconing.mode.rawValue, icon: "clock.fill", tint: .blue)
            TelemetryTile(title: "GPS Accuracy", value: model.locationService.currentLocation?.accuracyLabel ?? "—", detail: nil, icon: "scope", tint: .blue)
            TelemetryTile(title: "Speed", value: model.locationService.currentLocation?.speedLabel(unit: model.settings.display.speedUnit) ?? "—", detail: nil, icon: "car.fill", tint: .blue)
            TelemetryTile(title: "Altitude", value: model.locationService.currentLocation?.altitudeLabel ?? "—", detail: nil, icon: "mountain.2.fill", tint: .secondary)
            TelemetryTile(title: "Heading", value: model.locationService.currentLocation?.headingLabel ?? "—", detail: nil, icon: "location.fill", tint: .blue)
        }
    }
}

private struct TelemetryTile: View {
    let title: String
    let value: String
    let detail: String?
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            Text(detail ?? " ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
        .padding(11)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct TrackView: View {
    @Environment(AppModel.self) private var model

    private var fallback: CLLocationCoordinate2D {
        model.displayCoordinate ?? .preview
    }

    var body: some View {
        NavigationStack {
            Map(initialPosition: .region(region)) {
                if model.trail.count > 1 {
                    MapPolyline(coordinates: model.trail)
                        .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                Marker(
                    model.trail.isEmpty ? "Current Position" : "Latest Beacon",
                    coordinate: model.trail.last ?? fallback
                )
                .tint(.blue)
            }
            .mapStyle(.standard(elevation: .flat))
            .navigationTitle("Track")
            .overlay(alignment: .top) {
                if model.trail.isEmpty {
                    Text("Your transmitted beacons will appear here")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
        }
    }

    private var region: MKCoordinateRegion {
        MKCoordinateRegion(center: model.trail.last ?? fallback, latitudinalMeters: 10_000, longitudinalMeters: 10_000)
    }
}

enum StationAnnotationLayout {
    private static let metersPerDegreeLatitude = 111_000.0
    private static let pointsPerFullMarker = 30_000.0

    static func isCompact(
        latitudeDelta: CLLocationDegrees,
        viewportSize: CGSize,
        visibleStationCount: Int
    ) -> Bool {
        let spanMeters = latitudeDelta * metersPerDegreeLatitude
        return spanMeters > maximumFullMarkerSpan(for: viewportSize)
            || visibleStationCount > fullMarkerCapacity(for: viewportSize)
    }

    static func maximumFullMarkerSpan(for viewportSize: CGSize) -> CLLocationDistance {
        switch min(viewportSize.width, viewportSize.height) {
        case ..<350: 80_000
        case ..<600: 160_000
        default: 1_000_000
        }
    }

    static func fullMarkerCapacity(for viewportSize: CGSize) -> Int {
        let area = max(0, viewportSize.width * viewportSize.height)
        return min(60, max(4, Int(area / pointsPerFullMarker)))
    }

    static func visibleStationCount(
        in region: MKCoordinateRegion,
        stations: [APRSStation]
    ) -> Int {
        let halfLatitude = region.span.latitudeDelta / 2
        let halfLongitude = region.span.longitudeDelta / 2
        return stations.count { station in
            abs(station.coordinate.latitude - region.center.latitude) <= halfLatitude
                && abs(station.coordinate.longitude - region.center.longitude) <= halfLongitude
        }
    }
}

enum NearbyStationMapLayout {
    static func defaultSpanMeters(radiusKilometers: Int) -> CLLocationDistance {
        Double(radiusKilometers) * 2_000
    }

    static func defaultRegion(
        center: CLLocationCoordinate2D,
        radiusKilometers: Int
    ) -> MKCoordinateRegion {
        let spanMeters = defaultSpanMeters(radiusKilometers: radiusKilometers)
        return MKCoordinateRegion(
            center: center,
            latitudinalMeters: spanMeters,
            longitudinalMeters: spanMeters
        )
    }
}

struct APRSSymbolMapMarker: View {
    let symbol: APRSSymbol
    var overlay: Character?
    let callsign: String
    let isActive: Bool
    var isCompact = false

    var body: some View {
        Group {
            if isCompact {
                Circle()
                    .fill(.blue)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.white, lineWidth: 1.25))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .frame(width: 17, height: 17)
            } else {
                VStack(spacing: 2) {
                    if !callsign.isEmpty {
                        Text(callsign)
                            .font(.caption2.bold().monospaced())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.72), in: Capsule())
                    }
                    APRSSymbolIcon(symbol: symbol, size: 26, overlay: overlay)
                        .padding(2)
                        .background(.black.opacity(0.58), in: Circle())
                        .overlay(Circle().stroke(isActive ? .green : .white, lineWidth: isActive ? 3 : 1.5))
                        .shadow(color: .black.opacity(0.55), radius: 3, y: 2)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isCompact)
        .accessibilityLabel(callsign.isEmpty ? "My Position" : callsign)
    }
}

private extension MKCoordinateRegion {
    static let preview = MKCoordinateRegion(center: .preview, latitudinalMeters: 8_000, longitudinalMeters: 8_000)
}

private extension CLLocationCoordinate2D {
    static let preview = AppModel.demoCenterCoordinate
}
