import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    NavigationLink { AccountSettingsView() } label: {
                        LabeledContent("Microsoft account", value: model.accounts.active?.username ?? "Not signed in")
                    }
                }
                Section("Play") {
                    NavigationLink { ControlsSettingsView() } label: { Label("Touch controls", systemImage: "hand.tap") }
                    NavigationLink { KeyMappingView() } label: { Label("Keyboard & mouse mapping", systemImage: "keyboard") }
                    NavigationLink { GamepadSettingsView() } label: { Label("Gamepad", systemImage: "gamecontroller") }
                    Button { model.session.openControlsLab(model: model) } label: { Label("Controls Lab (try controls without a game)", systemImage: "testtube.2") }
                }
                Section("Game") {
                    NavigationLink { VideoSettingsView() } label: { Label("Video", systemImage: "display") }
                    NavigationLink { PerformanceSettingsView() } label: { Label("Performance & Java memory", systemImage: "speedometer") }
                    NavigationLink { RuntimeInfoView() } label: { Label("Runtime components", systemImage: "cpu") }
                }
                Section("Files") {
                    NavigationLink { FilesInfoView() } label: { Label("File management", systemImage: "folder") }
                    NavigationLink { LogFileView(url: LauncherLog.shared.fileURL) } label: { Label("Launcher log", systemImage: "doc.plaintext") }
                }
                Section {
                    LabeledContent("Version", value: "0.1 (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                    Text("ZMF Java Launcher is an independent, unofficial launcher. It is not affiliated with Mojang or Microsoft and ships no Minecraft game files.")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Settings")
        }
    }
}

struct AccountSettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                ForEach(model.accounts.accounts) { account in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.username).font(.headline)
                            Text(account.dashedUUID).font(.caption2).foregroundStyle(Theme.textSecondary)
                            Text("Entitlements: \(account.entitlements.isEmpty ? "none listed" : account.entitlements.joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if account.id == model.accounts.active?.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.accounts.activeID = account.id }
                    .swipeActions { Button("Log out", role: .destructive) { model.accounts.signOut(account) } }
                }
                Button {
                    Task { await model.accounts.signIn(clientID: model.settingsStore.effectiveClientID) }
                } label: {
                    if model.accounts.busy { ProgressView() } else { Label("Sign in with Microsoft", systemImage: "person.badge.plus") }
                }
                if let err = model.accounts.lastError { Text(err).font(.footnote).foregroundStyle(Theme.danger) }
            } header: { Text("Accounts") } footer: {
                Text("Sign-in happens on Microsoft's own page (OAuth 2.0 authorization code + PKCE); ZMF never sees your password. Tokens are stored in the iOS Keychain on this device only. Swipe an account to log out.")
            }
            Section {
                TextField("Azure application (client) ID", text: $store.settings.microsoftClientID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(.footnote, design: .monospaced))
                LabeledContent("In use", value: model.settingsStore.effectiveClientID.isEmpty ? "none" : model.settingsStore.effectiveClientID)
                    .font(.caption)
            } header: { Text("Microsoft application") } footer: {
                Text("Register a public client in Microsoft Entra (Azure) with redirect URI zmflauncher://auth. Microsoft must approve new app IDs for Minecraft services before login_with_xbox succeeds.")
            }
        }
        .navigationTitle("Account")
    }
}

struct ControlsSettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SettingsStore
    private var s: Binding<LauncherSettings> { $store.settings }

    var body: some View {
        Form {
            Section("Layout") {
                Picker("Preset", selection: s.activeHUDPreset) {
                    ForEach(model.hud.all) { Text($0.name).tag($0.id) }
                }
                NavigationLink("Edit layout (drag & drop)") { HUDEditorView(preset: model.hud.preset(model.settingsStore.settings.activeHUDPreset)) }
                slider("Opacity", s.controlOpacity, 0.15...1)
                slider("Size", s.controlScale, 0.6...1.6)
            }
            Section("Camera") {
                slider("Sensitivity", s.cameraSensitivity, 0.2...3)
                Toggle("Invert Y axis", isOn: s.invertY)
            }
            Section("Behaviour") {
                slider("Hold-to-mine delay (s)", s.holdToMineDelay, 0.1...0.8)
                Toggle("Double-tap joystick to sprint", isOn: s.doubleTapSprint)
                Toggle("Sneak button toggles", isOn: s.sneakIsToggle)
                Toggle("Haptic feedback", isOn: s.haptics)
            }
        }
        .navigationTitle("Touch Controls")
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(String(format: "%.2f", value.wrappedValue))").font(.subheadline)
            Slider(value: value, in: range)
        }
    }
}

struct KeyMappingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(KeyMapping.allCases) { action in
                    Picker(action.title, selection: Binding(
                        get: { model.settingsStore.settings.keyMap[action.rawValue] ?? KeyMapping.defaults[action.rawValue]! },
                        set: { model.settingsStore.settings.keyMap[action.rawValue] = $0 })) {
                        ForEach(GLFWKey.selectable, id: \.self) { Text(GLFWKey.name($0)).tag($0) }
                    }
                }
                Button("Reset to Minecraft defaults") { model.settingsStore.settings.keyMap = KeyMapping.defaults }
            } footer: {
                Text("Each touch or gamepad action sends this Java key. If you rebind a key inside Minecraft's Controls menu, change it here too. Mouse: Attack = left button, Use = right button, hotbar = number keys 1–9.")
            }
        }
        .navigationTitle("Key Mapping")
    }
}

struct GamepadSettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SettingsStore
    var body: some View {
        Form {
            Section {
                Toggle("Enable Bluetooth controllers", isOn: $store.settings.gamepadEnabled)
                VStack(alignment: .leading) {
                    Text("Look speed: \(String(format: "%.2f", model.settingsStore.settings.gamepadLookSpeed))")
                    Slider(value: $store.settings.gamepadLookSpeed, in: 0.2...3)
                }
                VStack(alignment: .leading) {
                    Text("Stick dead zone: \(String(format: "%.2f", model.settingsStore.settings.gamepadDeadzone))")
                    Slider(value: $store.settings.gamepadDeadzone, in: 0.02...0.4)
                }
            } footer: {
                Text("Layout: left stick move · right stick look · A jump · B sneak · X drop · Y inventory · RT attack · LT use · LB/RB hotbar · L3 sprint · R3 perspective · Menu pause · Options chat. In menus the left stick moves the pointer and A clicks. Bluetooth mice are supported too.")
            }
        }
        .navigationTitle("Gamepad")
    }
}

struct VideoSettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SettingsStore
    private var s: Binding<LauncherSettings> { $store.settings }

    var body: some View {
        Form {
            Section("Quality profile") {
                Picker("Profile", selection: Binding(get: { model.settingsStore.settings.qualityProfile },
                                                      set: { model.settingsStore.settings.apply($0) })) {
                    ForEach(QualityProfile.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Stepper("Render distance: \(s.wrappedValue.renderDistance) chunks", value: custom(s.renderDistance), in: 2...16)
                Stepper("Simulation distance: \(s.wrappedValue.simulationDistance)", value: custom(s.simulationDistance), in: 5...12)
                Picker("Frame-rate limit", selection: custom(s.fpsLimit)) {
                    Text("30").tag(30); Text("45").tag(45); Text("60").tag(60); Text("90").tag(90); Text("120").tag(120); Text("Unlimited").tag(0)
                }
                VStack(alignment: .leading) {
                    Text("Resolution scale: \(Int(s.wrappedValue.resolutionScale * 100))%")
                    Slider(value: custom(s.resolutionScale), in: 0.4...1, step: 0.05)
                }
                Toggle("Fancy graphics", isOn: custom(s.fancyGraphics))
                Toggle("Smooth lighting", isOn: custom(s.smoothLighting))
                Stepper("GUI scale: \(s.wrappedValue.guiScale == 0 ? "Auto" : "\(s.wrappedValue.guiScale)")", value: s.guiScale, in: 0...4)
            } header: { Text("Rendering") } footer: {
                Text("These values are written to the profile's options.txt before every launch, so they are what Minecraft uses.")
            }
            Section("Display") {
                Toggle("Fullscreen (hide status bar & home indicator)", isOn: s.fullscreen)
                Toggle("FPS counter", isOn: s.showFPS)
                Toggle("Memory usage", isOn: s.showMemory)
                Toggle("Shader packs where supported", isOn: s.enableShadersWhenSupported)
            }
        }
        .navigationTitle("Video")
    }

    /// Editing any individual value switches the quality profile to Custom.
    private func custom<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: {
            binding.wrappedValue = $0
            model.settingsStore.settings.qualityProfile = .custom
        })
    }
}

struct PerformanceSettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SettingsStore
    private var s: Binding<LauncherSettings> { $store.settings }

    var body: some View {
        Form {
            Section {
                Stepper("Max heap: \(s.wrappedValue.memoryMB) MB", value: s.memoryMB, in: LauncherSettings.memoryRange, step: 256)
                LabeledContent("Device RAM", value: ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
                LabeledContent("Available to app now", value: ByteCountFormatter.string(fromByteCount: Int64(ZMFAvailableMemory()), countStyle: .memory))
                Picker("Garbage collector", selection: s.gc) {
                    Text("G1").tag(GCMode.g1); Text("Serial (less memory)").tag(GCMode.serial)
                }
                TextField("Extra JVM arguments", text: s.extraJVMArguments)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().font(.system(.footnote, design: .monospaced))
            } header: { Text("Java") } footer: {
                Text("iOS terminates apps that exceed their memory limit. Without the increased-memory-limit entitlement, keep the heap at or below about half of “Available to app”.")
            }
            Section {
                Toggle("Thermal-aware frame cap", isOn: s.thermalAware)
                Toggle("Force interpreter (-Xint) when JIT is unavailable", isOn: s.forceInterpreterWithoutJIT)
            } footer: {
                Text("Thermal-aware: when iOS reports serious/critical thermal state the frame cap drops to 30/20 FPS until the device cools.")
            }
        }
        .navigationTitle("Performance")
    }
}

struct RuntimeInfoView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                LabeledContent("JIT", value: model.jitAvailable ? "Available (debugger attached)" : "Not available")
                Text(model.jitAvailable
                     ? "CS_DEBUGGED is set. On iOS 26 devices with TXM the JIT enabler must also service the runtime's JIT memory requests."
                     : "iOS only allows JIT for sideloaded apps while a debugger-based enabler (e.g. StikDebug) is attached. Without it, Java runs interpreted (-Xint), which is many times slower.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Button("Re-check") { model.refreshEnvironment() }
            } header: { Text("Execution") }

            Section("Java runtimes in this build") {
                if model.catalog.runtimes.isEmpty {
                    Text("None embedded. This IPA was built without an iOS Java runtime, so Java cannot start yet.").foregroundStyle(Theme.warning).font(.footnote)
                }
                ForEach(model.catalog.runtimes) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.displayName).font(.subheadline.bold())
                        Text(r.implementor ?? "unknown vendor").font(.caption2).foregroundStyle(Theme.textSecondary)
                        Text(r.libjvm ?? "libjvm.dylib missing").font(.caption2).foregroundStyle(r.libjvm == nil ? Theme.danger : Theme.textSecondary)
                        Button("Run bytecode self-test") { model.session.runSelfTest(runtime: r) }
                            .buttonStyle(.bordered)
                            .disabled(ZMFJVMBridge.hasLaunchedInThisProcess() || r.libjvm == nil)
                    }
                }
                if let result = model.session.selfTestResult {
                    Text(result).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                }
            }

            Section("Renderers") {
                ForEach(model.catalog.renderers) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(r.displayName).font(.subheadline.bold())
                        Text("Context: \(r.contextAPI.rawValue) · desktop GL: \(r.desktopGL ?? "none")").font(.caption2)
                        if let n = r.notes { Text(n).font(.caption2).foregroundStyle(Theme.textSecondary) }
                    }
                }
            }

            Section("LWJGL natives for iOS") {
                if model.catalog.lwjgl.isEmpty { Text("None embedded.").foregroundStyle(Theme.warning).font(.footnote) }
                ForEach(model.catalog.lwjgl, id: \.version) { n in
                    LabeledContent("LWJGL \(n.version)", value: n.hasOpenAL ? "with OpenAL" : "no OpenAL (no sound)")
                }
            }
            Section {
                Text("GLFW is provided by ZMF itself (ZMFGLFW.framework), implemented on UIKit/EAGL/EGL.").font(.caption)
            }
        }
        .navigationTitle("Runtime")
        .onAppear { model.refreshEnvironment() }
    }
}

struct FilesInfoView: View {
    @State private var sizes: [(String, Int64)] = []

    var body: some View {
        List {
            Section {
                Text("All launcher data is in Files › On My iPhone › ZMF Java › ZMF. Drop worlds into instances/<profile>/saves, resource packs into resourcepacks, shader packs into shaderpacks.")
                    .font(.footnote)
            }
            Section("Disk usage") {
                ForEach(sizes, id: \.0) { LabeledContent($0.0, value: ByteCountFormatter.string(fromByteCount: $0.1, countStyle: .file)) }
            }
            Section {
                Button("Clear temporary files") {
                    let tmp = FileManager.default.temporaryDirectory
                    for f in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: f) }
                    computeSizes()
                }
            }
        }
        .navigationTitle("Files")
        .task { computeSizes() }
    }

    private func computeSizes() {
        let dirs: [(String, URL)] = [("Versions", Paths.versions), ("Libraries", Paths.libraries), ("Assets", Paths.assets),
                                     ("Instances", Paths.instances), ("Logs", Paths.logs)]
        sizes = dirs.map { ($0.0, Self.size(of: $0.1)) }
    }

    static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
