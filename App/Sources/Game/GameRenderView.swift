import UIKit
import QuartzCore

/// The surface Minecraft draws into. EAGL renderers need a CAEAGLLayer;
/// EGL (ANGLE / MetalANGLE) renderers need a CAMetalLayer.
final class EAGLRenderView: UIView {
    override class var layerClass: AnyClass { CAEAGLLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let eagl = layer as! CAEAGLLayer
        eagl.isOpaque = true
        eagl.drawableProperties = [
            kEAGLDrawablePropertyRetainedBacking: false,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8,
        ]
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class MetalRenderView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.isOpaque = true
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Hidden first responder that brings up the software keyboard for chat and
/// command input and forwards typed text as GLFW character events.
final class KeyInputView: UIView, UIKeyInput {
    weak var sink: InputSink?

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .send

    func insertText(_ text: String) {
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                sink?.tapKey(GLFWKey.enter)
            } else {
                sink?.char(scalar.value)
            }
        }
    }

    func deleteBackward() { sink?.tapKey(GLFWKey.backspace) }
}

/// UIKeyboardHIDUsage → GLFW key code for hardware keyboards.
enum HardwareKeyMap {
    static func glfwKey(_ usage: UIKeyboardHIDUsage) -> Int? {
        let u = usage.rawValue
        switch u {
        case 0x04...0x1D: return 65 + (u - 0x04)          // A–Z
        case 0x1E...0x26: return 49 + (u - 0x1E)          // 1–9
        case 0x27: return 48                               // 0
        case 0x28: return GLFWKey.enter
        case 0x29: return GLFWKey.escape
        case 0x2A: return GLFWKey.backspace
        case 0x2B: return GLFWKey.tab
        case 0x2C: return GLFWKey.space
        case 0x2D: return 45
        case 0x2E: return 61
        case 0x2F: return 91
        case 0x30: return 93
        case 0x31: return 92
        case 0x33: return 59
        case 0x34: return 39
        case 0x35: return 96
        case 0x36: return 44
        case 0x37: return 46
        case 0x38: return 47
        case 0x3A...0x45: return 290 + (u - 0x3A)          // F1–F12
        case 0x4F: return GLFWKey.right
        case 0x50: return GLFWKey.left
        case 0x51: return GLFWKey.down
        case 0x52: return GLFWKey.up
        case 0xE0: return 341
        case 0xE1: return 340
        case 0xE2: return 342
        case 0xE3: return 343
        case 0xE4: return 345
        case 0xE5: return 344
        case 0xE6: return 346
        case 0xE7: return 347
        default: return nil
        }
    }
}
