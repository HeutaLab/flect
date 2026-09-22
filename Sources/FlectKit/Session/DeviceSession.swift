// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import CoreGraphics
import Foundation

/// One connected device: its video, its sound, and whether it's still there.
/// Calls arrive from several network threads, so each part has its own lock.
final class DeviceSession: @unchecked Sendable {
    let id: SessionID
    let video = VideoOutput()

    private let videoLock = NSLock()
    private let assembler = VideoStreamAssembler()
    private var videoRunning = false

    private let audioLock = NSLock()
    private var decoder: AudioStreamDecoder?
    private var output: AudioOutput?
    private var gain: Float = 1
    private var audible = false

    private let lifeLock = NSLock()
    private var lastSignOfLife = Date()

    init(id: SessionID) {
        self.id = id
    }

    // MARK: Liveness

    func noteSignOfLife() {
        lifeLock.withLock { lastSignOfLife = Date() }
    }

    /// Devices check in every two seconds while connected.
    func isStalled(timeout: TimeInterval, now: Date) -> Bool {
        lifeLock.withLock { now.timeIntervalSince(lastSignOfLife) > timeout }
    }

    // MARK: Video

    func setCodec(isH265: Bool) {
        videoLock.withLock { assembler.reset(codec: isH265 ? .h265 : .h264) }
    }

    struct FrameResult {
        /// The first picture since mirroring (re)started.
        var started = false
        /// Set when the picture's size changed (first frame, or the device rotated).
        var newSize: CGSize?
    }

    func handleVideo(_ annexB: UnsafeRawBufferPointer, isH265: Bool) throws -> FrameResult {
        let codec: VideoCodec = isH265 ? .h265 : .h264
        let (frame, started): (VideoStreamAssembler.Frame?, Bool) = try videoLock.withLock {
            if assembler.codec != codec {
                assembler.reset(codec: codec)
            }
            guard let frame = try assembler.assemble(annexB) else { return (nil, false) }
            let started = !videoRunning
            videoRunning = true
            return (frame, started)
        }
        guard let frame else { return FrameResult() }
        video.enqueue(frame.sampleBuffer, isKeyframe: frame.isKeyframe)
        return FrameResult(started: started, newSize: frame.newSize)
    }

    /// Returns whether video was running.
    @discardableResult
    func stopVideo() -> Bool {
        let wasRunning = videoLock.withLock {
            defer {
                videoRunning = false
                assembler.reset(codec: assembler.codec)
            }
            return videoRunning
        }
        video.clear()
        return wasRunning
    }

    // MARK: Audio

    func setAudioFormat(_ format: AirPlayAudioFormat) -> Bool {
        audioLock.withLock {
            decoder = AudioStreamDecoder(format: format)
            return decoder != nil
        }
    }

    func handleAudio(_ packet: UnsafeRawBufferPointer, format: AirPlayAudioFormat) {
        audioLock.withLock {
            guard audible else { return }
            if decoder?.format != format {
                decoder = AudioStreamDecoder(format: format)
            }
            guard let decoder, let pcm = decoder.decode(packet) else { return }
            if output == nil {
                let newOutput = AudioOutput(format: decoder.outputFormat)
                newOutput.volume = gain
                output = newOutput
            }
            output?.schedule(pcm)
        }
    }

    func setVolume(_ linear: Float) {
        audioLock.withLock {
            gain = linear
            output?.volume = linear
        }
    }

    func flushAudio() {
        audioLock.withLock {
            output?.flush()
            decoder?.reset()
        }
    }

    /// Only one device is heard at a time; the others' sound is dropped.
    func setAudible(_ audible: Bool) {
        let stopped: AudioOutput? = audioLock.withLock {
            self.audible = audible
            guard !audible else { return nil }
            decoder?.reset()
            defer { output = nil }
            return output
        }
        stopped?.stop()
    }

    func stop() {
        stopVideo()
        setAudible(false)
    }
}
