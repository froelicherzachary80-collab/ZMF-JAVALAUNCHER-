# Java runtime, graphics and native integration

This document explains how ZMF Java Launcher runs Minecraft: Java Edition
in-process on iOS, which parts ZMF implements itself, and which third-party
native components must be embedded for the game to start.

## Process model

iOS forbids spawning processes, so there is no `java` executable. ZMF loads
the JVM as a library inside the app:

```
SwiftUI launcher ──► LaunchPlanner (classpath, JVM + game arguments)
                         │
                         ▼
ZMFJVMBridge.m  dlopen(<runtime>/lib/server/libjvm.dylib)
                JNI_CreateJavaVM(...)            ← on a 16 MiB-stack pthread
                CallStaticVoidMethod(Bootstrap.main)
                         │
                         ▼
dev.zmf.support.Bootstrap (Java 8 bytecode, App.app/java/zmf-support.jar)
  → crash handler → Class.forName(<version mainClass>).main(gameArgs)
                         │  (vanilla: net.minecraft.client.main.Main,
                         │   Fabric:  net.fabricmc.loader.impl.launch.knot.KnotClient)
                         ▼
Minecraft → LWJGL 3 → org.lwjgl.glfw.libname = ZMFGLFW.framework (ours)
                    → org.lwjgl.opengl.libname = renderer GL library
                    → org.lwjgl.openal.libname = libopenal.dylib (optional)
```

* stdout/stderr of the process are redirected to `ZMF/logs/game-<time>.log`.
* JNI `exit`/`abort` hooks record the exit status so the next launch can
  report a crash.
* A JVM can be created **once per process**; to launch again the app must be
  restarted (the launcher tells the user).

## What ZMF implements (original code in this repository)

| Component | Where | Notes |
|---|---|---|
| JVM host | `App/Sources/Bridge/ZMFJVMBridge.m` | JNI invocation API, log redirection, exit hooks |
| Launch planning | `App/Sources/Runtime/LaunchPlanner.swift` | Mojang argument templates, rules, `-cp` → `-Djava.class.path`, quick play |
| GLFW 3.4 | `Native/ZMFGLFW/src/zmf_glfw.m` | Every GLFW entry point LWJGL binds; window = full-screen layer; EAGL or EGL context; event queue; clipboard; timers |
| Default-framebuffer mapping | `Native/ZMFGLFW/src/zmf_gl_interpose.c` | `glBindFramebuffer(0)` → EAGL drawable FBO |
| Input | `App/Sources/Game/*` | Touch → GLFW keys/mouse; hardware keyboard; GCController; GCMouse |
| Frame pacing / stats | `zmf_glfw.m` + `GameViewController.swift` | FPS cap, thermal cap, FPS + memory overlay |
| Support jar | `Java/src/dev/zmf/support` | Bootstrap + bytecode SelfTest |

## What must be embedded (not in the repository)

The IPA can only *run* Minecraft when these iOS **arm64** binaries are
embedded. They are third-party, independently licensed projects; ZMF does
not vendor them and CI fetches them only when you provide URLs.

| Directory in App.app | Content | Requirement |
|---|---|---|
| `runtimes/<name>/` | A Java home built for iOS (arm64, LC_BUILD_VERSION platform iOS): `release`, `lib/server/libjvm.dylib`, `lib/*.dylib`, `lib/modules` | Java 21 for 1.20.5+, Java 17 for 1.18–1.20.4, Java 8 for ≤1.16 |
| `lwjgl/<version>/` | `liblwjgl.dylib`, `liblwjgl_opengl.dylib`, `liblwjgl_stb.dylib`, `liblwjgl_tinyfd.dylib`, optional `libopenal.dylib`, built for iOS from LWJGL 3 sources | Same LWJGL major.minor as the game (1.21 uses 3.3.3) |
| `renderers/<id>/` | `renderer.json` + a GL library that exposes **desktop OpenGL** on top of GLES/Metal | GL 2.1 (≤1.16) or GL 3.2 core (1.17+) |

`renderer.json` example:

```json
{
  "id": "gl4es",
  "displayName": "GL4ES (desktop GL 2.1 on GLES 2)",
  "contextAPI": "eagl2",
  "glLibrary": "libGL.dylib",
  "initSymbol": "initialize_gl4es",
  "desktopGL": "2.1",
  "notes": "For Minecraft 1.16.5 and older."
}
```

`contextAPI` is `eagl2`, `eagl3` or `egl`. For `egl` (ANGLE / MetalANGLE)
also set `eglLibrary`; the game view then uses a `CAMetalLayer`.

### Embedding through CI

Set repository **variables** (Settings → Secrets and variables → Actions →
Variables) or the inputs of a manual workflow run:

* `ZMF_RUNTIME_URLS`, `ZMF_LWJGL_URLS`, `ZMF_RENDERER_URLS` — space-separated
  archive URLs (`.zip`, `.tar.gz`, `.tar.xz`), each optionally suffixed with
  `#sha256=<hex>`.

`scripts/fetch-components.sh` stages them; `scripts/embed-components.sh`
(an Xcode build phase) copies them into the app and **fails the build if any
Mach-O is not arm64 built for iOS**, so a macOS JDK can never slip in.

### Candidate sources (evaluate licences yourself)

* **Java runtime:** OpenJDK (GPLv2 + Classpath Exception) does not ship iOS
  builds. Community builds of OpenJDK 8/17/21 for iOS arm64 exist (for
  example the `android-openjdk-build-multiarch` project's iOS targets). ZMF
  uses such a build only as an external runtime dependency; no launcher code
  from other launchers is used.
* **LWJGL natives:** build LWJGL 3 (BSD-3) for iOS from its sources.
* **Graphics:** GL4ES (MIT) covers desktop GL 2.1 → GLES 2 for Minecraft ≤ 1.16.
  1.17+ needs a GL 3.2-core-capable translator (e.g. a GL→GLES3/ANGLE layer).
  ANGLE (BSD) with its Metal backend provides EGL + GLES 3 only; it is not by
  itself a desktop-GL implementation.

## JIT and the interpreter

* iOS grants JIT (writable + executable memory) to a sideloaded app only while
  a debugger is attached. ZMF detects this through the `CS_DEBUGGED`
  code-signing flag (`ZMFProcessHasDebuggerJIT`) and shows it in
  Settings › Runtime components.
* On iOS 26 with TXM (A15 and newer — includes iPhone 16 Pro) the flag alone is
  not enough: the JIT enabler (e.g. StikDebug) must also handle the runtime's
  JIT region requests, and the JVM build must support that protocol.
* **Signing alone never enables JIT**, and no entitlement available to
  sideloaded apps grants it.
* Without JIT ZMF passes `-Xint`. Caveat: HotSpot's *template* interpreter
  itself generates machine code at startup, so a standard HotSpot build still
  needs executable memory. A truly JIT-less fallback requires a runtime built
  with the **Zero** (C++ interpreter) VM variant. Expect Zero to be on the
  order of 10–50× slower than JIT-compiled code: it can be enough to reach
  menus slowly, not for smooth gameplay.

## Memory

iPhone 16 Pro has 8 GB RAM, but an app without the
`com.apple.developer.kernel.increased-memory-limit` entitlement is
terminated well below that. The launcher shows the live
`os_proc_available_memory()` value; keep `-Xmx` at about half of it.
