import UIKit

/// Full-screen landscape host for a game session (or the Controls Lab).
final class GameViewController: UIViewController {
    enum Mode {
        case game(LaunchPlan)
        case controlsLab
    }

    private let mode: Mode
    private var settings: LauncherSettings
    private let preset: HUDPreset
    private let sink: InputSink
    private let renderView: UIView
    private let overlay: ControlsOverlayView
    private let keyInput = KeyInputView()
    private let statsLabel = UILabel()
    private let messageView = UITextView()
    private let closeButton = UIButton(type: .system)
    private let labModeSwitch = UISegmentedControl(items: ["In world", "Menu"])
    private var external: ExternalInput?
    private var displayLink: CADisplayLink?
    private var attached = false
    private var lastSize: CGSize = .zero
    private var lastStatsUpdate: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var labLines: [String] = []
    var onFinish: (() -> Void)?

    init(mode: Mode, settings: LauncherSettings, preset: HUDPreset) {
        self.mode = mode
        self.settings = settings
        self.preset = preset
        switch mode {
        case .game(let plan):
            sink = GLFWInputSink()
            renderView = plan.renderer.contextAPI == .egl ? MetalRenderView() : EAGLRenderView()
        case .controlsLab:
            sink = RecordingInputSink()
            renderView = UIView()
            renderView.backgroundColor = UIColor(white: 0.08, alpha: 1)
        }
        overlay = ControlsOverlayView(sink: sink, settings: settings, preset: preset)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { settings.fullscreen }
    override var prefersHomeIndicatorAutoHidden: Bool { settings.fullscreen }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(renderView)
        view.addSubview(overlay)

        keyInput.sink = sink
        keyInput.frame = CGRect(x: -10, y: -10, width: 1, height: 1)
        view.addSubview(keyInput)
        overlay.onKeyboardRequest = { [weak self] in self?.toggleKeyboard() }

        statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        statsLabel.textColor = .white
        statsLabel.numberOfLines = 0
        statsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        statsLabel.layer.cornerRadius = 6
        statsLabel.clipsToBounds = true
        view.addSubview(statsLabel)

        messageView.isEditable = false
        messageView.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        messageView.textColor = .white
        messageView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        messageView.layer.cornerRadius = 10
        messageView.isHidden = true
        view.addSubview(messageView)

        closeButton.setTitle("Close", for: .normal)
        closeButton.titleLabel?.font = .boldSystemFont(ofSize: 15)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        closeButton.layer.cornerRadius = 8
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        if case .controlsLab = mode {
            let recorder = sink as! RecordingInputSink
            recorder.onEvent = { [weak self] line in self?.appendLab(line) }
            messageView.isHidden = false
            messageView.isUserInteractionEnabled = false
            messageView.text = "Controls Lab — touch the controls; the Java input events they produce appear here.\n"
            labModeSwitch.selectedSegmentIndex = 0
            labModeSwitch.addTarget(self, action: #selector(labModeChanged), for: .valueChanged)
            view.addSubview(labModeSwitch)
        } else {
            closeButton.isHidden = true
        }

        external = ExternalInput(sink: sink, settings: settings)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let scene = view.window?.windowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
            setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        renderView.frame = view.bounds
        overlay.frame = view.bounds
        let safe = view.safeAreaInsets
        statsLabel.frame = CGRect(x: safe.left + 8, y: max(safe.top, 6), width: 170, height: 44)
        closeButton.frame = CGRect(x: view.bounds.width - safe.right - 84, y: max(safe.top, 6) + 50, width: 76, height: 34)
        labModeSwitch.frame = CGRect(x: view.bounds.width - safe.right - 200, y: max(safe.top, 6) + 90, width: 192, height: 30)
        if case .controlsLab = mode {
            messageView.frame = CGRect(x: view.bounds.width * 0.28, y: view.bounds.height * 0.18, width: view.bounds.width * 0.44, height: view.bounds.height * 0.5)
        } else {
            messageView.frame = view.bounds.insetBy(dx: view.bounds.width * 0.15, dy: view.bounds.height * 0.15)
        }

        let screenScale = view.window?.screen.scale ?? UIScreen.main.scale
        let contentScale = screenScale * CGFloat(settings.resolutionScale)
        renderView.contentScaleFactor = contentScale
        overlay.pixelScale = contentScale
        let pixels = CGSize(width: (view.bounds.width * contentScale).rounded(), height: (view.bounds.height * contentScale).rounded())
        external?.surfaceSize = pixels
        guard pixels.width > 0, pixels.height > 0, view.bounds.width > view.bounds.height else { return }
        if case .game(let plan) = mode {
            if !attached {
                attached = true
                lastSize = pixels
                startGame(plan, pixels: pixels)
            } else if pixels != lastSize {
                lastSize = pixels
                zmf_surface_resized(Int32(pixels.width), Int32(pixels.height))
            }
        }
    }

    // MARK: Game

    private func startGame(_ plan: LaunchPlan, pixels: CGSize) {
        var config = zmf_renderer_config()
        switch plan.renderer.contextAPI {
        case .eagl2: config.api = ZMF_CONTEXT_EAGL_GLES2
        case .eagl3: config.api = ZMF_CONTEXT_EAGL_GLES3
        case .egl: config.api = ZMF_CONTEXT_EGL
        }
        let glPath = plan.renderer.libraryPath(plan.renderer.glLibrary)
        let eglPath = plan.renderer.libraryPath(plan.renderer.eglLibrary)
        withOptionalCString(glPath) { gl in
            withOptionalCString(eglPath) { egl in
                withOptionalCString(plan.renderer.initSymbol) { initSym in
                    config.gl_library_path = gl
                    config.egl_library_path = egl
                    config.init_symbol = initSym
                    zmf_set_renderer(&config) // copies the strings
                }
            }
        }
        zmf_set_fps_cap(Int32(settings.fpsLimit))
        zmf_attach_layer(Unmanaged.passUnretained(renderView.layer).toOpaque(), Int32(pixels.width), Int32(pixels.height))
        zmf_input_window_focus(true)

        let req = ZMFJVMLaunchRequest()
        req.javaHome = plan.runtime.home.path
        req.jvmArguments = plan.jvmArguments
        req.mainClass = plan.mainClass
        req.applicationArguments = plan.applicationArguments
        req.workingDirectory = plan.gameDirectory.path
        req.logPath = plan.logURL.path
        req.exitStatusPath = plan.exitStatusURL.path
        zlog.info("Starting JVM \(plan.runtime.displayName) with renderer \(plan.renderer.id); log: \(plan.logURL.lastPathComponent)")
        ZMFJVMBridge.launch(req) { [weak self] code, error in
            self?.gameEnded(code: Int(code), error: error, plan: plan)
        }
    }

    private func gameEnded(code: Int, error: String?, plan: LaunchPlan) {
        zlog.info("Game session ended: code \(code) \(error ?? "")")
        let tail = (try? String(contentsOf: plan.logURL, encoding: .utf8)).map { String($0.suffix(4000)) } ?? ""
        messageView.text = "Java exited with code \(code).\n\(error ?? "")\n\nLast log lines (\(plan.logURL.lastPathComponent)):\n\(tail)"
        messageView.isHidden = false
        messageView.isUserInteractionEnabled = true
        closeButton.isHidden = false
        overlay.isHidden = true
    }

    private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let s else { return body(nil) }
        return s.withCString { body($0) }
    }

    // MARK: Frame tick

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastFrameTime == 0 ? 1.0 / 60 : min(0.1, now - lastFrameTime)
        lastFrameTime = now
        overlay.setInGame(sink.cursorGrabbed)
        external?.poll(frameTime: dt)

        if now - lastStatsUpdate > 0.5 {
            lastStatsUpdate = now
            applyThermalPolicy()
            var lines: [String] = []
            if settings.showFPS {
                if case .game = mode { lines.append(String(format: "FPS %.0f", zmf_current_fps())) } else { lines.append("FPS — (no game)") }
            }
            if settings.showMemory {
                let used = Double(ZMFMemoryFootprint()) / 1_048_576
                let avail = Double(ZMFAvailableMemory()) / 1_048_576
                lines.append(String(format: "MEM %.0f MB · free %.0f", used, avail))
            }
            statsLabel.text = lines.isEmpty ? nil : lines.map { " " + $0 }.joined(separator: "\n")
            statsLabel.isHidden = lines.isEmpty
        }
    }

    private func applyThermalPolicy() {
        guard case .game = mode else { return }
        var cap = settings.fpsLimit
        if settings.thermalAware {
            switch ProcessInfo.processInfo.thermalState {
            case .serious: cap = cap == 0 ? 30 : min(cap, 30)
            case .critical: cap = cap == 0 ? 20 : min(cap, 20)
            default: break
            }
        }
        zmf_set_fps_cap(Int32(cap))
    }

    // MARK: Actions

    private func toggleKeyboard() {
        if keyInput.isFirstResponder { keyInput.resignFirstResponder() } else { keyInput.becomeFirstResponder() }
    }

    private func appendLab(_ line: String) {
        labLines.append(line)
        if labLines.count > 14 { labLines.removeFirst(labLines.count - 14) }
        messageView.text = "Controls Lab — events sent to Java:\n\n" + labLines.joined(separator: "\n")
    }

    @objc private func labModeChanged() {
        (sink as? RecordingInputSink)?.grabbed = labModeSwitch.selectedSegmentIndex == 0
    }

    @objc private func closeTapped() {
        dismiss(animated: true) { [onFinish] in onFinish?() }
    }

    @objc private func appWillResignActive() {
        overlay.releaseAll()
        if case .game = mode { zmf_input_window_focus(false) }
    }

    @objc private func appDidBecomeActive() {
        if case .game = mode { zmf_input_window_focus(true) }
    }

    // Hardware keyboard → GLFW keys + text.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let k = press.key, let code = HardwareKeyMap.glfwKey(k.keyCode) else { continue }
            sink.key(code, pressed: true)
            if !sink.cursorGrabbed, k.modifierFlags.intersection([.command, .control]).isEmpty {
                for scalar in k.characters.unicodeScalars where scalar.value >= 32 && scalar.value != 127 { sink.char(scalar.value) }
            }
            handled = true
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let k = press.key, let code = HardwareKeyMap.glfwKey(k.keyCode) else { continue }
            sink.key(code, pressed: false)
            handled = true
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }
}
