// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AVFoundation

/// Plays decoded audio as it arrives, keeping delay low: it waits for a
/// short cushion before starting, and drops audio if it falls too far
/// behind (the iPad's clock and the Mac's never match exactly).
final class AudioOutput: @unchecked Sendable {
    let format: AVAudioFormat

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Guards the engine and player.
    private let engineLock = NSLock()
    private var gain: Float = 1
    /// Guards `queuedFrames` only. Buffer completion handlers take it, and
    /// `player.stop()` may run them synchronously, so it is never held while
    /// calling into the player.
    private let queueLock = NSLock()
    private var queuedFrames: AVAudioFrameCount = 0
    private var observer: NSObjectProtocol?

    /// Start playing once this much is queued (~80 ms).
    private let startThreshold: AVAudioFrameCount
    /// Drop incoming audio while more than this is queued (~300 ms).
    private let maximumQueued: AVAudioFrameCount

    init(format: AVAudioFormat) {
        self.format = format
        startThreshold = AVAudioFrameCount(format.sampleRate * 0.08)
        maximumQueued = AVAudioFrameCount(format.sampleRate * 0.3)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // The output device changed (headphones, AirPlay to the TV...): carry on there.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.restart()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        player.stop()
        engine.stop()
    }

    /// Linear gain, 0...1.
    var volume: Float {
        get { engineLock.withLock { gain } }
        set {
            engineLock.withLock {
                gain = newValue
                player.volume = newValue
            }
        }
    }

    func schedule(_ buffer: AVAudioPCMBuffer) {
        let frames = buffer.frameLength
        let queued: AVAudioFrameCount? = queueLock.withLock {
            guard queuedFrames + frames <= maximumQueued else { return nil }
            queuedFrames += frames
            return queuedFrames
        }
        guard let queued else { return }  // too far behind: skip this packet

        engineLock.withLock {
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    queueLock.withLock { queuedFrames -= min(frames, queuedFrames) }
                    return
                }
            }
            player.scheduleBuffer(buffer) { [weak self] in
                guard let self else { return }
                self.queueLock.withLock { self.queuedFrames -= min(frames, self.queuedFrames) }
            }
            if !player.isPlaying, queued >= startThreshold {
                player.volume = gain
                player.play()
            }
        }
    }

    /// Throws away queued audio, e.g. when the sender pauses or seeks.
    func flush() {
        engineLock.withLock { player.stop() }
        queueLock.withLock { queuedFrames = 0 }
    }

    func stop() {
        engineLock.withLock {
            player.stop()
            engine.stop()
        }
        queueLock.withLock { queuedFrames = 0 }
    }

    private func restart() {
        engineLock.withLock {
            player.stop()
            try? engine.start()
        }
        queueLock.withLock { queuedFrames = 0 }
    }
}
