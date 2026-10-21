import Foundation

struct ModDependency: Hashable, Codable {
    var modID: String
    /// OR-alternatives of version predicates (Fabric style) or one Maven range.
    var versions: [String]
    var mandatory: Bool
}

/// Metadata read from inside a mod jar.
struct ModMetadata: Hashable, Codable {
    var loader: ModLoader
    var id: String
    var version: String
    var name: String
    var description: String?
    var dependencies: [ModDependency] = []
    var breaks: [ModDependency] = []
    /// Extra ids this jar satisfies (Fabric `provides` and jar-in-jar modules).
    var provides: [String] = []
    var environment: String?
    /// Desktop native libraries shipped in the jar (.so/.dll/.dylib/.jnilib).
    var nativeLibraries: [String] = []
}

enum ModMetadataReader {
    static func read(jar url: URL) throws -> ModMetadata? {
        try read(zip: ZipReader(url: url), depth: 0)
    }

    static func read(zip: ZipReader, depth: Int) throws -> ModMetadata? {
        var meta: ModMetadata?
        if let data = try zip.contents(of: "fabric.mod.json") {
            meta = try parseFabric(data)
        } else if let data = try zip.contents(of: "quilt.mod.json") {
            meta = try parseQuilt(data)
        } else if let data = try zip.contents(of: "META-INF/neoforge.mods.toml") {
            meta = parseModsToml(String(decoding: data, as: UTF8.self), loader: .neoforge)
        } else if let data = try zip.contents(of: "META-INF/mods.toml") {
            meta = parseModsToml(String(decoding: data, as: UTF8.self), loader: .forge)
        }
        guard var result = meta else { return nil }

        result.nativeLibraries = zip.entries.map(\.name).filter { name in
            let lower = name.lowercased()
            return lower.hasSuffix(".so") || lower.hasSuffix(".dll") || lower.hasSuffix(".dylib") || lower.hasSuffix(".jnilib")
        }

        // Jar-in-jar (Fabric "jars", Forge jarjar): nested modules provide ids
        // other mods depend on (e.g. Fabric API's fabric-api-base).
        if depth < 2 {
            for entry in zip.entries where entry.name.hasPrefix("META-INF/jars/") && entry.name.hasSuffix(".jar") {
                guard let nested = try? ZipReader(data: zip.contents(of: entry)),
                      let inner = try? read(zip: nested, depth: depth + 1) else { continue }
                result.provides.append(inner.id)
                result.provides += inner.provides
                result.nativeLibraries += inner.nativeLibraries.map { "\(entry.name)!/\($0)" }
            }
        }
        return result
    }

    // MARK: Fabric

    static func parseFabric(_ data: Data) throws -> ModMetadata {
        // fabric.mod.json allows control characters in strings in practice;
        // JSONSerialization handles the common cases.
        guard let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw InstallError.invalidFile("fabric.mod.json")
        }
        let id = obj["id"] as? String ?? "unknown"
        var meta = ModMetadata(loader: .fabric, id: id, version: obj["version"] as? String ?? "0",
                               name: obj["name"] as? String ?? id, description: obj["description"] as? String)
        meta.environment = obj["environment"] as? String
        meta.provides = obj["provides"] as? [String] ?? []
        meta.dependencies = fabricDeps(obj["depends"], mandatory: true) + fabricDeps(obj["recommends"], mandatory: false)
        meta.breaks = fabricDeps(obj["breaks"], mandatory: true)
        return meta
    }

    private static func fabricDeps(_ value: Any?, mandatory: Bool) -> [ModDependency] {
        guard let dict = value as? [String: Any] else { return [] }
        return dict.map { key, v in
            let versions: [String]
            if let s = v as? String { versions = [s] } else { versions = v as? [String] ?? ["*"] }
            return ModDependency(modID: key, versions: versions, mandatory: mandatory)
        }.sorted { $0.modID < $1.modID }
    }

    // MARK: Quilt

    static func parseQuilt(_ data: Data) throws -> ModMetadata {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ql = obj["quilt_loader"] as? [String: Any] else { throw InstallError.invalidFile("quilt.mod.json") }
        let id = ql["id"] as? String ?? "unknown"
        let md = ql["metadata"] as? [String: Any]
        var meta = ModMetadata(loader: .quilt, id: id, version: ql["version"] as? String ?? "0",
                               name: md?["name"] as? String ?? id, description: md?["description"] as? String)
        meta.provides = (ql["provides"] as? [Any])?.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["id"] as? String) } ?? []
        for dep in ql["depends"] as? [Any] ?? [] {
            if let s = dep as? String {
                meta.dependencies.append(ModDependency(modID: s, versions: ["*"], mandatory: true))
            } else if let d = dep as? [String: Any], let depID = d["id"] as? String {
                let versions: [String]
                if let s = d["versions"] as? String { versions = [s] } else { versions = d["versions"] as? [String] ?? ["*"] }
                let optional = d["optional"] as? Bool ?? false
                // Quilt ids may be namespaced "group:id".
                let bare = depID.split(separator: ":").last.map(String.init) ?? depID
                meta.dependencies.append(ModDependency(modID: bare, versions: versions, mandatory: !optional))
            }
        }
        return meta
    }

    // MARK: Forge / NeoForge (TOML subset)

    static func parseModsToml(_ text: String, loader: ModLoader) -> ModMetadata? {
        var mods: [[String: String]] = []
        var deps: [[String: String]] = []
        var section = ""
        var modTable: [String: String] = [:]
        var depTable: [String: String] = [:]

        func flush() {
            if section == "mods" { mods.append(modTable) }
            if section == "deps" { deps.append(depTable) }
            modTable = [:]
            depTable = [:]
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[[") {
                flush()
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                section = name == "mods" ? "mods" : name.hasPrefix("dependencies") ? "deps" : "other"
                continue
            }
            if line.hasPrefix("[") { flush(); section = "other"; continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                // Quoted string: keep up to the closing quote (ignores trailing comments).
                let body = value.dropFirst()
                value = String(body.prefix { $0 != quote })
            } else if let hash = value.firstIndex(of: "#") {
                value = value[..<hash].trimmingCharacters(in: .whitespaces)
            }
            if section == "mods" { modTable[key] = value }
            if section == "deps" { depTable[key] = value }
        }
        flush()

        guard let first = mods.first, let id = first["modId"] else { return nil }
        var meta = ModMetadata(loader: loader, id: id, version: first["version"] ?? "0",
                               name: first["displayName"] ?? id, description: first["description"])
        meta.provides = mods.dropFirst().compactMap { $0["modId"] }
        meta.dependencies = deps.compactMap { d in
            guard let depID = d["modId"] else { return nil }
            let mandatory = d["mandatory"].map { $0 == "true" } ?? (d["type"].map { $0.lowercased() == "required" } ?? true)
            return ModDependency(modID: depID, versions: [d["versionRange"] ?? "*"], mandatory: mandatory)
        }
        return meta
    }
}
