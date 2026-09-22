// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AVFoundation

/// Where decoded video goes: in the app, a display layer's renderer.
protocol FrameRenderer: AnyObject {
    var hasFailed: Bool { get }
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush()
    func clearImage()
}

extension AVSampleBufferVideoRenderer: FrameRenderer {
    var hasFailed: Bool { status == .failed }

    func clearImage() {
        flush(removingDisplayedImage: true, completionHandler: nil)
    }
}

/// Hands one device's frames to the renderer showing it. Safe from any thread.
///
/// Mirroring sends few keyframes, and a renderer can't start without one.
/// So frames that arrive before a renderer is attached are kept (from the
/// latest keyframe on) and handed over when it is. Keep a renderer attached
/// for as long as the device is shown.
public final class VideoOutput: @unchecked Sendable {
    /// About ten seconds at 60 fps; normally a renderer is attached within milliseconds.
    static let backlogLimit = 600

    private let lock = NSLock()
    private var renderer: FrameRenderer?
    private var backlog: [CMSampleBuffer] = []

    public init() {}

    public func attach(_ renderer: AVSampleBufferVideoRenderer?) {
        attachRenderer(renderer)
    }

    func attachRenderer(_ renderer: FrameRenderer?) {
        lock.withLock {
            self.renderer = renderer
            guard let renderer else { return }
            for frame in backlog {
                renderer.enqueue(frame)
            }
            backlog.removeAll()
        }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, isKeyframe: Bool) {
        lock.withLock {
            guard let renderer else {
                if isKeyframe {
                    backlog.removeAll()
                }
                if backlog.count < Self.backlogLimit {
                    backlog.append(sampleBuffer)
                }
                return
            }
            if renderer.hasFailed {
                // A decode error stops the renderer until it is flushed.
                renderer.flush()
            }
            renderer.enqueue(sampleBuffer)
        }
    }

    /// Removes the last picture, e.g. when mirroring ends.
    func clear() {
        lock.withLock {
            backlog.removeAll()
            renderer?.clearImage()
        }
    }
}
