import SwiftUI

struct ServersView: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var address = ""
    @State private var statuses: [UUID: Result<ServerStatus, Error>] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $name)
                    TextField("Address (host or host:port)", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Add server") {
                        model.servers.add(name: name, address: address)
                        name = ""; address = ""
                        refreshAll()
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: { Text("Add") } footer: {
                    Text("Saved servers are written to each profile's servers.dat, so they also appear in the game's own Multiplayer screen. LAN worlds can be joined by IP; automatic LAN discovery needs Apple's multicast entitlement, which sideloaded builds normally lack.")
                }

                Section("Servers") {
                    if model.servers.servers.isEmpty { Text("No saved servers.").foregroundStyle(Theme.textSecondary) }
                    ForEach(model.servers.servers) { server in row(server) }
                        .onDelete { idx in idx.map { model.servers.servers[$0] }.forEach { model.servers.remove($0) } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Servers")
            .refreshable { refreshAll() }
            .onAppear(perform: refreshAll)
        }
    }

    private func row(_ server: SavedServer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            favicon(server)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name).font(.subheadline.bold())
                Text(server.address).font(.caption).foregroundStyle(Theme.textSecondary)
                switch statuses[server.id] {
                case .success(let s)?:
                    Text(s.motd).font(.caption).lineLimit(2)
                    Text("\(s.versionName) · \(s.playersOnline)/\(s.playersMax) players · \(s.latencyMs) ms").font(.caption2).foregroundStyle(Theme.accent)
                case .failure(let e)?:
                    Text("Offline: \(e.localizedDescription)").font(.caption2).foregroundStyle(Theme.danger)
                case nil:
                    Text("Pinging…").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Button("Join") {
                guard let profile = model.selectedProfile else { return }
                Task { await model.session.play(profile: profile, model: model, quickPlay: QuickPlayTarget(host: server.host, port: Int(server.port))) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.accounts.active == nil || model.selectedProfile == nil)
        }
    }

    @ViewBuilder private func favicon(_ server: SavedServer) -> some View {
        if case .success(let s)? = statuses[server.id], let data = s.faviconPNG, let img = UIImage(data: data) {
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
                    let s = try await ServerPinger.ping(host: server.host, port: server.port)
                    statuses[server.id] = .success(s)
                } catch {
                    statuses[server.id] = .failure(error)
                }
            }
        }
    }
}
