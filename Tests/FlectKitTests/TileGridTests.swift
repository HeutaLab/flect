// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import CoreGraphics
import Testing

@testable import FlectKit

@Suite("Side-by-side grid")
struct TileGridTests {
    let window = CGSize(width: 1600, height: 1000)  // a 16:10 laptop screen
    let iPad: CGFloat = 4.0 / 3.0                    // landscape
    let iPhone: CGFloat = 9.0 / 19.5                 // portrait

    @Test("One device fills the window")
    func one() {
        #expect(TileGrid.best(count: 1, in: window, aspectRatios: [iPad], spacing: 6) == (1, 1))
    }

    @Test("Two iPads sit side by side, not stacked")
    func twoIPads() {
        #expect(TileGrid.best(count: 2, in: window, aspectRatios: [iPad, iPad], spacing: 6) == (2, 1))
    }

    @Test("Three iPads use two rows; four make a square")
    func threeAndFour() {
        #expect(TileGrid.best(count: 3, in: window, aspectRatios: Array(repeating: iPad, count: 3), spacing: 6) == (2, 2))
        #expect(TileGrid.best(count: 4, in: window, aspectRatios: Array(repeating: iPad, count: 4), spacing: 6) == (2, 2))
    }

    @Test("Portrait phones line up in one row")
    func phones() {
        #expect(TileGrid.best(count: 4, in: window, aspectRatios: Array(repeating: iPhone, count: 4), spacing: 6) == (4, 1))
    }

    @Test("Twelve iPads make a 4 by 3 grid")
    func twelve() {
        #expect(TileGrid.best(count: 12, in: window, aspectRatios: Array(repeating: iPad, count: 12), spacing: 6) == (4, 3))
    }

    @Test("Twenty-four iPads make a 6 by 4 grid")
    func twentyFour() {
        #expect(TileGrid.best(count: 24, in: window, aspectRatios: Array(repeating: iPad, count: 24), spacing: 6) == (6, 4))
    }

    @Test("A picture sits centred at the largest size that fits")
    func pictureFrame() {
        let tile = CGSize(width: 800, height: 500)
        let landscape = TileGrid.pictureFrame(aspectRatio: iPad, in: tile)
        #expect(landscape.height == 500)
        #expect(abs(landscape.width - 666.667) < 0.001)
        #expect(abs(landscape.minX - 66.667) < 0.001)
        let portrait = TileGrid.pictureFrame(aspectRatio: 3.0 / 4.0, in: tile)
        #expect(portrait.height == 500)
        #expect(abs(portrait.midX - 400) < 0.001)
        #expect(TileGrid.pictureFrame(aspectRatio: iPad, in: .zero) == .zero)
    }

    @Test("More devices are asked for smaller pictures")
    func pictureSizes() {
        #expect(ReceiverConfiguration.picture(forDevices: 1) == (1920, 1080, 60))
        #expect(ReceiverConfiguration.picture(forDevices: 4) == (1920, 1080, 60))
        #expect(ReceiverConfiguration.picture(forDevices: 6) == (1280, 720, 30))
        #expect(ReceiverConfiguration.picture(forDevices: 12) == (960, 540, 30))
    }

    @Test("A tall window stacks iPads")
    func tallWindow() {
        let tall = CGSize(width: 800, height: 1200)
        #expect(TileGrid.best(count: 2, in: tall, aspectRatios: [iPad, iPad], spacing: 6) == (1, 2))
    }
}
