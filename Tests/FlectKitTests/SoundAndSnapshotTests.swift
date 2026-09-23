// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import CoreVideo
import Foundation
import ImageIO
import Testing

@testable import FlectKit

@Suite("Sound and snapshots")
struct SoundAndSnapshotTests {
    @Test("The device heard is the enlarged one, else the first to connect")
    func whoIsHeard() {
        let order: [SessionID] = [7, 8, 9]
        #expect(MirrorHub.audibleSession(focused: nil, order: order, muted: [], soundOn: true) == 7)
        #expect(MirrorHub.audibleSession(focused: 9, order: order, muted: [], soundOn: true) == 9)
        // A device that has gone: fall back to the first.
        #expect(MirrorHub.audibleSession(focused: 42, order: order, muted: [], soundOn: true) == 7)
        #expect(MirrorHub.audibleSession(focused: nil, order: [], muted: [], soundOn: true) == nil)
    }

    @Test("Sound off, or that device muted, means silence — not the next device")
    func muting() {
        let order: [SessionID] = [7, 8, 9]
        #expect(MirrorHub.audibleSession(focused: nil, order: order, muted: [], soundOn: false) == nil)
        #expect(MirrorHub.audibleSession(focused: nil, order: order, muted: [7], soundOn: true) == nil)
        #expect(MirrorHub.audibleSession(focused: 9, order: order, muted: [9], soundOn: true) == nil)
        // Muting one device doesn't silence the one being heard.
        #expect(MirrorHub.audibleSession(focused: nil, order: order, muted: [8, 9], soundOn: true) == 7)
    }

    @Test("Snapshot file names carry the device and the time, and are safe to use")
    func fileNames() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)  // fixed instant
        let name = Snapshot.fileName(deviceName: "Maddy's iPad", date: date)
        #expect(name.hasPrefix("Maddy's iPad "))
        #expect(name.hasSuffix(".png"))
        #expect(!Snapshot.fileName(deviceName: "Year 5/6 iPad: red", date: date).contains("/"))
        #expect(!Snapshot.fileName(deviceName: "Year 5/6 iPad: red", date: date).contains(":"))
        #expect(Snapshot.fileName(deviceName: "  ", date: date).hasPrefix("iPad "))
    }

    @Test("A snapshot is written as a PNG of the right size")
    func writesPNG() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("flect-snapshot-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let picture = try makePixelBuffer(width: 64, height: 48)
        let url = try Snapshot.write(picture, deviceName: "Red7", to: folder)

        #expect(FileManager.default.fileExists(atPath: url.path))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetType(source) == "public.png" as CFString)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 64)
        #expect(image.height == 48)
    }

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0x7F,
               CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }
}
