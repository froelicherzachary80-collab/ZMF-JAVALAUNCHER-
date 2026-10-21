import SwiftUI
import UniformTypeIdentifiers

struct ModsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var mods = ModManager()
    @State private var profileID: UUID?
    @State private var importingMods = false
    @State private var importingPack = false
    @State private var importerShown = false
    @State private var packStatus: String?
    @State private var exportURL: URL?
    @State private var error: String?

    private var jarType: UTType { UTType(filenameExtension: "jar") ?? .zip }
    private var mrpackType: UTType { UTType(filenameExtension: "mrpack") ?? .zip }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Profile", selection: $profileID) {
                        ForEach(model.profiles.profiles) { p in Text("\(p.name) (\(p.loader.title))").tag(UUID?.some(p.id)) }
                    }
                    if let p = mods.profile {
                        LabeledContent("Loader", value: "\(p.loader.title) \(p.loaderVersion ?? "")")
                        LabeledContent("Folder", value: "instances/\(p.gameDirectoryName)/mods")
                    }
                } footer: {
                    Text("Fabric is the fully supported loader in v0.1. Mods are copied into the profile's mods folder, which is what the loader scans at game start.")
                }

                if !mods.issues.isEmpty {
                    Section("Compatibility") {
                        ForEach(mods.issues) { issue in
                            Label {
                                VStack(alignment: .leading) {
                                    Text(issue.message).font(.footnote)
                                    if let f = issue.modFile { Text(f).font(.caption2).foregroundStyle(Theme.textSecondary) }
                                }
                            } icon: {
                                Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(issue.severity == .error ? Theme.danger : Theme.warning)
                            }
                        }
                    }
                }

                Section("Installed mods (\(mods.mods.count))") {
                    if mods.mods.isEmpty { Text("No mods yet. Import .jar files from the Files app.").foregroundStyle(Theme.textSecondary) }
                    ForEach(mods.mods) { mod in
                        Toggle(isOn: Binding(get: { mod.enabled }, set: { mods.setEnabled(mod, $0) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mod.displayName).font(.subheadline.bold())
                                Text([mod.metadata?.id, mod.metadata?.version, mod.metadata?.loader.title].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                                Text(mod.id).font(.caption2).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .swipeActions { Button(role: .destructive) { mods.delete(mod) } label: { Label("Delete", systemImage: "trash") } }
                    }
                }

                Section("Manage") {
                    Button { importingPack = false; importingMods = true; importerShown = true } label: { Label("Import mods (.jar)", systemImage: "square.and.arrow.down") }
                        .disabled(mods.profile == nil)
                    Button { importingMods = false; importingPack = true; importerShown = true } label: { Label("Import Modrinth modpack (.mrpack)", systemImage: "shippingbox") }
                    if let packStatus { Text(packStatus).font(.caption).foregroundStyle(Theme.textSecondary) }
                    Button {
                        do { exportURL = try mods.exportProfile() } catch { self.error = error.localizedDescription }
                    } label: { Label("Export profile configuration", systemImage: "square.and.arrow.up") }
                        .disabled(mods.profile == nil)
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Share \(exportURL.lastPathComponent)", systemImage: "paperplane") }
                    }
                    if let p = mods.profile {
                        NavigationLink { CrashReportsView(profile: p) } label: { Label("Crash reports & logs", systemImage: "doc.text.magnifyingglass") }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Mods")
            .refreshable { mods.reload() }
            // One importer for both kinds: SwiftUI honours only one .fileImporter per view.
            .fileImporter(isPresented: $importerShown,
                          allowedContentTypes: importingPack ? [mrpackType, .zip] : [jarType],
                          allowsMultipleSelection: !importingPack) { result in
                guard case .success(let urls) = result else { return }
                if importingPack, let url = urls.first {
                    importPack(url)
                } else {
                    mods.importMods(urls)
                }
            }
            .alert(error ?? mods.lastError ?? "", isPresented: Binding(get: { error != nil || mods.lastError != nil },
                                                                     set: { if !$0 { error = nil; mods.lastError = nil } })) { Button("OK") {} }
            .onAppear {
                if profileID == nil { profileID = model.selectedProfile?.id }
                if let p = model.profiles.profile(profileID) { mods.load(p) }
            }
            .onChange(of: profileID) { _, id in if let p = model.profiles.profile(id) { mods.load(p) } }
        }
    }
}

extension ModsView {
    private func importPack(_ url: URL) {
        Task {
            do {
                let p = try await ModpackImporter.importPack(url, installer: model.installer, profiles: model.profiles) { packStatus = $0 }
                packStatus = "Imported \(p.name)"
                profileID = p.id
            } catch {
                packStatus = nil
                self.error = error.localizedDescription
            }
        }
    }
}

struct CrashReportsView: View {
    let profile: GameProfile
    @State private var files: [URL] = []

    var body: some View {
        List {
            if files.isEmpty { Text("No crash reports or logs yet.").foregroundStyle(Theme.textSecondary) }
            ForEach(files, id: \.self) { url in
                NavigationLink { LogFileView(url: url) } label: {
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent).font(.subheadline)
                        Text(url.deletingLastPathComponent().lastPathComponent).font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .navigationTitle("Crash Reports")
        .onAppear(perform: load)
    }

    private func load() {
        let fm = FileManager.default
        var urls: [URL] = []
        for dir in [profile.gameDirectory.appendingPathComponent("crash-reports"), profile.gameDirectory.appendingPathComponent("logs"), Paths.logs] {
            urls += (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        files = urls.filter { ["txt", "log"].contains($0.pathExtension) }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }
}

struct LogFileView: View {
    let url: URL
    @State private var text = ""

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text).font(.system(.caption2, design: .monospaced)).textSelection(.enabled).padding()
        }
        .navigationTitle(url.lastPathComponent)
        .toolbar { ShareLink(item: url) }
        .task {
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? "Unreadable file"
            text = content.count > 300_000 ? "…" + String(content.suffix(300_000)) : content
        }
    }
}
