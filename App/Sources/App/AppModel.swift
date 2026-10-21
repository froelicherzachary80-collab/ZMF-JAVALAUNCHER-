import Foundation
import Combine

/// Root object graph shared with every screen.
@MainActor
final class AppModel: ObservableObject {
    let settingsStore: SettingsStore
    let installer: InstallationManager
    let profiles: ProfileStore
    let accounts: AccountStore
    let servers: ServerStore
    let hud: HUDStore
    let session: GameSession
    @Published private(set) var catalog = RuntimeCatalog.discover()
    @Published private(set) var jitAvailable = ZMFProcessHasDebuggerJIT()
    @Published var news: [NewsItem] = []

    private var bag = Set<AnyCancellable>()

    init() {
        Paths.ensureLayout()
        settingsStore = SettingsStore()
        installer = InstallationManager()
        profiles = ProfileStore()
        accounts = AccountStore()
        servers = ServerStore()
        hud = HUDStore()
        session = GameSession()
        // Re-publish nested stores so views observing AppModel refresh.
        for publisher in [settingsStore.objectWillChange.eraseToAnyPublisher(),
                          installer.objectWillChange.eraseToAnyPublisher(),
                          profiles.objectWillChange.eraseToAnyPublisher(),
                          accounts.objectWillChange.eraseToAnyPublisher(),
                          servers.objectWillChange.eraseToAnyPublisher(),
                          hud.objectWillChange.eraseToAnyPublisher(),
                          session.objectWillChange.eraseToAnyPublisher()] {
            publisher.receive(on: RunLoop.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }
        if profiles.profiles.isEmpty, let latest = installer.manifest?.latest.release {
            profiles.upsert(GameProfile.make(name: "Latest Release", version: latest))
        }
    }

    var selectedProfile: GameProfile? {
        profiles.profile(settingsStore.settings.selectedProfileID) ?? profiles.recent.first
    }

    func refreshEnvironment() {
        catalog = RuntimeCatalog.discover()
        jitAvailable = ZMFProcessHasDebuggerJIT()
    }

    func bootstrap() async {
        await installer.refreshManifest()
        if profiles.profiles.isEmpty, let latest = installer.manifest?.latest.release {
            profiles.upsert(GameProfile.make(name: "Latest Release", version: latest))
        }
        news = await NewsItem.fetch(manifest: installer.manifest)
    }
}

/// Launcher news: built from the live version manifest (latest release and
/// snapshot) plus release notes of this launcher build.
struct NewsItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let body: String
    let date: Date?

    static func fetch(manifest: VersionManifest?) async -> [NewsItem] {
        var items: [NewsItem] = []
        if let m = manifest {
            let release = m.versions.first { $0.id == m.latest.release }
            let snapshot = m.versions.first { $0.id == m.latest.snapshot }
            items.append(NewsItem(title: "Latest release: \(m.latest.release)",
                                  body: "Available to install from Installations.", date: release?.releaseDate))
            if m.latest.snapshot != m.latest.release {
                items.append(NewsItem(title: "Latest snapshot: \(m.latest.snapshot)",
                                      body: "Snapshots are experimental and may break worlds — use a separate profile.", date: snapshot?.releaseDate))
            }
        }
        items.append(NewsItem(title: "ZMF Java Launcher 0.1",
                              body: "Native launcher foundation: version manager, Microsoft sign-in, Fabric profiles, mod manager, server list and touch controls. Gameplay requires the iOS runtime components described in Settings › Runtime.",
                              date: nil))
        return items
    }
}

extension AppModel {
    /// Exact requirements once installed, release-date estimate before.
    func requirements(for versionID: String) -> VersionRequirements {
        if let resolved = try? VersionResolver.resolve(versionID) { return VersionRequirements.from(resolved) }
        let entry = installer.manifest?.versions.first { $0.id == versionID }
        return VersionRequirements.estimate(releaseDate: entry?.releaseDate)
    }

    func compatibility(for versionID: String) -> CompatibilityStatus {
        Compatibility.evaluate(requirements(for: versionID), catalog: catalog)
    }
}
