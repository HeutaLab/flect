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
        SavedFile.folder(.picturesDirectory, fallback: "Pictures")
    }

    public static func fileName(deviceName: String, date: Date = Date()) -> String {
        SavedFile.name(deviceName: deviceName, date: date, extension: "png")
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
