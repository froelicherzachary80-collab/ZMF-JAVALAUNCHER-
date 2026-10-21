import Foundation

/// Destination for synthesized desktop input. In a game session this is the
/// GLFW event queue that Minecraft polls; the Controls Lab uses a recording
/// sink so the whole touch pipeline can be tried without a running JVM.
protocol InputSink: AnyObject {
    func key(_ code: Int, pressed: Bool)
    func char(_ scalar: UInt32)
    func mouseButton(_ button: Int, pressed: Bool)
    func cursorPosition(x: Double, y: Double)
    func cursorDelta(dx: Double, dy: Double)
    func scroll(dx: Double, dy: Double)
    var cursorGrabbed: Bool { get }
}

extension InputSink {
    func tapKey(_ code: Int) {
        key(code, pressed: true)
        key(code, pressed: false)
    }
}

final class GLFWInputSink: InputSink {
    func key(_ code: Int, pressed: Bool) { zmf_input_key(Int32(code), pressed ? ZMF_PRESS : ZMF_RELEASE, 0) }
    func char(_ scalar: UInt32) { zmf_input_char(scalar) }
    func mouseButton(_ button: Int, pressed: Bool) { zmf_input_mouse_button(Int32(button), pressed ? ZMF_PRESS : ZMF_RELEASE) }
    func cursorPosition(x: Double, y: Double) { zmf_input_cursor_pos(x, y) }
    func cursorDelta(dx: Double, dy: Double) { zmf_input_cursor_delta(dx, dy) }
    func scroll(dx: Double, dy: Double) { zmf_input_scroll(dx, dy) }
    var cursorGrabbed: Bool { zmf_cursor_grabbed() }
}

/// Records events and lets the user flip between in-world and menu modes.
final class RecordingInputSink: InputSink {
    var grabbed = true
    var onEvent: ((String) -> Void)?
    private var accumulatedDX = 0.0, accumulatedDY = 0.0

    func key(_ code: Int, pressed: Bool) { emit("key \(GLFWKey.name(code)) \(pressed ? "down" : "up")") }
    func char(_ scalar: UInt32) { emit("char '\(UnicodeScalar(scalar).map { String($0) } ?? "?")'") }
    func mouseButton(_ button: Int, pressed: Bool) {
        let name = button == 0 ? "left" : button == 1 ? "right" : "middle"
        emit("mouse \(name) \(pressed ? "down" : "up")")
    }
    func cursorPosition(x: Double, y: Double) { emit(String(format: "cursor %.0f, %.0f", x, y)) }
    func cursorDelta(dx: Double, dy: Double) {
        accumulatedDX += dx
        accumulatedDY += dy
        if abs(accumulatedDX) + abs(accumulatedDY) > 40 {
            emit(String(format: "look Δ %.0f, %.0f", accumulatedDX, accumulatedDY))
            accumulatedDX = 0
            accumulatedDY = 0
        }
    }
    func scroll(dx: Double, dy: Double) { emit(String(format: "scroll %.1f", dy)) }
    var cursorGrabbed: Bool { grabbed }

    private func emit(_ s: String) { onEvent?(s) }
}
