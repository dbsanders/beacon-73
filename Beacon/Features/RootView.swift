import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0
    @State private var tipStore = TipStore()

    var body: some View {
        Group {
            if model.experienceMode == .undecided {
                FirstLaunchView(
                    exploreDemo: {
                        Task { await model.enterDemoMode() }
                    },
                    setUpCallsign: {
                        model.chooseLiveSetup()
                        selection = 3
                    }
                )
            } else {
                VStack(spacing: 0) {
                    if model.isDemoMode {
                        DemoModeBanner {
                            model.exitDemoMode()
                            selection = 3
                        }
                    }
                    mainTabs
                }
            }
        }
        .tint(.blue)
        .preferredColorScheme(model.settings.display.theme == .light ? .light : .dark)
        .task {
            await model.prepareForLaunch()
            guard model.experienceMode != .undecided else { return }
            if !model.isDemoMode {
                model.locationService.requestPermission()
            }
            await model.startReceiving()
        }
        .task {
            await tipStore.observeTransactions()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                model.expireStations()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                switch phase {
                case .active:
                    await model.appDidBecomeActive()
                case .background:
                    await model.appDidEnterBackground()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selection) {
            DashboardView { selection = 3 }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            StationsView()
                .tabItem { Label("Stations", systemImage: "dot.radiowaves.left.and.right") }
                .tag(1)

            TrackView()
                .tabItem { Label("Track", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .tag(2)

            SettingsView(tipStore: tipStore) { selection = 0 }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
    }
}

private struct FirstLaunchView: View {
    let exploreDemo: () -> Void
    let setUpCallsign: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 68, weight: .medium))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    Text("Beacon").foregroundStyle(.primary)
                    Text("73").foregroundStyle(.orange)
                }
                .font(.largeTitle.bold())
                Text("APRS beaconing and maps for amateur radio operators")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button(action: exploreDemo) {
                    Label("Explore Demo", systemImage: "map.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)

                Button(action: setUpCallsign) {
                    Label("Set Up My Callsign", systemImage: "person.badge.key.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
            }

            Text("Demo Mode uses simulated station data and cannot transmit. Live APRS requires your own amateur-radio callsign and APRS-IS passcode.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(28)
    }
}

private struct DemoModeBanner: View {
    let exitDemo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Demo Mode", systemImage: "eye.fill")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text("TX off")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Set Up", action: exitDemo)
                .font(.subheadline.bold())
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.18))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}
