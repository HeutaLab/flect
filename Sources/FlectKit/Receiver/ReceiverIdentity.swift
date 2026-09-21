// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import Foundation
import SystemConfiguration

/// The identity this Mac presents to devices. It stays the same between
/// launches, so iPads keep recognising the receiver.
public struct ReceiverIdentity: Sendable {
    public let deviceID: String
    /// Private pairing key, created on first start.
    public let keyFile: URL?

    private static let deviceIDKey = "deviceID"

    public static func load(defaults: UserDefaults = .standard) -> ReceiverIdentity {
        let deviceID: String
        if let saved = defaults.string(forKey: deviceIDKey), isValidDeviceID(saved) {
            deviceID = saved
        } else {
            deviceID = randomDeviceID()
            defaults.set(deviceID, forKey: deviceIDKey)
        }
        return ReceiverIdentity(deviceID: deviceID, keyFile: keyFileURL())
    }

    /// Keeps the pairing key readable by this user only.
    public func protectKeyFile() {
        guard let keyFile, FileManager.default.fileExists(atPath: keyFile.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    }

    /// A random MAC-style address, marked "locally administered" so it can
    /// never clash with real hardware.
    static func randomDeviceID() -> String {
        var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = (bytes[0] & 0xFE) | 0x02
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    static func isValidDeviceID(_ id: String) -> Bool {
        let parts = id.split(separator: ":")
        return parts.count == 6 && parts.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
    }

    private static func keyFileURL() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let folder = support.appendingPathComponent("Flect", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return folder.appendingPathComponent("pairing-key.pem")
    }
}

public enum ReceiverName {
    /// Bonjour allows 63 bytes; AirPlay's audio service adds a 13-byte prefix.
    static let maximumBytes = 50

    /// "Flect – <this Mac's name>".
    public static var suggested: String {
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"
        return sanitized("Flect – \(computer)", fallback: "Flect")
    }

    /// Trims whitespace and control characters and shortens the name to fit.
    public static func sanitized(_ name: String, fallback: String? = nil) -> String {
        var cleaned = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            cleaned = fallback ?? suggested
        }
        while cleaned.utf8.count > maximumBytes {
            cleaned.removeLast()
        }
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
