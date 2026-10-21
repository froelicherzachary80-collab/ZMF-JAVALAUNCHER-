import SwiftUI

struct MultiplayerView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("Servers").tag(0)
                    Text("Voice").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)
                if tab == 0 { ServersView() } else { VoiceView(voice: model.voice) }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Multiplayer")
        }
    }
}

struct ServersView: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var address = ""
    @State private var statuses: [UUID: Result<ServerStatus, Error>] = [:]
    @State private var message: String?

    var body: some View {
        List {
            Section {
                TextField("Name", text: $name)
                TextField("Address (e.g. play.example.net)", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Add server") {
                    model.servers.add(name: name, address: address)
                    name = ""; address = ""
                    refreshAll()
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: { Text("Add a Java Edition server") } footer: {
                Text("Any normal Java server works (Paper, Spigot, Fabric, vanilla …). Online-mode servers verify your Microsoft account just like on PC. Saved servers also appear in the game's own Multiplayer screen.")
            }

            Section("Servers") {
                if model.servers.servers.isEmpty { Text("No saved servers.").foregroundStyle(Theme.textSecondary) }
                ForEach(model.servers.servers) { server in row(server) }
                    .onDelete { idx in idx.map { model.servers.servers[$0] }.forEach { model.servers.remove($0) } }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { refreshAll() }
        .onAppear(perform: refreshAll)
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK") {} }
    }

    private func row(_ server: SavedServer) -> some View {
        let status: ServerStatus? = { if case .success(let s)? = statuses[server.id] { return s } else { return nil } }()
        let needed = status.flatMap { ServerVersionMatcher.bestRelease(for: $0.versionName, manifest: model.installer.manifest) }
        let profile = profileFor(version: needed)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                favicon(status)
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.name).font(.subheadline.bold())
                    Text(server.address).font(.caption).foregroundStyle(Theme.textSecondary)
                    switch statuses[server.id] {
                    case .success(let s)?:
                        Text(s.motd).font(.caption).lineLimit(2)
                        Text("\(s.versionName) · \(s.playersOnline)/\(s.playersMax) online · \(s.latencyMs) ms").font(.caption2).foregroundStyle(Theme.accent)
                    case .failure(let e)?:
                        Text("Offline: \(e.localizedDescription)").font(.caption2).foregroundStyle(Theme.danger)
                    case nil:
                        Text("Pinging…").font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Button("Join") { join(server, profile: profile ?? model.selectedProfile) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.accounts.active == nil || (profile ?? model.selectedProfile) == nil)
            }
            if let needed {
                if let profile {
                    Text("Joins with “\(profile.name)” (\(profile.minecraftVersion))").font(.caption2).foregroundStyle(Theme.textSecondary)
                } else {
                    HStack {
                        Text("Server runs \(needed); no profile for it yet.").font(.caption2).foregroundStyle(Theme.warning)
                        Spacer()
                        Button("Create \(needed) profile") { createProfile(needed) }.font(.caption).buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    /// Prefer the selected profile when it matches, else any profile on that version.
    private func profileFor(version: String?) -> GameProfile? {
        guard let version else { return nil }
        if let sel = model.selectedProfile, sel.minecraftVersion == version { return sel }
        return model.profiles.recent.first { $0.minecraftVersion == version }
    }

    private func createProfile(_ version: String) {
        let p = GameProfile.make(name: "Minecraft \(version)", version: version)
        model.profiles.upsert(p)
        message = "Created profile “\(p.name)”. Join will install it automatically."
    }

    private func join(_ server: SavedServer, profile: GameProfile?) {
        guard let profile else { return }
        // Pass the address as typed: the game follows SRV records itself, and every
        // ZMF player then reports the same server key to ZMF Voice.
        Task { await model.session.play(profile: profile, model: model, quickPlay: QuickPlayTarget(host: server.host, port: Int(server.port))) }
    }

    @ViewBuilder private func favicon(_ status: ServerStatus?) -> some View {
        if let data = status?.faviconPNG, let img = UIImage(data: data) {
            Image(uiImage: img).interpolation(.none).resizable().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Theme.surfaceRaised).frame(width: 40, height: 40)
                .overlay(Image(systemName: "server.rack").foregroundStyle(Theme.textSecondary))
        }
    }

    private func refreshAll() {
        for server in model.servers.servers {
            Task {
                do {
                    statuses[server.id] = .success(try await ServerPinger.ping(server))
                } catch {
                    statuses[server.id] = .failure(error)
                }
            }
        }
    }
}
