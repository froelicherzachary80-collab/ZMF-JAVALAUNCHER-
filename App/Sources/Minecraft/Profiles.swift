import Foundation

enum ModLoader: String, Codable, CaseIterable, Identifiable {
    case vanilla, fabric, quilt, forge, neoforge
    var id: String { rawValue }
    var title: String {
        switch self {
        case .vanilla: return "Vanilla"
        case .fabric: return "Fabric"
        case .quilt: return "Quilt"
        case .forge: return "Forge"
        case .neoforge: return "NeoForge"
        }
    }
    /// Loaders whose installer ZMF implements end-to-end.
    var installable: Bool { self == .vanilla || self == .fabric || self == .quilt }
    var statusNote: String {
        switch self {
        case .vanilla: return "Official game files from Mojang."
        case .fabric: return "Fully implemented: profile from meta.fabricmc.net, libraries verified."
        case .quilt: return "Implemented via meta.quiltmc.org (same profile format as Fabric); less tested."
        case .forge, .neoforge: return "Not yet installable: their installers run Java processors that patch the game, which needs the embedded JVM. Planned after Fabric is verified on device."
        }
    }
}

/// A launchable configuration with its own game directory, so mods, worlds and
/// options are separated per profile.
struct GameProfile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Vanilla version id (e.g. "1.21.1").
    var minecraftVersion: String
    var loader: ModLoader = .vanilla
    var loaderVersion: String?
    /// Installed version id to launch (vanilla id or loader profile id).
    var launchVersionID: String
    var gameDirectoryName: String
    var memoryOverrideMB: Int?
    var runtimeOverride: String?
    var rendererOverride: String?
    var extraJVMArguments: String = ""
    var created = Date()
    var lastPlayed: Date?

    var gameDirectory: URL { Paths.instance(gameDirectoryName) }
    var modsDirectory: URL { gameDirectory.appendingPathComponent("mods", isDirectory: true) }

    static func make(name: String, version: String) -> GameProfile {
        let safe = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let dir = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + "-" + UUID().uuidString.prefix(6).lowercased()
        return GameProfile(name: name, minecraftVersion: version, launchVersionID: version, gameDirectoryName: dir)
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [GameProfile] { didSet { JSONStore.save(profiles, to: "profiles.json") } }

    init() {
        profiles = JSONStore.load([GameProfile].self, from: "profiles.json") ?? []
    }

    func profile(_ id: UUID?) -> GameProfile? { profiles.first { $0.id == id } }

    func upsert(_ profile: GameProfile) {
        try? FileManager.default.createDirectory(at: profile.modsDirectory, withIntermediateDirectories: true)
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = profile } else { profiles.append(profile) }
    }

    func delete(_ profile: GameProfile, removeFiles: Bool) {
        profiles.removeAll { $0.id == profile.id }
        if removeFiles { try? FileManager.default.removeItem(at: profile.gameDirectory) }
    }

    func markPlayed(_ id: UUID) {
        if let i = profiles.firstIndex(where: { $0.id == id }) { profiles[i].lastPlayed = Date() }
    }

    var recent: [GameProfile] {
        profiles.sorted { ($0.lastPlayed ?? $0.created) > ($1.lastPlayed ?? $1.created) }
    }
}

/// Reads and writes the game's options.txt so launcher video settings are the
/// values Minecraft actually uses.
enum GameOptionsFile {
    static func apply(_ s: LauncherSettings, to gameDirectory: URL) {
        let url = gameDirectory.appendingPathComponent("options.txt")
        var lines: [String] = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        let values: [String: String] = [
            "renderDistance": "\(s.renderDistance)",
            "simulationDistance": "\(s.simulationDistance)",
            "maxFps": s.fpsLimit == 0 ? "260" : "\(s.fpsLimit)",
            "graphicsMode": s.fancyGraphics ? "1" : "0",
            "fancyGraphics": s.fancyGraphics ? "true" : "false",
            "ao": s.smoothLighting ? "true" : "false",
            "fullscreen": "false",
            "guiScale": "\(s.guiScale)",
            "enableVsync": "false",
            "rawMouseInput": "false",
            "touchscreen": "false",
            "pauseOnLostFocus": "true",
            "onboardAccessibility": "false",
            "skipMultiplayerWarning": "true",
        ]
        var seen = Set<String>()
        lines = lines.map { line in
            guard let colon = line.firstIndex(of: ":") else { return line }
            let key = String(line[..<colon])
            guard let v = values[key] else { return line }
            seen.insert(key)
            return "\(key):\(v)"
        }
        for (k, v) in values.sorted(by: { $0.key < $1.key }) where !seen.contains(k) { lines.append("\(k):\(v)") }
        try? FileManager.default.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
