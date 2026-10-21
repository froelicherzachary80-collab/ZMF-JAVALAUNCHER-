import SwiftUI

/// Drag-and-drop editor for the in-game control layout. Positions are stored
/// normalized to the safe area so layouts survive screen-size differences.
struct HUDEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var preset: HUDPreset
    @State private var selected: HUDControlKind?

    init(preset: HUDPreset) {
        _preset = State(initialValue: preset)
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                    Text("Landscape preview").font(.caption).foregroundStyle(Theme.textSecondary)
                    ForEach($preset.controls) { $control in
                        controlShape(control, canvas: geo.size)
                            .position(x: control.x * geo.size.width, y: control.y * geo.size.height)
                            .gesture(DragGesture().onChanged { v in
                                selected = control.kind
                                control.x = min(max(0.03, v.location.x / geo.size.width), 0.97)
                                control.y = min(max(0.04, v.location.y / geo.size.height), 0.96)
                            })
                            .onTapGesture { selected = control.kind }
                    }
                }
            }
            .aspectRatio(2.17, contentMode: .fit)

            if let kind = selected, let index = preset.controls.firstIndex(where: { $0.kind == kind }) {
                VStack(alignment: .leading) {
                    Text("\(kind.title) size: \(Int(preset.controls[index].size)) pt").font(.subheadline)
                    Slider(value: $preset.controls[index].size, in: kind == .joystick ? 90...220 : 30...100)
                }
                .padding(.horizontal)
            } else {
                Text("Drag controls to move them; tap one to resize.").font(.footnote).foregroundStyle(Theme.textSecondary)
            }

            HStack {
                Button("Reset") {
                    preset.controls = (HUDPreset.builtins.first { $0.id == preset.id } ?? .bedrock).controls
                }
                .buttonStyle(.bordered)
                if !preset.builtin {
                    Button("Delete", role: .destructive) {
                        model.hud.delete(preset)
                        model.settingsStore.settings.activeHUDPreset = HUDPreset.bedrock.id
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button("Save & use") {
                    let saved = model.hud.save(preset)
                    model.settingsStore.settings.activeHUDPreset = saved.id
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            if preset.builtin {
                Text("Built-in presets are saved as a new custom preset.").font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(preset.name)
    }

    private func controlShape(_ c: HUDControl, canvas: CGSize) -> some View {
        // Preview is scaled from a ~850pt-wide landscape screen.
        let scale = canvas.width / 850 * model.settingsStore.settings.controlScale
        let size = c.size * scale
        let isSelected = selected == c.kind
        return Group {
            if c.kind == .hotbar {
                RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.7))
                    .frame(width: min(canvas.width * 0.42, size * 9), height: size)
            } else {
                RoundedRectangle(cornerRadius: c.kind == .joystick ? size / 2 : size * 0.28)
                    .fill(Color.black.opacity(0.45))
                    .overlay(Image(systemName: c.kind.symbol).font(.system(size: size * 0.35)).foregroundStyle(.white))
                    .frame(width: size, height: size)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Theme.accent : .clear, lineWidth: 2))
        .opacity(model.settingsStore.settings.controlOpacity * 0.6 + 0.4)
    }
}
