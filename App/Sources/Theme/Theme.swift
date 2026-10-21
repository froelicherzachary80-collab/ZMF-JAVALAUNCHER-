import SwiftUI

/// ZMF's own dark visual identity: graphite surfaces, an emerald accent and
/// an amber warning tone. No Mojang branding or assets are used.
enum Theme {
    static let background = Color(red: 0.055, green: 0.063, blue: 0.075)
    static let surface = Color(red: 0.10, green: 0.11, blue: 0.13)
    static let surfaceRaised = Color(red: 0.14, green: 0.155, blue: 0.18)
    static let accent = Color(red: 0.33, green: 0.85, blue: 0.47)
    static let accentDeep = Color(red: 0.12, green: 0.55, blue: 0.30)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.25)
    static let danger = Color(red: 0.95, green: 0.36, blue: 0.36)
    static let textSecondary = Color.white.opacity(0.62)

    static let heroGradient = LinearGradient(colors: [accentDeep.opacity(0.85), Color(red: 0.06, green: 0.20, blue: 0.16), background],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06)))
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color
    var symbol: String?
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.18), in: Capsule())
        .foregroundStyle(color)
    }
}

extension CompatibilityStatus {
    var color: Color {
        switch self {
        case .componentsReady: return Theme.accent
        case .missingComponents: return Theme.warning
        case .unsupported: return Theme.danger
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(Color.black)
    }
}
