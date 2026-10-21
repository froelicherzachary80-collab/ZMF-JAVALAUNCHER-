import Foundation

struct SavedServer: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var address: String // host[:port]

    var host: String {
        if address.hasPrefix("[") , let end = address.firstIndex(of: "]") { return String(address[address.index(after: address.startIndex)..<end]) }
        let parts = address.split(separator: ":")
        return parts.count == 2 ? String(parts[0]) : address
    }

    var port: UInt16 {
        if let colon = address.lastIndex(of: ":"), address.split(separator: ":").count == 2 || address.hasPrefix("["),
           let p = UInt16(address[address.index(after: colon)...]) { return p }
        return 25565
    }
}

/// Launcher-side server list, mirrored into every profile's servers.dat so the
/// same servers appear in the game's own Multiplayer screen.
@MainActor
final class ServerStore: ObservableObject {
    @Published var servers: [SavedServer] { didSet { JSONStore.save(servers, to: "servers.json") } }

    init() {
        servers = JSONStore.load([SavedServer].self, from: "servers.json") ?? []
    }

    func add(name: String, address: String) {
        servers.append(SavedServer(name: name.isEmpty ? address : name, address: address.trimmingCharacters(in: .whitespaces)))
    }

    func remove(_ s: SavedServer) { servers.removeAll { $0.id == s.id } }

    nonisolated static func serversDat(_ servers: [SavedServer]) -> Data {
        NBT.encodeRoot([
            ("servers", .list(servers.map { .compound([("name", .string($0.name)), ("ip", .string($0.address))]) })),
        ])
    }

    /// Writes servers.dat into a game directory. The launcher list is
    /// authoritative: servers added only in-game are replaced on next launch.
    func sync(to gameDirectory: URL) {
        guard !servers.isEmpty else { return }
        try? FileManager.default.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
        try? Self.serversDat(servers).write(to: gameDirectory.appendingPathComponent("servers.dat"), options: .atomic)
    }
}
