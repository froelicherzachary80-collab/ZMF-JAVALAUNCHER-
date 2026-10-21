import AVFoundation

/// Opus (48 kHz mono, 20 ms frames) via AudioToolbox's built-in Opus support —
/// no third-party codec library.
enum OpusFormat {
    static let sampleRate = 48_000.0
    static let frameSamples: AVAudioFrameCount = 960

    static let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    static let opus: AVAudioFormat? = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(frameSamples), mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &asbd)
    }()
}

enum OpusError: Error { case unavailable, encodeFailed, decodeFailed }

final class OpusEncoder {
    private let converter: AVAudioConverter

    init(bitrate: Int = 32_000) throws {
        guard let opus = OpusFormat.opus, let c = AVAudioConverter(from: OpusFormat.pcm, to: opus) else { throw OpusError.unavailable }
        c.bitRate = bitrate
        converter = c
    }

    /// Encodes exactly one 960-sample frame into one Opus packet.
    func encode(_ frame: AVAudioPCMBuffer) throws -> Data {
        guard let opus = OpusFormat.opus else { throw OpusError.unavailable }
        let out = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: 1500)
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return frame
        }
        guard status != .error, out.packetCount > 0, let desc = out.packetDescriptions?[0] else { throw OpusError.encodeFailed }
        return Data(bytes: out.data.advanced(by: Int(desc.mStartOffset)), count: Int(desc.mDataByteSize))
    }
}

final class OpusDecoder {
    private let converter: AVAudioConverter

    init() throws {
        guard let opus = OpusFormat.opus, let c = AVAudioConverter(from: opus, to: OpusFormat.pcm) else { throw OpusError.unavailable }
        converter = c
    }

    func decode(_ packet: Data) throws -> AVAudioPCMBuffer {
        guard let opus = OpusFormat.opus, !packet.isEmpty else { throw OpusError.decodeFailed }
        let input = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: max(packet.count, 1))
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))

        guard let out = AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm, frameCapacity: OpusFormat.frameSamples * 2) else { throw OpusError.decodeFailed }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, out.frameLength > 0 else { throw OpusError.decodeFailed }
        return out
    }
}
