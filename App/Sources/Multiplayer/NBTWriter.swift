import Foundation

/// Big-endian NBT writer — enough to produce servers.dat, which Minecraft
/// reads (uncompressed) to populate its multiplayer server list.
enum NBT {
    indirect enum Tag {
        case byte(Int8)
        case string(String)
        case list([Tag]) // homogeneous
        case compound([(String, Tag)])

        var id: UInt8 {
            switch self {
            case .byte: return 1
            case .string: return 8
            case .list: return 9
            case .compound: return 10
            }
        }
    }

    static func encodeRoot(_ root: [(String, Tag)]) -> Data {
        var out = Data([10])
        out += name("")
        out += payload(.compound(root))
        return out
    }

    private static func name(_ s: String) -> Data {
        let utf8 = Data(s.utf8)
        return Data([UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)]) + utf8
    }

    private static func payload(_ tag: Tag) -> Data {
        switch tag {
        case .byte(let b): return Data([UInt8(bitPattern: b)])
        case .string(let s): return name(s)
        case .list(let items):
            var out = Data([items.first?.id ?? 0])
            let n = UInt32(items.count)
            out += Data([UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
            for item in items { out += payload(item) }
            return out
        case .compound(let entries):
            var out = Data()
            for (key, value) in entries {
                out.append(value.id)
                out += name(key)
                out += payload(value)
            }
            out.append(0) // TAG_End
            return out
        }
    }
}
