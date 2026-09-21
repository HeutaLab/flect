// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

/// Finds NAL units in an Annex B byte stream (NALs separated by
/// 00 00 01 or 00 00 00 01 start codes), which is how the AirPlay library
/// hands over mirrored video.
enum AnnexB {
    /// Byte ranges of each NAL unit, start codes excluded.
    static func nalUnits(in buffer: UnsafeRawBufferPointer) -> [Range<Int>] {
        let bytes = buffer.bindMemory(to: UInt8.self)
        let count = bytes.count
        var units: [Range<Int>] = []
        var start: Int?
        var i = 0
        while i + 2 < count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let unitStart = start {
                    // Zeros before a start code (the first byte of a 4-byte
                    // code, or padding) never belong to the NAL: a NAL cannot
                    // end in 0x00.
                    var end = i
                    while end > unitStart, bytes[end - 1] == 0 { end -= 1 }
                    if end > unitStart { units.append(unitStart..<end) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if let unitStart = start, unitStart < count {
            units.append(unitStart..<count)
        }
        return units
    }
}

/// The NAL unit kinds the pipeline cares about, for H.264 and H.265.
enum NALKind: Hashable {
    case videoParameterSet    // H.265 only
    case sequenceParameterSet
    case pictureParameterSet
    case keyframe             // IDR (H.264) or IRAP (H.265)
    case frame                // any other picture data
    case accessUnitDelimiter
    case other                // SEI and friends, kept alongside the picture

    init(h264Header header: UInt8) {
        switch header & 0x1F {
        case 7: self = .sequenceParameterSet
        case 8: self = .pictureParameterSet
        case 5: self = .keyframe
        case 1...4: self = .frame
        case 9: self = .accessUnitDelimiter
        default: self = .other
        }
    }

    init(h265Header header: UInt8) {
        switch (header >> 1) & 0x3F {
        case 32: self = .videoParameterSet
        case 33: self = .sequenceParameterSet
        case 34: self = .pictureParameterSet
        case 16...23: self = .keyframe   // BLA, IDR, CRA and reserved IRAP types
        case 0...15, 24...31: self = .frame
        case 35: self = .accessUnitDelimiter
        default: self = .other
        }
    }

    var isParameterSet: Bool {
        self == .videoParameterSet || self == .sequenceParameterSet || self == .pictureParameterSet
    }
}
