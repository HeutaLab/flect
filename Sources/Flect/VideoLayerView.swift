// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AVFoundation
import AppKit
import SwiftUI

/// An NSView backed by a sample-buffer display layer, which decodes the
/// mirrored video in hardware and scales it to fit.
final class VideoLayerView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()

    var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func makeBackingLayer() -> CALayer {
        displayLayer
    }

    /// Clicks go through to SwiftUI, which handles them for the tile.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func clear() {
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}

/// Puts a device's video view into SwiftUI.
struct VideoSurface: NSViewRepresentable {
    let view: VideoLayerView

    func makeNSView(context: Context) -> VideoLayerView { view }

    func updateNSView(_ nsView: VideoLayerView, context: Context) {}
}
