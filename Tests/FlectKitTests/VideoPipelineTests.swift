// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

@testable import FlectKit

@Suite("Video pipeline")
struct VideoPipelineTests {
    @Test("Annex B parsing handles 3- and 4-byte start codes")
    func annexBParsing() {
        let stream: [UInt8] = [0, 0, 0, 1, 0x67, 0xAA, 0xBB,   // SPS
                               0, 0, 1, 0x68, 0xCC,             // PPS, 3-byte start code
                               0, 0, 0, 1, 0x65, 0x01, 0x02]    // IDR slice
        let units = stream.withUnsafeBytes { AnnexB.nalUnits(in: $0) }
        #expect(units == [4..<7, 10..<12, 16..<19])
    }

    @Test("NAL kinds for H.264 and H.265")
    func nalKinds() {
        #expect(NALKind(h264Header: 0x67) == .sequenceParameterSet)
        #expect(NALKind(h264Header: 0x68) == .pictureParameterSet)
        #expect(NALKind(h264Header: 0x65) == .keyframe)
        #expect(NALKind(h264Header: 0x41) == .frame)
        #expect(NALKind(h264Header: 0x06) == .other)
        #expect(NALKind(h265Header: 0x40) == .videoParameterSet)   // type 32
        #expect(NALKind(h265Header: 0x42) == .sequenceParameterSet)
        #expect(NALKind(h265Header: 0x44) == .pictureParameterSet)
        #expect(NALKind(h265Header: 0x26) == .keyframe)            // type 19, IDR_W_RADL
        #expect(NALKind(h265Header: 0x02) == .frame)               // type 1, TRAIL_R
    }

    @Test("H.264 frames survive the trip and decode", arguments: [VideoCodec.h264, .h265])
    func roundTrip(codec: VideoCodec) throws {
        let width = 640, height = 480, frameCount = 30
        guard let encoded = try SyntheticStream.encode(codec: codec, width: width, height: height, frames: frameCount) else {
            // No hardware encoder for this codec on this Mac.
            return
        }
        #expect(encoded.count == frameCount)

        let assembler = VideoStreamAssembler()
        assembler.reset(codec: codec)
        let decoder = try FrameDecoder()
        var keyframes = 0
        var sizeReports: [CMVideoDimensions] = []

        for annexB in encoded {
            let frame = try annexB.withUnsafeBytes { try assembler.assemble($0) }
            let assembled = try #require(frame)
            if assembled.isKeyframe { keyframes += 1 }
            if let size = assembled.newDimensions { sizeReports.append(size) }
            try decoder.decode(assembled.sampleBuffer)
        }
        decoder.finish()

        #expect(keyframes >= 1)
        #expect(sizeReports.count == 1)
        #expect(sizeReports.first?.width == Int32(width))
        #expect(sizeReports.first?.height == Int32(height))
        #expect(decoder.decodedFrames == frameCount)
        #expect(decoder.lastSize == CGSize(width: width, height: height))
        #expect(decoder.errors == 0)
    }

    @Test("Frames before the first keyframe are dropped, not crashed on")
    func waitsForParameterSets() throws {
        guard let encoded = try SyntheticStream.encode(codec: .h264, width: 320, height: 240, frames: 5) else { return }
        let assembler = VideoStreamAssembler()
        assembler.reset(codec: .h264)
        // Strip the parameter sets from the first frame, as if we joined mid-stream.
        let withoutSets = SyntheticStream.removingParameterSets(encoded[1])
        let frame = try withoutSets.withUnsafeBytes { try assembler.assemble($0) }
        #expect(frame == nil)
    }
}

// MARK: - Helpers

/// Encodes synthetic pictures and repackages them the way UxPlay delivers
/// mirrored video: Annex B, with parameter sets in front of keyframes.
enum SyntheticStream {
    static func encode(codec: VideoCodec, width: Int, height: Int, frames: Int) throws -> [Data]? {
        var session: VTCompressionSession?
        let type = codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: type,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { return nil }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 1000 as CFNumber)

        let collector = OutputCollector(codec: codec)
        for index in 0..<frames {
            let pixelBuffer = try makePixelBuffer(width: width, height: height, shade: UInt8(index * 7 % 255))
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            let encodeStatus = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixelBuffer, presentationTimeStamp: time, duration: .invalid,
                frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sampleBuffer in
                guard status == noErr, let sampleBuffer else { return }
                collector.add(sampleBuffer)
            }
            guard encodeStatus == noErr else { return nil }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return collector.frames
    }

    static func removingParameterSets(_ annexB: Data) -> Data {
        annexB.withUnsafeBytes { buffer in
            var out = Data()
            for unit in AnnexB.nalUnits(in: buffer) {
                let kind = NALKind(h264Header: buffer[unit.lowerBound])
                guard !kind.isParameterSet else { continue }
                out.append(contentsOf: [0, 0, 0, 1])
                out.append(contentsOf: buffer[unit])
            }
            return out
        }
    }

    private static func makePixelBuffer(width: Int, height: Int, shade: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for row in 0..<height {
            memset(base + row * bytesPerRow, Int32(shade &+ UInt8(truncatingIfNeeded: row)), width * 4)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    /// Converts encoder output (length-prefixed NALs) into Annex B.
    private final class OutputCollector: @unchecked Sendable {
        let codec: VideoCodec
        private let lock = NSLock()
        private var collected: [Data] = []

        init(codec: VideoCodec) { self.codec = codec }

        var frames: [Data] { lock.withLock { collected } }

        func add(_ sampleBuffer: CMSampleBuffer) {
            var annexB = Data()
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CFString: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            if !notSync, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
                for set in parameterSets(format) {
                    annexB.append(contentsOf: [0, 0, 0, 1])
                    annexB.append(set)
                }
            }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { return }
            let bytes = UnsafeRawBufferPointer(start: pointer, count: length)
            var offset = 0
            while offset + 4 <= length {
                let size = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian)
                annexB.append(contentsOf: [0, 0, 0, 1])
                annexB.append(contentsOf: bytes[(offset + 4)..<(offset + 4 + size)])
                offset += 4 + size
            }
            lock.withLock { collected.append(annexB) }
        }

        private func parameterSets(_ format: CMFormatDescription) -> [Data] {
            var count = 0
            let getter: (Int, UnsafeMutablePointer<UnsafePointer<UInt8>?>, UnsafeMutablePointer<Int>) -> OSStatus = {
                index, pointer, size in
                switch self.codec {
                case .h264:
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format, parameterSetIndex: index, parameterSetPointerOut: pointer,
                        parameterSetSizeOut: size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                case .h265:
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        format, parameterSetIndex: index, parameterSetPointerOut: pointer,
                        parameterSetSizeOut: size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                }
            }
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard getter(0, &pointer, &size) == noErr, let first = pointer else { return [] }
            var sets = [Data(bytes: first, count: size)]
            for index in 1..<max(count, 1) {
                if getter(index, &pointer, &size) == noErr, let pointer {
                    sets.append(Data(bytes: pointer, count: size))
                }
            }
            return sets
        }
    }
}

/// Decodes sample buffers with VideoToolbox, standing in for the display layer.
final class FrameDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private let lock = NSLock()
    private(set) var decodedFrames = 0
    private(set) var errors = 0
    private(set) var lastSize = CGSize.zero

    init() throws {}

    func decode(_ sampleBuffer: CMSampleBuffer) throws {
        let sampleFormat = try #require(CMSampleBufferGetFormatDescription(sampleBuffer))
        if session == nil || format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: sampleFormat) }) ?? true {
            if let session { VTDecompressionSessionInvalidate(session) }
            var newSession: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: nil, formatDescription: sampleFormat, decoderSpecification: nil,
                imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &newSession)
            try #require(status == noErr)
            session = newSession
            format = sampleFormat
        }
        let status = VTDecompressionSessionDecodeFrame(
            session!, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil
        ) { [self] status, _, imageBuffer, _, _ in
            lock.withLock {
                if status == noErr, let imageBuffer {
                    decodedFrames += 1
                    lastSize = CGSize(width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer))
                } else {
                    errors += 1
                }
            }
        }
        if status != noErr {
            lock.withLock { errors += 1 }
        }
    }

    func finish() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }
}
