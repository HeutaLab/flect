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

    @Test("A tall window stacks iPads")
    func tallWindow() {
        let tall = CGSize(width: 800, height: 1200)
        #expect(TileGrid.best(count: 2, in: tall, aspectRatios: [iPad, iPad], spacing: 6) == (1, 2))
    }
}
