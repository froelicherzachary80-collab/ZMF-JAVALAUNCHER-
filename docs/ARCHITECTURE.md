# Architecture

```
App/Sources
├── App/            SwiftUI entry point, AppModel (object graph, news)
├── Theme/          Original dark visual identity
├── Core/           Paths (Files-visible layout), settings, key mapping, logging
├── Net/            HTTP, SHA-1 hashing, concurrent verified Downloader
├── Minecraft/      Version manifest, version JSON model, rules, inheritance
│                   resolver, asset index, InstallationManager, profiles, options.txt
├── Loaders/        Fabric / Quilt profile installer (meta APIs)
├── Mods/           ZIP reader (stored+deflate), mod metadata (fabric/quilt/
│                   mods.toml), version predicates, ModManager, .mrpack importer
├── Accounts/       Microsoft OAuth PKCE → Xbox Live → XSTS → Minecraft
│                   services, Keychain, skin face renderer
├── Multiplayer/    Server List Ping (Network.framework), NBT writer, servers.dat
├── Runtime/        Runtime/renderer/LWJGL catalog, compatibility evaluation,
│                   LaunchPlanner, GameSession
├── Bridge/         ObjC: JVM host (JNI invocation API), JIT/memory probes
├── Game/           GameViewController, render views, touch overlay, HUD
│                   presets, hardware keyboard, GameController input
└── Views/          Home, Installations, Versions, Profile editor, Mods,
                    Crash reports, Servers, Settings, HUD editor
Native/ZMFGLFW      GLFW 3.4 implementation for iOS (framework LWJGL loads)
Java/src            Bootstrap + SelfTest (compiled to zmf-support.jar, Java 8 bytecode)
Tests/              XCTest unit tests run on the iOS Simulator in CI
scripts/            Java build, JNI headers, component fetch/embed, IPA packaging/signing
project.yml         XcodeGen spec → ZMFJavaLauncher.xcodeproj (generated in CI)
```

## Storage layout (Files › On My iPhone › ZMF Java › ZMF)

```
minecraft/versions/<id>/<id>.json, <id>.jar   shared Mojang-style store
minecraft/libraries/…                          maven layout
minecraft/assets/{indexes,objects,log_configs}
instances/<profile>/                          game dir: mods, saves, config, options.txt, servers.dat, crash-reports
launcher/                                      settings.json, profiles.json, servers.json, hud-presets.json, caches
logs/                                          launcher.log, game-*.log, launch-plan.txt (token redacted)
exports/                                       *.zmfprofile.json
```

## Input pipeline

Touch / keyboard / gamepad → `InputSink` → `zmf_input_*` (locked queue) →
`glfwPollEvents()` on the game thread → the callbacks Minecraft registered via
LWJGL. The overlay switches between in-world controls and a direct pointer
based on `glfwSetInputMode(GLFW_CURSOR)` — i.e. whether the game itself has
grabbed the mouse.
