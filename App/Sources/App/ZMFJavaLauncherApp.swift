import SwiftUI

@main
struct ZMFJavaLauncherApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.settingsStore)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await model.bootstrap() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }
            InstallationsView().tabItem { Label("Installations", systemImage: "square.stack.3d.up.fill") }
            ModsView().tabItem { Label("Mods", systemImage: "puzzlepiece.extension.fill") }
            ServersView().tabItem { Label("Servers", systemImage: "network") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .toolbarBackground(Theme.surface, for: .tabBar)
        .background(Theme.background.ignoresSafeArea())
    }
}
