// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AVFoundation
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
    private var muted = false

    private let lifeLock = NSLock()
    private var lastSignOfLife = Date()

    private let clockLock = NSLock()
    /// The device's own clock at its first frame; timestamps count from there.
    private var deviceEpoch: UInt64?

    private let recordLock = NSLock()
    private var recorder: DeviceRecorder?

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

    /// The device's clock, counted from its first frame. Audio and video
    /// share it, which is what keeps a recording in step.
    func time(forDeviceTime deviceTime: UInt64) -> CMTime {
        guard deviceTime > 0 else { return CMClockGetTime(CMClockGetHostTimeClock()) }
        let epoch: UInt64 = clockLock.withLock {
            if let deviceEpoch { return deviceEpoch }
            deviceEpoch = deviceTime
            return deviceTime
        }
        let elapsed = deviceTime >= epoch ? deviceTime - epoch : 0
        return CMTime(value: CMTimeValue(elapsed), timescale: 1_000_000_000)
    }

    func setCodec(isH265: Bool) {
        videoLock.withLock { assembler.reset(codec: isH265 ? .h265 : .h264) }
    }

    struct FrameResult {
        /// The first picture since mirroring (re)started.
        var started = false
        /// Set when the picture's size changed (first frame, or the device rotated).
        var newSize: CGSize?
    }

    func handleVideo(_ annexB: UnsafeRawBufferPointer, isH265: Bool, deviceTime: UInt64) throws -> FrameResult {
        let codec: VideoCodec = isH265 ? .h265 : .h264
        let presentationTime = time(forDeviceTime: deviceTime)
        let (frame, started): (VideoStreamAssembler.Frame?, Bool) = try videoLock.withLock {
            if assembler.codec != codec {
                assembler.reset(codec: codec)
            }
            guard let frame = try assembler.assemble(annexB, presentationTime: presentationTime) else {
                return (nil, false)
            }
            let started = !videoRunning
            videoRunning = true
            return (frame, started)
        }
        guard let frame else { return FrameResult() }
        video.enqueue(frame.sampleBuffer, isKeyframe: frame.isKeyframe)
        currentRecorder?.append(video: frame.sampleBuffer)
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

    func handleAudio(_ packet: UnsafeRawBufferPointer, format: AirPlayAudioFormat, deviceTime: UInt64) {
        // A recording keeps the device's sound even when it is silenced here.
        let recorder = currentRecorder
        audioLock.withLock {
            let play = audible && !muted
            guard play || recorder != nil else { return }
            if decoder?.format != format {
                decoder = AudioStreamDecoder(format: format)
            }
            guard let decoder, let pcm = decoder.decode(packet) else { return }
            recorder?.append(audio: pcm, at: time(forDeviceTime: deviceTime))
            guard play else { return }
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
            return takeOutput()
        }
        stopped?.stop()
    }

    var isMuted: Bool {
        audioLock.withLock { muted }
    }

    /// Silences this device on its own, whether or not it's the one heard.
    func setMuted(_ muted: Bool) {
        let stopped: AudioOutput? = audioLock.withLock {
            self.muted = muted
            guard muted else { return nil }
            return takeOutput()
        }
        stopped?.stop()
    }

    /// Hands back the audio output, if any, to be stopped outside the lock.
    private func takeOutput() -> AudioOutput? {
        decoder?.reset()
        defer { output = nil }
        return output
    }

    func stop() {
        stopVideo()
        setAudible(false)
    }

    // MARK: Recording

    private var currentRecorder: DeviceRecorder? {
        recordLock.withLock { recorder }
    }

    var isRecording: Bool { currentRecorder != nil }

    /// How long the recording has been running, for the badge on screen.
    var recordingDuration: TimeInterval { currentRecorder?.duration ?? 0 }

    func startRecording(to url: URL) throws {
        let hasAudio = audioLock.withLock { decoder != nil }
        let recorder = try DeviceRecorder(url: url, withAudio: hasAudio)
        recordLock.withLock { self.recorder = recorder }
    }

    /// Closes the file. Returns nil when nothing was being recorded.
    func stopRecording() async -> Result<RecordingSummary, Error>? {
        let recorder: DeviceRecorder? = recordLock.withLock {
            defer { self.recorder = nil }
            return self.recorder
        }
        guard let recorder else { return nil }
        return await recorder.finish()
    }
}
