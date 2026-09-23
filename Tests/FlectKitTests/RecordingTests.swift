// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AVFoundation
import Foundation
import Testing

@testable import FlectKit

@Suite("Recording", .serialized)
struct RecordingTests {
    @Test("A recording opens as a movie of the right size and length")
    func videoOnly() async throws {
        let url = Self.temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = try DeviceRecorder(url: url, withAudio: false)
        for frame in try Self.frames(width: 640, height: 480, count: 30) {
            recorder.append(video: frame)
            usleep(2000)  // let the writer keep up, as it would in real time
        }
        let summary = try await recorder.finish().get()

        #expect(summary.url == url)
        #expect(abs(summary.duration - 29.0 / 30.0) < 0.05)

        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        #expect(video.count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await video[0].load(.naturalSize) == CGSize(width: 640, height: 480))
        #expect(try await asset.load(.duration).seconds > 0.5)
    }

    @Test("Sound is recorded alongside the picture")
    func withAudio() async throws {
        let url = Self.temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = try DeviceRecorder(url: url, withAudio: true)
        let tone = SyntheticAudio.sine(seconds: 0.1)
        for (index, frame) in try Self.frames(width: 320, height: 240, count: 30).enumerated() {
            recorder.append(video: frame)
            // Roughly a tenth of a second of sound for every three frames.
            if index % 3 == 0 {
                recorder.append(audio: tone, at: CMTime(value: CMTimeValue(index), timescale: 30))
            }
            usleep(2000)
        }
        let summary = try await recorder.finish().get()
        #expect(summary.duration > 0.5)

        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test("A device rotating mid-recording doesn't spoil the file")
    func pictureSizeChanges() async throws {
        let url = Self.temporaryMovie()
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = try DeviceRecorder(url: url, withAudio: false)
        for frame in try Self.frames(width: 640, height: 480, count: 15) {
            recorder.append(video: frame)
            usleep(2000)
        }
        for frame in try Self.frames(width: 480, height: 640, count: 15, startingAt: CMTime(value: 15, timescale: 30)) {
            recorder.append(video: frame)
            usleep(2000)
        }
        let summary = try await recorder.finish().get()
        #expect(summary.duration > 0.5)
        #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).count == 1)
    }

    @Test("A recording that never saw a picture leaves no file behind")
    func nothingRecorded() async throws {
        let url = Self.temporaryMovie()
        let recorder = try DeviceRecorder(url: url, withAudio: false)
        let result = await recorder.finish()
        #expect(throws: (any Error).self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Lengths read as minutes and seconds")
    func lengths() {
        #expect(ReceiverControllerLength.format(0) == "0:00")
        #expect(ReceiverControllerLength.format(9.4) == "0:09")
        #expect(ReceiverControllerLength.format(74) == "1:14")
        #expect(ReceiverControllerLength.format(3600) == "60:00")
    }

    // MARK: Helpers

    private static func temporaryMovie() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flect-recording-\(UUID().uuidString).mov")
    }

    /// Real encoded frames, timed a thirtieth of a second apart.
    private static func frames(width: Int, height: Int, count: Int,
                               startingAt start: CMTime = .zero) throws -> [CMSampleBuffer] {
        guard let encoded = try SyntheticStream.encode(codec: .h264, width: width, height: height, frames: count) else {
            return []
        }
        let assembler = VideoStreamAssembler()
        assembler.reset(codec: .h264)
        var frames: [CMSampleBuffer] = []
        for (index, annexB) in encoded.enumerated() {
            let time = CMTimeAdd(start, CMTime(value: CMTimeValue(index), timescale: 30))
            if let frame = try annexB.withUnsafeBytes({ try assembler.assemble($0, presentationTime: time) }) {
                frames.append(frame.sampleBuffer)
            }
        }
        return frames
    }
}

/// The same formatting the window uses for recording badges.
enum ReceiverControllerLength {
    static func format(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
