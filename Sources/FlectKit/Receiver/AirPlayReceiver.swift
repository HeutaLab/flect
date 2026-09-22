// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AirPlayCore
import CoreGraphics
import Foundation

/// One connected device, for as long as it stays connected. Never reused.
public typealias SessionID = UInt32

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
    /// How many devices may be connected at once.
    public var maxClients = 1
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
/// receiver's own network threads, concurrently when several devices are
/// connected; buffers are only valid during the call.
public protocol AirPlayReceiverDelegate: AnyObject, Sendable {
    func receiverLog(_ message: String, level: ReceiverLogLevel)
    func receiverConnectionsChanged(open: Int)

    /// Return false to turn the device away.
    func receiverShouldAdmit(_ session: SessionID, deviceID: String, model: String, name: String) -> Bool
    /// The device's connection closed. No more calls for this session follow.
    func receiverSessionEnded(_ session: SessionID)
    /// The connection dropped unexpectedly; the owner should disconnect the session.
    func receiverConnectionLost(_ session: SessionID, reason: Int)
    func receiverHeartbeat(_ session: SessionID)
    func receiverShowCode(_ code: String, session: SessionID)

    /// Return false to refuse the codec.
    func receiverAcceptsVideo(_ session: SessionID, isH265: Bool) -> Bool
    func receiverVideoFrame(_ annexB: UnsafeRawBufferPointer, session: SessionID, isH265: Bool)
    func receiverVideoSize(_ size: CGSize, session: SessionID)
    func receiverVideoPaused(_ paused: Bool, session: SessionID)
    func receiverVideoStopped(_ session: SessionID)

    func receiverAudioFormat(_ format: AirPlayAudioFormat, session: SessionID)
    func receiverAudioPacket(_ packet: UnsafeRawBufferPointer, format: AirPlayAudioFormat, session: SessionID)
    /// AirPlay volume: -30 dB (quietest) to 0 dB (full); -144 dB is mute.
    func receiverAudioVolume(decibels: Float, session: SessionID)
    func receiverAudioFlush(_ session: SessionID)
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
            config.max_clients = Int32(configuration.maxClients)
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

    /// Drops every connection and keeps listening on the same port.
    public func resetConnections() {
        lifecycle.withLock {
            if let handle {
                flect_receiver_reset_connections(handle)
            }
        }
    }

    /// Drops one device (within about a second); the others carry on.
    public func disconnect(session: SessionID) {
        lifecycle.withLock {
            if let handle {
                flect_receiver_disconnect(handle, session)
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
        callbacks.connections_changed = { context, open in
            delegate(context)?.receiverConnectionsChanged(open: Int(open))
        }

        callbacks.client_request = { context, session, deviceID, model, name, admit in
            guard let delegate = delegate(context) else { return }
            admit?.pointee = delegate.receiverShouldAdmit(
                session, deviceID: string(deviceID), model: string(model), name: string(name))
        }
        callbacks.session_ended = { context, session in
            delegate(context)?.receiverSessionEnded(session)
        }
        callbacks.connection_lost = { context, session, reason in
            delegate(context)?.receiverConnectionLost(session, reason: Int(reason))
        }
        callbacks.heartbeat = { context, session in
            delegate(context)?.receiverHeartbeat(session)
        }
        callbacks.show_code = { context, session, code in
            delegate(context)?.receiverShowCode(string(code), session: session)
        }

        callbacks.video_codec = { context, session, isH265 in
            (delegate(context)?.receiverAcceptsVideo(session, isH265: isH265) ?? false) ? 0 : -1
        }
        callbacks.video_frame = { context, session, data, length, _, isH265, _ in
            guard let data, length > 0 else { return }
            delegate(context)?.receiverVideoFrame(
                UnsafeRawBufferPointer(start: data, count: length), session: session, isH265: isH265)
        }
        callbacks.video_size = { context, session, sourceWidth, sourceHeight, _, _ in
            delegate(context)?.receiverVideoSize(
                CGSize(width: CGFloat(sourceWidth), height: CGFloat(sourceHeight)), session: session)
        }
        callbacks.video_paused = { context, session, paused in
            delegate(context)?.receiverVideoPaused(paused, session: session)
        }
        callbacks.video_stopped = { context, session in
            delegate(context)?.receiverVideoStopped(session)
        }

        callbacks.audio_format = { context, session, type, _, _, _ in
            guard let format = AirPlayAudioFormat(rawValue: Int(type)) else { return }
            delegate(context)?.receiverAudioFormat(format, session: session)
        }
        callbacks.audio_packet = { context, session, data, length, type, _ in
            guard let data, length > 0, let format = AirPlayAudioFormat(rawValue: Int(type)) else { return }
            delegate(context)?.receiverAudioPacket(
                UnsafeRawBufferPointer(start: data, count: length), format: format, session: session)
        }
        callbacks.audio_volume = { context, session, volume in
            delegate(context)?.receiverAudioVolume(decibels: volume, session: session)
        }
        callbacks.audio_flush = { context, session in
            delegate(context)?.receiverAudioFlush(session)
        }
        return callbacks
    }
}
