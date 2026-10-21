import Foundation

/// Installs Fabric (fully supported) or Quilt loader profiles. Both services
/// publish a launcher profile JSON that `inheritsFrom` the vanilla version and
/// lists maven libraries; ZMF stores it as versions/<id>/<id>.json and the
/// regular installer then downloads and verifies every library.
enum LoaderInstaller {
    struct LoaderVersion: Identifiable, Hashable {
        let version: String
        let stable: Bool
        var id: String { version }
    }

    static func metaBase(_ loader: ModLoader) -> String? {
        switch loader {
        case .fabric: return "https://meta.fabricmc.net/v2"
        case .quilt: return "https://meta.quiltmc.org/v3"
        default: return nil
        }
    }

    /// Loader versions that support a given Minecraft version, newest first.
    static func availableVersions(_ loader: ModLoader, minecraft: String) async throws -> [LoaderVersion] {
        guard let base = metaBase(loader) else { return [] }
        let url = URL(string: "\(base)/versions/loader/\(minecraft.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? minecraft)")!
        let data = try await HTTP.get(url)
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let loaderInfo = entry["loader"] as? [String: Any], let v = loaderInfo["version"] as? String else { return nil }
            // Quilt has no "stable" flag; treat non-beta versions as stable.
            let stable = loaderInfo["stable"] as? Bool ?? !v.contains("beta")
            return LoaderVersion(version: v, stable: stable)
        }
    }

    /// Writes the loader profile and returns its version id.
    static func installProfile(_ loader: ModLoader, minecraft: String, loaderVersion: String) async throws -> String {
        guard let base = metaBase(loader) else { throw InstallError.unsupported("\(loader.title) is not installable yet. \(loader.statusNote)") }
        let mc = minecraft.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? minecraft
        let url = URL(string: "\(base)/versions/loader/\(mc)/\(loaderVersion)/profile/json")!
        let data = try await HTTP.get(url)
        let profile = try JSONDecoder().decode(VersionJSON.self, from: data)
        guard profile.inheritsFrom == minecraft else {
            throw InstallError.invalidFile("Loader profile inherits from \(profile.inheritsFrom ?? "nothing"), expected \(minecraft)")
        }
        try FileManager.default.createDirectory(at: Paths.versionDirectory(profile.id), withIntermediateDirectories: true)
        try data.write(to: Paths.versionJSON(profile.id), options: .atomic)
        zlog.info("Installed \(loader.title) profile \(profile.id)")
        return profile.id
    }

    /// Loader version embedded in an installed loader profile id.
    static func loaderVersion(fromProfileID id: String) -> String? {
        // fabric-loader-0.16.5-1.21.1 / quilt-loader-0.26.4-1.21.1
        let parts = id.split(separator: "-")
        guard parts.count >= 4, parts[1] == "loader" else { return nil }
        return String(parts[2])
    }
}
