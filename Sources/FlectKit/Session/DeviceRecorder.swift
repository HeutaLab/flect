// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AVFoundation

/// Where saved files go, and what they're called.
public enum SavedFile {
    /// "Maddy's iPad 2026-09-23 at 11.05.12.png", safe to use as a file name.
    public static func name(deviceName: String, date: Date = Date(), extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let cleaned = deviceName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty ? "iPad" : cleaned
        return "\(name) \(formatter.string(from: date)).\(ext)"
    }

    static func folder(_ directory: FileManager.SearchPathDirectory, fallback: String) -> URL {
        let base = FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallback)
        return base.appendingPathComponent("Flect", isDirectory: true)
    }

    /// Recordings go to Movies ▸ Flect.
    public static func recordingsFolder() -> URL {
        folder(.moviesDirectory, fallback: "Movies")
    }
}

public struct RecordingSummary: Sendable, Equatable {
    public let url: URL
    public let duration: TimeInterval
}

/// Writes one device's screen to a QuickTime movie.
///
/// The video is stored exactly as the device sent it, with no re-encoding,
/// so recording costs almost nothing. Sound is encoded to AAC, because
/// AirPlay's audio format isn't one that video files handle well. Both
/// carry the device's own timestamps, so they stay in step.
final class DeviceRecorder: @unchecked Sendable {
    let url: URL

    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private var sessionStart: CMTime?
    private var lastTime: CMTime?
    private var audioSamples = 0
    private var failure: Error?

    enum Failure: LocalizedError {
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .cannotWrite(let reason): reason
            }
        }
    }

    init(url: URL, withAudio: Bool) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // No output settings: the frames are written through as they arrived.
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw Failure.cannotWrite("Flect could not start a recording for this device.")
        }
        writer.add(videoInput)

        if withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AirPlayAudioFormat.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            audioInput = writer.canAdd(input) ? input : nil
            if let audioInput {
                writer.add(audioInput)
            }
        } else {
            audioInput = nil
        }
    }

    var duration: TimeInterval {
        lock.withLock {
            guard let sessionStart, let lastTime else { return 0 }
            return max(0, (lastTime - sessionStart).seconds)
        }
    }

    /// Recording starts with the first picture, so the file begins with one.
    func append(video sampleBuffer: CMSampleBuffer) {
        lock.withLock {
            guard failure == nil else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard time.isValid else { return }
            if sessionStart == nil {
                guard writer.startWriting() else {
                    failure = writer.error ?? Failure.cannotWrite("Flect could not start writing the recording.")
                    return
                }
                writer.startSession(atSourceTime: time)
                sessionStart = time
            }
            lastTime = time
            guard videoInput.isReadyForMoreMediaData else { return }  // dropped rather than queued up
            if !videoInput.append(sampleBuffer) {
                failure = writer.error ?? Failure.cannotWrite("Flect could not add to the recording.")
            }
        }
    }

    func append(audio buffer: AVAudioPCMBuffer, at time: CMTime) {
        lock.withLock {
            guard failure == nil, let audioInput, sessionStart != nil, time.isValid else { return }
            guard audioInput.isReadyForMoreMediaData, let sample = Self.sampleBuffer(from: buffer, at: time) else { return }
            if audioInput.append(sample) {
                audioSamples += 1
            }
        }
    }

    /// Closes the file. Returns how long it runs, or why it failed.
    func finish() async -> Result<RecordingSummary, Error> {
        let (failure, started, length): (Error?, Bool, TimeInterval) = lock.withLock {
            let started = sessionStart != nil
            let length = sessionStart.flatMap { start in lastTime.map { max(0, ($0 - start).seconds) } } ?? 0
            if started {
                // Only valid once writing has begun.
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
            }
            return (self.failure, started, length)
        }
        guard started else {
            try? FileManager.default.removeItem(at: url)
            return .failure(failure ?? Failure.cannotWrite("Nothing was recorded: the device sent no picture."))
        }
        await writer.finishWriting()
        if let error = failure ?? (writer.status == .failed ? writer.error : nil) {
            try? FileManager.default.removeItem(at: url)
            return .failure(error)
        }
        return .success(RecordingSummary(url: url, duration: length))
    }

    private static func sampleBuffer(from buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                             asbd: buffer.format.streamDescription,
                                             layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil, formatDescriptionOut: &format) == noErr,
              let format
        else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                   sampleCount: CMItemCount(buffer.frameLength), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer
        else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            bufferList: buffer.audioBufferList) == noErr
        else { return nil }
        return sampleBuffer
    }
}
