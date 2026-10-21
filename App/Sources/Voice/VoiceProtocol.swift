import Foundation

/// ZMF Voice protocol v1 (see voice-relay/src/protocol.js).
enum VoiceProtocol {
    static let version = 1
    static let audioType: UInt8 = 0x01
    static let flagWhisper: UInt8 = 0x01

    /// client → relay: [0x01][flags][seq u16 BE][opus]
    static func clientAudio(seq: UInt16, whisper: Bool, payload: Data) -> Data {
        var d = Data(capacity: 4 + payload.count)
        d.append(audioType)
        d.append(whisper ? flagWhisper : 0)
        d.append(UInt8(seq >> 8))
        d.append(UInt8(seq & 0xFF))
        d.append(payload)
        return d
    }

    struct RelayAudio: Equatable {
        let speaker: UInt16
        let seq: UInt16
        let whisper: Bool
        let payload: Data
    }

    /// relay → client: [0x01][flags][seq u16 BE][speaker u16 BE][opus]
    static func parseRelayAudio(_ d: Data) -> RelayAudio? {
        guard d.count >= 7 else { return nil }
        let b = [UInt8](d.prefix(6))
        guard b[0] == audioType else { return nil }
        return RelayAudio(speaker: UInt16(b[4]) << 8 | UInt16(b[5]),
                          seq: UInt16(b[2]) << 8 | UInt16(b[3]),
                          whisper: b[1] & flagWhisper != 0,
                          payload: d.subdata(in: (d.startIndex + 6)..<d.endIndex))
    }
}

struct VoiceRoom: Identifiable, Hashable, Decodable {
    struct Member: Hashable, Decodable { let id: Int; let name: String }
    let id: String
    let name: String
    let `public`: Bool
    let hasPassword: Bool
    let type: String
    let members: [Member]

    var isIsolated: Bool { type == "isolated" }
}

struct VoicePeer: Identifiable, Hashable, Decodable {
    let id: Int
    let name: String
    let uuid: String
    let pos: [Double]?
    let yaw: Double?
    let sameRoom: Bool
    let talking: Bool
}

/// Where the local player is, as reported by the game.
struct VoiceWorldState: Equatable {
    var world: String?
    var x: Double = 0, y: Double = 0, z: Double = 0
    var yaw: Float = 0
}
