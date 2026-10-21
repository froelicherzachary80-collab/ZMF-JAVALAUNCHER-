import Foundation

/// Mojang's launcher manifest (piston-meta version_manifest_v2.json). Versions
/// are discovered dynamically from here — nothing is hardcoded.
struct VersionManifest: Codable {
    struct Latest: Codable { let release: String; let snapshot: String }
    struct Entry: Codable, Identifiable, Hashable {
        let id: String
        let type: String
        let url: URL
        let time: String
        let releaseTime: String
        let sha1: String?
        let complianceLevel: Int?

        var isRelease: Bool { type == "release" }
        var isSnapshot: Bool { type == "snapshot" }
        var releaseDate: Date? { MinecraftDate.parse(releaseTime) }
    }

    let latest: Latest
    let versions: [Entry]

    static let url = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!

    static func fetch() async throws -> VersionManifest {
        let data = try await HTTP.get(url)
        // Cache for offline browsing of what is installed.
        try? data.write(to: Paths.launcherData.appendingPathComponent("version_manifest_v2.json"))
        return try JSONDecoder().decode(VersionManifest.self, from: data)
    }

    static func cached() -> VersionManifest? {
        guard let data = try? Data(contentsOf: Paths.launcherData.appendingPathComponent("version_manifest_v2.json")) else { return nil }
        return try? JSONDecoder().decode(VersionManifest.self, from: data)
    }
}

enum MinecraftDate {
    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}
