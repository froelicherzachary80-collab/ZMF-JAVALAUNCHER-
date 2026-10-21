import Foundation

struct Rule: Codable {
    struct OS: Codable {
        var name: String?
        var version: String?
        var arch: String?
    }
    var action: String
    var os: OS?
    var features: [String: Bool]?
}

/// The environment rules are evaluated against. iOS is not a Mojang platform:
/// Java-only libraries are selected as for macOS on arm64 (the closest match),
/// and desktop native classifiers are excluded later because iOS builds of
/// those natives come from the embedded runtime components instead.
struct RuleContext {
    var osName = "osx"
    var osArch = "arm64"
    var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    var features: [String: Bool] = [
        "is_demo_user": false,
        "has_custom_resolution": true,
        "has_quick_plays_support": false,
        "is_quick_play_singleplayer": false,
        "is_quick_play_multiplayer": false,
        "is_quick_play_realms": false,
    ]

    func allows(_ rules: [Rule]?) -> Bool {
        guard let rules, !rules.isEmpty else { return true }
        var allowed = false
        for rule in rules where matches(rule) {
            allowed = rule.action == "allow"
        }
        return allowed
    }

    private func matches(_ rule: Rule) -> Bool {
        if let os = rule.os {
            if let name = os.name, name != osName { return false }
            if let arch = os.arch {
                // Mojang uses "x86" for 32-bit JVMs; we are always 64-bit arm.
                if arch == "x86" { return false }
                if arch != osArch { return false }
            }
            if let pattern = os.version, osVersion.range(of: pattern, options: .regularExpression) == nil { return false }
        }
        if let wanted = rule.features {
            for (key, value) in wanted where (features[key] ?? false) != value { return false }
        }
        return true
    }
}
