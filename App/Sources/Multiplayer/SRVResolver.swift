import Foundation
import dnssd

/// Resolves Minecraft's `_minecraft._tcp.<host>` SRV record, which many
/// servers use to publish their real host and port (the game does the same).
enum SRVResolver {
    struct Target: Equatable { let host: String; let port: UInt16 }

    static func resolve(_ host: String, timeout: TimeInterval = 3) async -> Target? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: query("_minecraft._tcp.\(host)", timeout: timeout))
            }
        }
    }

    private final class Box { var result: Target? }
    private static let noError = DNSServiceErrorType(kDNSServiceErr_NoError)

    private static func query(_ name: String, timeout: TimeInterval) -> Target? {
        var ref: DNSServiceRef?
        let box = Box()
        let context = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<Box>.fromOpaque(context).release() }
        let err = DNSServiceQueryRecord(&ref, 0, 0, name, UInt16(kDNSServiceType_SRV), UInt16(kDNSServiceClass_IN),
                                        { _, _, _, errorCode, _, _, _, rdlen, rdata, _, ctx in
            guard errorCode == DNSServiceErrorType(kDNSServiceErr_NoError), let rdata, let ctx else { return }
            let box = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue()
            if box.result == nil {
                box.result = SRVResolver.parse(Data(bytes: rdata, count: Int(rdlen)))
            }
        }, context)
        guard err == noError, let ref else { return nil }
        defer { DNSServiceRefDeallocate(ref) }
        let fd = DNSServiceRefSockFD(ref)
        let deadline = Date().addingTimeInterval(timeout)
        while box.result == nil && Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 250) > 0 {
                if DNSServiceProcessResult(ref) != noError { break }
            }
        }
        return box.result
    }

    /// SRV rdata: priority u16, weight u16, port u16, target (DNS labels).
    static func parse(_ d: Data) -> Target? {
        let b = [UInt8](d)
        guard b.count >= 7 else { return nil }
        let port = UInt16(b[4]) << 8 | UInt16(b[5])
        var labels: [String] = []
        var i = 6
        while i < b.count {
            let len = Int(b[i])
            if len == 0 { break }
            guard i + 1 + len <= b.count else { return nil }
            labels.append(String(decoding: b[(i + 1)...(i + len)], as: UTF8.self))
            i += 1 + len
        }
        guard !labels.isEmpty else { return nil }
        return Target(host: labels.joined(separator: "."), port: port)
    }
}

/// Picks the Minecraft version a server runs from its status "version name"
/// ("1.21.1", "Paper 1.21.1", "Velocity 3.3.0 1.8.x-1.21.4", ...).
enum ServerVersionMatcher {
    static func candidates(in name: String) -> [String] {
        let pattern = #"1\.\d+(?:\.\d+)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: name, range: NSRange(name.startIndex..., in: name)).compactMap {
            Range($0.range, in: name).map { String(name[$0]) }
        }
    }

    /// The newest release mentioned in the version string that exists in the manifest.
    static func bestRelease(for versionName: String, manifest: VersionManifest?) -> String? {
        let found = candidates(in: versionName)
        let releases = Set(manifest?.versions.filter(\.isRelease).map(\.id) ?? [])
        let known = found.filter { releases.isEmpty || releases.contains($0) }
        return known.max { LooseVersion($0) < LooseVersion($1) }
    }
}
