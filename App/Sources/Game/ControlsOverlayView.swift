import UIKit

/// Bedrock-style touch layer. Everything it does ends up as GLFW keyboard /
/// mouse events, i.e. genuine Java Edition input — the game cannot tell it
/// from a desktop keyboard and mouse.
///
/// In-world (cursor grabbed): left joystick → movement keys, free touches on
/// the right → camera; holding still mines (left button held), a quick tap
/// uses/places (right click). In menus (cursor free): touches drive the mouse
/// pointer directly; tap = click, drag = drag, long-press = right click,
/// two-finger pan = scroll.
final class ControlsOverlayView: UIView {
    private enum Role {
        case joystick
        case button(HUDControlKind)
        case hotbar(Int)
        case camera(start: CGPoint, last: CGPoint, began: TimeInterval, moved: Bool, mining: Bool)
        case pointer(last: CGPoint, began: TimeInterval, moved: Bool)
    }

    var sink: InputSink
    var settings: LauncherSettings { didSet { applyAppearance() } }
    var preset: HUDPreset { didSet { rebuildControls() } }
    /// Drawable pixels per point of this view (resolution scale aware).
    var pixelScale: CGFloat = 2
    var onKeyboardRequest: (() -> Void)?
    /// Talk button pressed / released.
    var onVoiceButton: ((Bool) -> Void)?

    func setVoiceActive(_ active: Bool) { controlViews[.voice]?.isActive = active }

    private var roles: [ObjectIdentifier: Role] = [:]
    private var controlViews: [HUDControlKind: HUDControlView] = [:]
    private var joystickView: JoystickView?
    private var hotbarView: HotbarView?
    private var inGame = true

    private var joystickKeys = Set<Int>()
    private var lastJoystickBegan: TimeInterval = 0
    private var sprintFromDoubleTap = false
    private var sneakLatched = false
    private var sprintLatched = false
    private var holdTimers: [ObjectIdentifier: Timer] = [:]
    private var twoFingerScrollLastY: CGFloat?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init(sink: InputSink, settings: LauncherSettings, preset: HUDPreset) {
        self.sink = sink
        self.settings = settings
        self.preset = preset
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        rebuildControls()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func key(_ action: KeyMapping) -> Int { settings.keyMap[action.rawValue] ?? KeyMapping.defaults[action.rawValue]! }

    // MARK: Layout

    private func rebuildControls() {
        subviews.forEach { $0.removeFromSuperview() }
        controlViews.removeAll()
        joystickView = nil
        hotbarView = nil
        for control in preset.controls {
            switch control.kind {
            case .joystick:
                let j = JoystickView()
                addSubview(j)
                joystickView = j
            case .hotbar:
                let h = HotbarView()
                addSubview(h)
                hotbarView = h
            default:
                let v = HUDControlView(kind: control.kind)
                addSubview(v)
                controlViews[control.kind] = v
            }
        }
        applyAppearance()
        setNeedsLayout()
    }

    private func applyAppearance() {
        for v in subviews { v.alpha = CGFloat(settings.controlOpacity) }
        updateVisibility()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: safeAreaInsets)
        let scale = CGFloat(settings.controlScale)
        for control in preset.controls {
            let center = CGPoint(x: area.minX + area.width * control.x, y: area.minY + area.height * control.y)
            let s = CGFloat(control.size) * scale
            switch control.kind {
            case .joystick:
                joystickView?.frame = CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)
            case .hotbar:
                let w = min(area.width * 0.42, s * 9)
                hotbarView?.frame = CGRect(x: center.x - w / 2, y: center.y - s / 2, width: w, height: s)
            default:
                controlViews[control.kind]?.frame = CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)
            }
        }
    }

    /// Called every frame with the game's cursor state.
    func setInGame(_ grabbed: Bool) {
        guard grabbed != inGame else { return }
        inGame = grabbed
        releaseAll()
        updateVisibility()
    }

    private func updateVisibility() {
        for (kind, v) in controlViews { v.isHidden = !inGame && !kind.visibleInMenus }
        joystickView?.isHidden = !inGame
        hotbarView?.isHidden = !inGame
        controlViews[.sneak]?.isActive = sneakLatched
        controlViews[.sprint]?.isActive = sprintLatched
    }

    /// Release every held key/button (mode switch, app backgrounding).
    func releaseAll() {
        for k in joystickKeys { sink.key(k, pressed: false) }
        joystickKeys.removeAll()
        joystickView?.reset()
        for (_, role) in roles {
            switch role {
            case .button(let kind): release(kind)
            case .camera(_, _, _, _, let mining) where mining: sink.mouseButton(0, pressed: false)
            default: break
            }
        }
        holdTimers.values.forEach { $0.invalidate() }
        holdTimers.removeAll()
        roles.removeAll()
        if sprintFromDoubleTap {
            sink.key(key(.sprint), pressed: false)
            sprintFromDoubleTap = false
        }
    }

    // MARK: Touch routing

    private func hitControl(at p: CGPoint) -> Role? {
        if let j = joystickView, !j.isHidden, j.frame.insetBy(dx: -20, dy: -20).contains(p) { return .joystick }
        if let h = hotbarView, !h.isHidden, h.frame.contains(p) {
            let slot = Int((p.x - h.frame.minX) / (h.frame.width / 9))
            return .hotbar(max(0, min(8, slot)))
        }
        for (kind, v) in controlViews where !v.isHidden && v.frame.insetBy(dx: -6, dy: -6).contains(p) { return .button(kind) }
        return nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = CACurrentMediaTime()
        for t in touches {
            let p = t.location(in: self)
            let id = ObjectIdentifier(t)
            if let role = hitControl(at: p) {
                roles[id] = role
                switch role {
                case .joystick:
                    if settings.doubleTapSprint && now - lastJoystickBegan < 0.3 {
                        sprintFromDoubleTap = true
                        sink.key(key(.sprint), pressed: true)
                    }
                    lastJoystickBegan = now
                    updateJoystick(t)
                case .button(let kind): press(kind)
                case .hotbar(let slot):
                    sink.tapKey(GLFWKey.num1 + slot)
                    hotbarView?.selected = slot
                    feedback()
                default: break
                }
                continue
            }
            if inGame {
                roles[id] = .camera(start: p, last: p, began: now, moved: false, mining: false)
                scheduleHoldToMine(id)
            } else {
                handleMenuBegan(t, id: id, at: p, now: now, event: event)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            let p = t.location(in: self)
            guard let role = roles[id] else { continue }
            switch role {
            case .joystick:
                updateJoystick(t)
            case .camera(let start, let last, let began, var moved, let mining):
                let dx = p.x - last.x, dy = p.y - last.y
                if hypot(p.x - start.x, p.y - start.y) > 8 { moved = true }
                if moved {
                    let factor = CGFloat(settings.cameraSensitivity) * pixelScale
                    sink.cursorDelta(dx: Double(dx * factor), dy: Double(dy * factor * (settings.invertY ? -1 : 1)))
                }
                roles[id] = .camera(start: start, last: p, began: began, moved: moved, mining: mining)
            case .pointer(_, let began, var moved):
                if twoFingerScrollLastY != nil, (event?.allTouches?.count ?? 1) >= 2 {
                    handleTwoFingerScroll(event)
                    continue
                }
                moved = moved || hypot(p.x - (t.previousLocation(in: self).x), p.y - t.previousLocation(in: self).y) > 0
                sink.cursorPosition(x: Double(p.x * pixelScale), y: Double(p.y * pixelScale))
                roles[id] = .pointer(last: p, began: began, moved: moved)
            default: break
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for t in touches {
            let id = ObjectIdentifier(t)
            holdTimers[id]?.invalidate()
            holdTimers[id] = nil
            guard let role = roles.removeValue(forKey: id) else { continue }
            switch role {
            case .joystick:
                for k in joystickKeys { sink.key(k, pressed: false) }
                joystickKeys.removeAll()
                joystickView?.reset()
                if sprintFromDoubleTap {
                    sink.key(key(.sprint), pressed: false)
                    sprintFromDoubleTap = false
                }
            case .button(let kind):
                release(kind)
            case .camera(_, _, _, let moved, let mining):
                if mining {
                    sink.mouseButton(0, pressed: false)
                } else if !moved && !cancelled {
                    // Bedrock behaviour: a quick tap interacts / places.
                    sink.mouseButton(1, pressed: true)
                    sink.mouseButton(1, pressed: false)
                }
            case .pointer:
                sink.mouseButton(0, pressed: false)
                twoFingerScrollLastY = nil
            case .hotbar:
                break
            }
        }
    }

    // MARK: In-world helpers

    private func scheduleHoldToMine(_ id: ObjectIdentifier) {
        holdTimers[id] = Timer.scheduledTimer(withTimeInterval: settings.holdToMineDelay, repeats: false) { [weak self] _ in
            guard let self, case .camera(let s, let l, let b, let moved, false)? = self.roles[id], !moved else { return }
            self.roles[id] = .camera(start: s, last: l, began: b, moved: moved, mining: true)
            self.sink.mouseButton(0, pressed: true)
            self.feedback()
        }
    }

    private func updateJoystick(_ t: UITouch) {
        guard let j = joystickView else { return }
        let v = j.update(touch: t.location(in: j))
        var wanted = Set<Int>()
        let threshold: CGFloat = 0.35
        if v.dy < -threshold { wanted.insert(key(.forward)) }
        if v.dy > threshold { wanted.insert(key(.back)) }
        if v.dx < -threshold { wanted.insert(key(.left)) }
        if v.dx > threshold { wanted.insert(key(.right)) }
        for k in joystickKeys.subtracting(wanted) { sink.key(k, pressed: false) }
        for k in wanted.subtracting(joystickKeys) { sink.key(k, pressed: true) }
        joystickKeys = wanted
    }

    private func press(_ kind: HUDControlKind) {
        feedback()
        controlViews[kind]?.isPressed = true
        switch kind {
        case .jump: sink.key(key(.jump), pressed: true)
        case .attack: sink.mouseButton(0, pressed: true)
        case .use: sink.mouseButton(1, pressed: true)
        case .sneak:
            if settings.sneakIsToggle {
                sneakLatched.toggle()
                sink.key(key(.sneak), pressed: sneakLatched)
            } else {
                sink.key(key(.sneak), pressed: true)
            }
        case .sprint:
            sprintLatched.toggle()
            sink.key(key(.sprint), pressed: sprintLatched)
        case .inventory: sink.tapKey(key(.inventory))
        case .drop: sink.key(key(.drop), pressed: true)
        case .chat:
            sink.tapKey(key(.chat))
            onKeyboardRequest?()
        case .command:
            sink.tapKey(key(.command))
            onKeyboardRequest?()
        case .pause: sink.tapKey(key(.pause))
        case .perspective: sink.tapKey(key(.perspective))
        case .keyboard: onKeyboardRequest?()
        case .voice: onVoiceButton?(true)
        case .joystick, .hotbar: break
        }
        updateVisibility()
    }

    private func release(_ kind: HUDControlKind) {
        controlViews[kind]?.isPressed = false
        switch kind {
        case .jump: sink.key(key(.jump), pressed: false)
        case .attack: sink.mouseButton(0, pressed: false)
        case .use: sink.mouseButton(1, pressed: false)
        case .sneak where !settings.sneakIsToggle: sink.key(key(.sneak), pressed: false)
        case .drop: sink.key(key(.drop), pressed: false)
        case .voice: onVoiceButton?(false)
        default: break
        }
    }

    // MARK: Menu pointer

    private func handleMenuBegan(_ t: UITouch, id: ObjectIdentifier, at p: CGPoint, now: TimeInterval, event: UIEvent?) {
        let activePointers = roles.values.filter { if case .pointer = $0 { return true } else { return false } }.count
        if activePointers >= 1 {
            // Second finger: switch to scrolling instead of clicking.
            sink.mouseButton(0, pressed: false)
            twoFingerScrollLastY = averageY(event)
            roles[id] = .pointer(last: p, began: now, moved: true)
            return
        }
        sink.cursorPosition(x: Double(p.x * pixelScale), y: Double(p.y * pixelScale))
        sink.mouseButton(0, pressed: true)
        roles[id] = .pointer(last: p, began: now, moved: false)
        holdTimers[id] = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            guard let self, case .pointer(_, _, let moved)? = self.roles[id], !moved else { return }
            // Long press → right click (split stacks, context actions).
            self.sink.mouseButton(0, pressed: false)
            self.sink.mouseButton(1, pressed: true)
            self.sink.mouseButton(1, pressed: false)
            self.roles[id] = .pointer(last: p, began: now, moved: true)
            self.feedback()
        }
    }

    private func averageY(_ event: UIEvent?) -> CGFloat? {
        guard let touches = event?.allTouches, !touches.isEmpty else { return nil }
        return touches.map { $0.location(in: self).y }.reduce(0, +) / CGFloat(touches.count)
    }

    private func handleTwoFingerScroll(_ event: UIEvent?) {
        guard let y = averageY(event), let last = twoFingerScrollLastY else { return }
        let delta = (y - last) / 24
        if abs(delta) >= 1 {
            sink.scroll(dx: 0, dy: Double(delta.rounded(.towardZero)))
            twoFingerScrollLastY = y
        }
    }

    private func feedback() {
        if settings.haptics { haptic.impactOccurred() }
    }
}

// MARK: - Control views

final class HUDControlView: UIView {
    let kind: HUDControlKind
    private let icon = UIImageView()
    var isPressed = false { didSet { refresh() } }
    var isActive = false { didSet { refresh() } }

    init(kind: HUDControlKind) {
        self.kind = kind
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerRadius = 12
        layer.borderWidth = 1.5
        icon.image = UIImage(systemName: kind.symbol)
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        addSubview(icon)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = bounds.insetBy(dx: bounds.width * 0.26, dy: bounds.height * 0.26)
        layer.cornerRadius = min(bounds.width, bounds.height) * 0.28
    }

    private func refresh() {
        let accent = UIColor(red: 0.33, green: 0.85, blue: 0.47, alpha: 1)
        backgroundColor = isPressed ? accent.withAlphaComponent(0.55) : isActive ? accent.withAlphaComponent(0.35) : UIColor.black.withAlphaComponent(0.35)
        layer.borderColor = (isActive ? accent : UIColor.white.withAlphaComponent(0.55)).cgColor
    }
}

final class JoystickView: UIView {
    private let knob = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.25)
        layer.borderColor = UIColor.white.withAlphaComponent(0.5).cgColor
        layer.borderWidth = 1.5
        knob.backgroundColor = UIColor.white.withAlphaComponent(0.65)
        addSubview(knob)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        let k = bounds.width * 0.38
        knob.bounds = CGRect(x: 0, y: 0, width: k, height: k)
        knob.layer.cornerRadius = k / 2
        if knob.center == .zero { knob.center = CGPoint(x: bounds.midX, y: bounds.midY) }
    }

    /// Returns the deflection vector, each axis in -1...1.
    func update(touch p: CGPoint) -> CGVector {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r = bounds.width / 2
        var dx = p.x - c.x, dy = p.y - c.y
        let len = hypot(dx, dy)
        if len > r { dx *= r / len; dy *= r / len }
        knob.center = CGPoint(x: c.x + dx, y: c.y + dy)
        return CGVector(dx: dx / r, dy: dy / r)
    }

    func reset() { knob.center = CGPoint(x: bounds.midX, y: bounds.midY) }
}

final class HotbarView: UIView {
    var selected = 0 { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let w = bounds.width / 9
        for i in 0..<9 {
            let r = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height).insetBy(dx: 1.5, dy: 1.5)
            let path = UIBezierPath(roundedRect: r, cornerRadius: 4)
            (i == selected ? UIColor.white.withAlphaComponent(0.35) : UIColor.black.withAlphaComponent(0.2)).setFill()
            path.fill()
            (i == selected ? UIColor.white : UIColor.white.withAlphaComponent(0.4)).setStroke()
            path.lineWidth = i == selected ? 2 : 1
            path.stroke()
        }
    }
}
