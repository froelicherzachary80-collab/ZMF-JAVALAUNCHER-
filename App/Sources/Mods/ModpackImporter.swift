import Foundation

/// Imports Modrinth modpacks (.mrpack): creates a profile with the pack's
/// Minecraft and loader versions, downloads each client file from the URLs in
/// the index (verified by SHA-1) and applies the overrides folders.
@MainActor
enum ModpackImporter {
    struct Index: Decodable {
        struct File: Decodable {
            let path: String
            let hashes: [String: String]
            let env: [String: String]?
            let downloads: [URL]
            let fileSize: Int64?
        }
        let formatVersion: Int
        let game: String
        let versionId: String
        let name: String
        let files: [File]
        let dependencies: [String: String]
    }

    static func importPack(_ url: URL, installer: InstallationManager, profiles: ProfileStore,
                           status: @escaping (String) -> Void) async throws -> GameProfile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let zip = try ZipReader(data: Data(contentsOf: url))
        guard let indexData = try zip.contents(of: "modrinth.index.json") else {
            throw InstallError.invalidFile("Not a Modrinth pack (no modrinth.index.json)")
        }
        let index = try JSONDecoder().decode(Index.self, from: indexData)
        guard index.game == "minecraft", let mc = index.dependencies["minecraft"] else {
            throw InstallError.invalidFile("Pack does not target Minecraft")
        }

        var profile = GameProfile.make(name: index.name, version: mc)
        if let fabric = index.dependencies["fabric-loader"] {
            profile.loader = .fabric
            profile.loaderVersion = fabric
        } else if let quilt = index.dependencies["quilt-loader"] {
            profile.loader = .quilt
            profile.loaderVersion = quilt
        } else if index.dependencies["forge"] != nil || index.dependencies["neoforge"] != nil {
            throw InstallError.unsupported("This pack needs Forge/NeoForge. \(ModLoader.forge.statusNote)")
        }

        status("Installing Minecraft \(mc)…")
        try await installer.install(mc)
        if profile.loader != .vanilla, let lv = profile.loaderVersion {
            status("Installing \(profile.loader.title) \(lv)…")
            profile.launchVersionID = try await LoaderInstaller.installProfile(profile.loader, minecraft: mc, loaderVersion: lv)
            try await installer.install(profile.launchVersionID)
        }

        let gameDir = profile.gameDirectory
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let root = gameDir.standardizedFileURL.path
        var items: [DownloadItem] = []
        for file in index.files where file.env?["client"] != "unsupported" {
            let dest = gameDir.appendingPathComponent(file.path).standardizedFileURL
            guard dest.path.hasPrefix(root + "/") else { throw InstallError.invalidFile("unsafe path \(file.path)") }
            guard let src = file.downloads.first else { continue }
            items.append(DownloadItem(url: src, destination: dest, sha1: file.hashes["sha1"], size: file.fileSize))
        }
        status("Downloading \(items.count) pack files…")
        try await Downloader().fetch(items) { p in
            Task { @MainActor in status("Downloading pack files \(p.completedFiles)/\(p.totalFiles)") }
        }
        status("Applying overrides…")
        _ = try zip.extract(prefix: "overrides/", to: gameDir)
        _ = try zip.extract(prefix: "client-overrides/", to: gameDir)

        profiles.upsert(profile)
        zlog.info("Imported modpack \(index.name) (\(items.count) files)")
        return profile
    }
}
