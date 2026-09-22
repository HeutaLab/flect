// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import CoreMedia
import Darwin
import Foundation
import Testing

@testable import FlectKit

@Suite("Receiver", .serialized)
struct ReceiverTests {
    static let info = "GET /info RTSP/1.0\r\nCSeq: 1\r\n\r\n"

    private func startReceiver(name: String, maxClients: Int = 1,
                               delegate: AirPlayReceiverDelegate) throws -> AirPlayReceiver {
        var configuration = ReceiverConfiguration(name: name, deviceID: ReceiverIdentity.randomDeviceID())
        configuration.advertise = false  // no Bonjour in tests
        configuration.maxClients = maxClients
        let receiver = AirPlayReceiver(configuration: configuration)
        try receiver.start(delegate: delegate)
        return receiver
    }

    @Test("Answers an AirPlay /info request on loopback")
    func answersInfo() throws {
        let hub = MirrorHub(onEvent: { _ in })
        let receiver = try startReceiver(name: "Flect Test", delegate: hub)
        defer { receiver.stop() }
        #expect(receiver.port > 0)

        let response = try LoopbackConnection(port: receiver.port).request(Self.info)
        #expect(response.starts(with: Data("RTSP/1.0 200 OK".utf8)))
        // The body is a binary plist that names the receiver.
        #expect(response.range(of: Data("bplist00".utf8)) != nil)
        #expect(response.range(of: Data("Flect Test".utf8)) != nil)
    }

    @Test("With one device allowed, a second is turned away")
    func oneAtATime() throws {
        let hub = MirrorHub(onEvent: { _ in })
        let receiver = try startReceiver(name: "Flect One", maxClients: 1, delegate: hub)
        defer { receiver.stop() }

        let first = try LoopbackConnection(port: receiver.port)
        #expect(try first.request(Self.info).starts(with: Data("RTSP/1.0 200".utf8)))
        let second = try LoopbackConnection(port: receiver.port)
        #expect(try second.request(Self.info).starts(with: Data("RTSP/1.0 409".utf8)))
    }

    @Test("Several devices connect at once, and one can be dropped on its own")
    func severalAtOnce() throws {
        let recorder = SessionRecorder()
        let receiver = try startReceiver(name: "Flect Many", maxClients: 3, delegate: recorder)
        defer { receiver.stop() }

        let devices = try (0..<3).map { _ in try LoopbackConnection(port: receiver.port) }
        for device in devices {
            #expect(try device.request(Self.info).starts(with: Data("RTSP/1.0 200".utf8)))
        }
        let fourth = try LoopbackConnection(port: receiver.port)
        #expect(try fourth.request(Self.info).starts(with: Data("RTSP/1.0 409".utf8)))

        // Sessions are numbered in the order devices connect.
        receiver.disconnect(session: 2)
        #expect(devices[1].waitForClose(timeout: 3))
        #expect(!devices[0].waitForClose(timeout: 0.3))
        #expect(!devices[2].waitForClose(timeout: 0.3))
        #expect(recorder.endedSessions == [2])

        // Its place is free again.
        let replacement = try LoopbackConnection(port: receiver.port)
        #expect(try replacement.request(Self.info).starts(with: Data("RTSP/1.0 200".utf8)))
    }

    @Test("Twelve devices fit at once")
    func twelveAtOnce() throws {
        let hub = MirrorHub(onEvent: { _ in })
        let receiver = try startReceiver(name: "Flect Twelve", maxClients: 12, delegate: hub)
        defer { receiver.stop() }

        let devices = try (0..<12).map { _ in try LoopbackConnection(port: receiver.port) }
        for device in devices {
            #expect(try device.request(Self.info).starts(with: Data("RTSP/1.0 200".utf8)))
        }
        let thirteenth = try LoopbackConnection(port: receiver.port)
        #expect(try thirteenth.request(Self.info).starts(with: Data("RTSP/1.0 409".utf8)))
    }

    @Test("Stops and starts again cleanly")
    func restarts() throws {
        let hub = MirrorHub(onEvent: { _ in })
        for _ in 0..<3 {
            let receiver = try startReceiver(name: "Flect Restart", delegate: hub)
            #expect(receiver.port > 0)
            receiver.resetConnections()
            receiver.stop()
            #expect(receiver.port == 0)
        }
    }

    @Test("Frames that arrive before the view exists reach it, from the latest keyframe")
    func videoBacklog() {
        let output = VideoOutput()
        let frames = (0..<6).map { _ in EmptySampleBuffer.make() }
        output.enqueue(frames[0], isKeyframe: true)
        output.enqueue(frames[1], isKeyframe: false)
        output.enqueue(frames[2], isKeyframe: true)
        output.enqueue(frames[3], isKeyframe: false)

        let renderer = RecordingRenderer()
        output.attachRenderer(renderer)
        #expect(renderer.received.count == 2)
        #expect(renderer.received.first === frames[2])
        #expect(renderer.received.last === frames[3])

        output.enqueue(frames[4], isKeyframe: false)
        #expect(renderer.received.last === frames[4])
    }

    @Test("Device IDs and names are well formed")
    func identity() {
        for _ in 0..<20 {
            let id = ReceiverIdentity.randomDeviceID()
            #expect(ReceiverIdentity.isValidDeviceID(id))
            let first = UInt8(id.prefix(2), radix: 16)!
            #expect(first & 0x02 == 0x02)  // locally administered
            #expect(first & 0x01 == 0)     // unicast
        }
        #expect(ReceiverName.sanitized("  Room 12\n") == "Room 12")
        #expect(ReceiverName.sanitized(String(repeating: "é", count: 60)).utf8.count <= 50)
        #expect(ReceiverName.sanitized("   ", fallback: "Flect") == "Flect")
    }
}

// MARK: - Helpers

/// Records which sessions ended; ignores everything else.
final class SessionRecorder: AirPlayReceiverDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var ended: [SessionID] = []

    var endedSessions: [SessionID] { lock.withLock { ended } }

    func receiverSessionEnded(_ session: SessionID) { lock.withLock { ended.append(session) } }

    func receiverLog(_ message: String, level: ReceiverLogLevel) {}
    func receiverConnectionsChanged(open: Int) {}
    func receiverShouldAdmit(_ session: SessionID, deviceID: String, model: String, name: String) -> Bool { true }
    func receiverConnectionLost(_ session: SessionID, reason: Int) {}
    func receiverHeartbeat(_ session: SessionID) {}
    func receiverShowCode(_ code: String, session: SessionID) {}
    func receiverAcceptsVideo(_ session: SessionID, isH265: Bool) -> Bool { true }
    func receiverVideoFrame(_ annexB: UnsafeRawBufferPointer, session: SessionID, isH265: Bool) {}
    func receiverVideoSize(_ size: CGSize, session: SessionID) {}
    func receiverVideoPaused(_ paused: Bool, session: SessionID) {}
    func receiverVideoStopped(_ session: SessionID) {}
    func receiverAudioFormat(_ format: AirPlayAudioFormat, session: SessionID) {}
    func receiverAudioPacket(_ packet: UnsafeRawBufferPointer, format: AirPlayAudioFormat, session: SessionID) {}
    func receiverAudioVolume(decibels: Float, session: SessionID) {}
    func receiverAudioFlush(_ session: SessionID) {}
}

final class RecordingRenderer: FrameRenderer {
    private(set) var received: [CMSampleBuffer] = []
    var hasFailed: Bool { false }
    func enqueue(_ sampleBuffer: CMSampleBuffer) { received.append(sampleBuffer) }
    func flush() {}
    func clearImage() {}
}

enum EmptySampleBuffer {
    static func make() -> CMSampleBuffer {
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: nil, formatDescription: nil, sampleCount: 0,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0,
                                  sampleSizeArray: nil, sampleBufferOut: &buffer)
        return buffer!
    }
}

/// A blocking TCP connection to the receiver that stays open, standing in
/// for a device.
final class LoopbackConnection {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket() failed") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw Failure(description: "connect() failed: \(errno)")
        }
    }

    deinit {
        close(fd)
    }

    func request(_ text: String, timeout: TimeInterval = 5) throws -> Data {
        let bytes = Array(text.utf8)
        guard send(fd, bytes, bytes.count, 0) == bytes.count else { throw Failure(description: "send() failed") }
        setTimeout(timeout)
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count <= 0 { break }
            response.append(contentsOf: chunk[0..<count])
            if let header = response.range(of: Data("\r\n\r\n".utf8)),
               response.count - header.upperBound >= contentLength(response[..<header.lowerBound]) {
                break
            }
        }
        return response
    }

    /// Whether the receiver closes the connection within `timeout`.
    func waitForClose(timeout: TimeInterval) -> Bool {
        setTimeout(timeout)
        var byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = recv(fd, &byte, 1, 0)
            if count == 0 { return true }                                  // orderly close
            if count < 0 { return errno != EAGAIN && errno != EWOULDBLOCK }  // reset counts as closed
        }
        return false
    }

    private func setTimeout(_ timeout: TimeInterval) {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func contentLength(_ header: Data) -> Int {
        let text = String(decoding: header, as: UTF8.self).lowercased()
        guard let line = text.split(separator: "\r\n").first(where: { $0.hasPrefix("content-length:") }) else { return 0 }
        return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
    }
}
