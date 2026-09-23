// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.
//
// How many devices can one Mac take? These are measurements, not pass/fail
// tests, so they only run when asked:
//
//     FLECT_CAPACITY=24 swift test --filter Capacity

import AVFoundation
import Foundation
import Testing
import VideoToolbox

@testable import FlectKit

@Suite("Capacity", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["FLECT_CAPACITY"] != nil,
                "set FLECT_CAPACITY to the number of devices to measure"))
struct CapacityTests {
    static var devices: Int {
        Int(ProcessInfo.processInfo.environment["FLECT_CAPACITY"] ?? "") ?? 24
    }

    @Test("Connections: that many devices connect, and one more is refused")
    func connections() throws {
        let count = Self.devices
        let hub = MirrorHub(onEvent: { _ in })
        var configuration = ReceiverConfiguration(name: "Flect Capacity",
                                                  deviceID: ReceiverIdentity.randomDeviceID())
        configuration.advertise = false
        configuration.maxClients = count
        let receiver = AirPlayReceiver(configuration: configuration)
        try receiver.start(delegate: hub)
        defer { receiver.stop() }

        var admitted = 0
        var connections: [LoopbackConnection] = []
        for _ in 0..<count {
            let device = try LoopbackConnection(port: receiver.port)
            if try device.request(ReceiverTests.info).starts(with: Data("RTSP/1.0 200".utf8)) {
                admitted += 1
            }
            connections.append(device)
        }
        let extra = try LoopbackConnection(port: receiver.port)
        let refused = try extra.request(ReceiverTests.info).starts(with: Data("RTSP/1.0 409".utf8))

        print("CAPACITY connections: \(admitted) of \(count) admitted, extra refused: \(refused)")
        #expect(admitted == count)
        #expect(refused)
    }

    @Test("Decoding: that many streams decode at once, and how fast")
    func decoding() throws {
        let count = Self.devices
        let size = ProcessInfo.processInfo.environment["FLECT_CAPACITY_SIZE"] ?? "960x540"
        let parts = size.split(separator: "x").compactMap { Int($0) }
        let width = parts.first ?? 960, height = parts.last ?? 540
        let frames = 60  // two seconds at 30 fps
        guard let encoded = try SyntheticStream.encode(codec: .h264, width: width, height: height, frames: frames) else {
            print("CAPACITY decoding: no encoder on this Mac")
            return
        }

        let results = Results()
        let started = Date()
        let cpuBefore = Self.cpuSeconds()
        DispatchQueue.concurrentPerform(iterations: count) { _ in
            do {
                let assembler = VideoStreamAssembler()
                assembler.reset(codec: .h264)
                let decoder = try FrameDecoder()
                for (index, annexB) in encoded.enumerated() {
                    let time = CMTime(value: CMTimeValue(index), timescale: 30)
                    if let frame = try annexB.withUnsafeBytes({ try assembler.assemble($0, presentationTime: time) }) {
                        try decoder.decode(frame.sampleBuffer)
                    }
                }
                decoder.finish()
                results.add(decoded: decoder.decodedFrames, errors: decoder.errors)
            } catch {
                results.add(decoded: 0, errors: frames)
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        let cpu = Self.cpuSeconds() - cpuBefore
        let wanted = Double(count * frames)

        print(String(format: """
            CAPACITY decoding: %d streams of %dx%d, %d frames each
              decoded %d of %.0f frames, %d errors
              %.2fs wall, %.2fs CPU (%.0f%% of one core), %.0f frames a second
              real time needs %d frames a second at 30 fps
            """, count, width, height, frames,
            results.decoded, wanted, results.errors,
            elapsed, cpu, cpu / elapsed * 100, wanted / elapsed, count * 30))

        #expect(results.decoded >= Int(wanted * 0.99))
        #expect(results.errors == 0)
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var decoded = 0
        private(set) var errors = 0

        func add(decoded: Int, errors: Int) {
            lock.withLock {
                self.decoded += decoded
                self.errors += errors
            }
        }
    }
}
