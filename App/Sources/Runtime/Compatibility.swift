import Foundation

/// What a Minecraft version needs from the iOS side.
struct VersionRequirements {
    var javaMajor: Int
    var desktopGL: Double
    var lwjglVersion: String?
    var usesLWJGL2: Bool
    /// True when derived from the installed version JSON, false when estimated
    /// from the release date (before installation).
    var exact: Bool

    // Release dates where requirements changed (first snapshot with the change).
    private static let lwjgl3Date = MinecraftDate.parse("2017-10-25T00:00:00+00:00")!   // 17w43a
    private static let gl32Date = MinecraftDate.parse("2021-03-10T00:00:00+00:00")!     // 21w10a
    private static let java16Date = MinecraftDate.parse("2021-05-05T00:00:00+00:00")!   // 21w19a
    private static let java17Date = MinecraftDate.parse("2021-10-07T00:00:00+00:00")!   // 1.18 snapshots
    private static let java21Date = MinecraftDate.parse("2024-04-03T00:00:00+00:00")!   // 24w14a

    static func estimate(releaseDate: Date?) -> VersionRequirements {
        let d = releaseDate ?? Date()
        let java = d >= java21Date ? 21 : d >= java17Date ? 17 : d >= java16Date ? 16 : 8
        return VersionRequirements(javaMajor: java, desktopGL: d >= gl32Date ? 3.2 : 2.1,
                                   lwjglVersion: nil, usesLWJGL2: d < lwjgl3Date, exact: false)
    }

    static func from(_ version: VersionJSON) -> VersionRequirements {
        let date = version.releaseTime.flatMap(MinecraftDate.parse)
        var req = estimate(releaseDate: date)
        req.javaMajor = version.requiredJavaMajor
        req.lwjglVersion = LibraryPlanner.lwjglVersion(of: version)
        if let lw = req.lwjglVersion { req.usesLWJGL2 = lw.hasPrefix("2.") }
        req.exact = true
        return req
    }
}

enum CompatibilityStatus: Equatable {
    /// Every component is embedded. Gameplay is still unverified on device
    /// until someone actually plays it; the UI says so.
    case componentsReady
    case missingComponents([String])
    case unsupported(String)

    var label: String {
        switch self {
        case .componentsReady: return "Components ready · device-untested"
        case .missingComponents: return "Missing runtime components"
        case .unsupported: return "Unsupported"
        }
    }

    var symbol: String {
        switch self {
        case .componentsReady: return "checkmark.seal"
        case .missingComponents: return "shippingbox"
        case .unsupported: return "xmark.octagon"
        }
    }

    var reasons: [String] {
        switch self {
        case .componentsReady: return ["Java runtime, renderer and LWJGL natives for this version are embedded. On-device play has not been verified by the launcher."]
        case .missingComponents(let r): return r
        case .unsupported(let r): return [r]
        }
    }
}

enum Compatibility {
    static func evaluate(_ req: VersionRequirements, catalog: RuntimeCatalog) -> CompatibilityStatus {
        if req.usesLWJGL2 {
            return .unsupported("Uses LWJGL 2 (Minecraft 1.12.2 and older). ZMF implements the LWJGL 3 / GLFW path only.")
        }
        var missing: [String] = []
        if catalog.runtime(forRequiredMajor: req.javaMajor) == nil {
            missing.append(req.javaMajor <= 8 ? "iOS Java 8 runtime" : "iOS Java \(req.javaMajor)+ runtime")
        }
        if catalog.bestRenderer(minimumDesktopGL: req.desktopGL) == nil {
            missing.append(String(format: "GL translation layer exposing desktop OpenGL %.1f", req.desktopGL))
        }
        if let lw = req.lwjglVersion {
            if catalog.lwjglNatives(for: lw) == nil { missing.append("LWJGL \(lw) natives built for iOS") }
        } else if catalog.lwjgl.isEmpty {
            missing.append("LWJGL natives built for iOS")
        }
        return missing.isEmpty ? .componentsReady : .missingComponents(missing)
    }
}
