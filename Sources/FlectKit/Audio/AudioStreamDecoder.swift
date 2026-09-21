// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AudioToolbox
import AVFoundation

/// AirPlay's audio compression types ("ct"). Always 44.1 kHz stereo.
public enum AirPlayAudioFormat: Int, Sendable {
    /// 16-bit little-endian PCM.
    case pcm = 1
    /// Apple Lossless, 352 frames per packet: music and other AirPlay audio.
    case alac = 2
    /// AAC-LC, 1024 frames per packet (rare).
    case aacLC = 4
    /// AAC-ELD, 480 frames per packet: the sound that goes with screen mirroring.
    case aacELD = 8

    static let sampleRate: Double = 44_100

    var framesPerPacket: UInt32 {
        switch self {
        case .pcm, .alac: 352
        case .aacLC: 1024
        case .aacELD: 480
        }
    }

    fileprivate var streamDescription: AudioStreamBasicDescription {
        var description = AudioStreamBasicDescription()
        description.mSampleRate = Self.sampleRate
        description.mChannelsPerFrame = 2
        description.mFramesPerPacket = framesPerPacket
        switch self {
        case .pcm:
            description.mFormatID = kAudioFormatLinearPCM
            description.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            description.mFramesPerPacket = 1
            description.mBitsPerChannel = 16
            description.mBytesPerFrame = 4
            description.mBytesPerPacket = 4
        case .alac:
            description.mFormatID = kAudioFormatAppleLossless
            description.mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData
        case .aacLC:
            description.mFormatID = kAudioFormatMPEG4AAC
        case .aacELD:
            description.mFormatID = kAudioFormatMPEG4AAC_ELD
        }
        return description
    }

    /// Decoder configuration ("magic cookie"). AirPlay senders always use
    /// these fixed values (the same ones UxPlay feeds GStreamer).
    fileprivate var magicCookie: [UInt8]? {
        switch self {
        case .pcm:
            nil
        case .alac:
            // ALACSpecificConfig: 352 frames, 16-bit, pb 40, mb 10, kb 14, 2 ch, 44100 Hz.
            [0x00, 0x00, 0x01, 0x60, 0x00, 0x10, 0x28, 0x0A, 0x0E, 0x02, 0x00, 0xFF,
             0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xAC, 0x44]
        case .aacLC:
            Self.esds([0x12, 0x10])  // AudioSpecificConfig: AAC-LC, 44.1 kHz, stereo
        case .aacELD:
            Self.esds([0xF8, 0xE8, 0x50, 0x00])  // AudioSpecificConfig: ELD, 44.1 kHz, stereo, 480
        }
    }

    /// AudioToolbox's AAC decoders take their AudioSpecificConfig wrapped
    /// in an MPEG-4 ES descriptor, laid out as the Mac's own encoder writes it.
    private static func esds(_ audioSpecificConfig: [UInt8]) -> [UInt8] {
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
            [tag, 0x80, 0x80, 0x80, UInt8(body.count)] + body
        }
        let decoderSpecificInfo = descriptor(0x05, audioSpecificConfig)
        let decoderConfig = descriptor(0x04, [
            0x40,                    // object type: MPEG-4 audio
            0x14,                    // stream type: audio
            0x00, 0x18, 0x00,        // buffer size
            0x00, 0x00, 0x00, 0x00,  // max bitrate
            0x00, 0x00, 0x00, 0x00,  // average bitrate
        ] + decoderSpecificInfo)
        let slConfig = descriptor(0x06, [0x02])
        return descriptor(0x03, [0x00, 0x00, 0x00] + decoderConfig + slConfig)
    }
}

/// Decodes one AirPlay audio packet at a time into float PCM.
///
/// Uses AudioToolbox directly: AVAudioConverter ignores decoder
/// configuration, which ALAC can't do without.
/// Not thread-safe: use from one thread at a time.
final class AudioStreamDecoder {
    let format: AirPlayAudioFormat
    /// 44.1 kHz stereo, 32-bit float, non-interleaved.
    let outputFormat: AVAudioFormat

    private let converter: AudioConverterRef
    private let input = PendingPacket()

    init?(format: AirPlayAudioFormat) {
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: AirPlayAudioFormat.sampleRate, channels: 2)
        else { return nil }
        var inputDescription = format.streamDescription
        var converter: AudioConverterRef?
        guard AudioConverterNew(&inputDescription, outputFormat.streamDescription, &converter) == noErr,
              let converter
        else { return nil }
        if let cookie = format.magicCookie {
            let status = cookie.withUnsafeBytes {
                AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie,
                                          UInt32($0.count), $0.baseAddress!)
            }
            guard status == noErr else {
                AudioConverterDispose(converter)
                return nil
            }
        }
        self.format = format
        self.outputFormat = outputFormat
        self.converter = converter
    }

    deinit {
        AudioConverterDispose(converter)
    }

    /// Returns nil when the packet is unusable or the decoder is still
    /// filling its pipeline (AAC decoders hold back the first packet or two).
    func decode(_ packet: UnsafeRawBufferPointer) -> AVAudioPCMBuffer? {
        guard !packet.isEmpty else { return nil }
        let isPCM = format == .pcm
        let packetFrames = isPCM ? UInt32(packet.count / 4) : format.framesPerPacket
        let capacity = max(packetFrames, 1) * 2
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        output.frameLength = capacity  // sizes the buffer list for the converter

        input.load(packet, isPCM: isPCM)
        var frames = capacity
        let status = AudioConverterFillComplexBuffer(
            converter, supplyPendingPacket, Unmanaged.passUnretained(input).toOpaque(),
            &frames, output.mutableAudioBufferList, nil)
        guard status == noErr || status == PendingPacket.drained, frames > 0 else { return nil }
        output.frameLength = frames
        return output
    }

    func reset() {
        AudioConverterReset(converter)
    }
}

/// The packet being decoded, handed to the converter one packet at a time.
private final class PendingPacket {
    /// Tells the converter there's nothing more for now (not an error).
    static let drained: OSStatus = 0x6E6F_6D6F  // 'nomo'

    private(set) var bytes: UnsafeMutableRawPointer
    private var capacity: Int
    private(set) var count = 0
    private(set) var isPCM = false
    var consumed = true
    /// Heap-allocated so the converter can hold on to its address.
    let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

    init() {
        capacity = 2048
        bytes = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        description.initialize(to: AudioStreamPacketDescription())
    }

    deinit {
        bytes.deallocate()
        description.deallocate()
    }

    /// Copies the packet, which must stay valid while the converter reads it.
    func load(_ packet: UnsafeRawBufferPointer, isPCM: Bool) {
        if packet.count > capacity {
            bytes.deallocate()
            capacity = packet.count
            bytes = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        }
        bytes.copyMemory(from: packet.baseAddress!, byteCount: packet.count)
        count = packet.count
        self.isPCM = isPCM
        consumed = false
    }
}

private func supplyPendingPacket(
    _ converter: AudioConverterRef,
    _ packetCount: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutablePointer<AudioBufferList>,
    _ packetDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    let pending = Unmanaged<PendingPacket>.fromOpaque(userData!).takeUnretainedValue()
    guard !pending.consumed else {
        packetCount.pointee = 0
        return PendingPacket.drained
    }
    pending.consumed = true
    data.pointee.mNumberBuffers = 1
    data.pointee.mBuffers.mNumberChannels = 2
    data.pointee.mBuffers.mData = pending.bytes
    data.pointee.mBuffers.mDataByteSize = UInt32(pending.count)
    if pending.isPCM {
        packetCount.pointee = UInt32(pending.count / 4)
    } else {
        packetCount.pointee = 1
        pending.description.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(pending.count))
        packetDescriptions?.pointee = pending.description
    }
    return noErr
}
