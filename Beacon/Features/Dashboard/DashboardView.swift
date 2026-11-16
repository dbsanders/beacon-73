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

            NavigationStack {
                Group {
                    if isLandscape {
                        landscapeMap
                    } else {
                        VStack(spacing: 12) {
                            dashboardHeader
                            DashboardCardLayout {
                                compactMap(height: nil)
                                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                AutoBeaconButton(showSettings: showSettings)
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                                    .allowsHitTesting(false)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        .background(Color(uiColor: .systemBackground))
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            BeaconSummaryPanel()
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .padding(.horizontal, 14)
                                .padding(.bottom, 8)
                        }
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
                    Text(model.beaconAlertMessage ?? String(localized: "Unknown error"))
                }
            }
        }
    }

    private var dashboardHeader: some View {
        HStack(alignment: .center, spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("Beacon").foregroundStyle(.primary)
                    Text("73").foregroundStyle(.orange)
                }
                .font(.title.bold())
                if !model.settings.identity.fullCallsign.isEmpty && !model.isDemoMode {
                    Text(model.settings.identity.fullCallsign)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

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

    private func compactMap(height: CGFloat?) -> some View {
        aprsMap(position: $mapPosition, visibleRegion: $visibleMapRegion, centersOnUser: true)
            .frame(height: height)
            .clipped()
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
            MapReader { proxy in
                // Reading the camera region refreshes projection when the map moves or zooms.
                let _ = visibleRegion.wrappedValue
                let candidates = model.nearbyStations.compactMap { station -> StationAnnotationLayout.Candidate? in
                    guard let point = proxy.convert(station.coordinate, to: .local) else { return nil }
                    return .init(id: station.id, point: point, fullSize: StationAnnotationLayout.markerSize(callsign: station.callsign))
                }
                let ownBounds: [CGRect] = !model.isDemoMode ? proxy.convert(userCoordinate, to: .local).map { point in
                    let size = StationAnnotationLayout.markerSize(callsign: model.settings.identity.fullCallsign)
                    return [CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)]
                } ?? [] : []
                let presentations = StationAnnotationLayout.presentations(
                    candidates: candidates, viewport: CGRect(origin: .zero, size: geometry.size),
                    reserved: ownBounds, selectedID: model.selectedStation?.id
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
                                isCompact: presentations[station.id] == .dot,
                                showsCallsign: presentations[station.id] != .icon
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
    static func mapHeight(availableHeight: CGFloat, headerHeight: CGFloat, controlsHeight: CGFloat) -> CGFloat {
        // Keep the controls and breathing room visible before allocating space to the map.
        let remaining = max(0, availableHeight - headerHeight - 12 - controlsHeight)
        return max(0, remaining - max(32, remaining * 0.12))
    }
}

private struct DashboardCardLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let natural = ProposedViewSize(width: bounds.width, height: nil)
        let controlsHeight = subviews[1].sizeThatFits(natural).height
        let mapHeight = DashboardLayout.mapHeight(
            availableHeight: bounds.height, headerHeight: 0, controlsHeight: controlsHeight
        )
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: mapHeight))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + mapHeight + 12), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: max(controlsHeight, bounds.height - mapHeight - 12)))
    }
}

private enum BeaconTransmissionFeedback {
    static func progress(lastBeaconAt: Date?, now: Date) -> Double? {
        guard let lastBeaconAt else { return nil }
        let elapsed = now.timeIntervalSince(lastBeaconAt)
        guard elapsed >= 0, elapsed < 2 else { return nil }
        return elapsed / 2
    }
}

private struct APRSConnectionIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let isTransmitting = model.locationService.hasLocationPermission && BeaconTransmissionFeedback.progress(lastBeaconAt: model.lastBeaconAt, now: timeline.date) != nil

            HStack(spacing: 5) {
                Circle()
                    .fill(model.isDemoMode
                          ? .orange
                          : (isTransmitting ? .orange : (model.connectionState.isConnected ? .green : .secondary)))
                    .frame(width: 8, height: 8)
                Text(model.isDemoMode
                     ? String(localized: "Demo")
                     : (isTransmitting ? String(localized: "APRS TX") : model.connectionState.shortLabel))
                    .font(.caption.weight(.medium))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.isDemoMode
                                ? String(localized: "Demo Mode")
                                : (isTransmitting ? String(localized: "APRS transmitting") : model.connectionState.shortLabel))
        }
    }
}

private struct AutoBeaconButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isUpdating = false
    let showSettings: () -> Void

    private var hasCallsign: Bool {
        !model.settings.identity.fullCallsign.isEmpty
    }

    private var isManual: Bool { model.settings.beaconing.mode == .manual }
    private var isOn: Bool { model.isBeaconing && !isManual && model.locationService.hasLocationPermission }
    private var activeColor: Color {
        colorScheme == .light ? Color(red: 0.05, green: 0.48, blue: 0.18) : .green
    }
    private var inactiveColor: Color {
        colorScheme == .light
            ? Color(red: 0.7, green: 0.35, blue: 0)
            : Color(red: 1, green: 0.65, blue: 0)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { status in
            let isTransmitting = model.locationService.hasLocationPermission && BeaconTransmissionFeedback.progress(lastBeaconAt: model.lastBeaconAt, now: status.date) != nil
            let isLit = isOn || isTransmitting
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isLit || reduceMotion)) { timeline in
                let progress = BeaconTransmissionFeedback.progress(lastBeaconAt: model.lastBeaconAt, now: timeline.date)
                let pulse = isTransmitting ? (reduceMotion ? 0.6 : (sin((progress ?? 1) * .pi * 2) + 1) / 2) : glowIntensity(at: timeline.date)
                VStack(spacing: 14) {
                    VStack(spacing: 14) {
                        Button(action: activateBeaconButton) {
                            Image(systemName: "power")
                                .font(.system(size: 42, weight: .semibold))
                                .foregroundStyle(isLit ? activeColor : inactiveColor)
                                .frame(width: 108, height: 108)
                        }
                        .buttonStyle(PhysicalBeaconButtonStyle(isOn: isLit, pulse: pulse))
                        .overlay {
                            if isTransmitting, !reduceMotion, let progress {
                                Circle()
                                    .stroke(Color.green.opacity(0.65 * (1 - progress)), lineWidth: 2)
                                    .scaleEffect(1 + 0.35 * progress)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .highPriorityGesture(
                            LongPressGesture(minimumDuration: 0.6)
                                .exclusively(before: TapGesture())
                                .onEnded { gesture in
                                    switch gesture {
                                    case .first(true): sendManualBeacon()
                                    case .second: activateBeaconButton()
                                    default: break
                                    }
                                }
                        )
                        .disabled(model.isDemoMode || isUpdating)
                        .opacity(model.isDemoMode ? 0.45 : 1)
                        .accessibilityLabel(hasCallsign ? "Beacon control" : "Set your callsign")
                        .accessibilityValue(!model.locationService.hasLocationPermission ? "Location access required" : isManual ? "Manual mode" : (isOn ? "Auto-beaconing on" : "Auto-beaconing off"))
                        .accessibilityHint(isManual
                                           ? "Tap to send a manual beacon"
                                           : "Tap to toggle auto-beaconing. Hold to send a manual beacon")
                        .accessibilityAction(named: "Send manual beacon") { sendManualBeacon() }

                        Text(model.isDemoMode ? "Auto-beaconing unavailable in Demo"
                             : (!model.locationService.hasLocationPermission ? "Location access required" : isManual ? "Manual beaconing" : !hasCallsign ? "Set your callsign"
                                : (isOn ? "Auto-beaconing is ON" : "Auto-beaconing is OFF")))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isOn ? activeColor : Color.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)


                    VStack(spacing: 4) {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            let remaining = model.beaconNowCooldownRemaining(at: timeline.date)
                            Text(remaining > 0 ? "Manual beacon ready in \(remaining)s" : " ")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(remaining == 0)
                        }
                        Text(!model.locationService.hasLocationPermission ? "Enable Location access in iOS Settings" : isManual ? "Tap button to send manual beacon" : "Hold button to send manual beacon")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 12)
            }
        }
    }

    private func activateBeaconButton() {
        guard !model.isDemoMode, !isUpdating else { return }
        if isManual {
            sendManualBeacon()
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard hasCallsign else { showSettings(); return }
        isUpdating = true
        Task {
            await model.toggleBeaconing()
            isUpdating = false
        }
    }

    private func sendManualBeacon() {
        guard !model.isDemoMode, !isUpdating, model.beaconNowCooldownRemaining() == 0 else { return }
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1.0)
        isUpdating = true
        Task {
            await model.beaconNow()
            isUpdating = false
        }
    }

    private func glowIntensity(at date: Date) -> Double {
        guard isOn else { return 0 }
        guard !reduceMotion else { return 0.35 }
        let cycle = date.timeIntervalSinceReferenceDate * (.pi / 1.15)
        return (sin(cycle) + 1) / 2
    }
}

private struct PhysicalBeaconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isOn: Bool
    let pulse: Double

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? Color.green : Color.primary.opacity(0.8))
            .shadow(color: isOn ? .green.opacity(0.2) : .clear, radius: 3)
            .background {
                Circle()
                    .fill(LinearGradient(
                        colors: [
                            Color(uiColor: configuration.isPressed ? .secondarySystemGroupedBackground : .tertiarySystemGroupedBackground),
                            Color(uiColor: .secondarySystemBackground)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .overlay {
                        Circle().strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.2), .primary.opacity(0.08)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1
                        )
                    }
                    .shadow(color: .black.opacity(0.12), radius: configuration.isPressed ? 1 : 4,
                            y: configuration.isPressed ? 1 : 3)
            }
            .offset(y: configuration.isPressed ? 1 : -1)
            .padding(6)
            .background {
                Circle()
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .overlay {
                        Circle().strokeBorder(isOn ? Color.green.opacity(0.25 + 0.4 * pulse) : .gray.opacity(0.12), lineWidth: 2)
                    }
                    .shadow(color: isOn ? .green.opacity(0.08 + 0.2 * pulse) : .black.opacity(0.2),
                            radius: isOn ? 3 + 6 * pulse : 2, y: isOn ? 0 : 3)
            }
            .contentShape(Circle())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct BeaconSummaryPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 12) {
                summaryValue(
                    String(localized: "Last beacon"),
                    value: model.lastBeaconAt?.relativeLabel(at: timeline.date) ?? String(localized: "None yet")
                )
                summaryValue(String(localized: "Next beacon"), value: nextStatus(at: timeline.date))
            }
            .foregroundStyle(.secondary)
        }
    }

    private func summaryValue(_ title: String, value: String) -> some View {
        Text("\(title): \(value)")
            .font(.caption)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
    }

    private func nextStatus(at now: Date) -> String {
        if model.isDemoMode { return String(localized: "Demo") }
        if model.settings.beaconing.mode == .manual { return String(localized: "Manual") }
        if !model.isBeaconing { return String(localized: "Paused") }
        if model.connectionState != .connected(verified: true) { return String(localized: "Waiting for connection") }
        guard let location = model.locationService.currentLocation else { return String(localized: "Waiting for GPS") }
        if location.horizontalAccuracy < 0 || location.horizontalAccuracy > model.settings.beaconing.maximumAccuracyMeters {
            return String(localized: "Low GPS accuracy")
        }
        if model.lastBeaconError != nil { return String(localized: "Retrying") }
        return model.nextBeaconAt?.countdownLabel(at: now) ?? String(localized: "Preparing")
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

                ForEach(Array(model.trail.enumerated()), id: \.offset) { index, coordinate in
                    Annotation("", coordinate: coordinate) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                            .accessibilityLabel("Beacon \(index + 1)")
                    }
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
    enum Presentation { case full, icon, dot }

    struct Candidate {
        let id: String
        let point: CGPoint
        let fullSize: CGSize
    }

    static func markerSize(callsign: String) -> CGSize {
        let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .bold)
        let width = (callsign as NSString).size(withAttributes: [.font: font]).width + 10
        return CGSize(width: max(32, width), height: callsign.isEmpty ? 32 : font.lineHeight + 36)
    }

    static func presentations(
        candidates: [Candidate], viewport: CGRect, reserved: [CGRect] = [], selectedID: String? = nil
    ) -> [String: Presentation] {
        var occupied = reserved
        var result: [String: Presentation] = [:]
        // Stable ordering avoids changing the visible labels whenever packets arrive.
        let ordered = candidates.sorted {
            if ($0.id == selectedID) != ($1.id == selectedID) { return $0.id == selectedID }
            return $0.id < $1.id
        }
        for candidate in ordered {
            guard candidate.point.x.isFinite, candidate.point.y.isFinite else { continue }
            func bounds(_ size: CGSize) -> CGRect {
                CGRect(x: candidate.point.x - size.width / 2, y: candidate.point.y - size.height,
                       width: size.width, height: size.height)
            }
            let full = bounds(candidate.fullSize)
            guard full.intersects(viewport) else { continue }
            func fits(_ rect: CGRect) -> Bool {
                occupied.allSatisfy { other in
                    let overlap = rect.intersection(other)
                    guard !overlap.isNull else { return true }
                    let smallerArea = min(rect.width * rect.height, other.width * other.height)
                    // Small edge overlaps are fine; substantial occlusion is not.
                    return overlap.width * overlap.height <= smallerArea * 0.1
                }
            }
            if candidate.id == selectedID || fits(full) {
                result[candidate.id] = .full
                occupied.append(full)
            } else {
                let icon = bounds(CGSize(width: 32, height: 32))
                if fits(icon) {
                    result[candidate.id] = .icon
                    occupied.append(icon)
                } else {
                    result[candidate.id] = .dot
                    occupied.append(bounds(CGSize(width: 17, height: 17)))
                }
            }
        }
        return result
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
    var showsCallsign = true

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
                    if showsCallsign && !callsign.isEmpty {
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
        .accessibilityLabel(callsign.isEmpty ? String(localized: "My Position") : callsign)
    }
}

private extension MKCoordinateRegion {
    static let preview = MKCoordinateRegion(center: .preview, latitudinalMeters: 8_000, longitudinalMeters: 8_000)
}

private extension CLLocationCoordinate2D {
    static let preview = AppModel.demoCenterCoordinate
}
