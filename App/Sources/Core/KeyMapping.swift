import Foundation

/// GLFW key codes (glfw3.h) used to synthesize Java Edition keyboard input.
enum GLFWKey {
    static let space = 32, apostrophe = 39, comma = 44, minus = 45, period = 46, slash = 47
    static let num0 = 48, num1 = 49, num9 = 57
    static let semicolon = 59, equal = 61
    static let a = 65, d = 68, e = 69, f = 70, q = 81, s = 83, t = 84, w = 87, z = 90
    static let escape = 256, enter = 257, tab = 258, backspace = 259
    static let right = 262, left = 263, down = 264, up = 265
    static let f1 = 290, f2 = 291, f3 = 292, f5 = 294, f11 = 300
    static let leftShift = 340, leftControl = 341, leftAlt = 342

    static func forCharacter(_ ch: Character) -> Int? {
        guard let ascii = ch.uppercased().unicodeScalars.first?.value, ch.unicodeScalars.count == 1 else { return nil }
        switch ascii {
        case 65...90, 48...57: return Int(ascii)
        case 32: return space
        case 47: return slash
        case 45: return minus
        case 46: return period
        case 44: return comma
        default: return nil
        }
    }

    static func name(_ code: Int) -> String {
        switch code {
        case space: return "Space"
        case escape: return "Esc"
        case enter: return "Enter"
        case tab: return "Tab"
        case backspace: return "Backspace"
        case leftShift: return "Left Shift"
        case leftControl: return "Left Ctrl"
        case leftAlt: return "Left Alt"
        case f1...f11: return "F\(code - f1 + 1)"
        case 65...90, 48...57: return String(UnicodeScalar(UInt8(code)))
        case slash: return "/"
        default: return "Key \(code)"
        }
    }

    static let selectable: [Int] = [space, leftShift, leftControl, leftAlt, tab, enter, escape, slash]
        + Array(65...90) + Array(48...57) + Array(f1...f11)
}

/// Mobile actions and the Java key they produce. Defaults match Minecraft's
/// default key bindings so nothing needs remapping in-game.
enum KeyMapping: String, CaseIterable, Identifiable {
    case forward, back, left, right, jump, sneak, sprint, inventory, drop, chat, command, pause, perspective, debug, swapHands, playerList

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forward: return "Walk Forward"
        case .back: return "Walk Backward"
        case .left: return "Strafe Left"
        case .right: return "Strafe Right"
        case .jump: return "Jump"
        case .sneak: return "Sneak"
        case .sprint: return "Sprint"
        case .inventory: return "Inventory"
        case .drop: return "Drop Item"
        case .chat: return "Open Chat"
        case .command: return "Open Command"
        case .pause: return "Pause / Back"
        case .perspective: return "Toggle Perspective"
        case .debug: return "Debug Screen"
        case .swapHands: return "Swap Hands"
        case .playerList: return "Player List"
        }
    }

    static let defaults: [String: Int] = [
        forward.rawValue: GLFWKey.w, back.rawValue: GLFWKey.s, left.rawValue: GLFWKey.a, right.rawValue: GLFWKey.d,
        jump.rawValue: GLFWKey.space, sneak.rawValue: GLFWKey.leftShift, sprint.rawValue: GLFWKey.leftControl,
        inventory.rawValue: GLFWKey.e, drop.rawValue: GLFWKey.q, chat.rawValue: GLFWKey.t, command.rawValue: GLFWKey.slash,
        pause.rawValue: GLFWKey.escape, perspective.rawValue: GLFWKey.f5, debug.rawValue: GLFWKey.f3,
        swapHands.rawValue: GLFWKey.f, playerList.rawValue: GLFWKey.tab,
    ]
}
