// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AirPlayCore
import CoreGraphics
import Foundation

/// Who may mirror to this Mac.
public enum ReceiverAccess: Sendable, Equatable {
    /// Anyone on the network.
    case open
    /// A new four-digit code, shown on this screen, for every connection.
    case screenCode
    /// The same password for everyone.
    case password(String)
}

public enum ReceiverLogLevel: Int32, Sendable, Comparable {
    case error = 3
    case warning = 4
    case notice = 5
    case info = 6
    case debug = 7

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct ReceiverConfiguration: Sendable {
    /// Shown in the iPad's Screen Mirroring list.
    public var name: String
    /// Stable "xx:xx:xx:xx:xx:xx" identity, so devices recognise this Mac.
    public var deviceID: String
    /// Where the pairing key is kept. `nil` derives it from `deviceID`.
    public var keyFile: URL?
    public var access: ReceiverAccess = .open
    public var allowH265 = false
    /// The largest picture a device should send.
    public var maxWidth = 1920
    public var maxHeight = 1080
    public var maxFramesPerSecond = 60
    /// Announce the receiver with Bonjour. Tests turn this off.
    public var advertise = true
    public var logLevel: ReceiverLogLevel = .info

    public init(name: String, deviceID: String, keyFile: URL? = nil) {
        self.name = name
        self.deviceID = deviceID
        self.keyFile = keyFile
    }
}

/// Everything the receiver reports. All methods are called on the
/// receiver's own network threads; buffers are only valid during the call.
public protocol AirPlayReceiverDelegate: AnyObject, Sendable {
    func receiverLog(_ message: String, level: ReceiverLogLevel)
    /// Return false to turn the device away.
    func receiverShouldAdmit(deviceID: String, model: String, name: String) -> Bool
    func receiverConnectionsChanged(open: Int)
    /// The connection dropped; the owner should call `resetConnections()`.
    func receiverConnectionLost(reason: Int)
    func receiverHeartbeat()
    func receiverShowCode(_ code: String)

    /// Return false to refuse the codec.
    func receiverAcceptsVideo(isH265: Bool) -> Bool
    func receiverVideoFrame(_ annexB: UnsafeRawBufferPointer, isH265: Bool)
    func receiverVideoSize(_ size: CGSize)
    func receiverVideoPaused(_ paused: Bool)
    func receiverVideoStopped()
    func receiverVideoFlush()

    func receiverAudioFormat(_ format: AirPlayAudioFormat)
    func receiverAudioPacket(_ packet: UnsafeRawBufferPointer, format: AirPlayAudioFormat)
    /// AirPlay volume: -30 dB (quietest) to 0 dB (full); -144 dB is mute.
    func receiverAudioVolume(decibels: Float)
    func receiverAudioFlush()
}

public enum AirPlayReceiverError: LocalizedError {
    case alreadyRunning
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "The receiver is already running."
        case .startFailed(let reason): reason
        }
    }
}

/// Swift face of the AirPlay server (UxPlay's library, via flect_receiver.h).
///
/// `start`, `stop` and `resetConnections` block while network threads wind
/// down, so call them from a background queue, never from a delegate method.
public final class AirPlayReceiver: @unchecked Sendable {
    public let configuration: ReceiverConfiguration

    /// Serialises start, stop and reset. Never taken by callbacks.
    private let lifecycle = NSLock()
    private var handle: OpaquePointer?
    private var context: Unmanaged<CallbackContext>?

    private let portLock = NSLock()
    private var listeningPort: UInt16 = 0

    public init(configuration: ReceiverConfiguration) {
        self.configuration = configuration
    }

    deinit {
        stop()
    }

    /// The TCP port the server listens on, or 0 when stopped.
    public var port: UInt16 {
        portLock.withLock { listeningPort }
    }

    public func start(delegate: AirPlayReceiverDelegate) throws {
        try lifecycle.withLock {
            guard handle == nil else { throw AirPlayReceiverError.alreadyRunning }

            let context = Unmanaged.passRetained(CallbackContext(delegate: delegate))
            var callbacks = Self.makeCallbacks(context: context.toOpaque())

            let name = strdup(configuration.name)
            let deviceID = strdup(configuration.deviceID)
            let keyFile = strdup(configuration.keyFile?.path ?? "")
            var password: UnsafeMutablePointer<CChar>?
            defer {
                free(name)
                free(deviceID)
                free(keyFile)
                free(password)
            }

            var config = flect_config_t()
            config.name = UnsafePointer(name)
            config.device_id = UnsafePointer(deviceID)
            config.key_file = UnsafePointer(keyFile)
            switch configuration.access {
            case .open:
                config.access = FLECT_ACCESS_OPEN
            case .screenCode:
                config.access = FLECT_ACCESS_SCREEN_CODE
            case .password(let secret):
                config.access = FLECT_ACCESS_PASSWORD
                password = strdup(secret)
                config.password = UnsafePointer(password)
            }
            config.allow_h265 = configuration.allowH265
            config.width = Int32(configuration.maxWidth)
            config.height = Int32(configuration.maxHeight)
            config.max_fps = Int32(configuration.maxFramesPerSecond)
            config.advertise = configuration.advertise
            config.log_level = configuration.logLevel.rawValue

            var error = [CChar](repeating: 0, count: 256)
            guard let started = flect_receiver_start(&config, &callbacks, &error, error.count) else {
                context.release()
                let reason = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                throw AirPlayReceiverError.startFailed(reason.isEmpty ? "The AirPlay server did not start." : reason)
            }
            handle = started
            self.context = context
            let port = flect_receiver_port(started)
            portLock.withLock { listeningPort = port }
        }
    }

    public func stop() {
        lifecycle.withLock {
            // Callbacks can still arrive while the server shuts down, so the
            // context is released only afterwards.
            if let handle {
                flect_receiver_stop(handle)
            }
            context?.release()
            handle = nil
            context = nil
            portLock.withLock { listeningPort = 0 }
        }
    }

    /// Drops every connection (for example, a stuck or unwanted device)
    /// and keeps listening on the same port.
    public func resetConnections() {
        lifecycle.withLock {
            if let handle {
                flect_receiver_reset_connections(handle)
            }
        }
    }
}

// MARK: - C callbacks

/// Outlives the C receiver, so callbacks never see a freed object.
private final class CallbackContext: @unchecked Sendable {
    weak var delegate: AirPlayReceiverDelegate?

    init(delegate: AirPlayReceiverDelegate) {
        self.delegate = delegate
    }
}

private func delegate(_ context: UnsafeMutableRawPointer?) -> AirPlayReceiverDelegate? {
    guard let context else { return nil }
    return Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue().delegate
}

private func string(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
}

extension AirPlayReceiver {
    fileprivate static func makeCallbacks(context: UnsafeMutableRawPointer) -> flect_callbacks_t {
        var callbacks = flect_callbacks_t()
        callbacks.context = context

        callbacks.log = { context, level, message in
            let level = ReceiverLogLevel(rawValue: level) ?? (level < 3 ? .error : .debug)
            delegate(context)?.receiverLog(string(message), level: level)
        }
        callbacks.client_request = { context, deviceID, model, name, admit in
            guard let delegate = delegate(context) else { return }
            admit?.pointee = delegate.receiverShouldAdmit(
                deviceID: string(deviceID), model: string(model), name: string(name))
        }
        callbacks.connection_opened = { context, open in
            delegate(context)?.receiverConnectionsChanged(open: Int(open))
        }
        callbacks.connection_closed = { context, open in
            delegate(context)?.receiverConnectionsChanged(open: Int(open))
        }
        callbacks.connection_lost = { context, reason in
            delegate(context)?.receiverConnectionLost(reason: Int(reason))
        }
        callbacks.heartbeat = { context in
            delegate(context)?.receiverHeartbeat()
        }
        callbacks.show_code = { context, code in
            delegate(context)?.receiverShowCode(string(code))
        }

        callbacks.video_codec = { context, isH265 in
            (delegate(context)?.receiverAcceptsVideo(isH265: isH265) ?? false) ? 0 : -1
        }
        callbacks.video_frame = { context, data, length, _, isH265, _ in
            guard let data, length > 0 else { return }
            delegate(context)?.receiverVideoFrame(UnsafeRawBufferPointer(start: data, count: length), isH265: isH265)
        }
        callbacks.video_size = { context, sourceWidth, sourceHeight, _, _ in
            delegate(context)?.receiverVideoSize(CGSize(width: CGFloat(sourceWidth), height: CGFloat(sourceHeight)))
        }
        callbacks.video_paused = { context, paused in
            delegate(context)?.receiverVideoPaused(paused)
        }
        callbacks.video_stopped = { context in
            delegate(context)?.receiverVideoStopped()
        }
        callbacks.video_flush = { context in
            delegate(context)?.receiverVideoFlush()
        }

        callbacks.audio_format = { context, type, _, _, _ in
            guard let format = AirPlayAudioFormat(rawValue: Int(type)) else { return }
            delegate(context)?.receiverAudioFormat(format)
        }
        callbacks.audio_packet = { context, data, length, type, _ in
            guard let data, length > 0, let format = AirPlayAudioFormat(rawValue: Int(type)) else { return }
            delegate(context)?.receiverAudioPacket(UnsafeRawBufferPointer(start: data, count: length), format: format)
        }
        callbacks.audio_volume = { context, volume in
            delegate(context)?.receiverAudioVolume(decibels: volume)
        }
        callbacks.audio_flush = { context in
            delegate(context)?.receiverAudioFlush()
        }
        return callbacks
    }
}
