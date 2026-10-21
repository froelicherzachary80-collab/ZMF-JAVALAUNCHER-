import XCTest
import AVFoundation
@testable import ZMFJavaLauncher

final class VoiceTests: XCTestCase {
    func testAudioFraming() throws {
        let out = VoiceProtocol.clientAudio(seq: 0x0102, whisper: true, payload: Data([9, 8, 7]))
        XCTAssertEqual(Array(out), [1, 1, 1, 2, 9, 8, 7])
        let relay = Data([1, 0, 0, 5, 0x12, 0x34, 0xAA, 0xBB])
        let frame = try XCTUnwrap(VoiceProtocol.parseRelayAudio(relay))
        XCTAssertEqual(frame.speaker, 0x1234)
        XCTAssertEqual(frame.seq, 5)
        XCTAssertFalse(frame.whisper)
        XCTAssertEqual(frame.payload, Data([0xAA, 0xBB]))
        XCTAssertNil(VoiceProtocol.parseRelayAudio(Data([2, 0, 0, 0, 0, 0, 1])))
    }

    func testRelayJSONDecoding() throws {
        let rooms = try JSONDecoder().decode([VoiceRoom].self, from: Data(#"[{"id":"ab12","name":"Squad","public":false,"hasPassword":true,"type":"isolated","members":[{"id":3,"name":"Alex"}]}]"#.utf8))
        XCTAssertTrue(rooms[0].isIsolated)
        XCTAssertEqual(rooms[0].members.first?.name, "Alex")
        let peers = try JSONDecoder().decode([VoicePeer].self, from: Data(#"[{"id":2,"name":"Steve","uuid":"u","pos":null,"yaw":0,"sameRoom":true,"talking":false}]"#.utf8))
        XCTAssertNil(peers[0].pos)
    }

    func testSpatialMathMatchesMinecraftAxes() {
        // Facing south (yaw 0): a source further south is straight ahead (-z in audio space).
        var v = SpatialAudio.relative(listener: (0, 64, 0, 0), source: (0, 64, 10))
        XCTAssertEqual(v.z, -10, accuracy: 1e-9)
        XCTAssertEqual(v.x, 0, accuracy: 1e-9)
        // Facing south, east (+x) is on the listener's left.
        v = SpatialAudio.relative(listener: (0, 64, 0, 0), source: (10, 64, 0))
        XCTAssertEqual(v.x, -10, accuracy: 1e-9)
        // Facing west (yaw 90), a source to the north is on the right.
        v = SpatialAudio.relative(listener: (0, 64, 0, 90), source: (0, 64, -10))
        XCTAssertEqual(v.x, 10, accuracy: 1e-9)
        XCTAssertEqual(v.z, 0, accuracy: 1e-9)
        XCTAssertEqual(SpatialAudio.gain(distance: 2, range: 48), 1)
        XCTAssertEqual(SpatialAudio.gain(distance: 48, range: 48), 0)
        XCTAssertTrue(SpatialAudio.gain(distance: 20, range: 48) < SpatialAudio.gain(distance: 10, range: 48))
    }

    func testSRVParsing() throws {
        // priority 0, weight 5, port 25570, target mc.example.org
        var d = Data([0, 0, 0, 5, 0x63, 0xE2])
        for label in ["mc", "example", "org"] { d.append(UInt8(label.count)); d.append(contentsOf: Array(label.utf8)) }
        d.append(0)
        XCTAssertEqual(SRVResolver.parse(d), SRVResolver.Target(host: "mc.example.org", port: 25570))
        XCTAssertNil(SRVResolver.parse(Data([0, 0])))
    }

    func testServerVersionMatching() {
        XCTAssertEqual(ServerVersionMatcher.bestRelease(for: "Paper 1.21.1", manifest: nil), "1.21.1")
        XCTAssertEqual(ServerVersionMatcher.bestRelease(for: "Velocity 3.3.0 1.8.x-1.21.4", manifest: nil), "1.21.4")
        XCTAssertNil(ServerVersionMatcher.bestRelease(for: "Requires MC", manifest: nil))
        XCTAssertEqual(SavedServer(name: "a", address: "x.org").hasExplicitPort, false)
        XCTAssertEqual(SavedServer(name: "a", address: "x.org:1").hasExplicitPort, true)
    }

    func testDeviceCodePollErrors() {
        XCTAssertEqual(DeviceCodeLogin.pollError(#"{"error":"authorization_pending"}"#), "authorization_pending")
        XCTAssertNil(DeviceCodeLogin.pollError("nope"))
    }

    func testOpusRoundTrip() throws {
        let encoder: OpusEncoder
        let decoder: OpusDecoder
        do {
            encoder = try OpusEncoder()
            decoder = try OpusDecoder()
        } catch {
            throw XCTSkip("Opus codec not available in this runtime: \(error)")
        }
        let frame = AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm, frameCapacity: OpusFormat.frameSamples)!
        frame.frameLength = OpusFormat.frameSamples
        for i in 0..<Int(OpusFormat.frameSamples) {
            frame.floatChannelData![0][i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / 48_000)
        }
        var packets: [Data] = []
        for _ in 0..<5 { packets.append(try encoder.encode(frame)) }
        XCTAssertTrue(packets.allSatisfy { !$0.isEmpty && $0.count < 400 }, "sizes: \(packets.map(\.count))")
        let pcm = try decoder.decode(packets[4])
        XCTAssertEqual(pcm.frameLength, OpusFormat.frameSamples)
    }
}
