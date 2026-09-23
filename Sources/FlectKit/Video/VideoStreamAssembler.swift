// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import CoreMedia
import Foundation

public enum VideoCodec: Sendable {
    case h264
    case h265
}

enum VideoAssemblyError: Error {
    case badParameterSets(OSStatus)
    case sampleBuffer(OSStatus)
}

/// Turns AirPlay's Annex B frames into sample buffers AVFoundation can
/// decode in hardware. It keeps track of the parameter sets (which arrive
/// in front of keyframes), builds the format description from them, and
/// rewrites start codes as the 4-byte lengths CoreMedia expects.
///
/// Not thread-safe: use from one thread at a time.
final class VideoStreamAssembler {
    struct Frame {
        let sampleBuffer: CMSampleBuffer
        let isKeyframe: Bool
        /// Set when this frame starts a new picture size (e.g. the iPad
        /// rotated): the size as shown, after any cropping.
        let newSize: CGSize?
    }

    private(set) var codec: VideoCodec = .h264
    private(set) var formatDescription: CMVideoFormatDescription?
    private var parameterSets: [NALKind: [UInt8]] = [:]

    func reset(codec: VideoCodec) {
        self.codec = codec
        formatDescription = nil
        parameterSets = [:]
    }

    func assemble(_ annexB: UnsafeRawBufferPointer, presentationTime: CMTime) throws -> Frame? {
        let bytes = annexB.bindMemory(to: UInt8.self)
        guard let base = bytes.baseAddress else { return nil }

        var incomingSets: [NALKind: [UInt8]] = [:]
        var pictureUnits: [Range<Int>] = []
        var hasPicture = false
        var isKeyframe = false

        for unit in AnnexB.nalUnits(in: annexB) {
            let header = bytes[unit.lowerBound]
            let kind = codec == .h264 ? NALKind(h264Header: header) : NALKind(h265Header: header)
            switch kind {
            case .videoParameterSet, .sequenceParameterSet, .pictureParameterSet:
                incomingSets[kind] = Array(bytes[unit])
            case .accessUnitDelimiter:
                continue
            case .keyframe:
                isKeyframe = true
                hasPicture = true
                pictureUnits.append(unit)
            case .frame:
                hasPicture = true
                pictureUnits.append(unit)
            case .other:
                pictureUnits.append(unit)
            }
        }

        var newSize: CGSize?
        if !incomingSets.isEmpty {
            let merged = parameterSets.merging(incomingSets) { _, new in new }
            if merged != parameterSets || formatDescription == nil {
                parameterSets = merged
                if let description = try makeFormatDescription() {
                    let old = formatDescription.map(Self.displaySize)
                    let size = Self.displaySize(description)
                    if old != size {
                        newSize = size
                    }
                    formatDescription = description
                }
            }
        }

        // Until the first keyframe's parameter sets arrive there is nothing to decode against.
        guard hasPicture, let formatDescription else { return nil }

        let length = pictureUnits.reduce(0) { $0 + 4 + $1.count }
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw VideoAssemblyError.sampleBuffer(status)
        }

        var destination: UnsafeMutablePointer<CChar>?
        status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &destination)
        guard status == kCMBlockBufferNoErr, let destination else {
            throw VideoAssemblyError.sampleBuffer(status)
        }
        var offset = 0
        for unit in pictureUnits {
            var size = UInt32(unit.count).bigEndian
            memcpy(destination + offset, &size, 4)
            memcpy(destination + offset + 4, base + unit.lowerBound, unit.count)
            offset += 4 + unit.count
        }

        // The timestamp is the device's, for recordings; on screen the frame
        // is shown as soon as it is decoded, which is what mirroring wants.
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else {
            throw VideoAssemblyError.sampleBuffer(status)
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
            as? [NSMutableDictionary], let attachment = attachments.first {
            attachment[kCMSampleAttachmentKey_DisplayImmediately] = true
            attachment[kCMSampleAttachmentKey_NotSync] = !isKeyframe
            attachment[kCMSampleAttachmentKey_DependsOnOthers] = !isKeyframe
        }

        return Frame(sampleBuffer: sampleBuffer, isKeyframe: isKeyframe, newSize: newSize)
    }

    /// The picture as displayed: the encoder may pad it (1080 lines coded
    /// as 1088, say) and crop the padding off again.
    private static func displaySize(_ description: CMVideoFormatDescription) -> CGSize {
        CMVideoFormatDescriptionGetPresentationDimensions(
            description, usePixelAspectRatio: true, useCleanAperture: true)
    }

    private func makeFormatDescription() throws -> CMVideoFormatDescription? {
        let order: [NALKind] = codec == .h264
            ? [.sequenceParameterSet, .pictureParameterSet]
            : [.videoParameterSet, .sequenceParameterSet, .pictureParameterSet]
        let sets = order.compactMap { parameterSets[$0] }
        guard sets.count == order.count else { return nil }

        let copies = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let copy = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            copy.initialize(from: set, count: set.count)
            return copy
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)

        var description: CMVideoFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        case .h265:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        }
        guard status == noErr else { throw VideoAssemblyError.badParameterSets(status) }
        return description
    }
}
