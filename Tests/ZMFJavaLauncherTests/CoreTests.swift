import XCTest
@testable import ZMFJavaLauncher

final class CoreTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: CoreTests.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    // MARK: Rules

    func testRuleEvaluation() {
        let ctx = RuleContext()
        XCTAssertTrue(ctx.allows(nil))
        XCTAssertTrue(ctx.allows([Rule(action: "allow", os: .init(name: "osx"))]))
        XCTAssertFalse(ctx.allows([Rule(action: "allow", os: .init(name: "windows"))]))
        XCTAssertFalse(ctx.allows([Rule(action: "allow"), Rule(action: "disallow", os: .init(name: "osx"))]))
        XCTAssertFalse(ctx.allows([Rule(action: "allow", os: .init(arch: "x86"))]))
        XCTAssertFalse(ctx.allows([Rule(action: "allow", features: ["is_demo_user": true])]))
        XCTAssertTrue(ctx.allows([Rule(action: "allow", features: ["has_custom_resolution": true])]))
    }

    // MARK: Version documents

    func testVersionJSONDecodingAndLibraryPlanning() throws {
        let data = try Data(contentsOf: fixture("version-1.21-sample", "json"))
        let v = try JSONDecoder().decode(VersionJSON.self, from: data)
        XCTAssertEqual(v.requiredJavaMajor, 21)
        XCTAssertEqual(v.gameArguments.count, 21)
        XCTAssertEqual(LibraryPlanner.lwjglVersion(of: v), "3.3.3")

        let libs = LibraryPlanner.classpathLibraries(for: v).map { $0.library.name }
        // Natives classifiers are excluded; osx-only Java libraries are kept.
        XCTAssertEqual(libs, ["com.mojang:brigadier:1.2.9", "org.lwjgl:lwjgl:3.3.3", "ca.weblite:java-objc-bridge:1.1", "org.ow2.asm:asm:9.6"])

        var ctx = RuleContext()
        let jvm = LaunchPlanner.expand(v.jvmArguments, ctx)
        XCTAssertEqual(jvm, ["-XstartOnFirstThread", "-Djava.library.path=${natives_directory}", "-Dminecraft.launcher.brand=${launcher_name}", "-cp", "${classpath}"])
        let game = LaunchPlanner.expand(v.gameArguments, ctx)
        XCTAssertTrue(game.contains("--width"))
        XCTAssertFalse(game.contains("--demo"))
        XCTAssertFalse(game.contains("--quickPlayMultiplayer"))
        ctx.features["is_quick_play_multiplayer"] = true
        XCTAssertTrue(LaunchPlanner.expand(v.gameArguments, ctx).contains("--quickPlayMultiplayer"))
    }

    func testInheritanceMerge() throws {
        let vanilla = try JSONDecoder().decode(VersionJSON.self, from: Data(contentsOf: fixture("version-1.21-sample", "json")))
        let fabric = try JSONDecoder().decode(VersionJSON.self, from: Data(contentsOf: fixture("fabric-profile-sample", "json")))
        let merged = VersionResolver.merge([fabric, vanilla])
        XCTAssertEqual(merged.id, "fabric-loader-0.16.5-1.21-sample")
        XCTAssertEqual(merged.mainClass, "net.fabricmc.loader.impl.launch.knot.KnotClient")
        XCTAssertEqual(merged.assetIndex?.id, "17")
        XCTAssertEqual(merged.requiredJavaMajor, 21)
        let asm = merged.libraries?.filter { $0.coordinate?.artifact == "asm" }
        XCTAssertEqual(asm?.count, 1)
        XCTAssertEqual(asm?.first?.coordinate?.version, "9.7.1", "loader library must replace vanilla's")
        let planned = LibraryPlanner.classpathLibraries(for: merged)
        let loader = planned.first { $0.library.name == "net.fabricmc:fabric-loader:0.16.5" }
        XCTAssertEqual(loader?.item.url.absoluteString, "https://maven.fabricmc.net/net/fabricmc/fabric-loader/0.16.5/fabric-loader-0.16.5.jar")
        XCTAssertTrue(merged.jvmArguments.count > vanilla.jvmArguments.count)
    }

    func testMavenCoordinate() {
        let c = MavenCoordinate("org.lwjgl:lwjgl:3.3.3:natives-macos-arm64")!
        XCTAssertEqual(c.path, "org/lwjgl/lwjgl/3.3.3/lwjgl-3.3.3-natives-macos-arm64.jar")
        XCTAssertTrue(c.isNativesClassifier)
        XCTAssertEqual(MavenCoordinate("a.b:c:1@zip")?.path, "a/b/c/1/c-1.zip")
        XCTAssertNil(MavenCoordinate("bad"))
    }

    func testArgumentSubstitution() {
        XCTAssertEqual(LaunchPlanner.substitute("--gameDir=${game_directory}/x${unknown}", ["game_directory": "/g"]), "--gameDir=/g/x${unknown}")
        XCTAssertEqual(LaunchPlanner.splitArguments("-Xmx1G  \"-Dname=a b\" -Dx"), ["-Xmx1G", "-Dname=a b", "-Dx"])
        XCTAssertEqual(LaunchPlanner.dropEmptyOptions(["--a", "", "--b", "1"]), ["--b", "1"])
    }

    // MARK: Compatibility

    func testCompatibilityWithoutComponents() {
        let catalog = RuntimeCatalog()
        let modern = VersionRequirements(javaMajor: 21, desktopGL: 3.2, lwjglVersion: "3.3.3", usesLWJGL2: false, exact: true)
        guard case .missingComponents(let reasons) = Compatibility.evaluate(modern, catalog: catalog) else { return XCTFail() }
        XCTAssertEqual(reasons.count, 3)
        let old = VersionRequirements.estimate(releaseDate: MinecraftDate.parse("2016-11-14T14:34:40+00:00"))
        XCTAssertTrue(old.usesLWJGL2)
        XCTAssertEqual(Compatibility.evaluate(old, catalog: catalog).isUnsupported, true)
        XCTAssertEqual(VersionRequirements.estimate(releaseDate: MinecraftDate.parse("2022-06-07T09:42:18+00:00")).javaMajor, 17)
        XCTAssertEqual(RuntimeCatalog.javaMajor("1.8.0_402"), 8)
        XCTAssertEqual(RuntimeCatalog.javaMajor("17.0.12"), 17)
    }

    // MARK: Mods

    func testFabricJarWithNestedModules() throws {
        let meta = try XCTUnwrap(ModMetadataReader.read(jar: fixture("fabric-api-test", "jar")))
        XCTAssertEqual(meta.id, "fabric-api")
        XCTAssertEqual(meta.loader, .fabric)
        XCTAssertTrue(meta.provides.contains("fabric-api-base"))
        XCTAssertTrue(meta.nativeLibraries.isEmpty)
    }

    func testStoredJarAndNativeDetection() throws {
        let meta = try XCTUnwrap(ModMetadataReader.read(jar: fixture("sodium-like-test", "jar")))
        XCTAssertEqual(meta.version, "1.2.3")
        XCTAssertEqual(meta.nativeLibraries, ["natives/libthing.so"])
        XCTAssertEqual(meta.dependencies.first { $0.modID == "minecraft" }?.versions, ["1.20.x", "1.21.x"])
    }

    func testForgeToml() throws {
        let meta = try XCTUnwrap(ModMetadataReader.read(jar: fixture("forge-test", "jar")))
        XCTAssertEqual(meta.loader, .forge)
        XCTAssertEqual(meta.id, "forgeexample")
        XCTAssertEqual(meta.name, "Forge Example")
        XCTAssertEqual(meta.dependencies.first?.versions, ["[1.20.1,1.21)"])
    }

    func testDependencyAnalysis() throws {
        var profile = GameProfile.make(name: "t", version: "1.21.1")
        profile.loader = .fabric
        profile.loaderVersion = "0.16.5"
        let api = InstalledMod(fileURL: try fixture("fabric-api-test", "jar"), enabled: true, metadata: try ModMetadataReader.read(jar: fixture("fabric-api-test", "jar")))
        let ex = InstalledMod(fileURL: try fixture("sodium-like-test", "jar"), enabled: true, metadata: try ModMetadataReader.read(jar: fixture("sodium-like-test", "jar")))
        let issues = ModManager.analyze(mods: [api, ex], profile: profile, javaMajor: 21)
        XCTAssertTrue(issues.contains { $0.message.contains("missingdep") && $0.severity == .error })
        XCTAssertTrue(issues.contains { $0.message.contains("native code") })
        XCTAssertFalse(issues.contains { $0.message.contains("fabric-api-base") }, "jar-in-jar module satisfies the dependency")
        XCTAssertFalse(issues.contains { $0.message.contains("needs minecraft") })
    }

    func testVersionPredicates() {
        XCTAssertTrue(VersionPredicate.matches("0.16.5", ">=0.15.0"))
        XCTAssertFalse(VersionPredicate.matches("0.14.9", ">=0.15.0"))
        XCTAssertTrue(VersionPredicate.matches("1.21.1", "~1.21"))
        XCTAssertFalse(VersionPredicate.matches("1.22", "~1.21"))
        XCTAssertTrue(VersionPredicate.matches("1.21.4", "1.21.x"))
        XCTAssertFalse(VersionPredicate.matches("1.20.4", "1.21.x"))
        XCTAssertTrue(VersionPredicate.matches("1.20.4", anyOf: ["1.19.x", "1.20.x"]))
        XCTAssertTrue(VersionPredicate.matches("1.20.4", "[1.20.1,1.21)"))
        XCTAssertFalse(VersionPredicate.matches("1.21", "[1.20.1,1.21)"))
        XCTAssertTrue(VersionPredicate.matches("2.0", ">=1.0 <3"))
        XCTAssertTrue(LooseVersion("1.0.0-beta.2") < LooseVersion("1.0.0"))
    }

    func testModpackIndexAndZipExtraction() throws {
        let zip = try ZipReader(url: fixture("test", "mrpack"))
        let index = try JSONDecoder().decode(ModpackImporter.Index.self, from: XCTUnwrap(zip.contents(of: "modrinth.index.json")))
        XCTAssertEqual(index.dependencies["fabric-loader"], "0.16.5")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try zip.extract(prefix: "overrides/", to: dir), 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("config/test.txt"), encoding: .utf8), "hello")
    }

    // MARK: Multiplayer

    func testVarIntAndHandshake() throws {
        XCTAssertEqual(MinecraftProtocol.varInt(0), Data([0]))
        XCTAssertEqual(MinecraftProtocol.varInt(300), Data([0xAC, 0x02]))
        XCTAssertEqual(MinecraftProtocol.varInt(-1), Data([0xFF, 0xFF, 0xFF, 0xFF, 0x0F]))
        let (value, n) = try XCTUnwrap(MinecraftProtocol.readVarInt(Data([0xAC, 0x02, 0x00]), at: 0))
        XCTAssertEqual(value, 300)
        XCTAssertEqual(n, 2)
        XCTAssertNil(try MinecraftProtocol.readVarInt(Data([0xAC]), at: 0))
        let hs = MinecraftProtocol.handshake(host: "a", port: 25565)
        // length, id 0, protocol -1 (5 bytes), "a", port, next state 1
        XCTAssertEqual(Array(hs), [11, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0x0F, 1, 0x61, 0x63, 0xDD, 1])
    }

    func testStatusParsing() throws {
        let json = #"{"version":{"name":"1.21.1","protocol":767},"players":{"max":20,"online":3},"description":{"text":"Hello ","extra":[{"text":"§aWorld"}]}}"#
        let s = try MinecraftProtocol.parseStatus(Data(json.utf8), latency: 12)
        XCTAssertEqual(s.protocolVersion, 767)
        XCTAssertEqual(s.playersOnline, 3)
        XCTAssertEqual(s.motd, "Hello World")
    }

    func testServersDatNBT() {
        let data = ServerStore.serversDat([SavedServer(name: "A", address: "b:1")])
        var expected: [UInt8] = [10, 0, 0]                    // root compound, empty name
        expected += [9, 0, 7] + Array("servers".utf8)          // list "servers"
        expected += [10, 0, 0, 0, 1]                           // of 1 compound
        expected += [8, 0, 4] + Array("name".utf8) + [0, 1, 0x41]
        expected += [8, 0, 2] + Array("ip".utf8) + [0, 3] + Array("b:1".utf8)
        expected += [0, 0]                                     // end server, end root
        XCTAssertEqual(Array(data), expected)
        XCTAssertEqual(SavedServer(name: "x", address: "mc.example.org:25570").port, 25570)
        XCTAssertEqual(SavedServer(name: "x", address: "mc.example.org").host, "mc.example.org")
    }

    // MARK: Accounts

    func testPKCEChallengeRFC7636Vector() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(PKCE.makeVerifier().count, 43)
    }

    func testOptionsFileMerge() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "lang:de_de\nrenderDistance:32\n".write(to: dir.appendingPathComponent("options.txt"), atomically: true, encoding: .utf8)
        var s = LauncherSettings()
        s.renderDistance = 6
        GameOptionsFile.apply(s, to: dir)
        let text = try String(contentsOf: dir.appendingPathComponent("options.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("lang:de_de"))
        XCTAssertTrue(text.contains("renderDistance:6"))
        XCTAssertFalse(text.contains("renderDistance:32"))
    }

    func testSettingsDecodeIsLenient() throws {
        let s = try JSONDecoder().decode(LauncherSettings.self, from: Data(#"{"memoryMB":3072}"#.utf8))
        XCTAssertEqual(s.memoryMB, 3072)
        XCTAssertEqual(s.fpsLimit, LauncherSettings().fpsLimit)
        XCTAssertEqual(s.keyMap[KeyMapping.jump.rawValue], GLFWKey.space)
    }
}
