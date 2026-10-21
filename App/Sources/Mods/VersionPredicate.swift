import Foundation

/// Semantic-version-ish comparison and the predicate syntax used by Fabric
/// (`>=0.15.0`, `~1.20.1`, `^1.2`, `1.20.x`, `*`, space-separated AND) and
/// Maven ranges used by Forge/NeoForge (`[1.20.1,1.21)`).
struct LooseVersion: Comparable {
    let components: [Int]
    let prerelease: String?

    init(_ s: String) {
        var core = s
        var pre: String?
        if let plus = core.firstIndex(of: "+") { core = String(core[..<plus]) }
        if let dash = core.firstIndex(of: "-") {
            pre = String(core[core.index(after: dash)...])
            core = String(core[..<dash])
        }
        components = core.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        prerelease = pre
    }

    static func < (a: LooseVersion, b: LooseVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        for i in 0..<n {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (x?, y?): return x.compare(y, options: .numeric) == .orderedAscending
        }
    }

    static func == (a: LooseVersion, b: LooseVersion) -> Bool { !(a < b) && !(b < a) }
}

enum VersionPredicate {
    /// Any of `alternatives` (OR); each is space-separated AND terms.
    static func matches(_ version: String, anyOf alternatives: [String]) -> Bool {
        alternatives.isEmpty || alternatives.contains { matches(version, $0) }
    }

    static func matches(_ version: String, _ predicate: String) -> Bool {
        let p = predicate.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || p == "*" { return true }
        if p.hasPrefix("[") || p.hasPrefix("(") { return mavenRange(version, p) }
        return p.split(separator: " ").allSatisfy { term(version, String($0)) }
    }

    private static func term(_ version: String, _ t: String) -> Bool {
        let v = LooseVersion(version)
        for op in [">=", "<=", ">", "<", "=", "~", "^"] where t.hasPrefix(op) {
            let target = String(t.dropFirst(op.count))
            let tv = LooseVersion(target.replacingOccurrences(of: ".x", with: ""))
            switch op {
            case ">=": return v >= tv
            case "<=": return v <= tv
            case ">": return v > tv
            case "<": return v < tv
            case "=": return wildcard(version, target)
            case "~": // >= target, same major.minor
                let a = v.components + [0, 0], b = tv.components + [0, 0]
                return v >= tv && a[0] == b[0] && a[1] == b[1]
            case "^": // >= target, same major
                return v >= tv && (v.components.first ?? 0) == (tv.components.first ?? 0)
            default: break
            }
        }
        return wildcard(version, t)
    }

    private static func wildcard(_ version: String, _ pattern: String) -> Bool {
        if pattern.contains("x") || pattern.contains("X") || pattern.contains("*") {
            let fixed = pattern.split(separator: ".").prefix { $0 != "x" && $0 != "X" && $0 != "*" }
            let parts = version.split(separator: ".")
            return parts.count >= fixed.count && zip(parts, fixed).allSatisfy { $0 == $1 }
        }
        return LooseVersion(version) == LooseVersion(pattern)
    }

    private static func mavenRange(_ version: String, _ range: String) -> Bool {
        let v = LooseVersion(version)
        let lowInclusive = range.hasPrefix("[")
        let highInclusive = range.hasSuffix("]")
        let inner = range.dropFirst().dropLast()
        let bounds = inner.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if bounds.count == 1 { return v == LooseVersion(bounds[0]) }
        if let lo = bounds.first, !lo.isEmpty {
            let l = LooseVersion(lo)
            if lowInclusive ? v < l : v <= l { return false }
        }
        if bounds.count > 1, !bounds[1].isEmpty {
            let h = LooseVersion(bounds[1])
            if highInclusive ? v > h : v >= h { return false }
        }
        return true
    }
}
