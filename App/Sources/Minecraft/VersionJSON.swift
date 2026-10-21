import Foundation

/// A client version document (versions/<id>/<id>.json). Covers the Mojang
/// format from 1.0 through current snapshots, plus loader profiles (Fabric,
/// Quilt) which use `inheritsFrom` and maven-only library entries.
struct VersionJSON: Codable {
    var id: String
    var type: String?
    var mainClass: String?
    var inheritsFrom: String?
    var minecraftArguments: String?
    var arguments: Arguments?
    var assetIndex: AssetIndexRef?
    var assets: String?
    var downloads: [String: Artifact]?
    var javaVersion: JavaVersion?
    var libraries: [Library]?
    var logging: Logging?
    var releaseTime: String?
    var complianceLevel: Int?

    struct Arguments: Codable {
        var game: [Argument]?
        var jvm: [Argument]?
    }

    struct AssetIndexRef: Codable {
        var id: String
        var sha1: String?
        var size: Int64?
        var totalSize: Int64?
        var url: URL
    }

    struct Artifact: Codable {
        var path: String?
        var sha1: String?
        var size: Int64?
        var url: URL?
    }

    struct JavaVersion: Codable {
        var component: String?
        var majorVersion: Int
    }

    struct Logging: Codable {
        struct Client: Codable {
            var argument: String
            var file: FileRef
            var type: String?
        }
        struct FileRef: Codable {
            var id: String
            var sha1: String?
            var size: Int64?
            var url: URL
        }
        var client: Client?
    }

    struct Library: Codable {
        struct Downloads: Codable {
            var artifact: Artifact?
            var classifiers: [String: Artifact]?
        }
        struct Extract: Codable { var exclude: [String]? }

        var name: String
        var downloads: Downloads?
        var rules: [Rule]?
        var natives: [String: String]?
        var extract: Extract?
        /// Maven repository base for loader libraries without `downloads`.
        var url: String?
        var sha1: String?
        var size: Int64?

        var coordinate: MavenCoordinate? { MavenCoordinate(name) }
    }

    /// Either a plain string or a conditional `{rules, value}` entry.
    enum Argument: Codable {
        case plain(String)
        case conditional(rules: [Rule], values: [String])

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let s = try? single.decode(String.self) {
                self = .plain(s)
                return
            }
            struct Conditional: Codable {
                var rules: [Rule]
                var value: StringOrArray
            }
            let c = try single.decode(Conditional.self)
            self = .conditional(rules: c.rules, values: c.value.values)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .plain(let s): try c.encode(s)
            case .conditional(let rules, let values):
                try c.encode(["rules": AnyEncodable(rules), "value": AnyEncodable(values)])
            }
        }
    }

    var jvmArguments: [Argument] { arguments?.jvm ?? [] }
    var gameArguments: [Argument] { arguments?.game ?? [] }
    var requiredJavaMajor: Int { javaVersion?.majorVersion ?? 8 }
}

struct StringOrArray: Codable {
    var values: [String]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { values = [s] } else { values = try c.decode([String].self) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(values)
    }
}

struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeFn = value.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}

/// group:artifact:version[:classifier][@extension]
struct MavenCoordinate: Hashable {
    let group: String
    let artifact: String
    let version: String
    let classifier: String?
    let ext: String

    init?(_ name: String) {
        var base = name
        var ext = "jar"
        if let at = name.lastIndex(of: "@") {
            ext = String(name[name.index(after: at)...])
            base = String(name[..<at])
        }
        let parts = base.split(separator: ":").map(String.init)
        guard parts.count >= 3 else { return nil }
        group = parts[0]
        artifact = parts[1]
        version = parts[2]
        classifier = parts.count > 3 ? parts[3] : nil
        self.ext = ext
    }

    /// Libraries are unique by group:artifact(:classifier) — used when a loader
    /// profile overrides a vanilla library with another version.
    var identity: String { [group, artifact, classifier].compactMap { $0 }.joined(separator: ":") }

    var path: String {
        let file = classifier.map { "\(artifact)-\(version)-\($0).\(ext)" } ?? "\(artifact)-\(version).\(ext)"
        return "\(group.replacingOccurrences(of: ".", with: "/"))/\(artifact)/\(version)/\(file)"
    }

    var isNativesClassifier: Bool { classifier?.hasPrefix("natives-") ?? false }
}
