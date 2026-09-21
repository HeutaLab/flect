// Draws Flect's app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: s, y: s)

    // Rounded-square body on the standard macOS icon grid.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    context.addPath(body)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [CGColor(srgbRed: 0.09, green: 0.66, blue: 0.64, alpha: 1),
                 CGColor(srgbRed: 0.15, green: 0.36, blue: 0.86, alpha: 1)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.restoreGState()

    // The iPad's screen and its reflection on the Mac.
    let screenSize = CGSize(width: 440, height: 316)
    let reflection = CGRect(origin: CGPoint(x: 330, y: 398), size: screenSize)
    let screen = CGRect(origin: CGPoint(x: 254, y: 310), size: screenSize)

    context.addPath(CGPath(roundedRect: reflection, cornerWidth: 44, cornerHeight: 44, transform: nil))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35))
    context.fillPath()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40,
                      color: CGColor(srgbRed: 0, green: 0.1, blue: 0.3, alpha: 0.35))
    context.addPath(CGPath(roundedRect: screen, cornerWidth: 44, cornerHeight: 44, transform: nil))
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // A brush stroke on the screen: a nod to drawing demos.
    let stroke = CGMutablePath()
    stroke.move(to: CGPoint(x: 318, y: 402))
    stroke.addCurve(to: CGPoint(x: 630, y: 540),
                    control1: CGPoint(x: 420, y: 560), control2: CGPoint(x: 500, y: 380))
    context.addPath(stroke)
    context.setStrokeColor(CGColor(srgbRed: 0.15, green: 0.45, blue: 0.86, alpha: 1))
    context.setLineWidth(30)
    context.setLineCap(.round)
    context.strokePath()

    return context.makeImage()!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let url = iconset.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, drawIcon(size: base * scale), nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(name)") }
    }
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
