import Foundation

struct LaunchBlocked: LocalizedError {
    let reasons: [String]
    var errorDescription: String? { reasons.joined(separator: "\n") }
}

/// Fully resolved JVM invocation for one game start.
struct LaunchPlan {
    var runtime: JavaRuntime
    var renderer: RendererComponent
    var lwjgl: LWJGLNatives
    var jvmArguments: [String]
    var mainClass: String          // always the ZMF Bootstrap
    var applicationArguments: [String] // [real main class, game args...]
    var gameDirectory: URL
    var logURL: URL
    var crashURL: URL
    var exitStatusURL: URL
    var jitAvailable: Bool

    /// Same plan with secrets removed, for the diagnostics file.
    var redactedDescription: String {
        let hide: (String) -> String = { arg in
            arg.count > 100 && arg.split(separator: ".").count == 3 ? "<redacted token>" : arg
        }
        var out = "runtime: \(runtime.displayName) @ \(runtime.home.path)\n"
        out += "renderer: \(renderer.displayName)\nlwjgl natives: \(lwjgl.version)\njit: \(jitAvailable)\n\nJVM:\n"
        out += jvmArguments.map { "  \($0)" }.joined(separator: "\n")
        out += "\n\nmain: \(mainClass)\nargs:\n"
        var redactNext = false
        for arg in applicationArguments {
            out += "  " + (redactNext ? "<redacted>" : hide(arg)) + "\n"
            redactNext = arg == "--accessToken"
        }
        return out
    }
}

struct QuickPlayTarget {
    var host: String
    var port: Int
}

enum LaunchPlanner {
    static let bootstrapClass = "dev.zmf.support.Bootstrap"

    static func plan(profile: GameProfile,
                     settings: LauncherSettings,
                     account: MinecraftAccount,
                     catalog: RuntimeCatalog,
                     surface: (width: Int, height: Int),
                     quickPlay: QuickPlayTarget? = nil) throws -> LaunchPlan {
        let version = try VersionResolver.resolve(profile.launchVersionID)
        let rootID = VersionResolver.rootVersionID(profile.launchVersionID)
        let req = VersionRequirements.from(version)

        if case .unsupported(let reason) = Compatibility.evaluate(req, catalog: catalog) { throw LaunchBlocked(reasons: [reason]) }

        var blockers: [String] = []
        let runtime = profile.runtimeOverride.flatMap { id in catalog.runtimes.first { $0.id == id } }
            ?? catalog.runtime(forRequiredMajor: req.javaMajor)
        if runtime == nil { blockers.append("No embedded iOS Java runtime satisfies Java \(req.javaMajor). See docs/RUNTIME.md.") }
        if let r = runtime, r.libjvm == nil { blockers.append("Runtime \(r.id) has no libjvm.dylib.") }
        let renderer = profile.rendererOverride.flatMap { id in catalog.renderers.first { $0.id == id } }
            ?? catalog.bestRenderer(minimumDesktopGL: req.desktopGL)
        if renderer == nil { blockers.append(String(format: "No embedded GL layer exposes desktop OpenGL %.1f (needed by this version).", req.desktopGL)) }
        let natives = catalog.lwjglNatives(for: req.lwjglVersion)
        if natives == nil { blockers.append("No iOS build of LWJGL \(req.lwjglVersion ?? "3") natives is embedded.") }
        guard let supportJar = Paths.bundleSupportJar else {
            throw LaunchBlocked(reasons: ["zmf-support.jar missing from the app bundle (build problem)."])
        }

        // Game files present? (Hashes are checked by Verify; existence is enough here.)
        let fm = FileManager.default
        let libs = LibraryPlanner.classpathLibraries(for: version)
        let missing = libs.filter { !fm.fileExists($0.item.destination) }.map { $0.item.destination.lastPathComponent }
        if !fm.fileExists(Paths.clientJar(rootID)) { blockers.append("Client jar for \(rootID) is missing — run Repair.") }
        if !missing.isEmpty { blockers.append("\(missing.count) libraries missing (e.g. \(missing.prefix(3).joined(separator: ", "))) — run Repair.") }
        guard blockers.isEmpty, let runtime, let renderer, let natives else { throw LaunchBlocked(reasons: blockers) }

        // Classpath: launcher bootstrap, libraries, then the client jar.
        let classpath = ([supportJar.path] + libs.map { $0.item.destination.path } + [Paths.clientJar(rootID).path])
            .joined(separator: ":")

        let gameDir = profile.gameDirectory
        try? fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logURL = Paths.logs.appendingPathComponent("game-\(stamp).log")
        let crashURL = gameDir.appendingPathComponent("crash-reports/zmf-launch-\(stamp).txt")
        try? fm.createDirectory(at: crashURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let assetIndexID = version.assetIndex?.id ?? version.assets ?? "legacy"
        let assetsRoot = Paths.assets.path
        let gameAssets: String = {
            if let data = try? Data(contentsOf: Paths.assetIndexes.appendingPathComponent("\(assetIndexID).json")),
               let index = try? JSONDecoder().decode(AssetIndex.self, from: data) {
                index.materializeLegacyLayout(indexID: assetIndexID, gameDirectory: gameDir)
                if index.map_to_resources == true { return gameDir.appendingPathComponent("resources").path }
                if index.virtual == true { return Paths.assets.appendingPathComponent("virtual/\(assetIndexID)").path }
            }
            return assetsRoot
        }()

        let vars: [String: String] = [
            "auth_player_name": account.username,
            "version_name": version.id,
            "game_directory": gameDir.path,
            "assets_root": assetsRoot,
            "game_assets": gameAssets,
            "assets_index_name": assetIndexID,
            "auth_uuid": account.id,
            "auth_access_token": account.minecraftAccessToken,
            "auth_session": "token:\(account.minecraftAccessToken):\(account.id)",
            "auth_xuid": account.xuid ?? "0",
            "clientid": Bundle.main.object(forInfoDictionaryKey: "ZMFMSAClientID") as? String ?? "",
            "user_type": "msa",
            "user_properties": "{}",
            "version_type": version.type ?? "release",
            "resolution_width": "\(surface.width)",
            "resolution_height": "\(surface.height)",
            "natives_directory": natives.directory.path,
            "launcher_name": "ZMFJavaLauncher",
            "launcher_version": "0.1",
            "classpath": classpath,
            "classpath_separator": ":",
            "library_directory": Paths.libraries.path,
            "quickPlayMultiplayer": quickPlay.map { "\($0.host):\($0.port)" } ?? "",
            "quickPlayPath": gameDir.appendingPathComponent("quickPlay/log.json").path,
        ]

        var ctx = RuleContext()
        if quickPlay != nil {
            ctx.features["is_quick_play_multiplayer"] = true
            ctx.features["has_quick_plays_support"] = true
        }

        // JVM arguments --------------------------------------------------------
        let jit = ZMFProcessHasDebuggerJIT()
        let memory = profile.memoryOverrideMB ?? settings.memoryMB
        var jvm: [String] = [
            "-Xmx\(memory)M",
            "-Xms256M",
            settings.gc.jvmFlag,
            "-Xss2M",
            "-Djava.io.tmpdir=\(NSTemporaryDirectory())",
            "-Duser.home=\(Paths.root.path)",
            "-Duser.dir=\(gameDir.path)",
            "-Djava.library.path=\(natives.directory.path)",
            "-Dorg.lwjgl.librarypath=\(natives.directory.path)",
            "-Dorg.lwjgl.system.SharedLibraryExtractPath=\(NSTemporaryDirectory())",
            "-Dorg.lwjgl.glfw.libname=\(Paths.glfwFramework.path)",
            "-Dorg.lwjgl.opengl.libname=\(renderer.libraryPath(renderer.glLibrary) ?? Paths.glfwFramework.path)",
            "-Dorg.lwjgl.glfw.checkThread0=false",
            "-Dorg.lwjgl.system.allocator=system",
            "-Dlog4j2.formatMsgNoLookups=true",
            "-Dfml.earlyprogresswindow=false",
            "-Dzmf.crashFile=\(crashURL.path)",
            "-Dzmf.renderer=\(renderer.id)",
        ]
        // ZMF Voice position telemetry (see Java/src/dev/zmf/support/telemetry).
        if settings.voiceEnabled {
            jvm.append("-Dzmf.telemetry=true")
            jvm.append("-Dzmf.playerUuid=\(account.id)")
            if fm.fileExists(Paths.clientMappings(rootID)) {
                jvm.append("-Dzmf.mappings=\(Paths.clientMappings(rootID).path)")
            }
            if let intermediary = libs.first(where: { $0.library.coordinate?.group == "net.fabricmc" && $0.library.coordinate?.artifact == "intermediary" }) {
                jvm.append("-Dzmf.intermediary=\(intermediary.item.destination.path)")
            }
        }
        if natives.hasOpenAL {
            jvm.append("-Dorg.lwjgl.openal.libname=\(natives.directory.appendingPathComponent("libopenal.dylib").path)")
        }
        if !jit && settings.forceInterpreterWithoutJIT {
            // Without a debugger-granted JIT, iOS refuses executable memory.
            // -Xint keeps HotSpot from compiling methods (see docs/RUNTIME.md
            // for why a template interpreter still needs a JIT-less build).
            jvm.append("-Xint")
        }
        if let logging = version.logging?.client {
            let path = Paths.assets.appendingPathComponent("log_configs/\(logging.file.id)").path
            jvm.append(logging.argument.replacingOccurrences(of: "${path}", with: path))
        }

        var sawClasspath = false
        var skipNext = false
        let versionJVM = version.jvmArguments.isEmpty
            ? ["-Djava.library.path=${natives_directory}", "-cp", "${classpath}"]
            : expand(version.jvmArguments, ctx)
        for (i, raw) in versionJVM.enumerated() {
            if skipNext { skipNext = false; continue }
            // JNI_CreateJavaVM takes no -cp: convert to the system property.
            if raw == "-cp" || raw == "-classpath" {
                if i + 1 < versionJVM.count {
                    jvm.append("-Djava.class.path=" + substitute(versionJVM[i + 1], vars))
                    sawClasspath = true
                    skipNext = true
                }
                continue
            }
            // Desktop-launcher-only flags, and ones ZMF already set.
            if raw == "-XstartOnFirstThread" || raw.hasPrefix("-Djava.library.path=") || raw.hasPrefix("-Xss") { continue }
            jvm.append(substitute(raw, vars))
        }
        if !sawClasspath { jvm.append("-Djava.class.path=\(classpath)") }
        jvm += splitArguments(settings.extraJVMArguments) + splitArguments(profile.extraJVMArguments)

        // Game arguments ---------------------------------------------------------
        var game: [String]
        if !version.gameArguments.isEmpty {
            game = expand(version.gameArguments, ctx).map { substitute($0, vars) }
        } else {
            game = splitArguments(version.minecraftArguments ?? "").map { substitute($0, vars) }
            game += ["--width", "\(surface.width)", "--height", "\(surface.height)"]
        }
        if let qp = quickPlay, !game.contains("--quickPlayMultiplayer") {
            game += ["--server", qp.host, "--port", "\(qp.port)"]
        }
        // Drop any quick-play flag whose value ended up empty.
        game = dropEmptyOptions(game)

        guard let realMain = version.mainClass else { throw LaunchBlocked(reasons: ["Version \(version.id) has no main class."]) }

        return LaunchPlan(
            runtime: runtime, renderer: renderer, lwjgl: natives, jvmArguments: jvm,
            mainClass: bootstrapClass, applicationArguments: [realMain] + game,
            gameDirectory: gameDir, logURL: logURL, crashURL: crashURL,
            exitStatusURL: Paths.launcherData.appendingPathComponent("last-exit-status"),
            jitAvailable: jit)
    }

    static func expand(_ args: [VersionJSON.Argument], _ ctx: RuleContext) -> [String] {
        args.flatMap { arg -> [String] in
            switch arg {
            case .plain(let s): return [s]
            case .conditional(let rules, let values): return ctx.allows(rules) ? values : []
            }
        }
    }

    static func substitute(_ s: String, _ vars: [String: String]) -> String {
        guard s.contains("${") else { return s }
        var out = ""
        var rest = Substring(s)
        while let start = rest.range(of: "${") {
            out += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].firstIndex(of: "}") else {
                out += rest[start.lowerBound...]
                return out
            }
            let key = String(rest[start.upperBound..<end])
            out += vars[key] ?? "${\(key)}"
            rest = rest[rest.index(after: end)...]
        }
        return out + rest
    }

    /// Splits a user-entered argument string, honouring double quotes.
    static func splitArguments(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle(); continue }
            if ch.isWhitespace && !quoted {
                if !current.isEmpty { result.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func dropEmptyOptions(_ args: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < args.count {
            if args[i].hasPrefix("--"), i + 1 < args.count, args[i + 1].isEmpty {
                i += 2
                continue
            }
            out.append(args[i])
            i += 1
        }
        return out
    }

    /// Minimal VM invocation for the runtime self-test (no game, no graphics).
    static func selfTestPlan(runtime: JavaRuntime, outputURL: URL) throws -> ZMFJVMLaunchRequest {
        guard let jar = Paths.bundleSupportJar else { throw LaunchBlocked(reasons: ["zmf-support.jar missing"]) }
        let req = ZMFJVMLaunchRequest()
        req.javaHome = runtime.home.path
        var args = ["-Xmx256M", "-Djava.class.path=\(jar.path)", "-Djava.io.tmpdir=\(NSTemporaryDirectory())"]
        if !ZMFProcessHasDebuggerJIT() { args.append("-Xint") }
        req.jvmArguments = args
        req.mainClass = "dev.zmf.support.SelfTest"
        req.applicationArguments = [outputURL.path]
        req.workingDirectory = Paths.root.path
        req.logPath = Paths.logs.appendingPathComponent("selftest.log").path
        req.exitStatusPath = Paths.launcherData.appendingPathComponent("last-exit-status").path
        return req
    }
}
