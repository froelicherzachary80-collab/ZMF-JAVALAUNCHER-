import UIKit

/// Orchestrates "Play": account check, installation check, settings sync,
/// launch planning, and presenting the game view that hosts the JVM.
@MainActor
final class GameSession: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing(String)
        case blocked([String])
        case running
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var selfTestResult: String?
    @Published var lastExitNotice: String?

    init() {
        let statusURL = Paths.launcherData.appendingPathComponent("last-exit-status")
        if let text = try? String(contentsOf: statusURL, encoding: .utf8) {
            let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if code != "0" { lastExitNotice = "The last game session ended with status \(code). Crash reports and logs are in Mods › Crash Reports." }
            try? FileManager.default.removeItem(at: statusURL)
        }
    }

    func play(profile: GameProfile, model: AppModel, quickPlay: QuickPlayTarget? = nil) async {
        if ZMFJVMBridge.hasLaunchedInThisProcess() {
            state = .blocked(["Java can be started once per app session (a JNI limitation). Close ZMF Java from the app switcher and open it again to launch."])
            return
        }
        do {
            state = .preparing("Checking account")
            let account = try await model.accounts.validSession(clientID: model.settingsStore.effectiveClientID)

            state = .preparing("Checking installation")
            if !model.installer.isInstalled(profile.launchVersionID) {
                state = .preparing("Installing \(profile.launchVersionID)")
                try await model.installer.install(profile.launchVersionID)
            }

            let settings = model.settingsStore.settings
            if settings.voiceEnabled && settings.voiceAutoConnect && !model.voice.isConnected && !model.settingsStore.effectiveRelayURL.isEmpty {
                state = .preparing("Connecting ZMF Voice")
                await model.connectVoice() // failures are shown in the Voice tab; the game still starts
            }
            GameOptionsFile.apply(settings, to: profile.gameDirectory)
            model.servers.sync(to: profile.gameDirectory)

            let screen = UIScreen.main.nativeBounds.size
            let scale = settings.resolutionScale
            let surface = (width: Int(max(screen.width, screen.height) * scale), height: Int(min(screen.width, screen.height) * scale))
            let catalog = RuntimeCatalog.discover()
            let plan = try LaunchPlanner.plan(profile: profile, settings: settings, account: account, catalog: catalog,
                                              surface: surface, quickPlay: quickPlay)
            try? plan.redactedDescription.write(to: Paths.logs.appendingPathComponent("launch-plan.txt"), atomically: true, encoding: .utf8)
            model.profiles.markPlayed(profile.id)
            present(.game(plan), model: model)
            state = .running
        } catch let blocked as LaunchBlocked {
            state = .blocked(blocked.reasons)
        } catch {
            state = .failed(error.localizedDescription)
            zlog.error("Launch failed: \(error.localizedDescription)")
        }
    }

    func openControlsLab(model: AppModel) {
        present(.controlsLab, model: model)
    }

    private func present(_ mode: GameViewController.Mode, model: AppModel) {
        let settings = model.settingsStore.settings
        let vc = GameViewController(mode: mode, settings: settings, preset: model.hud.preset(settings.activeHUDPreset), voice: model.voice)
        vc.onFinish = { [weak self] in
            if case .running = self?.state { self?.state = .idle }
        }
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(vc, animated: true)
    }

    /// Starts the embedded JVM with the SelfTest class: proof that real Java
    /// bytecode executes on this device. Uses up this process's single JVM.
    func runSelfTest(runtime: JavaRuntime) {
        let output = Paths.launcherData.appendingPathComponent("selftest.json")
        try? FileManager.default.removeItem(at: output)
        do {
            let req = try LaunchPlanner.selfTestPlan(runtime: runtime, outputURL: output)
            selfTestResult = "Running on \(runtime.displayName)…"
            ZMFJVMBridge.launch(req) { [weak self] code, error in
                if let data = try? Data(contentsOf: output), let json = String(data: data, encoding: .utf8) {
                    self?.selfTestResult = "PASS (exit \(code))\n\(json)"
                } else {
                    let log = (try? String(contentsOfFile: req.logPath, encoding: .utf8)).map { String($0.suffix(1500)) } ?? ""
                    self?.selfTestResult = "FAILED (exit \(code)) \(error ?? "")\n\(log)"
                }
            }
        } catch {
            selfTestResult = "FAILED: \(error.localizedDescription)"
        }
    }
}
