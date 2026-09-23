// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import CoreImage
import CoreVideo
import Foundation

/// Saves a still of what a device is showing.
public enum Snapshot {
    public enum Failure: LocalizedError {
        case couldNotEncode
        case couldNotWrite(String)

        public var errorDescription: String? {
            switch self {
            case .couldNotEncode: "Flect could not turn the picture into an image."
            case .couldNotWrite(let reason): reason
            }
        }
    }

    /// Where snapshots go: Pictures ▸ Flect.
    public static func defaultFolder() -> URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("Flect", isDirectory: true)
    }

    /// "Mia's iPad 2026-09-23 at 11.05.12.png", safe to use as a file name.
    public static func fileName(deviceName: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let cleaned = deviceName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty ? "iPad" : cleaned
        return "\(name) \(formatter.string(from: date)).png"
    }

    /// Writes the picture as a PNG and returns where it went.
    @discardableResult
    public static func write(_ pixelBuffer: CVPixelBuffer, deviceName: String,
                             to folder: URL? = nil, date: Date = Date()) throws -> URL {
        let folder = folder ?? defaultFolder()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Failure.couldNotWrite("Flect could not use the folder \(folder.lastPathComponent): \(error.localizedDescription)")
        }
        let url = folder.appendingPathComponent(fileName(deviceName: deviceName, date: date))
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw Failure.couldNotEncode
        }
        do {
            try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: colorSpace)
        } catch {
            throw Failure.couldNotWrite("Flect could not save the snapshot: \(error.localizedDescription)")
        }
        return url
    }
}
