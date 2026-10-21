import SwiftUI

struct InstallationsView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: GameProfile?
    @State private var verifyReport: (String, InstallationManager.VerifyReport)?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.profiles.recent) { profile in
                        profileRow(profile)
                    }
                    Button {
                        editing = GameProfile.make(name: "New Profile", version: model.installer.manifest?.latest.release ?? model.installer.installed.last ?? "")
                    } label: { Label("New profile", systemImage: "plus.circle.fill") }
                } header: { Text("Profiles") } footer: {
                    Text("Each profile has its own game folder (mods, worlds, options) under ZMF/instances in the Files app.")
                }

                Section("Installed versions") {
                    if model.installer.installed.isEmpty {
                        Text("Nothing installed yet.").foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(model.installer.installed, id: \.self) { id in installedRow(id) }
                }

                Section {
                    NavigationLink { VersionBrowserView() } label: { Label("Browse Minecraft versions", systemImage: "list.bullet.rectangle") }
                    Button {
                        Task {
                            let freed = await model.installer.collectGarbage()
                            message = "Removed unused files: \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))"
                        }
                    } label: { Label("Clean unused libraries & assets", systemImage: "trash.slash") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Installations")
            .sheet(item: $editing) { ProfileEditorView(profile: $0) }
            .alert("Verification", isPresented: Binding(get: { verifyReport != nil }, set: { if !$0 { verifyReport = nil } })) {
                if let v = verifyReport, !v.1.isHealthy {
                    Button("Repair") { Task { try? await model.installer.repair(v.0) } }
                }
                Button("OK", role: .cancel) {}
            } message: {
                if let r = verifyReport?.1 {
                    Text(r.isHealthy ? "All \(r.checked) files verified (SHA-1)." :
                            "\(r.checked) checked · \(r.missing.count) missing · \(r.corrupt.count) corrupt.\n\((r.missing + r.corrupt).prefix(5).joined(separator: "\n"))")
                }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") {} }
        }
    }

    private func profileRow(_ profile: GameProfile) -> some View {
        let status = model.compatibility(for: profile.launchVersionID)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(profile.name).font(.headline)
                    if profile.id == model.selectedProfile?.id { Image(systemName: "star.fill").foregroundStyle(Theme.accent).font(.caption) }
                }
                Text("\(profile.loader.title)\(profile.loaderVersion.map { " \($0)" } ?? "") · \(profile.minecraftVersion)")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                StatusBadge(text: status.label, color: status.color, symbol: status.symbol)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { model.settingsStore.settings.selectedProfileID = profile.id }
        .swipeActions {
            Button(role: .destructive) { model.profiles.delete(profile, removeFiles: false) } label: { Label("Remove", systemImage: "trash") }
            Button { editing = profile } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
        }
        .contextMenu {
            Button { editing = profile } label: { Label("Edit", systemImage: "pencil") }
            Button { model.settingsStore.settings.selectedProfileID = profile.id } label: { Label("Select", systemImage: "star") }
            Button(role: .destructive) { model.profiles.delete(profile, removeFiles: true) } label: { Label("Delete with game folder", systemImage: "trash") }
        }
    }

    private func installedRow(_ id: String) -> some View {
        let status = model.compatibility(for: id)
        let req = model.requirements(for: id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(id).font(.subheadline.bold())
                Spacer()
                StatusBadge(text: status.label, color: status.color, symbol: status.symbol)
            }
            Text("Java \(req.javaMajor) · OpenGL \(String(format: "%.1f", req.desktopGL))\(req.lwjglVersion.map { " · LWJGL \($0)" } ?? "")")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            if let job = model.installer.tasks[id] {
                ProgressView(value: job.progress) { Text("\(job.phase) \(job.detail)").font(.caption2) }
            } else {
                HStack {
                    Button("Verify") {
                        Task {
                            let report = await model.installer.verify(id)
                            verifyReport = (id, report)
                        }
                    }
                    Button("Repair") { Task { do { try await model.installer.repair(id) } catch { message = error.localizedDescription } } }
                    Spacer()
                    Button("Delete", role: .destructive) { model.installer.delete(id) }
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
            if case .missingComponents(let reasons) = status {
                ForEach(reasons, id: \.self) { Text("• \($0)").font(.caption2).foregroundStyle(Theme.warning) }
            }
        }
    }
}

struct VersionBrowserView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter = "release"
    @State private var search = ""
    @State private var error: String?

    var body: some View {
        List {
            Picker("Type", selection: $filter) {
                Text("Releases").tag("release")
                Text("Snapshots").tag("snapshot")
                Text("Old").tag("old")
            }
            .pickerStyle(.segmented)
            if model.installer.manifest == nil {
                HStack { ProgressView(); Text("Loading version list from Mojang…") }
            }
            ForEach(versions) { entry in
                let status = Compatibility.evaluate(VersionRequirements.estimate(releaseDate: entry.releaseDate), catalog: model.catalog)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.id).font(.subheadline.bold())
                        if let d = entry.releaseDate { Text(d, style: .date).font(.caption2).foregroundStyle(Theme.textSecondary) }
                        StatusBadge(text: status.label, color: status.color, symbol: status.symbol)
                    }
                    Spacer()
                    if let job = model.installer.tasks[entry.id] {
                        ProgressView(value: job.progress).frame(width: 80)
                    } else if model.installer.isInstalled(entry.id) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    } else {
                        Button("Install") {
                            Task { do { try await model.installer.install(entry.id) } catch { self.error = error.localizedDescription } }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(status.isUnsupported)
                    }
                }
            }
        }
        .searchable(text: $search)
        .refreshable { await model.installer.refreshManifest() }
        .navigationTitle("Versions")
        .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} }
    }

    private var versions: [VersionManifest.Entry] {
        let all = model.installer.manifest?.versions ?? []
        return all.filter { e in
            let typeOK = filter == "old" ? (e.type == "old_beta" || e.type == "old_alpha") : e.type == filter
            return typeOK && (search.isEmpty || e.id.localizedCaseInsensitiveContains(search))
        }
    }
}

extension CompatibilityStatus {
    var isUnsupported: Bool { if case .unsupported = self { return true } else { return false } }
}
