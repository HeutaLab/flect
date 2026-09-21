// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AppKit
import FlectKit
import Observation
import os

enum SettingsKey {
    static let name = "receiverName"
    static let requireCode = "requireCode"
    static let playAudio = "playAudio"
}

/// Runs the AirPlay receiver and publishes what the window should show.
@MainActor
@Observable
final class ReceiverController {
    enum Status: Equatable {
        case starting
        case ready
        case failed(String)
    }

    private(set) var status: Status = .starting
    private(set) var receiverName = ""
    private(set) var requiresCode = false
    /// The device connecting or connected, as it names itself.
    private(set) var deviceName: String?
    /// A code the device is asking its user to type.
    private(set) var code: String?
    private(set) var isMirroring = false
    private(set) var isPaused = false
    private(set) var connections = 0

    /// One video layer for the life of the app (see `VideoOutput`).
    @ObservationIgnored let videoView = VideoLayerView()

    @ObservationIgnored private var receiver: AirPlayReceiver?
    @ObservationIgnored private var session: MirrorSession?
    /// Start, stop and reset block while network threads wind down.
    @ObservationIgnored private let queue = DispatchQueue(label: "org.flect.receiver")
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var lastReset = Date.distantPast
    @ObservationIgnored private var awakeActivity: NSObjectProtocol?
    @ObservationIgnored private let identity = ReceiverIdentity.load()
    @ObservationIgnored private let logger = Logger(subsystem: "org.flect.Flect", category: "receiver")

    func start() {
        guard receiver == nil else { return }
        let defaults = UserDefaults.standard
        let name = ReceiverName.sanitized(defaults.string(forKey: SettingsKey.name) ?? "",
                                          fallback: ReceiverName.suggested)
        requiresCode = defaults.bool(forKey: SettingsKey.requireCode)
        receiverName = name
        status = .starting

        var configuration = ReceiverConfiguration(name: name, deviceID: identity.deviceID, keyFile: identity.keyFile)
        configuration.access = requiresCode ? .screenCode : .open

        let logger = logger
        let session = MirrorSession(
            playsAudio: defaults.object(forKey: SettingsKey.playAudio) as? Bool ?? true,
            onEvent: { [weak self] event in
                // The main queue keeps events in order.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handle(event) }
                }
            },
            onLog: { message, level in
                logger.log(level: level.osLogType, "\(message, privacy: .public)")
            })
        session.video.attach(videoView.renderer)

        let receiver = AirPlayReceiver(configuration: configuration)
        self.receiver = receiver
        self.session = session
        let identity = identity
        queue.async { [weak self] in
            do {
                try receiver.start(delegate: session)
                identity.protectKeyFile()
                logger.notice("Receiver \"\(name, privacy: .public)\" listening on port \(receiver.port)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.receiver === receiver else { return }
                        self.status = .ready
                    }
                }
            } catch {
                let reason = error.localizedDescription
                logger.error("Receiver failed to start: \(reason, privacy: .public)")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.receiver === receiver else { return }
                        self.receiver = nil
                        self.session = nil
                        self.status = .failed(reason)
                    }
                }
            }
        }
        startWatchdog()
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        session?.video.attach(nil)
        let receiver = receiver
        self.receiver = nil
        session = nil
        queue.async { receiver?.stop() }
        videoView.clear()
        resetViewState()
        status = .starting
    }

    func restart() {
        stop()
        start()
    }

    /// Ends the current mirroring session (the iPad sees it stop).
    func disconnect() {
        guard let receiver else { return }
        lastReset = Date()
        queue.async { receiver.resetConnections() }
    }

    func setPlaysAudio(_ plays: Bool) {
        session?.playsAudio = plays
    }

    // MARK: Events

    private func handle(_ event: MirrorEvent) {
        switch event {
        case .deviceConnecting(let name, _):
            deviceName = name.isEmpty ? nil : name
        case .showCode(let code):
            self.code = code
        case .connectionsChanged(let count):
            connections = count
            if count == 0 {
                resetViewState()
            }
        case .videoStarted:
            code = nil
            isMirroring = true
            isPaused = false
            keepDisplayAwake(true)
        case .videoSize:
            break
        case .videoPaused(let paused):
            isPaused = paused
        case .videoStopped:
            isMirroring = false
            isPaused = false
            keepDisplayAwake(false)
        case .connectionLost:
            logger.notice("Lost the connection to \(self.deviceName ?? "the device", privacy: .public)")
            disconnect()
        }
    }

    private func resetViewState() {
        deviceName = nil
        code = nil
        isMirroring = false
        isPaused = false
        connections = 0
        keepDisplayAwake(false)
    }

    /// Devices check in every two seconds. One that has gone quiet for 15
    /// (Wi-Fi dropped, battery died) would otherwise block the receiver.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                if session.isStalled(timeout: 15), Date().timeIntervalSince(self.lastReset) > 15 {
                    self.logger.notice("Device stopped responding; freeing the receiver")
                    self.disconnect()
                }
            }
        }
    }

    /// No screensaver or display sleep in the middle of a demo.
    private func keepDisplayAwake(_ awake: Bool) {
        if awake, awakeActivity == nil {
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Showing a mirrored screen")
        } else if !awake, let activity = awakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            awakeActivity = nil
        }
    }
}

private extension ReceiverLogLevel {
    var osLogType: OSLogType {
        switch self {
        case .error: .error
        case .warning, .notice: .default
        case .info: .info
        case .debug: .debug
        }
    }
}
