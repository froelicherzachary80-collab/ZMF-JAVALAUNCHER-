import Foundation
import Network

/// Java Edition Server List Ping (handshake → status request → ping), the
/// same exchange the in-game multiplayer screen performs.
struct ServerStatus {
    var versionName: String
    var protocolVersion: Int
    var playersOnline: Int
    var playersMax: Int
    var motd: String
    var faviconPNG: Data?
    var latencyMs: Int
}

enum ServerPingError: LocalizedError {
    case timeout, closed, malformed(String)
    var errorDescription: String? {
        switch self {
        case .timeout: return "Timed out"
        case .closed: return "Connection closed"
        case .malformed(let m): return "Unexpected response: \(m)"
        }
    }
}

enum MinecraftProtocol {
    static func varInt(_ value: Int32) -> Data {
        var v = UInt32(bitPattern: value)
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    /// Returns (value, bytes consumed) or nil if more data is needed.
    static func readVarInt(_ data: Data, at offset: Int) throws -> (Int32, Int)? {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        var i = offset
        while i < data.count {
            let byte = data[data.startIndex + i]
            result |= UInt32(byte & 0x7F) << shift
            i += 1
            if byte & 0x80 == 0 { return (Int32(bitPattern: result), i - offset) }
            shift += 7
            if shift >= 35 { throw ServerPingError.malformed("VarInt too long") }
        }
        return nil
    }

    static func string(_ s: String) -> Data {
        let utf8 = Data(s.utf8)
        return varInt(Int32(utf8.count)) + utf8
    }

    static func packet(id: Int32, _ payload: Data) -> Data {
        let body = varInt(id) + payload
        return varInt(Int32(body.count)) + body
    }

    static func handshake(host: String, port: UInt16, protocolVersion: Int32 = -1, nextState: Int32 = 1) -> Data {
        var p = varInt(protocolVersion)
        p += string(host)
        p += Data([UInt8(port >> 8), UInt8(port & 0xFF)])
        p += varInt(nextState)
        return packet(id: 0x00, p)
    }

    /// Flattens a chat component (string or JSON object) to plain text.
    static func flattenChat(_ value: Any?) -> String {
        if let s = value as? String { return s.replacingOccurrences(of: "§[0-9a-fk-or]", with: "", options: .regularExpression) }
        if let arr = value as? [Any] { return arr.map(flattenChat).joined() }
        guard let obj = value as? [String: Any] else { return "" }
        var out = flattenChat(obj["text"])
        if let extra = obj["extra"] as? [Any] { out += extra.map(flattenChat).joined() }
        return out
    }

    static func parseStatus(_ json: Data, latency: Int) throws -> ServerStatus {
        guard let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw ServerPingError.malformed("status JSON") }
        let version = obj["version"] as? [String: Any]
        let players = obj["players"] as? [String: Any]
        var favicon: Data?
        if let fav = obj["favicon"] as? String, let comma = fav.firstIndex(of: ",") {
            favicon = Data(base64Encoded: String(fav[fav.index(after: comma)...]), options: .ignoreUnknownCharacters)
        }
        return ServerStatus(versionName: version?["name"] as? String ?? "?",
                            protocolVersion: version?["protocol"] as? Int ?? -1,
                            playersOnline: players?["online"] as? Int ?? 0,
                            playersMax: players?["max"] as? Int ?? 0,
                            motd: flattenChat(obj["description"]),
                            faviconPNG: favicon, latencyMs: latency)
    }
}

/// Guards a continuation against double resumption from repeated callbacks.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

final class ServerPinger {
    static func ping(host: String, port: UInt16, timeout: TimeInterval = 6) async throws -> ServerStatus {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { conn.cancel() }
        let queue = DispatchQueue(label: "dev.zmf.ping")

        try await withTimeout(timeout) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let once = ResumeOnce()
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if once.claim() { c.resume() }
                    case .failed(let e), .waiting(let e): if once.claim() { c.resume(throwing: e) }
                    case .cancelled: if once.claim() { c.resume(throwing: ServerPingError.closed) }
                    default: break
                    }
                }
                conn.start(queue: queue)
            }
        }

        let start = Date()
        try await send(conn, MinecraftProtocol.handshake(host: host, port: port) + MinecraftProtocol.packet(id: 0x00, Data()))
        let json: Data = try await withTimeout(timeout) {
            var buffer = Data()
            while true {
                if let (length, n) = try MinecraftProtocol.readVarInt(buffer, at: 0), buffer.count >= n + Int(length) {
                    let packet = buffer.subdata(in: (buffer.startIndex + n)..<(buffer.startIndex + n + Int(length)))
                    guard let (pid, pn) = try MinecraftProtocol.readVarInt(packet, at: 0), pid == 0,
                          let (slen, sn) = try MinecraftProtocol.readVarInt(packet, at: pn) else {
                        throw ServerPingError.malformed("status packet")
                    }
                    let s = pn + sn
                    guard packet.count >= s + Int(slen) else { throw ServerPingError.malformed("short status") }
                    return packet.subdata(in: (packet.startIndex + s)..<(packet.startIndex + s + Int(slen)))
                }
                buffer += try await receive(conn)
            }
        }
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        return try MinecraftProtocol.parseStatus(json, latency: latency)
    }

    private static func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    private static func receive(_ conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let error { c.resume(throwing: error) }
                else if let data, !data.isEmpty { c.resume(returning: data) }
                else if complete { c.resume(throwing: ServerPingError.closed) }
                else { c.resume(returning: Data()) }
            }
        }
    }

    private static func withTimeout<T>(_ seconds: TimeInterval, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                throw ServerPingError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
