# Status and verification — v0.1

Legend: **CI** = demonstrated automatically on GitHub Actions ·
**Device** = must be tested by you on the iPhone · **Blocked** = cannot work
until the named component exists.

## Acceptance checks

| Check | Status | Evidence / blocker |
|---|---|---|
| Xcode project compiles for physical iOS arm64 | **CI** | `Compile for iOS device` job (`xcodebuild -sdk iphoneos ARCHS=arm64`) |
| IPA contains a real iOS executable | **CI** | `package-ipa.sh` checks Mach-O arm64 + LC_BUILD_VERSION, ZMFGLFW framework exports, support jar |
| Launcher logic (rules, inheritance, mods, NBT, SLP, PKCE, options) | **CI** | `Unit tests (iOS Simulator)` job |
| Support jar is valid Java bytecode | **CI** | host JVM runs `Bootstrap → SelfTest` in the build job |
| Java runtime executes real bytecode **on iOS** | **Blocked → Device** | Needs an iOS arm64 Java runtime embedded (none in default builds). Then: Settings › Runtime › Run bytecode self-test |
| Authenticated Minecraft installation downloads | **Device** | Needs an approved Azure client ID + your account. Installer, SHA-1 verify and repair are implemented |
| Minecraft reaches the title screen | **Blocked** | Needs iOS Java runtime + iOS LWJGL natives + desktop-GL translation layer, and realistically JIT |
| Single-player world loads with touch controls | **Blocked** | As above. Touch → GLFW event path can be tried now in the Controls Lab |
| Fabric mod verified in gameplay | **Blocked** | Fabric profile install + mod manager implemented; gameplay blocked as above |
| Multiplayer on a test server | **Partially Device** | Server ping/status works without the game (Servers tab). Joining blocked as above |

## v0.2 additions

| Feature | Status | Evidence |
|---|---|---|
| Voice relay: auth, proximity, whisper, private/password rooms, isolated/open | **CI** | `Voice relay` workflow: unit + end-to-end tests with real WebSocket clients |
| Position probe resolves names in vanilla (obfuscated) and Fabric (intermediary) builds | **CI** | `scripts/test-java.sh` against fake game classes + mapping files |
| Voice framing, 3D math, SRV parsing, version matching, Opus encode/decode | **CI** | `VoiceTests` on the iOS Simulator (Opus test skips if the simulator lacks the codec) |
| Mic capture, 3D playback, voice processing on iPhone | **Device** | needs testing on your phone with a deployed relay |
| Rooms from the launcher (no game running) | **Device** | usable now once a relay is deployed |
| Proximity voice in game | **Blocked** | needs the game itself running (see runtime blockers above) |
| Device-code sign-in | **Device** | needs an approved Microsoft app ID |

**Not claimed:** no build of this repository has run Minecraft. The default
IPA is a complete launcher whose Play button explains exactly which runtime
components are missing; it never shows simulated gameplay.

## Remaining limitations (honest list)

1. **No iOS Java runtime in the default IPA.** OpenJDK has no official iOS
   port; a community iOS build must be supplied (docs/RUNTIME.md).
2. **LWJGL natives for iOS** must be built from LWJGL sources and embedded.
3. **Graphics:** Minecraft 1.17+ requires desktop OpenGL 3.2 core. iOS has
   only OpenGL ES (deprecated) and Metal; a translation layer is mandatory.
   The built-in EAGL renderer is diagnostic only.
4. **JIT:** only available while a debugger-based enabler is attached; iOS 26
   + TXM devices need enabler/runtime support. Without JIT, HotSpot needs a
   Zero (interpreter-only) build and will be very slow.
5. **One JVM per app launch** (JNI limitation): restart the app between game
   sessions.
6. **Forge/NeoForge** are detected (mods.toml parsing, compatibility checks)
   but not installable: their installers execute Java processors.
7. **LWJGL 2 versions** (≤1.12.2) are reported as unsupported.
8. **LAN discovery** needs Apple's multicast entitlement; join by IP.
9. **Desktop native code in mods** (.so/.dll/.dylib) cannot load; ZMF flags
   such mods.
10. **Microsoft sign-in** needs an Azure app ID approved for Minecraft
    services (Microsoft's policy, not bypassable).
11. **Memory**: without the increased-memory-limit entitlement, iOS may kill
    the app at a few GB; heap defaults to 2 GB and is adjustable.
12. SRV DNS records (`_minecraft._tcp`) are not resolved by the launcher's
    ping (the game itself resolves them when joining).
