#if canImport(SwiftUI)
import SwiftUI

/// The app's root: four tabs (Import, Builds, Releases, Settings) sharing
/// one AppEnvironment. The M8 app shell provides `@main` and hosts this.
public struct RootView: View {
    @StateObject private var environment = AppEnvironment()
    @StateObject private var importStore = ImportStore()
    @StateObject private var buildStore = BuildStore()
    @StateObject private var releasesStore = ReleasesStore()
    @State private var selectedTab: Tab = .import

    public enum Tab: Hashable {
        case importDeb, builds, releases, settings
    }

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            ImportScreen(environment: environment,
                         importStore: importStore,
                         buildStore: buildStore,
                         openBuilds: { selectedTab = .builds })
                .tabItem { Label("Import", systemImage: "square.and.arrow.down") }
                .tag(Tab.importDeb)

            BuildScreen(environment: environment, store: buildStore,
                        openReleases: { selectedTab = .releases })
                .tabItem { Label("Builds", systemImage: "gearshape.2") }
                .tag(Tab.builds)

            ReleasesScreen(environment: environment, store: releasesStore)
                .tabItem { Label("Releases", systemImage: "arrow.down.circle") }
                .tag(Tab.releases)

            SettingsScreen(environment: environment)
                .tabItem { Label("Settings", systemImage: "wrench") }
                .tag(Tab.settings)
        }
        // Attached INSIDE RootView's own body on purpose: a `.task` the
        // app shell attaches from outside would capture an uninstalled
        // copy of this view, whose @StateObject fields materialize fresh
        // throwaway objects - the bootstrap would mutate stores nobody
        // displays. Inside the body, `self` is the installed value, so
        // bootstrap() hits the live objects once, when the app appears.
        .task { await bootstrap() }
    }
}

public extension RootView {
    /// Kicks the environment awake: validates the token if present and
    /// loads the releases so every tab starts in the right state. Called
    /// from RootView's own `.task` (see above) when the app appears.
    func bootstrap() async {
        await environment.validateToken()
        await releasesStore.refresh(environment: environment)
    }
}
#endif
