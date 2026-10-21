import Foundation

/// A Java runtime embedded in the app bundle (App.app/runtimes/<name>).
/// It must be an iOS arm64 build of OpenJDK; desktop macOS builds cannot load.
struct JavaRuntime: Identifiable, Hashable {
    let id: String        // directory name
    let home: URL
    let version: String   // JAVA_VERSION from the `release` file
    let major: Int
    let implementor: String?
    let libjvm: String?

    var displayName: String { "Java \(major) (\(version))" }
}

/// A GL implementation the GLFW shim can bring up
/// (App.app/renderers/<id>/renderer.json, or the built-in diagnostic EAGL path).
struct RendererComponent: Identifiable, Hashable, Codable {
    enum ContextAPI: String, Codable { case eagl2, eagl3, egl }

    let id: String
    let displayName: String
    let contextAPI: ContextAPI
    /// Library providing the desktop-GL entry points Minecraft calls.
    let glLibrary: String?
    let eglLibrary: String?
    let initSymbol: String?
    /// Highest desktop OpenGL version the layer exposes ("2.1", "3.2", ...).
    /// nil means no desktop GL at all (GLES only).
    let desktopGL: String?
    let notes: String?

    var directory: URL { Paths.bundleRenderers.appendingPathComponent(id, isDirectory: true) }

    func libraryPath(_ name: String?) -> String? {
        guard let name else { return nil }
        return directory.appendingPathComponent(name).path
    }

    var desktopGLValue: Double { desktopGL.flatMap(Double.init) ?? 0 }

    static let builtinGLES = RendererComponent(
        id: "builtin-gles3", displayName: "Built-in OpenGL ES 3 (diagnostic)", contextAPI: .eagl3,
        glLibrary: nil, eglLibrary: nil, initSymbol: nil, desktopGL: nil,
        notes: "Brings up the window, input and an EAGL context, but exposes only OpenGL ES. Minecraft requires desktop OpenGL, so the game will stop at context creation. Embed a translation layer to play.")
}

/// iOS builds of LWJGL's native libraries (App.app/lwjgl/<version>/).
struct LWJGLNatives: Hashable {
    let version: String
    let directory: URL
    var hasOpenAL: Bool { FileManager.default.fileExists(directory.appendingPathComponent("libopenal.dylib")) }
}

/// Everything optional that is embedded in this particular IPA build.
struct RuntimeCatalog {
    var runtimes: [JavaRuntime] = []
    var renderers: [RendererComponent] = [.builtinGLES]
    var lwjgl: [LWJGLNatives] = []

    static func discover() -> RuntimeCatalog {
        var catalog = RuntimeCatalog()
        let fm = FileManager.default

        for name in (try? fm.contentsOfDirectory(atPath: Paths.bundleRuntimes.path)) ?? [] {
            let home = Paths.bundleRuntimes.appendingPathComponent(name, isDirectory: true)
            let release = parseRelease(home.appendingPathComponent("release"))
            let version = release["JAVA_VERSION"] ?? name
            catalog.runtimes.append(JavaRuntime(
                id: name, home: home, version: version, major: javaMajor(version),
                implementor: release["IMPLEMENTOR"], libjvm: ZMFJVMBridge.libjvmPath(forJavaHome: home.path)))
        }
        catalog.runtimes.sort { $0.major < $1.major }

        for name in (try? fm.contentsOfDirectory(atPath: Paths.bundleRenderers.path)) ?? [] {
            let descriptor = Paths.bundleRenderers.appendingPathComponent(name).appendingPathComponent("renderer.json")
            guard let data = try? Data(contentsOf: descriptor) else { continue }
            do {
                catalog.renderers.append(try JSONDecoder().decode(RendererComponent.self, from: data))
            } catch {
                zlog.warn("Invalid renderer descriptor \(name): \(error)")
            }
        }

        for name in (try? fm.contentsOfDirectory(atPath: Paths.bundleLWJGL.path)) ?? [] {
            let dir = Paths.bundleLWJGL.appendingPathComponent(name, isDirectory: true)
            if fm.fileExists(dir.appendingPathComponent("liblwjgl.dylib")) {
                catalog.lwjgl.append(LWJGLNatives(version: name, directory: dir))
            }
        }
        return catalog
    }

    static func parseRelease(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return result
    }

    /// "1.8.0_402" → 8, "17.0.12" → 17, "21" → 21
    static func javaMajor(_ version: String) -> Int {
        let parts = version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard let first = parts.first else { return 0 }
        return first == 1 && parts.count > 1 ? parts[1] : first
    }

    /// Java 8 era versions (LaunchWrapper, pre-1.17) need exactly Java 8;
    /// newer ones run on the smallest runtime at or above their requirement.
    func runtime(forRequiredMajor required: Int) -> JavaRuntime? {
        if required <= 8 { return runtimes.first { $0.major == 8 } }
        return runtimes.first { $0.major >= required }
    }

    func lwjglNatives(for version: String?) -> LWJGLNatives? {
        guard let version else { return nil }
        if let exact = lwjgl.first(where: { $0.version == version }) { return exact }
        // Same major.minor is ABI-compatible enough within LWJGL 3.x patch releases.
        let mm = version.split(separator: ".").prefix(2).joined(separator: ".")
        return lwjgl.first { $0.version.split(separator: ".").prefix(2).joined(separator: ".") == mm }
    }

    func bestRenderer(minimumDesktopGL: Double) -> RendererComponent? {
        renderers.filter { $0.desktopGLValue >= minimumDesktopGL }.min { $0.desktopGLValue < $1.desktopGLValue }
    }
}
