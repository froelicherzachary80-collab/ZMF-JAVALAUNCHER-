import SwiftUI

struct ProfileEditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var profile: GameProfile
    @State private var loaderVersions: [LoaderInstaller.LoaderVersion] = []
    @State private var loadingLoaders = false
    @State private var saving = false
    @State private var error: String?
    @State private var useMemoryOverride = false

    init(profile: GameProfile) {
        _profile = State(initialValue: profile)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $profile.name)
                    Picker("Minecraft version", selection: $profile.minecraftVersion) {
                        ForEach(versionChoices, id: \.self) { Text($0).tag($0) }
                    }
                    LabeledContent("Game folder", value: "instances/\(profile.gameDirectoryName)")
                }

                Section {
                    Picker("Mod loader", selection: $profile.loader) {
                        ForEach(ModLoader.allCases) { l in Text(l.title + (l.installable ? "" : " (planned)")).tag(l) }
                    }
                    if profile.loader == .fabric || profile.loader == .quilt {
                        if loadingLoaders {
                            HStack { ProgressView(); Text("Loading \(profile.loader.title) versions…") }
                        } else {
                            Picker("Loader version", selection: Binding(get: { profile.loaderVersion ?? "" }, set: { profile.loaderVersion = $0 })) {
                                ForEach(loaderVersions) { v in Text(v.version + (v.stable ? "" : " (beta)")).tag(v.version) }
                            }
                        }
                    }
                } header: { Text("Loader") } footer: { Text(profile.loader.statusNote) }

                Section("Runtime") {
                    Picker("Java runtime", selection: $profile.runtimeOverride) {
                        Text("Automatic").tag(String?.none)
                        ForEach(model.catalog.runtimes) { r in Text(r.displayName).tag(String?.some(r.id)) }
                    }
                    Picker("Renderer", selection: $profile.rendererOverride) {
                        Text("Automatic").tag(String?.none)
                        ForEach(model.catalog.renderers) { r in Text(r.displayName).tag(String?.some(r.id)) }
                    }
                    Toggle("Custom memory", isOn: $useMemoryOverride)
                    if useMemoryOverride {
                        Stepper("Memory: \(profile.memoryOverrideMB ?? model.settingsStore.settings.memoryMB) MB",
                                value: Binding(get: { profile.memoryOverrideMB ?? model.settingsStore.settings.memoryMB },
                                               set: { profile.memoryOverrideMB = $0 }),
                                in: LauncherSettings.memoryRange, step: 256)
                    }
                    TextField("Extra JVM arguments", text: $profile.extraJVMArguments)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }

                if let error {
                    Section { Text(error).foregroundStyle(Theme.danger).font(.footnote) }
                }
            }
            .navigationTitle(profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save") { Task { await save() } }.disabled(!profile.loader.installable) }
                }
            }
            .task(id: "\(profile.loader.rawValue)-\(profile.minecraftVersion)") { await loadLoaderVersions() }
            .onAppear { useMemoryOverride = profile.memoryOverrideMB != nil }
            .onChange(of: useMemoryOverride) { _, on in if !on { profile.memoryOverrideMB = nil } }
        }
    }

    private var versionChoices: [String] {
        var ids = model.installer.manifest?.versions.filter { $0.isRelease || $0.isSnapshot }.map(\.id) ?? []
        for id in model.installer.installed where !ids.contains(id) && !id.contains("-loader-") { ids.insert(id, at: 0) }
        if !ids.contains(profile.minecraftVersion) && !profile.minecraftVersion.isEmpty { ids.insert(profile.minecraftVersion, at: 0) }
        return ids
    }

    private func loadLoaderVersions() async {
        guard profile.loader == .fabric || profile.loader == .quilt else { loaderVersions = []; return }
        loadingLoaders = true
        defer { loadingLoaders = false }
        do {
            loaderVersions = try await LoaderInstaller.availableVersions(profile.loader, minecraft: profile.minecraftVersion)
            if profile.loaderVersion == nil || !loaderVersions.contains(where: { $0.version == profile.loaderVersion }) {
                profile.loaderVersion = loaderVersions.first(where: \.stable)?.version ?? loaderVersions.first?.version
            }
            if loaderVersions.isEmpty { error = "\(profile.loader.title) does not support Minecraft \(profile.minecraftVersion) yet." }
        } catch {
            self.error = "Could not load loader versions: \(error.localizedDescription)"
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            switch profile.loader {
            case .vanilla:
                profile.launchVersionID = profile.minecraftVersion
                profile.loaderVersion = nil
            case .fabric, .quilt:
                guard let lv = profile.loaderVersion else { error = "Choose a loader version."; return }
                profile.launchVersionID = try await LoaderInstaller.installProfile(profile.loader, minecraft: profile.minecraftVersion, loaderVersion: lv)
                model.installer.refreshInstalled()
            case .forge, .neoforge:
                error = profile.loader.statusNote
                return
            }
            model.profiles.upsert(profile)
            if model.settingsStore.settings.selectedProfileID == nil { model.settingsStore.settings.selectedProfileID = profile.id }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
