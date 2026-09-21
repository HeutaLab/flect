// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import CoreGraphics
import CoreMedia
import Foundation

/// What the UI needs to hear about. Delivered on the receiver's threads.
public enum MirrorEvent: Sendable, Equatable {
    case deviceConnecting(name: String, model: String)
    /// The device is asking its user for this code.
    case showCode(String)
    case connectionsChanged(Int)
    case videoStarted
    /// The picture's size changed (first frame, or the device rotated).
    case videoSize(CGSize)
    case videoPaused(Bool)
    case videoStopped
    /// The device vanished without saying goodbye.
    case connectionLost
}

/// Receives one mirroring device: feeds its video to `video` and plays its
/// sound, and reports what happens through `onEvent`.
public final class MirrorSession: AirPlayReceiverDelegate, @unchecked Sendable {
    public let video = VideoOutput()

    private let onEvent: @Sendable (MirrorEvent) -> Void
    private let onLog: @Sendable (String, ReceiverLogLevel) -> Void

    private let videoLock = NSLock()
    private let assembler = VideoStreamAssembler()
    private var videoRunning = false

    private let audioLock = NSLock()
    private var audioEnabled: Bool
    private var decoder: AudioStreamDecoder?
    private var output: AudioOutput?
    private var gain: Float = 1

    private let stateLock = NSLock()
    private var openConnections = 0
    private var lastSignOfLife = Date()

    public init(
        playsAudio: Bool = true,
        onEvent: @escaping @Sendable (MirrorEvent) -> Void,
        onLog: @escaping @Sendable (String, ReceiverLogLevel) -> Void = { _, _ in }
    ) {
        audioEnabled = playsAudio
        self.onEvent = onEvent
        self.onLog = onLog
    }

    public var playsAudio: Bool {
        get { audioLock.withLock { audioEnabled } }
        set {
            let stopped: AudioOutput? = audioLock.withLock {
                audioEnabled = newValue
                guard !newValue else { return nil }
                defer { output = nil }
                return output
            }
            stopped?.stop()
        }
    }

    /// True when a connected device has been silent for longer than
    /// `timeout`. Devices check in every two seconds while connected.
    public func isStalled(timeout: TimeInterval, now: Date = Date()) -> Bool {
        stateLock.withLock {
            openConnections > 0 && now.timeIntervalSince(lastSignOfLife) > timeout
        }
    }

    // MARK: Connections

    public func receiverLog(_ message: String, level: ReceiverLogLevel) {
        onLog(message, level)
    }

    public func receiverShouldAdmit(deviceID: String, model: String, name: String) -> Bool {
        onEvent(.deviceConnecting(name: name, model: model))
        return true
    }

    public func receiverConnectionsChanged(open: Int) {
        stateLock.withLock {
            openConnections = open
            lastSignOfLife = Date()
        }
        if open == 0 {
            endVideo(notify: true)
            endAudio()
        }
        onEvent(.connectionsChanged(open))
    }

    public func receiverConnectionLost(reason: Int) {
        onEvent(.connectionLost)
    }

    public func receiverHeartbeat() {
        stateLock.withLock { lastSignOfLife = Date() }
    }

    public func receiverShowCode(_ code: String) {
        onEvent(.showCode(code))
    }

    // MARK: Video

    public func receiverAcceptsVideo(isH265: Bool) -> Bool {
        videoLock.withLock { assembler.reset(codec: isH265 ? .h265 : .h264) }
        return true
    }

    public func receiverVideoFrame(_ annexB: UnsafeRawBufferPointer, isH265: Bool) {
        let codec: VideoCodec = isH265 ? .h265 : .h264
        let result: (frame: VideoStreamAssembler.Frame?, started: Bool) = videoLock.withLock {
            if assembler.codec != codec {
                assembler.reset(codec: codec)
            }
            let frame: VideoStreamAssembler.Frame?
            do {
                frame = try assembler.assemble(annexB)
            } catch {
                onLog("Skipped a video frame: \(error)", .warning)
                return (nil, false)
            }
            let started = frame != nil && !videoRunning
            if started {
                videoRunning = true
            }
            return (frame, started)
        }
        guard let frame = result.frame else { return }
        video.enqueue(frame.sampleBuffer)
        if result.started {
            onEvent(.videoStarted)
        }
        if let dimensions = frame.newDimensions {
            onEvent(.videoSize(CGSize(width: Int(dimensions.width), height: Int(dimensions.height))))
        }
    }

    public func receiverVideoSize(_ size: CGSize) {
        onLog("Device screen is \(Int(size.width))×\(Int(size.height))", .info)
    }

    public func receiverVideoPaused(_ paused: Bool) {
        onEvent(.videoPaused(paused))
    }

    public func receiverVideoStopped() {
        endVideo(notify: true)
    }

    public func receiverVideoFlush() {
        // Sent as each connection closes; the last one closing ends the video.
    }

    private func endVideo(notify: Bool) {
        let wasRunning = videoLock.withLock {
            defer {
                videoRunning = false
                assembler.reset(codec: assembler.codec)
            }
            return videoRunning
        }
        video.clear()
        if wasRunning, notify {
            onEvent(.videoStopped)
        }
    }

    // MARK: Audio

    public func receiverAudioFormat(_ format: AirPlayAudioFormat) {
        audioLock.withLock {
            decoder = AudioStreamDecoder(format: format)
            if decoder == nil {
                onLog("This Mac can't decode AirPlay audio format \(format)", .error)
            }
        }
    }

    public func receiverAudioPacket(_ packet: UnsafeRawBufferPointer, format: AirPlayAudioFormat) {
        audioLock.withLock {
            guard audioEnabled else { return }
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

    public func receiverAudioVolume(decibels: Float) {
        let linear = Self.gain(forDecibels: decibels)
        audioLock.withLock {
            gain = linear
            output?.volume = linear
        }
    }

    public func receiverAudioFlush() {
        audioLock.withLock {
            output?.flush()
            decoder?.reset()
        }
    }

    private func endAudio() {
        let stopped: AudioOutput? = audioLock.withLock {
            defer {
                output = nil
                decoder = nil
            }
            return output
        }
        stopped?.stop()
    }

    /// AirPlay volume runs from -30 dB (bottom of the slider) to 0 dB;
    /// -144 dB means mute. Same mapping as UxPlay.
    static func gain(forDecibels decibels: Float) -> Float {
        guard decibels > -30 else { return 0 }
        return powf(10, min(decibels, 0) / 20)
    }
}
