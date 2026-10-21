import Foundation
import CoreGraphics

enum HUDControlKind: String, Codable, CaseIterable, Identifiable {
    case joystick, jump, sneak, sprint, attack, use, inventory, drop, chat, command, pause, perspective, keyboard, hotbar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .joystick: return "Move"
        case .jump: return "Jump"
        case .sneak: return "Sneak"
        case .sprint: return "Sprint"
        case .attack: return "Attack"
        case .use: return "Use"
        case .inventory: return "Inventory"
        case .drop: return "Drop"
        case .chat: return "Chat"
        case .command: return "Command"
        case .pause: return "Pause"
        case .perspective: return "View"
        case .keyboard: return "Keyboard"
        case .hotbar: return "Hotbar"
        }
    }

    var symbol: String {
        switch self {
        case .joystick: return "circle.circle"
        case .jump: return "arrow.up.to.line"
        case .sneak: return "arrow.down.to.line"
        case .sprint: return "hare"
        case .attack: return "hammer"
        case .use: return "hand.point.up.left"
        case .inventory: return "square.grid.3x3"
        case .drop: return "arrow.down.app"
        case .chat: return "bubble.left"
        case .command: return "chevron.left.forwardslash.chevron.right"
        case .pause: return "pause"
        case .perspective: return "eye"
        case .keyboard: return "keyboard"
        case .hotbar: return "rectangle.split.3x1"
        }
    }

    /// Controls that stay visible in menus (cursor released).
    var visibleInMenus: Bool { self == .pause || self == .keyboard }
}

struct HUDControl: Codable, Identifiable, Hashable {
    var kind: HUDControlKind
    /// Center in normalized safe-area coordinates (0...1).
    var x: Double
    var y: Double
    /// Diameter / height in points before the global control scale.
    var size: Double
    var id: String { kind.rawValue }
}

struct HUDPreset: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var controls: [HUDControl]
    var builtin: Bool = false

    func control(_ kind: HUDControlKind) -> HUDControl? { controls.first { $0.kind == kind } }

    static let bedrock = HUDPreset(id: "bedrock", name: "Bedrock Classic", controls: [
        .init(kind: .joystick, x: 0.13, y: 0.72, size: 150),
        .init(kind: .jump, x: 0.90, y: 0.74, size: 64),
        .init(kind: .sneak, x: 0.80, y: 0.86, size: 54),
        .init(kind: .sprint, x: 0.80, y: 0.62, size: 50),
        .init(kind: .attack, x: 0.92, y: 0.50, size: 58),
        .init(kind: .use, x: 0.82, y: 0.40, size: 54),
        .init(kind: .inventory, x: 0.73, y: 0.95, size: 40),
        .init(kind: .drop, x: 0.27, y: 0.95, size: 40),
        .init(kind: .chat, x: 0.58, y: 0.06, size: 40),
        .init(kind: .command, x: 0.66, y: 0.06, size: 40),
        .init(kind: .perspective, x: 0.74, y: 0.06, size: 40),
        .init(kind: .keyboard, x: 0.82, y: 0.06, size: 40),
        .init(kind: .pause, x: 0.50, y: 0.06, size: 40),
        .init(kind: .hotbar, x: 0.50, y: 0.95, size: 40),
    ], builtin: true)

    static let compact = HUDPreset(id: "compact", name: "Compact", controls: bedrock.controls.map { c in
        var c = c
        c.size *= 0.8
        switch c.kind {
        case .joystick: c.x = 0.11; c.y = 0.76
        case .jump: c.x = 0.92; c.y = 0.78
        case .attack: c.x = 0.93; c.y = 0.56
        case .use: c.x = 0.85; c.y = 0.47
        default: break
        }
        return c
    }, builtin: true)

    static let leftHanded = HUDPreset(id: "lefty", name: "Left-Handed", controls: bedrock.controls.map { c in
        var c = c
        if c.kind != .hotbar && c.kind != .pause { c.x = 1 - c.x }
        return c
    }, builtin: true)

    static let builtins = [bedrock, compact, leftHanded]
}

@MainActor
final class HUDStore: ObservableObject {
    @Published var custom: [HUDPreset] { didSet { JSONStore.save(custom, to: "hud-presets.json") } }

    init() {
        custom = JSONStore.load([HUDPreset].self, from: "hud-presets.json") ?? []
    }

    var all: [HUDPreset] { HUDPreset.builtins + custom }

    func preset(_ id: String) -> HUDPreset { all.first { $0.id == id } ?? .bedrock }

    func save(_ preset: HUDPreset) -> HUDPreset {
        var p = preset
        if p.builtin {
            p.id = UUID().uuidString
            p.name = "\(preset.name) (Custom)"
            p.builtin = false
        }
        if let i = custom.firstIndex(where: { $0.id == p.id }) { custom[i] = p } else { custom.append(p) }
        return p
    }

    func delete(_ preset: HUDPreset) { custom.removeAll { $0.id == preset.id } }
}
