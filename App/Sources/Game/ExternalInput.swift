import GameController
import UIKit

/// Bluetooth controllers and mice via GameController.framework, translated
/// into the same keyboard/mouse events as the touch layer.
final class ExternalInput {
    private let sink: InputSink
    private var settings: LauncherSettings
    private var heldKeys = Set<Int>()
    private var observers: [NSObjectProtocol] = []
    private var menuCursor = CGPoint(x: 400, y: 300)
    var surfaceSize = CGSize(width: 1600, height: 740)

    init(sink: InputSink, settings: LauncherSettings) {
        self.sink = sink
        self.settings = settings
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        })
        observers.append(center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] n in
            if let m = n.object as? GCMouse { self?.attach(m) }
        })
        GCController.controllers().forEach(attach)
        GCMouse.mice().forEach(attach)
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func update(settings: LauncherSettings) { self.settings = settings }

    private func key(_ a: KeyMapping) -> Int { settings.keyMap[a.rawValue] ?? KeyMapping.defaults[a.rawValue]! }

    private func attach(_ controller: GCController) {
        guard settings.gamepadEnabled, let pad = controller.extendedGamepad else { return }
        zlog.info("Controller connected: \(controller.vendorName ?? "unknown")")
        let bind: (GCControllerButtonInput, @escaping (Bool) -> Void) -> Void = { button, action in
            button.pressedChangedHandler = { _, _, pressed in action(pressed) }
        }
        bind(pad.buttonA) { [weak self] p in
            guard let self else { return }
            if self.sink.cursorGrabbed { self.sink.key(self.key(.jump), pressed: p) } else { self.sink.mouseButton(0, pressed: p) }
        }
        bind(pad.buttonB) { [weak self] p in
            guard let self else { return }
            if self.sink.cursorGrabbed { self.sink.key(self.key(.sneak), pressed: p) } else if p { self.sink.tapKey(self.key(.pause)) }
        }
        bind(pad.buttonX) { [weak self] p in guard let self else { return }; self.sink.key(self.key(.drop), pressed: p) }
        bind(pad.buttonY) { [weak self] p in guard let self, p else { return }; self.sink.tapKey(self.key(.inventory)) }
        bind(pad.rightTrigger) { [weak self] p in self?.sink.mouseButton(0, pressed: p) }
        bind(pad.leftTrigger) { [weak self] p in self?.sink.mouseButton(1, pressed: p) }
        bind(pad.leftShoulder) { [weak self] p in if p { self?.sink.scroll(dx: 0, dy: 1) } }
        bind(pad.rightShoulder) { [weak self] p in if p { self?.sink.scroll(dx: 0, dy: -1) } }
        bind(pad.buttonMenu) { [weak self] p in guard let self, p else { return }; self.sink.tapKey(self.key(.pause)) }
        if let options = pad.buttonOptions { bind(options) { [weak self] p in guard let self, p else { return }; self.sink.tapKey(self.key(.chat)) } }
        if let l3 = pad.leftThumbstickButton { bind(l3) { [weak self] p in guard let self else { return }; self.sink.key(self.key(.sprint), pressed: p) } }
        if let r3 = pad.rightThumbstickButton { bind(r3) { [weak self] p in guard let self, p else { return }; self.sink.tapKey(self.key(.perspective)) } }
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { [weak self] _, dx, dy in
            guard let self else { return }
            if self.sink.cursorGrabbed {
                self.sink.cursorDelta(dx: Double(dx), dy: Double(-dy))
            } else {
                self.moveMenuCursor(dx: CGFloat(dx), dy: CGFloat(-dy))
            }
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, p in self?.sink.mouseButton(0, pressed: p) }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, p in self?.sink.mouseButton(1, pressed: p) }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, p in self?.sink.mouseButton(2, pressed: p) }
        input.scroll.valueChangedHandler = { [weak self] _, _, y in if y != 0 { self?.sink.scroll(dx: 0, dy: Double(y > 0 ? 1 : -1)) } }
    }

    private func moveMenuCursor(dx: CGFloat, dy: CGFloat) {
        menuCursor.x = min(max(0, menuCursor.x + dx), surfaceSize.width)
        menuCursor.y = min(max(0, menuCursor.y + dy), surfaceSize.height)
        sink.cursorPosition(x: Double(menuCursor.x), y: Double(menuCursor.y))
    }

    /// Called once per display frame for analog sticks.
    func poll(frameTime: Double) {
        guard settings.gamepadEnabled, let pad = GCController.current?.extendedGamepad else { return }
        let dz = Float(settings.gamepadDeadzone)
        let ls = pad.leftThumbstick, rs = pad.rightThumbstick
        if sink.cursorGrabbed {
            var wanted = Set<Int>()
            if ls.yAxis.value > 0.4 { wanted.insert(key(.forward)) }
            if ls.yAxis.value < -0.4 { wanted.insert(key(.back)) }
            if ls.xAxis.value < -0.4 { wanted.insert(key(.left)) }
            if ls.xAxis.value > 0.4 { wanted.insert(key(.right)) }
            for k in heldKeys.subtracting(wanted) { sink.key(k, pressed: false) }
            for k in wanted.subtracting(heldKeys) { sink.key(k, pressed: true) }
            heldKeys = wanted
            let speed = 900.0 * settings.gamepadLookSpeed * frameTime
            let x = abs(rs.xAxis.value) > dz ? Double(rs.xAxis.value) : 0
            let y = abs(rs.yAxis.value) > dz ? Double(rs.yAxis.value) : 0
            if x != 0 || y != 0 { sink.cursorDelta(dx: x * speed, dy: -y * speed * (settings.invertY ? -1 : 1)) }
        } else {
            for k in heldKeys { sink.key(k, pressed: false) }
            heldKeys.removeAll()
            let speed = CGFloat(1200 * frameTime)
            let x = abs(ls.xAxis.value) > dz ? CGFloat(ls.xAxis.value) : 0
            let y = abs(ls.yAxis.value) > dz ? CGFloat(ls.yAxis.value) : 0
            if x != 0 || y != 0 { moveMenuCursor(dx: x * speed, dy: -y * speed) }
        }
    }
}
