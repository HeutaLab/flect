// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AVFoundation

/// Hands frames to whichever renderer is on screen. Safe from any thread.
///
/// Attach one renderer for the life of the app: mirroring streams send few
/// keyframes, so a renderer attached mid-stream may stay blank for a while.
public final class VideoOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var renderer: AVSampleBufferVideoRenderer?

    public init() {}

    public func attach(_ renderer: AVSampleBufferVideoRenderer?) {
        lock.withLock { self.renderer = renderer }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock {
            guard let renderer else { return }
            if renderer.status == .failed {
                // A decode error stops the renderer until it is flushed.
                renderer.flush()
            }
            renderer.enqueue(sampleBuffer)
        }
    }

    /// Removes the last picture, e.g. when mirroring ends.
    func clear() {
        lock.withLock {
            renderer?.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }
}
