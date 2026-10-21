import SwiftUI

struct VoiceView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: SettingsStore
    @ObservedObject var voice: VoiceClient
    @State private var newRoomName = ""
    @State private var newRoomPublic = true
    @State private var newRoomPassword = ""
    @State private var newRoomIsolated = true
    @State private var joinCode = ""
    @State private var joinPassword = ""
    @State private var passwordPrompt: VoiceRoom?
    @State private var promptPassword = ""

    var body: some View {
        List {
            connectionSection
            if voice.isConnected {
                talkSection
                roomSection
                nearbySection
            }
            settingsSection
        }
        .scrollContentBackground(.hidden)
        .alert("Room password", isPresented: Binding(get: { passwordPrompt != nil }, set: { if !$0 { passwordPrompt = nil } })) {
            SecureField("Password", text: $promptPassword)
            Button("Join") {
                if let r = passwordPrompt { voice.joinRoom(id: r.id, password: promptPassword) }
                promptPassword = ""
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(voice.lastError ?? "", isPresented: Binding(get: { voice.lastError != nil }, set: { if !$0 { voice.lastError = nil } })) { Button("OK") {} }
    }

    // MARK: Sections

    private var connectionSection: some View {
        Section {
            HStack {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(voice.status.label).font(.subheadline)
                Spacer()
                if voice.isConnected {
                    Button("Disconnect", role: .destructive) { voice.disconnect() }.buttonStyle(.bordered)
                } else {
                    Button("Connect") { Task { await model.connectVoice() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.accounts.active == nil || store.effectiveRelayURL.isEmpty || voice.status == .connecting || voice.status == .verifying)
                }
            }
            if model.accounts.active == nil {
                Text("Sign in with your Minecraft account first — voice verifies your identity with Mojang so nobody can impersonate you.")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if voice.isConnected {
                LabeledContent("Proximity", value: worldDescription).font(.caption)
            }
        } header: { Text("ZMF Voice") } footer: {
            Text("Proximity voice works in every version and on every server or world — no server plugin needed. Only other ZMF players connected to the same relay can hear you; everyone else on the server hears nothing.")
        }
    }

    private var worldDescription: String {
        guard let w = voice.world.world else { return "Not in a world (rooms still work)" }
        let parts = w.split(separator: "|")
        let server = parts.first.map(String.init) ?? w
        return server.hasPrefix("local:") ? "Singleplayer" : server
    }

    private var talkSection: some View {
        Section("Talk") {
            if store.settings.voiceActivation == .pushToTalk {
                Text(voice.transmitting ? "Transmitting" : "Hold to talk")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(voice.transmitting ? Theme.accent : Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(voice.transmitting ? Color.black : Color.white)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !voice.pushToTalkHeld { voice.pushToTalkHeld = true } }
                        .onEnded { _ in voice.pushToTalkHeld = false })
            }
            LevelMeter(level: voice.inputLevel, threshold: Float(store.settings.voiceThresholdDB))
            Toggle("Mute microphone", isOn: $voice.micMuted)
            Toggle("Deafen (hear nobody)", isOn: $voice.deafened)
            Toggle("Whisper (\(Int(voice.proximityRange / 2)) block range)", isOn: $voice.whisper)
        }
    }

    private var roomSection: some View {
        Section {
            if let room = voice.currentRoom {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(room.name).font(.headline)
                        StatusBadge(text: room.public ? "Public" : "Private", color: room.public ? Theme.accent : Theme.warning)
                        StatusBadge(text: room.isIsolated ? "Room only" : "Room + nearby", color: Theme.textSecondary)
                    }
                    Text("Code: \(room.id)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text(room.members.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(Theme.textSecondary)
                    HStack {
                        ShareLink(item: "Join my ZMF Voice room \"\(room.name)\" — code \(room.id)") { Label("Share code", systemImage: "square.and.arrow.up") }
                        Spacer()
                        Button("Leave", role: .destructive) { voice.leaveRoom() }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("Not in a room — you're using proximity chat.").font(.subheadline).foregroundStyle(Theme.textSecondary)
            }

            DisclosureGroup("Create a room") {
                TextField("Room name", text: $newRoomName)
                Picker("Visibility", selection: $newRoomPublic) {
                    Text("Public (listed)").tag(true)
                    Text("Private (code only)").tag(false)
                }
                SecureField("Password (optional)", text: $newRoomPassword)
                Picker("Who hears the room", selection: $newRoomIsolated) {
                    Text("Only room members").tag(true)
                    Text("Room members + nearby players").tag(false)
                }
                Button("Create & join") {
                    voice.createRoom(name: newRoomName, isPublic: newRoomPublic, password: newRoomPassword, isolated: newRoomIsolated)
                    newRoomName = ""; newRoomPassword = ""
                }
                .disabled(newRoomName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            DisclosureGroup("Join with a code") {
                TextField("Room code", text: $joinCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password (if any)", text: $joinPassword)
                Button("Join") { voice.joinRoom(id: joinCode, password: joinPassword); joinCode = ""; joinPassword = "" }
                    .disabled(joinCode.isEmpty)
            }

            ForEach(voice.rooms.filter { $0.id != voice.currentRoom?.id }) { room in
                HStack {
                    VStack(alignment: .leading) {
                        HStack(spacing: 4) {
                            Text(room.name).font(.subheadline.bold())
                            if room.hasPassword { Image(systemName: "lock.fill").font(.caption2) }
                        }
                        Text("\(room.members.count) in room · \(room.isIsolated ? "room only" : "room + nearby")").font(.caption2).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Join") {
                        if room.hasPassword { passwordPrompt = room } else { voice.joinRoom(id: room.id) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        } header: {
            HStack { Text("Rooms"); Spacer(); Button { voice.refreshRooms() } label: { Image(systemName: "arrow.clockwise") } }
        } footer: {
            Text("Rooms work anywhere — different servers, singleplayer, or just the launcher.")
        }
    }

    private var nearbySection: some View {
        Section("Players you can hear (\(voice.peers.count))") {
            if voice.peers.isEmpty { Text("No other ZMF players nearby or in your room.").font(.caption).foregroundStyle(Theme.textSecondary) }
            ForEach(voice.peers) { peer in
                VStack(alignment: .leading) {
                    HStack {
                        Image(systemName: peer.talking ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(peer.talking ? Theme.accent : Theme.textSecondary)
                        Text(peer.name)
                        if peer.sameRoom { StatusBadge(text: "Room", color: Theme.accent) }
                        Spacer()
                        Button {
                            let muted = (store.settings.playerVolumes[peer.uuid] ?? 1) == 0
                            store.settings.playerVolumes[peer.uuid] = muted ? 1 : 0
                        } label: {
                            Image(systemName: (store.settings.playerVolumes[peer.uuid] ?? 1) == 0 ? "speaker.slash.fill" : "speaker.wave.1")
                        }
                        .buttonStyle(.borderless)
                    }
                    Slider(value: Binding(get: { store.settings.playerVolumes[peer.uuid] ?? 1 },
                                          set: { store.settings.playerVolumes[peer.uuid] = $0 }), in: 0...2)
                }
            }
        }
    }

    private var settingsSection: some View {
        Section {
            TextField("Relay URL (wss://…)", text: $store.settings.voiceRelayURL)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .font(.system(.footnote, design: .monospaced))
            if store.settings.voiceRelayURL.isEmpty && !store.effectiveRelayURL.isEmpty {
                LabeledContent("Default", value: store.effectiveRelayURL).font(.caption)
            }
            Toggle("Enable voice in games", isOn: $store.settings.voiceEnabled)
            Toggle("Connect automatically when playing", isOn: $store.settings.voiceAutoConnect)
            Picker("Activation", selection: $store.settings.voiceActivation) {
                ForEach(VoiceActivation.allCases) { Text($0.title).tag($0) }
            }
            if store.settings.voiceActivation == .voiceActivation {
                VStack(alignment: .leading) {
                    Text("Activation threshold: \(Int(store.settings.voiceThresholdDB)) dB")
                    Slider(value: $store.settings.voiceThresholdDB, in: -70 ... -10)
                }
            }
            VStack(alignment: .leading) {
                Text("Microphone gain: \(String(format: "%.1f×", store.settings.micGain))")
                Slider(value: $store.settings.micGain, in: 0.2...4)
            }
            VStack(alignment: .leading) {
                Text("Voice volume: \(Int(store.settings.voiceOutputVolume * 100))%")
                Slider(value: $store.settings.voiceOutputVolume, in: 0...1.5)
            }
            Toggle("Noise suppression & echo cancellation", isOn: $store.settings.voiceNoiseSuppression)
            Toggle("3D positional audio (headphones)", isOn: $store.settings.voice3DAudio)
            Toggle("Show who's talking in game", isOn: $store.settings.showVoiceOverlay)
        } header: { Text("Voice settings") } footer: {
            Text("The relay is a small server you (or a friend) host — see voice-relay/README.md. Everyone who should hear each other must use the same relay.")
        }
    }

    private var statusColor: Color {
        switch voice.status {
        case .connected: return Theme.accent
        case .failed: return Theme.danger
        case .disconnected: return Theme.textSecondary
        default: return Theme.warning
        }
    }
}

struct LevelMeter: View {
    let level: Float
    let threshold: Float

    var body: some View {
        GeometryReader { geo in
            let fraction = CGFloat(max(0, min(1, (level + 70) / 70)))
            let t = CGFloat(max(0, min(1, (threshold + 70) / 70)))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceRaised)
                Capsule().fill(level > threshold ? Theme.accent : Theme.textSecondary).frame(width: geo.size.width * fraction)
                Rectangle().fill(Theme.warning).frame(width: 2).offset(x: geo.size.width * t)
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Microphone level")
    }
}
