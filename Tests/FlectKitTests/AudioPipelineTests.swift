// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AVFoundation
import Foundation
import Testing

@testable import FlectKit

@Suite("Audio pipeline")
struct AudioPipelineTests {
    @Test("AAC-ELD, as sent alongside screen mirroring, decodes with AirPlay's fixed config")
    func aacELD() throws {
        let input = SyntheticAudio.sine(seconds: 1)
        let encoded = try SyntheticAudio.encode(input, formatID: kAudioFormatMPEG4AAC_ELD, framesPerPacket: 480)
        try #require(encoded.packets.count > 80)

        let decoder = try #require(AudioStreamDecoder(format: .aacELD))
        let output = decodeAll(encoded.packets, with: decoder)

        // Lossy, and the decoder holds back a packet or two, but most of the tone survives.
        let expected = Int(input.frameLength)
        #expect(output.frames >= expected - 480 * 4)
        #expect(output.frames <= expected + 480 * 2)
        #expect(output.rms > SyntheticAudio.rms(input) * 0.5)
    }

    @Test("ALAC, as sent for music, decodes losslessly")
    func alac() throws {
        let input = SyntheticAudio.sine(seconds: 1)
        let encoded = try SyntheticAudio.encode(
            input, formatID: kAudioFormatAppleLossless, framesPerPacket: 352,
            flags: kAppleLosslessFormatFlag_16BitSourceData)
        try #require(encoded.packets.count > 100)

        let decoder = try #require(AudioStreamDecoder(format: .alac))
        let output = decodeAll(encoded.packets, with: decoder)

        #expect(output.frames == Int(input.frameLength))
        // Lossless apart from 16-bit rounding.
        let original = input.floatChannelData![0]
        let worst = (0..<min(output.frames, Int(input.frameLength))).map { abs(output.left[$0] - original[$0]) }.max() ?? 1
        #expect(worst < 1.0 / 16_000)
    }

    @Test("16-bit PCM converts directly")
    func pcm() throws {
        let decoder = try #require(AudioStreamDecoder(format: .pcm))
        var samples: [Int16] = []
        for i in 0..<352 { samples += [Int16(i * 50), Int16(-i * 50)] }
        let pcm = try #require(samples.withUnsafeBytes { decoder.decode($0) })
        #expect(pcm.frameLength == 352)
        #expect(abs(pcm.floatChannelData![0][100] - Float(5000) / 32768) < 0.0001)
        #expect(abs(pcm.floatChannelData![1][100] + Float(5000) / 32768) < 0.0001)
    }

    @Test("AirPlay volume maps to gain like UxPlay does")
    func volume() {
        #expect(MirrorSession.gain(forDecibels: 0) == 1)
        #expect(MirrorSession.gain(forDecibels: -144) == 0)
        #expect(MirrorSession.gain(forDecibels: -30) == 0)
        #expect(abs(MirrorSession.gain(forDecibels: -6) - 0.501) < 0.001)
        #expect(MirrorSession.gain(forDecibels: 3) == 1)
    }

    private func decodeAll(_ packets: [Data], with decoder: AudioStreamDecoder) -> (frames: Int, rms: Float, left: [Float]) {
        var left: [Float] = []
        for packet in packets {
            guard let pcm = packet.withUnsafeBytes({ decoder.decode($0) }) else { continue }
            left.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
        }
        let rms = left.isEmpty ? 0 : (left.reduce(0) { $0 + $1 * $1 } / Float(left.count)).squareRoot()
        return (left.count, rms, left)
    }
}

enum SyntheticAudio {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    static func sine(seconds: Double, frequency: Float = 440) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                samples[i] = 0.5 * sinf(2 * .pi * frequency * Float(i) / 44_100)
            }
        }
        return buffer
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let samples = buffer.floatChannelData![0]
        let count = Int(buffer.frameLength)
        return ((0..<count).reduce(Float(0)) { $0 + samples[$1] * samples[$1] } / Float(count)).squareRoot()
    }

    /// Encodes with the Mac's own encoder, one packet per `Data`.
    static func encode(_ input: AVAudioPCMBuffer, formatID: AudioFormatID, framesPerPacket: UInt32,
                       flags: AudioFormatFlags = 0) throws -> (packets: [Data], cookie: Data?) {
        var description = AudioStreamBasicDescription()
        description.mSampleRate = 44_100
        description.mFormatID = formatID
        description.mFormatFlags = flags
        description.mChannelsPerFrame = 2
        description.mFramesPerPacket = framesPerPacket
        let outputFormat = try #require(AVAudioFormat(streamDescription: &description))
        let converter = try #require(AVAudioConverter(from: input.format, to: outputFormat))

        var packets: [Data] = []
        var supplied = false
        while true {
            let output = AVAudioCompressedBuffer(
                format: outputFormat, packetCapacity: 64,
                maximumPacketSize: max(converter.maximumOutputPacketSize, 4096))
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            try #require(status != .error, "encoder failed: \(String(describing: error))")
            for index in 0..<Int(output.packetCount) {
                let packet = output.packetDescriptions![index]
                packets.append(Data(bytes: output.data + Int(packet.mStartOffset), count: Int(packet.mDataByteSize)))
            }
            if status == .endOfStream || output.packetCount == 0 {
                break
            }
        }
        return (packets, converter.magicCookie)
    }
}
