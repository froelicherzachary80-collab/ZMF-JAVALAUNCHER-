import Foundation
import Combine

enum QualityProfile: String, Codable, CaseIterable, Identifiable {
    case battery, balanced, quality, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .battery: return "Battery Saver"
        case .balanced: return "Balanced"
        case .quality: return "Quality"
        case .custom: return "Custom"
        }
    }
}

enum VoiceActivation: String, Codable, CaseIterable, Identifiable {
    case pushToTalk, voiceActivation
    var id: String { rawValue }
    var title: String { self == .pushToTalk ? "Push to talk" : "Voice activation" }
}

enum GCMode: String, Codable, CaseIterable, Identifiable {
    case serial, g1
    var id: String { rawValue }
    var jvmFlag: String { self == .serial ? "-XX:+UseSerialGC" : "-XX:+UseG1GC" }
}

struct LauncherSettings: Codable, Equatable {
    // Java
    var memoryMB: Int = 2048
    var gc: GCMode = .g1
    var extraJVMArguments: String = ""
    /// When JIT is unavailable, pass -Xint so a JIT-requiring VM does not crash
    /// on the first executable-memory mapping.
    var forceInterpreterWithoutJIT: Bool = true

    // Video
    var qualityProfile: QualityProfile = .balanced
    var renderDistance: Int = 8
    var simulationDistance: Int = 6
    var fpsLimit: Int = 60
    var resolutionScale: Double = 0.75
    var fancyGraphics: Bool = false
    var smoothLighting: Bool = true
    var thermalAware: Bool = true
    var showFPS: Bool = true
    var showMemory: Bool = true
    var fullscreen: Bool = true
    var enableShadersWhenSupported: Bool = false
    var guiScale: Int = 0

    // Controls
    var cameraSensitivity: Double = 1.0
    var invertY: Bool = false
    var controlOpacity: Double = 0.6
    var controlScale: Double = 1.0
    var holdToMineDelay: Double = 0.30
    var doubleTapSprint: Bool = true
    var sneakIsToggle: Bool = true
    var haptics: Bool = true
    var activeHUDPreset: String = HUDPreset.bedrock.id

    // Gamepad
    var gamepadEnabled: Bool = true
    var gamepadLookSpeed: Double = 1.0
    var gamepadDeadzone: Double = 0.15

    // Keys sent to Java for each mobile action (GLFW key codes).
    var keyMap: [String: Int] = KeyMapping.defaults

    // Accounts
    /// Optional override for the Azure application (client) ID used for
    /// Microsoft sign-in. Empty uses the ID baked in at build time.
    var microsoftClientID: String = ""

    var selectedProfileID: UUID?

    // ZMF Voice
    var voiceEnabled: Bool = true
    /// Empty uses the relay baked in at build time (ZMF_VOICE_RELAY_URL).
    var voiceRelayURL: String = ""
    var voiceActivation: VoiceActivation = .pushToTalk
    /// Voice-activation threshold in dBFS.
    var voiceThresholdDB: Double = -45
    var micGain: Double = 1.0
    var voiceOutputVolume: Double = 1.0
    var voiceNoiseSuppression: Bool = true
    var voiceAutoConnect: Bool = true
    var voice3DAudio: Bool = true
    var showVoiceOverlay: Bool = true
    /// Per-player volume (Minecraft UUID → 0...2), 0 = muted.
    var playerVolumes: [String: Double] = [:]

    init() {}

    // Decode leniently so adding settings never wipes a user's configuration.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ current: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? current }
        memoryMB = v(.memoryMB, memoryMB)
        gc = v(.gc, gc)
        extraJVMArguments = v(.extraJVMArguments, extraJVMArguments)
        forceInterpreterWithoutJIT = v(.forceInterpreterWithoutJIT, forceInterpreterWithoutJIT)
        qualityProfile = v(.qualityProfile, qualityProfile)
        renderDistance = v(.renderDistance, renderDistance)
        simulationDistance = v(.simulationDistance, simulationDistance)
        fpsLimit = v(.fpsLimit, fpsLimit)
        resolutionScale = v(.resolutionScale, resolutionScale)
        fancyGraphics = v(.fancyGraphics, fancyGraphics)
        smoothLighting = v(.smoothLighting, smoothLighting)
        thermalAware = v(.thermalAware, thermalAware)
        showFPS = v(.showFPS, showFPS)
        showMemory = v(.showMemory, showMemory)
        fullscreen = v(.fullscreen, fullscreen)
        enableShadersWhenSupported = v(.enableShadersWhenSupported, enableShadersWhenSupported)
        guiScale = v(.guiScale, guiScale)
        cameraSensitivity = v(.cameraSensitivity, cameraSensitivity)
        invertY = v(.invertY, invertY)
        controlOpacity = v(.controlOpacity, controlOpacity)
        controlScale = v(.controlScale, controlScale)
        holdToMineDelay = v(.holdToMineDelay, holdToMineDelay)
        doubleTapSprint = v(.doubleTapSprint, doubleTapSprint)
        sneakIsToggle = v(.sneakIsToggle, sneakIsToggle)
        haptics = v(.haptics, haptics)
        activeHUDPreset = v(.activeHUDPreset, activeHUDPreset)
        gamepadEnabled = v(.gamepadEnabled, gamepadEnabled)
        gamepadLookSpeed = v(.gamepadLookSpeed, gamepadLookSpeed)
        gamepadDeadzone = v(.gamepadDeadzone, gamepadDeadzone)
        keyMap = KeyMapping.defaults.merging(v(.keyMap, [String: Int]())) { _, user in user }
        microsoftClientID = v(.microsoftClientID, microsoftClientID)
        selectedProfileID = (try? c.decodeIfPresent(UUID.self, forKey: .selectedProfileID)) ?? nil
        voiceEnabled = v(.voiceEnabled, voiceEnabled)
        voiceRelayURL = v(.voiceRelayURL, voiceRelayURL)
        voiceActivation = v(.voiceActivation, voiceActivation)
        voiceThresholdDB = v(.voiceThresholdDB, voiceThresholdDB)
        micGain = v(.micGain, micGain)
        voiceOutputVolume = v(.voiceOutputVolume, voiceOutputVolume)
        voiceNoiseSuppression = v(.voiceNoiseSuppression, voiceNoiseSuppression)
        voiceAutoConnect = v(.voiceAutoConnect, voiceAutoConnect)
        voice3DAudio = v(.voice3DAudio, voice3DAudio)
        showVoiceOverlay = v(.showVoiceOverlay, showVoiceOverlay)
        playerVolumes = v(.playerVolumes, playerVolumes)
    }

    mutating func apply(_ profile: QualityProfile) {
        qualityProfile = profile
        switch profile {
        case .battery:
            renderDistance = 5; simulationDistance = 5; fpsLimit = 30; resolutionScale = 0.6
            fancyGraphics = false; smoothLighting = false
        case .balanced:
            renderDistance = 8; simulationDistance = 6; fpsLimit = 60; resolutionScale = 0.75
            fancyGraphics = false; smoothLighting = true
        case .quality:
            renderDistance = 12; simulationDistance = 8; fpsLimit = 120; resolutionScale = 1.0
            fancyGraphics = true; smoothLighting = true
        case .custom:
            break
        }
    }

    static let memoryRange = 512...6144
}

/// Owns the persisted settings document.
final class SettingsStore: ObservableObject {
    @Published var settings: LauncherSettings {
        didSet { if settings != oldValue { JSONStore.save(settings, to: "settings.json") } }
    }

    init() {
        settings = JSONStore.load(LauncherSettings.self, from: "settings.json") ?? LauncherSettings()
    }

    /// Voice relay: user override, else the build-time value.
    var effectiveRelayURL: String {
        let override = settings.voiceRelayURL.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return override }
        return (Bundle.main.object(forInfoDictionaryKey: "ZMFVoiceRelayURL") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Microsoft application ID: user override, else the build-time value.
    var effectiveClientID: String {
        let override = settings.microsoftClientID.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return override }
        return (Bundle.main.object(forInfoDictionaryKey: "ZMFMSAClientID") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
