import Foundation
import AVFoundation

/// ZMF Voice: proximity voice in any Minecraft world/server plus private and
/// public rooms. Only other ZMF users connected to the same relay can hear you.
@MainActor
final class VoiceClient: ObservableObject {
    enum Status: Equatable {
        case disconnected
        case connecting
        case verifying
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting…"
            case .verifying: return "Verifying Minecraft account…"
            case .connected: return "Connected"
            case .failed(let m): return m
            }
        }
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var rooms: [VoiceRoom] = []
    @Published private(set) var currentRoom: VoiceRoom?
    @Published private(set) var peers: [VoicePeer] = []
    @Published private(set) var world = VoiceWorldState()
    @Published private(set) var inputLevel: Float = -120
    @Published private(set) var transmitting = false
    @Published var pushToTalkHeld = false { didSet { updateTransmitting() } }
    @Published var micMuted = false { didSet { updateTransmitting() } }
    @Published var deafened = false { didSet { sendJSON(["t": "deafen", "on": deafened]) } }
    @Published var whisper = false
    @Published var lastError: String?
    @Published private(set) var lastCreatedRoomID: String?
    @Published private(set) var proximityRange: Double = 48

    private var socket: URLSessionWebSocketTask?
    private let audio = VoiceAudioEngine()
    private var myID: Int?
    private var seq: UInt16 = 0
    private var settings = LauncherSettings()
    private var lastStateSent = Date.distantPast
    private var peersByID: [Int: VoicePeer] = [:]

    init() {
        GameTelemetry.shared.onUpdate = { [weak self] state in self?.worldChanged(state) }
    }

    var isConnected: Bool { status == .connected }
    var talkingPeers: [VoicePeer] { peers.filter(\.talking) }

    func apply(settings: LauncherSettings) {
        self.settings = settings
        audio.micGain = Float(settings.micGain)
        audio.thresholdDB = Float(settings.voiceThresholdDB)
        audio.voiceActivated = settings.voiceActivation == .voiceActivation
        if audio.running { audio.outputVolume = Float(settings.voiceOutputVolume) }
        updateTransmitting()
    }

    // MARK: Connection

    func connect(relay: String, account: MinecraftAccount) async {
        disconnect()
        guard var comps = URLComponents(string: relay.trimmingCharacters(in: .whitespaces)),
              let scheme = comps.scheme, ["ws", "wss", "http", "https"].contains(scheme) else {
            status = .failed("Set a voice relay URL (wss://…) in Multiplayer › Voice.")
            return
        }
        if scheme == "http" { comps.scheme = "ws" }
        if scheme == "https" { comps.scheme = "wss" }
        if comps.path.isEmpty || comps.path == "/" { comps.path = "/voice" }
        guard let url = comps.url else { return }

        if AVAudioSession.sharedInstance().recordPermission != .granted {
            let granted = await withCheckedContinuation { c in
                AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
            }
            if !granted { lastError = "Microphone access is off. You can still listen; enable it in iOS Settings › ZMF Java to talk." }
        }

        status = .connecting
        let task = HTTP.session.webSocketTask(with: url)
        socket = task
        task.resume()
        receiveLoop(task, account: account)
    }

    func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        audio.stop()
        status = .disconnected
        peers = []
        peersByID = [:]
        currentRoom = nil
        rooms = []
        myID = nil
        transmitting = false
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, account: MinecraftAccount) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .failure(let error):
                    if self.status != .disconnected {
                        self.status = .failed("Voice relay connection lost: \(error.localizedDescription)")
                        self.audio.stop()
                    }
                    return
                case .success(.string(let text)):
                    await self.handle(text: text, account: account)
                case .success(.data(let data)):
                    self.handle(audio: data)
                @unknown default:
                    break
                }
                self.receiveLoop(task, account: account)
            }
        }
    }

    private func handle(text: String, account: MinecraftAccount) async {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["t"] as? String else { return }
        switch type {
        case "challenge":
            status = .verifying
            let nonce = obj["nonce"] as? String ?? ""
            if (obj["auth"] as? String) == "mojang" {
                do {
                    try await MojangSession.join(account: account, serverId: nonce)
                } catch {
                    status = .failed("Could not verify your Minecraft account with Mojang: \(error.localizedDescription)")
                    return
                }
            }
            sendJSON(["t": "auth", "name": account.username, "uuid": account.id])
        case "welcome":
            myID = obj["id"] as? Int
            if let cfg = obj["config"] as? [String: Any], let range = cfg["proximityRange"] as? Double { proximityRange = range }
            rooms = decode([VoiceRoom].self, obj["rooms"]) ?? []
            status = .connected
            startAudio()
            worldChanged(GameTelemetry.shared.current, force: true)
            zlog.info("ZMF Voice connected as \(account.username)")
        case "rooms":
            rooms = decode([VoiceRoom].self, obj["list"]) ?? []
        case "room":
            currentRoom = decode(VoiceRoom.self, obj["room"])
        case "room.created":
            lastCreatedRoomID = obj["id"] as? String
        case "peers":
            let list = decode([VoicePeer].self, obj["list"]) ?? []
            let gone = Set(peersByID.keys).subtracting(list.map(\.id))
            for id in gone { audio.removeSpeaker(UInt16(id)) }
            peersByID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            peers = list.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case "error":
            let msg = obj["msg"] as? String ?? "Voice error"
            if obj["fatal"] as? Bool == true { status = .failed(msg) } else { lastError = msg }
        default:
            break
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
        guard let value, !(value is NSNull), let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: Rooms

    func createRoom(name: String, isPublic: Bool, password: String, isolated: Bool) {
        var msg: [String: Any] = ["t": "room.create", "name": name, "public": isPublic, "type": isolated ? "isolated" : "open"]
        if !password.isEmpty { msg["password"] = password }
        sendJSON(msg)
    }

    func joinRoom(id: String, password: String = "") {
        sendJSON(["t": "room.join", "id": id.trimmingCharacters(in: .whitespaces).lowercased(), "password": password])
    }

    func leaveRoom() { sendJSON(["t": "room.leave"]) }
    func refreshRooms() { sendJSON(["t": "room.list"]) }

    // MARK: World state (proximity)

    private func worldChanged(_ state: VoiceWorldState, force: Bool = false) {
        world = state
        guard isConnected else { return }
        // ~10 Hz is plenty for proximity; the relay rate-limits nothing here but bandwidth matters.
        if !force && Date().timeIntervalSince(lastStateSent) < 0.1 { return }
        lastStateSent = Date()
        var msg: [String: Any] = ["t": "state", "yaw": Double(state.yaw)]
        if let w = state.world {
            msg["world"] = w
            msg["pos"] = [state.x, state.y, state.z]
        } else {
            msg["world"] = NSNull()
            msg["pos"] = NSNull()
        }
        sendJSON(msg)
    }

    // MARK: Audio

    private func startAudio() {
        audio.onEncodedFrame = { [weak self] packet in
            Task { @MainActor in self?.sendAudio(packet) }
        }
        audio.onLevel = { [weak self] level in
            Task { @MainActor in self?.inputLevel = level }
        }
        audio.transmitting = { [weak self] in
            // Read from the audio thread; plain Bool reads are fine here.
            self?.transmitFlag ?? false
        }
        apply(settings: settings)
        do {
            try audio.start(noiseSuppression: settings.voiceNoiseSuppression)
            audio.outputVolume = Float(settings.voiceOutputVolume)
            audio.proximityRange = Float(proximityRange)
        } catch {
            lastError = "Audio could not start: \(error.localizedDescription)"
        }
    }

    nonisolated(unsafe) private var transmitFlag = false

    private func updateTransmitting() {
        let micAllowed = AVAudioSession.sharedInstance().recordPermission == .granted
        let wants = settings.voiceActivation == .voiceActivation ? true : pushToTalkHeld
        transmitFlag = isConnected && micAllowed && !micMuted && wants
        transmitting = transmitFlag && settings.voiceActivation == .pushToTalk
    }

    private func sendAudio(_ packet: Data) {
        guard let socket, isConnected else { return }
        seq &+= 1
        socket.send(.data(VoiceProtocol.clientAudio(seq: seq, whisper: whisper, payload: packet))) { _ in }
    }

    private func handle(audio data: Data) {
        guard !deafened, let frame = VoiceProtocol.parseRelayAudio(data) else { return }
        let peer = peersByID[Int(frame.speaker)]
        let volume = Float(settings.playerVolumes[peer?.uuid ?? ""] ?? 1)
        guard volume > 0 else { return }
        var position: SpatialAudio.Vector?
        var gain: Float = 1
        if let peer, !peer.sameRoom, let pos = peer.pos, pos.count == 3, world.world != nil {
            let rel = SpatialAudio.relative(listener: (world.x, world.y, world.z, Double(world.yaw)), source: (pos[0], pos[1], pos[2]))
            if settings.voice3DAudio {
                position = rel
            } else {
                gain = Float(SpatialAudio.gain(distance: sqrt(rel.x * rel.x + rel.y * rel.y + rel.z * rel.z), range: proximityRange))
            }
        }
        audio.play(speaker: frame.speaker, packet: frame.payload, position: position, volume: volume * gain)
    }
}

/// Proves account ownership to the relay without sharing the token: the same
/// "join" call a Minecraft client makes before connecting to a server.
enum MojangSession {
    static func join(account: MinecraftAccount, serverId: String) async throws {
        _ = try await HTTP.postJSON(URL(string: "https://sessionserver.mojang.com/session/minecraft/join")!, body: [
            "accessToken": account.minecraftAccessToken,
            "selectedProfile": account.id,
            "serverId": serverId,
        ])
    }
}
