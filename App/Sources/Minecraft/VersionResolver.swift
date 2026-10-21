import Foundation

/// Loads version documents from disk and flattens `inheritsFrom` chains
/// (loader profile → vanilla) into a single launchable description.
enum VersionResolver {
    static func load(_ id: String) throws -> VersionJSON {
        let url = Paths.versionJSON(id)
        guard let data = try? Data(contentsOf: url) else { throw InstallError.versionNotFound(id) }
        do {
            return try JSONDecoder().decode(VersionJSON.self, from: data)
        } catch {
            throw InstallError.invalidFile("\(id).json: \(error.localizedDescription)")
        }
    }

    static func resolve(_ id: String) throws -> VersionJSON {
        var chain: [VersionJSON] = []
        var next: String? = id
        while let current = next {
            if chain.contains(where: { $0.id == current }) { throw InstallError.invalidFile("inheritance loop at \(current)") }
            let doc = try load(current)
            chain.append(doc)
            next = doc.inheritsFrom
        }
        return merge(chain)
    }

    /// `chain[0]` is the most specific document. Child values win; libraries
    /// are concatenated child-first and de-duplicated by maven identity so a
    /// loader can replace vanilla's copy of a library (ASM, Guava ...).
    static func merge(_ chain: [VersionJSON]) -> VersionJSON {
        guard var result = chain.last else { fatalError("empty chain") }
        for child in chain.dropLast().reversed() {
            result.id = child.id
            result.type = child.type ?? result.type
            result.mainClass = child.mainClass ?? result.mainClass
            result.minecraftArguments = child.minecraftArguments ?? result.minecraftArguments
            result.assetIndex = child.assetIndex ?? result.assetIndex
            result.assets = child.assets ?? result.assets
            result.javaVersion = child.javaVersion ?? result.javaVersion
            result.logging = child.logging ?? result.logging
            result.releaseTime = child.releaseTime ?? result.releaseTime
            if let childArgs = child.arguments {
                var args = result.arguments ?? VersionJSON.Arguments()
                args.game = (args.game ?? []) + (childArgs.game ?? [])
                args.jvm = (args.jvm ?? []) + (childArgs.jvm ?? [])
                result.arguments = args
            }
            var seen = Set<String>()
            var libs: [VersionJSON.Library] = []
            for lib in (child.libraries ?? []) + (result.libraries ?? []) {
                let key = lib.coordinate?.identity ?? lib.name
                if seen.insert(key).inserted { libs.append(lib) }
            }
            result.libraries = libs
            // Keep the vanilla client jar download from the root.
            result.inheritsFrom = nil
        }
        return result
    }

    /// The vanilla version at the root of the chain (its jar is the client).
    static func rootVersionID(_ id: String) -> String {
        var current = id
        while let doc = try? load(current), let parent = doc.inheritsFrom { current = parent }
        return current
    }
}

/// Library selection shared by installer, verifier and launcher.
enum LibraryPlanner {
    static let mojangLibraries = "https://libraries.minecraft.net/"

    struct PlannedLibrary {
        let library: VersionJSON.Library
        let item: DownloadItem
    }

    /// Java libraries for the classpath. Desktop natives (LWJGL natives-*,
    /// legacy `natives` classifiers) are excluded: they cannot load on iOS.
    static func classpathLibraries(for version: VersionJSON, context: RuleContext = RuleContext()) -> [PlannedLibrary] {
        var result: [PlannedLibrary] = []
        for lib in version.libraries ?? [] where context.allows(lib.rules) {
            if lib.natives != nil && lib.downloads?.artifact == nil { continue }
            guard let coord = lib.coordinate, !coord.isNativesClassifier else { continue }
            if let artifact = lib.downloads?.artifact {
                let path = artifact.path ?? coord.path
                guard let url = artifact.url ?? URL(string: mojangLibraries + path) else { continue }
                // An empty URL means "provided by the launcher" in some loader profiles.
                if url.absoluteString.isEmpty { continue }
                result.append(PlannedLibrary(library: lib, item: DownloadItem(
                    url: url, destination: Paths.libraries.appendingPathComponent(path), sha1: artifact.sha1, size: artifact.size)))
            } else {
                var base = lib.url ?? mojangLibraries
                if !base.hasSuffix("/") { base += "/" }
                guard let url = URL(string: base + coord.path) else { continue }
                result.append(PlannedLibrary(library: lib, item: DownloadItem(
                    url: url, destination: Paths.libraries.appendingPathComponent(coord.path), sha1: lib.sha1, size: lib.size)))
            }
        }
        return result
    }

    /// LWJGL version the game was built against (decides which iOS native
    /// build and GLFW feature level is required).
    static func lwjglVersion(of version: VersionJSON) -> String? {
        version.libraries?.compactMap(\.coordinate).first { $0.group == "org.lwjgl" && $0.artifact == "lwjgl" }?.version
            ?? version.libraries?.compactMap(\.coordinate).first { $0.group == "org.lwjgl.lwjgl" && $0.artifact == "lwjgl" }?.version
    }
}
