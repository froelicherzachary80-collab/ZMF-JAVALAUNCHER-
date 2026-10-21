import Foundation

struct InstalledMod: Identifiable, Hashable {
    var fileURL: URL
    var enabled: Bool
    var metadata: ModMetadata?
    var parseError: String?
    var id: String { fileURL.lastPathComponent }
    var displayName: String { metadata?.name ?? fileURL.deletingPathExtension().lastPathComponent }
}

struct ModIssue: Identifiable, Hashable {
    enum Severity: Int, Comparable {
        case info, warning, error
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    let severity: Severity
    let modFile: String?
    let message: String
    var id: String { "\(modFile ?? "-")|\(message)" }
}

/// Mods live in each profile's own mods/ folder — that is what the mod loader
/// inside the game scans — so enabling, disabling and deleting here changes
/// exactly what loads in-game. Disabled mods are renamed to *.jar.disabled.
@MainActor
final class ModManager: ObservableObject {
    @Published private(set) var mods: [InstalledMod] = []
    @Published private(set) var issues: [ModIssue] = []
    @Published var lastError: String?

    private(set) var profile: GameProfile?
    private var cache: [String: (Date, ModMetadata?)] = [:]

    func load(_ profile: GameProfile) {
        self.profile = profile
        reload()
    }

    func reload() {
        guard let profile else { mods = []; issues = []; return }
        let fm = FileManager.default
        try? fm.createDirectory(at: profile.modsDirectory, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: profile.modsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var result: [InstalledMod] = []
        for url in files {
            let name = url.lastPathComponent
            let enabled = name.hasSuffix(".jar")
            guard enabled || name.hasSuffix(".jar.disabled") else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let key = name.replacingOccurrences(of: ".disabled", with: "")
            var mod = InstalledMod(fileURL: url, enabled: enabled)
            if let cached = cache[key], cached.0 == mtime {
                mod.metadata = cached.1
            } else {
                do {
                    mod.metadata = try ModMetadataReader.read(jar: url)
                } catch {
                    mod.parseError = error.localizedDescription
                }
                cache[key] = (mtime, mod.metadata)
            }
            result.append(mod)
        }
        mods = result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        issues = Self.analyze(mods: mods, profile: profile, javaMajor: nil)
    }

    // MARK: File operations

    func importMods(_ urls: [URL]) {
        guard let profile else { return }
        let fm = FileManager.default
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard url.pathExtension.lowercased() == "jar" else {
                lastError = "\(url.lastPathComponent) is not a .jar file."
                continue
            }
            let dest = profile.modsDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                if fm.fileExists(dest) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: url, to: dest)
                if (try? ModMetadataReader.read(jar: dest)) == nil {
                    lastError = "\(url.lastPathComponent) was imported but contains no Fabric/Quilt/Forge/NeoForge metadata."
                }
                zlog.info("Imported mod \(url.lastPathComponent) into \(profile.name)")
            } catch {
                lastError = "Import failed for \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        reload()
    }

    func setEnabled(_ mod: InstalledMod, _ enabled: Bool) {
        guard mod.enabled != enabled else { return }
        let name = mod.fileURL.lastPathComponent
        let newName = enabled ? String(name.dropLast(".disabled".count)) : name + ".disabled"
        let dest = mod.fileURL.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: mod.fileURL, to: dest)
        } catch {
            lastError = error.localizedDescription
        }
        reload()
    }

    func delete(_ mod: InstalledMod) {
        try? FileManager.default.removeItem(at: mod.fileURL)
        reload()
    }

    // MARK: Analysis

    /// Ids provided by the platform itself for dependency resolution.
    nonisolated static func builtinProvides(profile: GameProfile, javaMajor: Int?) -> [String: String] {
        var p: [String: String] = ["minecraft": profile.minecraftVersion]
        if let j = javaMajor { p["java"] = "\(j)" }
        let lv = profile.loaderVersion ?? "0"
        switch profile.loader {
        case .fabric: p["fabricloader"] = lv
        case .quilt:
            p["quilt_loader"] = lv
            p["fabricloader"] = lv // Quilt provides Fabric loader compatibility
        case .forge: p["forge"] = lv
        case .neoforge: p["neoforge"] = lv
        case .vanilla: break
        }
        return p
    }

    nonisolated static func analyze(mods: [InstalledMod], profile: GameProfile, javaMajor: Int?) -> [ModIssue] {
        var issues: [ModIssue] = []
        let enabled = mods.filter(\.enabled)
        var provided = builtinProvides(profile: profile, javaMajor: javaMajor)
        var owners: [String: [String]] = [:]
        for mod in enabled {
            guard let m = mod.metadata else { continue }
            provided[m.id] = m.version
            owners[m.id, default: []].append(mod.id)
            for extra in m.provides where provided[extra] == nil { provided[extra] = m.version }
        }

        if profile.loader == .vanilla && !enabled.isEmpty {
            issues.append(ModIssue(severity: .error, modFile: nil, message: "This profile is Vanilla — mods in its mods folder will not load. Create a Fabric profile."))
        }
        for (id, files) in owners where files.count > 1 {
            issues.append(ModIssue(severity: .error, modFile: files.joined(separator: ", "), message: "Duplicate mod id \(id)"))
        }

        for mod in enabled {
            guard let m = mod.metadata else {
                issues.append(ModIssue(severity: .warning, modFile: mod.id, message: mod.parseError.map { "Unreadable jar: \($0)" } ?? "No mod metadata found"))
                continue
            }
            let compatibleLoader = m.loader == profile.loader || (profile.loader == .quilt && m.loader == .fabric)
            if profile.loader != .vanilla && !compatibleLoader {
                issues.append(ModIssue(severity: .error, modFile: mod.id, message: "\(m.name) is a \(m.loader.title) mod; this profile uses \(profile.loader.title)."))
            }
            if m.environment == "server" {
                issues.append(ModIssue(severity: .warning, modFile: mod.id, message: "\(m.name) is server-only and does nothing on a client."))
            }
            if !m.nativeLibraries.isEmpty {
                issues.append(ModIssue(severity: .warning, modFile: mod.id,
                                       message: "\(m.name) ships desktop native code (\(m.nativeLibraries.prefix(2).joined(separator: ", "))). Native libraries built for macOS/Windows/Linux cannot load on iOS; features using them will fail."))
            }
            for dep in m.dependencies {
                guard let have = provided[dep.modID] else {
                    if dep.mandatory {
                        issues.append(ModIssue(severity: .error, modFile: mod.id, message: "\(m.name) requires \(dep.modID) \(dep.versions.joined(separator: " or ")) — not installed."))
                    }
                    continue
                }
                if !VersionPredicate.matches(have, anyOf: dep.versions) {
                    issues.append(ModIssue(severity: dep.mandatory ? .error : .warning, modFile: mod.id,
                                           message: "\(m.name) needs \(dep.modID) \(dep.versions.joined(separator: " or ")), found \(have)."))
                }
            }
            for b in m.breaks {
                if let have = provided[b.modID], VersionPredicate.matches(have, anyOf: b.versions) {
                    issues.append(ModIssue(severity: .error, modFile: mod.id, message: "\(m.name) is incompatible with \(b.modID) \(have)."))
                }
            }
        }
        return issues.sorted { $0.severity > $1.severity }
    }

    // MARK: Export

    struct ProfileExport: Codable {
        struct Mod: Codable { var file: String; var id: String?; var version: String?; var sha1: String; var enabled: Bool }
        var format = "zmf-profile-1"
        var name: String
        var minecraftVersion: String
        var loader: ModLoader
        var loaderVersion: String?
        var memoryMB: Int?
        var jvmArguments: String
        var mods: [Mod]
    }

    func exportProfile() throws -> URL {
        guard let profile else { throw InstallError.invalidFile("no profile") }
        let export = ProfileExport(
            name: profile.name, minecraftVersion: profile.minecraftVersion, loader: profile.loader,
            loaderVersion: profile.loaderVersion, memoryMB: profile.memoryOverrideMB, jvmArguments: profile.extraJVMArguments,
            mods: mods.map { .init(file: $0.id, id: $0.metadata?.id, version: $0.metadata?.version,
                                   sha1: Hashing.sha1(of: $0.fileURL) ?? "", enabled: $0.enabled) })
        let dir = Paths.root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(profile.name.replacingOccurrences(of: "/", with: "-")).zmfprofile.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(export).write(to: url, options: .atomic)
        return url
    }
}
