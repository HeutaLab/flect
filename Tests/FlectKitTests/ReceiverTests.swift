// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import Darwin
import Foundation
import Testing

@testable import FlectKit

@Suite("Receiver", .serialized)
struct ReceiverTests {
    @Test("Answers an AirPlay /info request on loopback")
    func answersInfo() throws {
        var configuration = ReceiverConfiguration(name: "Flect Test", deviceID: ReceiverIdentity.randomDeviceID())
        configuration.advertise = false  // no Bonjour in tests
        let receiver = AirPlayReceiver(configuration: configuration)
        let session = MirrorSession(onEvent: { _ in })
        try receiver.start(delegate: session)
        defer { receiver.stop() }

        let port = receiver.port
        #expect(port > 0)

        let response = try LoopbackClient.request("GET /info RTSP/1.0\r\nCSeq: 1\r\n\r\n", port: port)
        #expect(response.starts(with: Data("RTSP/1.0 200 OK".utf8)))
        // The body is a binary plist that names the receiver.
        #expect(response.range(of: Data("bplist00".utf8)) != nil)
        #expect(response.range(of: Data("Flect Test".utf8)) != nil)
    }

    @Test("Stops and starts again cleanly")
    func restarts() throws {
        var configuration = ReceiverConfiguration(name: "Flect Restart", deviceID: ReceiverIdentity.randomDeviceID())
        configuration.advertise = false
        let session = MirrorSession(onEvent: { _ in })
        for _ in 0..<3 {
            let receiver = AirPlayReceiver(configuration: configuration)
            try receiver.start(delegate: session)
            #expect(receiver.port > 0)
            receiver.resetConnections()
            receiver.stop()
            #expect(receiver.port == 0)
        }
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

/// Minimal blocking TCP client for talking to the receiver in tests.
enum LoopbackClient {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func request(_ text: String, port: UInt16, timeout: TimeInterval = 5) throws -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket() failed") }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

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
        guard connected == 0 else { throw Failure(description: "connect() failed: \(errno)") }

        let bytes = Array(text.utf8)
        guard send(fd, bytes, bytes.count, 0) == bytes.count else { throw Failure(description: "send() failed") }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count <= 0 { break }
            response.append(contentsOf: chunk[0..<count])
            if let header = response.range(of: Data("\r\n\r\n".utf8)),
               let length = contentLength(response[..<header.lowerBound]),
               response.count - header.upperBound >= length {
                break
            }
        }
        return response
    }

    private static func contentLength(_ header: Data) -> Int? {
        let text = String(decoding: header, as: UTF8.self).lowercased()
        guard let line = text.split(separator: "\r\n").first(where: { $0.hasPrefix("content-length:") }) else { return 0 }
        return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
    }
}
