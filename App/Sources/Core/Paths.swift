import Foundation

/// On-disk layout. Everything lives under Documents/ZMF so it is visible in
/// the Files app ("On My iPhone › ZMF Java") for importing mods, worlds and
/// resource packs by hand.
enum Paths {
    static let root: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("ZMF", isDirectory: true)
    }()

    /// Shared Mojang-style store: versions/, libraries/, assets/.
    static var minecraft: URL { root.appendingPathComponent("minecraft", isDirectory: true) }
    static var versions: URL { minecraft.appendingPathComponent("versions", isDirectory: true) }
    static var libraries: URL { minecraft.appendingPathComponent("libraries", isDirectory: true) }
    static var assets: URL { minecraft.appendingPathComponent("assets", isDirectory: true) }
    static var assetIndexes: URL { assets.appendingPathComponent("indexes", isDirectory: true) }
    static var assetObjects: URL { assets.appendingPathComponent("objects", isDirectory: true) }

    /// Per-profile game directories (mods, saves, config, options.txt ...).
    static var instances: URL { root.appendingPathComponent("instances", isDirectory: true) }
    static var launcherData: URL { root.appendingPathComponent("launcher", isDirectory: true) }
    static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    static var imports: URL { root.appendingPathComponent("imports", isDirectory: true) }

    static func versionDirectory(_ id: String) -> URL { versions.appendingPathComponent(id, isDirectory: true) }
    static func versionJSON(_ id: String) -> URL { versionDirectory(id).appendingPathComponent("\(id).json") }
    static func clientJar(_ id: String) -> URL { versionDirectory(id).appendingPathComponent("\(id).jar") }
    static func clientMappings(_ id: String) -> URL { versionDirectory(id).appendingPathComponent("client_mappings.txt") }
    static func nativesDirectory(_ id: String) -> URL { versionDirectory(id).appendingPathComponent("natives", isDirectory: true) }

    static func instance(_ directoryName: String) -> URL { instances.appendingPathComponent(directoryName, isDirectory: true) }

    static func ensureLayout() {
        for dir in [root, minecraft, versions, libraries, assets, assetIndexes, assetObjects, instances, launcherData, logs, imports] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Contents of the app bundle where optional native components are embedded
    /// by scripts/embed-components.sh.
    static var bundleRuntimes: URL { Bundle.main.bundleURL.appendingPathComponent("runtimes", isDirectory: true) }
    static var bundleRenderers: URL { Bundle.main.bundleURL.appendingPathComponent("renderers", isDirectory: true) }
    static var bundleLWJGL: URL { Bundle.main.bundleURL.appendingPathComponent("lwjgl", isDirectory: true) }
    static var bundleSupportJar: URL? { Bundle.main.url(forResource: "zmf-support", withExtension: "jar", subdirectory: "java") }
    static var glfwFramework: URL { Bundle.main.privateFrameworksURL!.appendingPathComponent("ZMFGLFW.framework/ZMFGLFW") }
}

extension FileManager {
    func fileExists(_ url: URL) -> Bool { fileExists(atPath: url.path) }

    func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func fileSize(_ url: URL) -> Int64? {
        (try? attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}
