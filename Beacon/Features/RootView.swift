import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0

    var body: some View {
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

            SettingsView { selection = 0 }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .tint(.blue)
        .preferredColorScheme(.dark)
        .task {
            model.locationService.requestAlwaysPermission()
            await model.startReceiving()
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
}
