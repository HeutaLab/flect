// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import CoreGraphics
import Foundation

/// What the UI needs to hear about. Delivered on the receiver's threads.
public enum MirrorEvent: Sendable, Equatable {
    case connectionsChanged(Int)
    /// A device asked to start mirroring or playing.
    case deviceConnecting(SessionID, name: String, model: String)
    /// The device is asking its user for this code.
    case showCode(SessionID, String)
    case videoStarted(SessionID)
    /// The picture's size changed (first frame, or the device rotated).
    case videoSize(SessionID, CGSize)
    case videoPaused(SessionID, Bool)
    case videoStopped(SessionID)
    /// The device disconnected.
    case sessionEnded(SessionID)
    /// The device vanished without saying goodbye; disconnect it.
    case connectionLost(SessionID)
    case recordingStarted(SessionID, URL)
    /// The recording closed: a summary, or why it failed.
    case recordingFinished(SessionID, RecordingSummary?, String?)
}

/// Receives every connected device: routes each one's video and sound to
/// its own `DeviceSession`, and reports what happens through `onEvent`.
///
/// Only one device is heard at a time: the focused one, or else the one
/// that connected first.
public final class MirrorHub: AirPlayReceiverDelegate, @unchecked Sendable {
    private let onEvent: @Sendable (MirrorEvent) -> Void
    private let onLog: @Sendable (String, ReceiverLogLevel) -> Void

    private let lock = NSLock()
    private var sessions: [SessionID: DeviceSession] = [:]
    /// In the order the devices connected.
    private var order: [SessionID] = []
    private var focused: SessionID?
    private var audioEnabled: Bool
    private var audible: SessionID?

    public init(
        playsAudio: Bool = true,
        onEvent: @escaping @Sendable (MirrorEvent) -> Void,
        onLog: @escaping @Sendable (String, ReceiverLogLevel) -> Void = { _, _ in }
    ) {
        audioEnabled = playsAudio
        self.onEvent = onEvent
        self.onLog = onLog
    }

    /// The device's video, to attach to a renderer. Nil once it has gone.
    public func videoOutput(for id: SessionID) -> VideoOutput? {
        lock.withLock { sessions[id]?.video }
    }

    public var playsAudio: Bool {
        get { lock.withLock { audioEnabled } }
        set {
            lock.withLock { audioEnabled = newValue }
            updateAudibleSession()
        }
    }

    /// The device the teacher has enlarged, if any. Its sound is the one heard.
    public func focus(_ id: SessionID?) {
        lock.withLock { focused = id }
        updateAudibleSession()
    }

    public func isRecording(_ id: SessionID) -> Bool {
        existingSession(id)?.isRecording ?? false
    }

    /// How long this device has been recording, for the badge on screen.
    public func recordingDuration(_ id: SessionID) -> TimeInterval {
        existingSession(id)?.recordingDuration ?? 0
    }

    /// Starts recording one device to Movies ▸ Flect and returns the file.
    @discardableResult
    public func startRecording(_ id: SessionID, deviceName: String, folder: URL? = nil) throws -> URL {
        guard let session = existingSession(id) else {
            throw DeviceRecorder.Failure.cannotWrite("That device is no longer connected.")
        }
        let folder = folder ?? SavedFile.recordingsFolder()
        let url = folder.appendingPathComponent(SavedFile.name(deviceName: deviceName, extension: "mov"))
        try session.startRecording(to: url)
        onEvent(.recordingStarted(id, url))
        return url
    }

    /// Closes a recording; the result arrives as `.recordingFinished`.
    public func stopRecording(_ id: SessionID) {
        guard let session = existingSession(id) else { return }
        Task { await self.finishRecording(id, session: session) }
    }

    private func finishRecording(_ id: SessionID, session: DeviceSession) async {
        guard let result = await session.stopRecording() else { return }
        switch result {
        case .success(let summary):
            onEvent(.recordingFinished(id, summary, nil))
        case .failure(let error):
            onEvent(.recordingFinished(id, nil, error.localizedDescription))
        }
    }

    public func isMuted(_ id: SessionID) -> Bool {
        existingSession(id)?.isMuted ?? false
    }

    /// Silences one device. A muted device stays silent even when it is the
    /// one that would be heard; the others don't take over.
    public func setMuted(_ muted: Bool, for id: SessionID) {
        existingSession(id)?.setMuted(muted)
        updateAudibleSession()
    }

    /// The device whose sound plays: the enlarged one, else the first to
    /// connect. Nothing plays when sound is off, or when that device is muted.
    static func audibleSession(focused: SessionID?, order: [SessionID],
                               muted: Set<SessionID>, soundOn: Bool) -> SessionID? {
        guard soundOn else { return nil }
        guard let chosen = focused.flatMap({ order.contains($0) ? $0 : nil }) ?? order.first else { return nil }
        return muted.contains(chosen) ? nil : chosen
    }

    /// Devices that have stopped checking in for longer than `timeout`.
    public func stalledSessions(timeout: TimeInterval, now: Date = Date()) -> [SessionID] {
        let all = lock.withLock { Array(sessions.values) }
        return all.filter { $0.isStalled(timeout: timeout, now: now) }.map(\.id)
    }

    // MARK: Sessions

    /// The session for a device, created on its first event. 0 isn't a device.
    private func session(_ id: SessionID) -> DeviceSession? {
        guard id != 0 else { return nil }
        let (session, created) = lock.withLock { () -> (DeviceSession, Bool) in
            if let existing = sessions[id] {
                return (existing, false)
            }
            let new = DeviceSession(id: id)
            sessions[id] = new
            order.append(id)
            return (new, true)
        }
        if created {
            updateAudibleSession()
        }
        return session
    }

    private func existingSession(_ id: SessionID) -> DeviceSession? {
        lock.withLock { sessions[id] }
    }

    /// Serialises changes of who is heard, so two can't interleave.
    private let audibleLock = NSLock()

    private func updateAudibleSession() {
        audibleLock.withLock {
            let (previous, next, live): (SessionID?, SessionID?, [SessionID: DeviceSession]) = lock.withLock {
                let muted = Set(sessions.values.filter(\.isMuted).map(\.id))
                let wanted = Self.audibleSession(focused: focused, order: order,
                                                 muted: muted, soundOn: audioEnabled)
                defer { audible = wanted }
                return (audible, wanted, sessions)
            }
            guard previous != next else { return }
            if let previous {
                live[previous]?.setAudible(false)
            }
            if let next {
                live[next]?.setAudible(true)
            }
        }
    }

    // MARK: AirPlayReceiverDelegate

    public func receiverLog(_ message: String, level: ReceiverLogLevel) {
        onLog(message, level)
    }

    public func receiverConnectionsChanged(open: Int) {
        onEvent(.connectionsChanged(open))
    }

    public func receiverShouldAdmit(_ session: SessionID, deviceID: String, model: String, name: String) -> Bool {
        self.session(session)?.noteSignOfLife()
        onEvent(.deviceConnecting(session, name: name, model: model))
        return true
    }

    public func receiverSessionEnded(_ id: SessionID) {
        let removed: DeviceSession? = lock.withLock {
            guard let session = sessions.removeValue(forKey: id) else { return nil }
            order.removeAll { $0 == id }
            if focused == id {
                focused = nil
            }
            return session
        }
        guard let removed else { return }
        Task { await self.finishRecording(id, session: removed) }
        removed.stop()
        updateAudibleSession()
        onEvent(.sessionEnded(id))
    }

    public func receiverConnectionLost(_ session: SessionID, reason: Int) {
        onEvent(.connectionLost(session))
    }

    public func receiverHeartbeat(_ session: SessionID) {
        existingSession(session)?.noteSignOfLife()
    }

    public func receiverShowCode(_ code: String, session: SessionID) {
        onEvent(.showCode(session, code))
    }

    public func receiverAcceptsVideo(_ session: SessionID, isH265: Bool) -> Bool {
        self.session(session)?.setCodec(isH265: isH265)
        return true
    }

    public func receiverVideoFrame(_ annexB: UnsafeRawBufferPointer, session id: SessionID,
                                   isH265: Bool, deviceTime: UInt64) {
        guard let session = session(id) else { return }
        do {
            let result = try session.handleVideo(annexB, isH265: isH265, deviceTime: deviceTime)
            if result.started {
                onEvent(.videoStarted(id))
            }
            if let size = result.newSize {
                onEvent(.videoSize(id, size))
            }
        } catch {
            onLog("Skipped a video frame from device \(id): \(error)", .warning)
        }
    }

    public func receiverVideoSize(_ size: CGSize, session: SessionID) {
        onLog("Device \(session) screen is \(Int(size.width))×\(Int(size.height))", .info)
    }

    public func receiverVideoPaused(_ paused: Bool, session: SessionID) {
        onEvent(.videoPaused(session, paused))
    }

    public func receiverVideoStopped(_ id: SessionID) {
        guard let session = existingSession(id) else { return }
        // No more pictures are coming, so close any recording.
        Task { await self.finishRecording(id, session: session) }
        if session.stopVideo() {
            onEvent(.videoStopped(id))
        }
    }

    public func receiverAudioFormat(_ format: AirPlayAudioFormat, session id: SessionID) {
        if session(id)?.setAudioFormat(format) == false {
            onLog("This Mac can't decode AirPlay audio format \(format)", .error)
        }
    }

    public func receiverAudioPacket(_ packet: UnsafeRawBufferPointer, format: AirPlayAudioFormat,
                                    session id: SessionID, deviceTime: UInt64) {
        session(id)?.handleAudio(packet, format: format, deviceTime: deviceTime)
    }

    public func receiverAudioVolume(decibels: Float, session id: SessionID) {
        session(id)?.setVolume(Self.gain(forDecibels: decibels))
    }

    public func receiverAudioFlush(_ id: SessionID) {
        existingSession(id)?.flushAudio()
    }

    /// AirPlay volume runs from -30 dB (bottom of the slider) to 0 dB;
    /// -144 dB means mute. Same mapping as UxPlay.
    static func gain(forDecibels decibels: Float) -> Float {
        guard decibels > -30 else { return 0 }
        return powf(10, min(decibels, 0) / 20)
    }
}
