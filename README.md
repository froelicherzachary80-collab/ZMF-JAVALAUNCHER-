# ZMF Java Launcher 0.1

An original, native iOS launcher for **Minecraft: Java Edition** — Swift/SwiftUI,
Objective-C and C, built into an IPA by GitHub Actions. Unofficial; not affiliated
with Mojang or Microsoft; ships no game files.

**Not an official Minecraft product. Not approved by or associated with Mojang or Microsoft.**

## Install

* **AltStore / SideStore:** add the source
  `https://github.com/froelicherzachary80-collab/ZMF-JAVALAUNCHER-/releases/latest/download/altstore-source.json`
* **Signulous / other signing services:** download the IPA from
  [Releases](https://github.com/froelicherzachary80-collab/ZMF-JAVALAUNCHER-/releases) and sign it.
* Details: [docs/INSTALL.md](docs/INSTALL.md) · Privacy: [PRIVACY.md](PRIVACY.md) ·
  Licenses: [LICENSE](LICENSE), [NOTICE.md](NOTICE.md) · Publishing: [docs/PUBLISHING.md](docs/PUBLISHING.md)

## What works in this build

- Version manager: live Mojang manifest, install / verify (SHA-1) / repair / delete, per-version compatibility status
- Profiles with separate game folders; Fabric (and Quilt) loader profiles
- Mod manager: import .jar from Files, enable/disable/delete, dependency & incompatibility detection (incl. jar-in-jar and desktop native code), Modrinth .mrpack import, profile export, crash reports & logs
- Microsoft sign-in (OAuth 2.0 + PKCE in the system sheet), Keychain tokens, refresh, ownership + profile + skin
- Servers: saved list mirrored to `servers.dat`, live status ping (with SRV records), server-version detection with one-tap matching profile, Join
- **ZMF Voice**: proximity voice chat on any server/version plus public/private/password rooms — only ZMF players hear each other ([docs/VOICE.md](docs/VOICE.md), relay in `voice-relay/`)
- Sign in with Microsoft's page or with a code at microsoft.com/link
- In-process JVM host (JNI), GLFW 3.4 implementation for LWJGL, EAGL/EGL contexts
- Bedrock-style touch controls (joystick, camera, hold-to-mine, tap-to-use, hotbar, chat keyboard…), HUD drag-and-drop editor + presets, key mapping, Bluetooth controller & mouse, hardware keyboard
- Video/performance settings written to `options.txt`; FPS/memory overlay; thermal-aware frame cap

## What does not work yet

Minecraft itself cannot start from the default IPA: it needs an iOS arm64 Java
runtime, iOS LWJGL natives and a desktop-GL translation layer embedded at build
time, and in practice JIT. The launcher says so explicitly instead of faking it.
Full, honest status: **[docs/STATUS.md](docs/STATUS.md)** · runtime details:
**[docs/RUNTIME.md](docs/RUNTIME.md)** · code map: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Build

CI does everything (`.github/workflows/build-ipa.yml`). On a Mac:

```sh
brew install xcodegen
./scripts/prepare-jni-headers.sh && ./scripts/build-java-support.sh
xcodegen generate && open ZMFJavaLauncher.xcodeproj
```
