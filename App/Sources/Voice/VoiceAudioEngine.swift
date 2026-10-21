import AVFoundation

/// Microphone capture → 20 ms Opus frames, and per-speaker playback through an
/// AVAudioEnvironmentNode (HRTF 3D audio for proximity, centred for rooms).
final class VoiceAudioEngine {
    struct Speaker {
        let player: AVAudioPlayerNode
        let decoder: OpusDecoder
        var queued = 0
    }

    /// Called on the audio thread with each encoded frame while transmitting.
    var onEncodedFrame: (@Sendable (Data) -> Void)?
    /// Called (audio thread) with the current input level in dBFS.
    var onLevel: (@Sendable (Float) -> Void)?

    var transmitting: @Sendable () -> Bool = { false }
    var micGain: Float = 1
    var thresholdDB: Float = -45
    var voiceActivated = false

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private var encoder: OpusEncoder?
    private var resampler: AVAudioConverter?
    private var pending = AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm, frameCapacity: OpusFormat.frameSamples)!
    private var speakers: [UInt16: Speaker] = [:]
    private let playbackQueue = DispatchQueue(label: "dev.zmf.voice.playback")
    private var vadHangover = 0
    private(set) var running = false

    func start(noiseSuppression: Bool) throws {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: noiseSuppression ? .voiceChat : .default,
                                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers])
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)

        let input = engine.inputNode
        if noiseSuppression {
            // Apple's voice processing: echo cancellation + noise suppression + AGC.
            try? input.setVoiceProcessingEnabled(true)
        }
        encoder = try OpusEncoder()

        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        environment.renderingAlgorithm = .HRTFHQ
        environment.distanceAttenuationParameters.distanceAttenuationModel = .linear
        environment.distanceAttenuationParameters.referenceDistance = 4
        environment.distanceAttenuationParameters.maximumDistance = 48
        environment.reverbParameters.enable = false

        let inFormat = input.outputFormat(forBus: 0)
        resampler = AVAudioConverter(from: inFormat, to: OpusFormat.pcm)
        input.installTap(onBus: 0, bufferSize: 480, format: inFormat) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        playbackQueue.sync {
            for s in speakers.values { engine.detach(s.player) }
            speakers.removeAll()
        }
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var outputVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    var proximityRange: Float {
        get { environment.distanceAttenuationParameters.maximumDistance }
        set { environment.distanceAttenuationParameters.maximumDistance = newValue }
    }

    // MARK: Capture

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let resampler else { return }
        let ratio = OpusFormat.sampleRate / buffer.format.sampleRate
        guard let converted = AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm,
                                               frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return }
        var consumed = false
        resampler.convert(to: converted, error: nil) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard let src = converted.floatChannelData?[0] else { return }
        var offset = 0
        let total = Int(converted.frameLength)
        while offset < total {
            let dst = pending.floatChannelData![0]
            let have = Int(pending.frameLength)
            let take = min(Int(OpusFormat.frameSamples) - have, total - offset)
            for i in 0..<take { dst[have + i] = max(-1, min(1, src[offset + i] * micGain)) }
            pending.frameLength = AVAudioFrameCount(have + take)
            offset += take
            if pending.frameLength == OpusFormat.frameSamples {
                emitFrame()
                pending.frameLength = 0
            }
        }
    }

    private func emitFrame() {
        let level = Self.levelDB(pending)
        onLevel?(level)
        var send = transmitting()
        if voiceActivated {
            if level > thresholdDB { vadHangover = 15 } // keep talking 300 ms after the last loud frame
            send = vadHangover > 0
            if vadHangover > 0 { vadHangover -= 1 }
        }
        guard send, let encoder, let data = try? encoder.encode(pending) else { return }
        onEncodedFrame?(data)
    }

    static func levelDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let p = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -120 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += p[i] * p[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return rms > 0 ? 20 * log10(rms) : -120
    }

    // MARK: Playback

    /// Plays one received frame. `position` is listener-relative (nil = centred, e.g. room voice).
    func play(speaker id: UInt16, packet: Data, position: SpatialAudio.Vector?, volume: Float) {
        playbackQueue.async { [weak self] in
            guard let self, self.running else { return }
            var s: Speaker
            if let existing = self.speakers[id] {
                s = existing
            } else {
                guard let decoder = try? OpusDecoder() else { return }
                let player = AVAudioPlayerNode()
                self.engine.attach(player)
                self.engine.connect(player, to: self.environment, format: OpusFormat.pcm)
                player.play()
                s = Speaker(player: player, decoder: decoder)
            }
            // Bound latency: drop frames if more than ~120 ms are already queued.
            guard s.queued < 6, let pcm = try? s.decoder.decode(packet) else { self.speakers[id] = s; return }
            if let p = position {
                s.player.renderingAlgorithm = .HRTFHQ
                s.player.position = AVAudio3DPoint(x: Float(p.x), y: Float(p.y), z: Float(p.z))
            } else {
                s.player.renderingAlgorithm = .equalPowerPanning
                s.player.position = AVAudio3DPoint(x: 0, y: 0, z: 0)
            }
            s.player.volume = volume
            s.queued += 1
            self.speakers[id] = s
            s.player.scheduleBuffer(pcm) { [weak self] in
                self?.playbackQueue.async { self?.speakers[id]?.queued -= 1 }
            }
        }
    }

    func removeSpeaker(_ id: UInt16) {
        playbackQueue.async { [weak self] in
            guard let self, let s = self.speakers.removeValue(forKey: id) else { return }
            s.player.stop()
            self.engine.detach(s.player)
        }
    }
}
