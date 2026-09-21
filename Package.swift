// swift-tools-version: 6.0
//
// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.
//
// Build the app bundle with scripts/build-app.sh. `swift build` and
// `swift test` work for development.

import Foundation
import PackageDescription

/// OpenSSL's libcrypto is linked statically. The first match wins:
/// FLECT_OPENSSL_PREFIX, then build/openssl (universal, macOS 14+, from
/// scripts/build-openssl.sh), then Homebrew or MacPorts (this Mac only).
let opensslPrefix: String = {
    if let prefix = ProcessInfo.processInfo.environment["FLECT_OPENSSL_PREFIX"], !prefix.isEmpty {
        return prefix
    }
    let candidates = [
        "\(Context.packageDirectory)/build/openssl",
        "/opt/homebrew/opt/openssl@3",
        "/usr/local/opt/openssl@3",
        "/opt/local",
    ]
    return candidates.first { FileManager.default.fileExists(atPath: "\($0)/lib/libcrypto.a") }
        ?? candidates[0]
}()

let package = Package(
    name: "Flect",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Flect", targets: ["Flect"]),
    ],
    targets: [
        // UxPlay's AirPlay protocol library and libplist (both vendored
        // unmodified by scripts/vendor.sh) plus Flect's C bridge.
        .target(
            name: "AirPlayCore",
            exclude: [
                "uxplay/LICENSE",
                "uxplay/VERSION",
                "uxplay/playfair/LICENSE.md",
                "uxplay/llhttp/LICENSE-MIT",
                "libplist/COPYING.LESSER",
                "libplist/VERSION",
            ],
            cSettings: [
                .headerSearchPath("uxplay"),
                .headerSearchPath("uxplay/playfair"),
                .headerSearchPath("uxplay/llhttp"),
                .headerSearchPath("libplist/include"),
                .headerSearchPath("libplist/src"),
                .headerSearchPath("libplist/libcnary/include"),
                // UxPlay: libplist API level.
                .define("PLIST_210"),
                .define("PLIST_230"),
                // libplist: what autoconf would have detected on macOS.
                .define("LIBPLIST_STATIC"),
                .define("HAVE_GMTIME_R"),
                .define("HAVE_LOCALTIME_R"),
                .define("HAVE_MEMMEM"),
                .define("HAVE_STRNDUP"),
                .define("HAVE_STRPTIME"),
                .define("HAVE_TIMEGM"),
                .define("HAVE_TM_TM_GMTOFF"),
                .define("HAVE_TM_TM_ZONE"),
                .define("PACKAGE_VERSION", to: "\"2.7.0\""),
                // The vendored code stores sizes in ints throughout; this is noise.
                .unsafeFlags(["-I\(opensslPrefix)/include", "-Wno-shorten-64-to-32"]),
            ],
            linkerSettings: [
                .unsafeFlags(["\(opensslPrefix)/lib/libcrypto.a"]),
            ]
        ),
        // Receiver, video and audio pipelines. No UI.
        .target(
            name: "FlectKit",
            dependencies: ["AirPlayCore"]
        ),
        // The SwiftUI app.
        .executableTarget(
            name: "Flect",
            dependencies: ["FlectKit"]
        ),
        .testTarget(
            name: "FlectKitTests",
            dependencies: ["FlectKit"]
        ),
    ]
)
