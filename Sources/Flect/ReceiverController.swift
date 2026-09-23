// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AppKit
import FlectKit
import Observation
import os

enum SettingsKey {
    static let name = "receiverName"
    static let requireCode = "requireCode"
    static let playAudio = "playAudio"
    static let maxDevices = "maxDevices"
    static let requireApproval = "requireApproval"
    static let rememberApprovals = "rememberApprovals"
    /// Device IDs let on before, and the names they had.
    static let allowedDevices = "allowedDevices"
}

/// A device showing on screen.
@MainActor
@Observable
final class DeviceTile: Identifiable {
    let id: SessionID
    let name: String
    var isPaused = false
    /// Silenced on its own, whether or not it is the device being heard.
    var isMuted = false
    /// When recording started, for the badge on screen.
    var recordingSince: Date?
    /// The picture's size, once known.
    var videoSize: CGSize?
    /// The tile's own video layer, kept for as long as the device shows
    /// (see `VideoOutput`).
    @ObservationIgnored let view = VideoLayerView()

    init(id: SessionID, name: String) {
        self.id = id
        self.name = name
    }

    var aspectRatio: CGFloat {
        guard let size = videoSize, size.width > 0, size.height > 0 else { return 4.0 / 3.0 }
        return size.width / size.height
    }
}

/// What happened to the last saved file, shown briefly in the window.
struct SavedFileNotice: Equatable {
    let message: String
    let url: URL?
}

/// A device waiting for its user to type the code on screen.
struct CodeRequest: Equatable {
    let session: SessionID
    let code: String
    let deviceName: String?
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
    /// Devices wait for the teacher before they reach the screen.
    private(set) var requiresApproval = false
    /// Who is waiting, and who has been let on.
    private(set) var approvals = ApprovalQueue()
    /// Whether iPads let on are remembered after Flect quits.
    private(set) var remembersApprovals = true
    /// The iPads remembered, by name, for Settings.
    private(set) var allowedDeviceNames: [String] = []
    private(set) var maxDevices = 1
    /// Devices showing, in the order they started.
    private(set) var tiles: [DeviceTile] = []
    /// The device the teacher has enlarged, if any.
    private(set) var focusedTile: SessionID?
    /// A device that is connecting but not showing yet.
    private(set) var connectingName: String?
    private(set) var codeRequest: CodeRequest?
    private(set) var connections = 0
    /// Whether any device's sound plays on this Mac.
    private(set) var soundEnabled = true
    private(set) var savedFileNotice: SavedFileNotice?
    /// The network check: what it found, and whether it's still looking.
    private(set) var networkFindings: [NetworkFinding] = []
    private(set) var isCheckingNetwork = false
    var showsNetworkCheck = false
    @ObservationIgnored private var networkSummary = ""

    /// Snapshots need macOS 14.4 or later.
    var canSnapshot: Bool {
        if #available(macOS 14.4, *) { true } else { false }
    }

    var isMirroring: Bool { !tiles.isEmpty }

    @ObservationIgnored private var receiver: AirPlayReceiver?
    @ObservationIgnored private var hub: MirrorHub?
    @ObservationIgnored private var deviceNames: [SessionID: String] = [:]
    @ObservationIgnored private var deviceIDs: [SessionID: String] = [:]
    @ObservationIgnored private var connectingSession: SessionID?
    /// Sessions whose picture is ready but held back, awaiting approval.
    @ObservationIgnored private var heldBack: Set<SessionID> = []
    /// Start, stop and disconnect block while network threads wind down.
    @ObservationIgnored private let queue = DispatchQueue(label: "org.flect.receiver")
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var disconnectRequested: [SessionID: Date] = [:]
    @ObservationIgnored private var awakeActivity: NSObjectProtocol?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    @ObservationIgnored private let identity = ReceiverIdentity.load()
    @ObservationIgnored private let logger = Logger(subsystem: "org.flect.Flect", category: "receiver")

    func start() {
        guard receiver == nil else { return }
        let defaults = UserDefaults.standard
        let name = ReceiverName.sanitized(defaults.string(forKey: SettingsKey.name) ?? "",
                                          fallback: ReceiverName.suggested)
        requiresCode = defaults.bool(forKey: SettingsKey.requireCode)
        requiresApproval = defaults.bool(forKey: SettingsKey.requireApproval)
        remembersApprovals = defaults.object(forKey: SettingsKey.rememberApprovals) as? Bool ?? true
        loadAllowedDevices()
        soundEnabled = defaults.object(forKey: SettingsKey.playAudio) as? Bool ?? true
        maxDevices = max(1, defaults.object(forKey: SettingsKey.maxDevices) as? Int ?? 4)
        receiverName = name
        status = .starting

        var configuration = ReceiverConfiguration(name: name, deviceID: identity.deviceID, keyFile: identity.keyFile)
        configuration.access = requiresCode ? .screenCode : .open
        configuration.maxClients = maxDevices
        let picture = ReceiverConfiguration.picture(forDevices: maxDevices)
        configuration.maxWidth = picture.width
        configuration.maxHeight = picture.height
        configuration.maxFramesPerSecond = picture.framesPerSecond

        let logger = logger
        let hub = MirrorHub(
            playsAudio: soundEnabled,
            onEvent: { [weak self] event in
                // The main queue keeps events in order.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handle(event) }
                }
            },
            onLog: { message, level in
                logger.log(level: level.osLogType, "\(message, privacy: .public)")
            })

        let receiver = AirPlayReceiver(configuration: configuration)
        self.receiver = receiver
        self.hub = hub
        let identity = identity
        let maxDevices = maxDevices
        queue.async { [weak self] in
            do {
                try receiver.start(delegate: hub)
                identity.protectKeyFile()
                logger.notice("Receiver \"\(name, privacy: .public)\" listening on port \(receiver.port), up to \(maxDevices) devices")
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
                        self.hub = nil
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
        let receiver = receiver
        self.receiver = nil
        hub = nil
        queue.async { receiver?.stop() }
        resetViewState()
        status = .starting
    }

    func restart() {
        stop()
        start()
    }

    /// Ends one device's mirroring (it sees it stop); the others carry on.
    func disconnect(_ session: SessionID) {
        guard let receiver else { return }
        disconnectRequested[session] = Date()
        queue.async { receiver.disconnect(session: session) }
    }

    func disconnectAll() {
        guard let receiver else { return }
        queue.async { receiver.resetConnections() }
    }

    /// Enlarges a device to fill the window, or goes back to showing all.
    /// Sound comes from the enlarged device.
    func toggleFocus(_ session: SessionID) {
        guard tiles.count > 1 || focusedTile != nil else { return }
        setFocus(focusedTile == session ? nil : session)
    }

    func showAll() {
        setFocus(nil)
    }

    /// Turning approval off lets everyone already waiting straight on.
    func setRequiresApproval(_ required: Bool) {
        requiresApproval = required
        UserDefaults.standard.set(required, forKey: SettingsKey.requireApproval)
        if required {
            // Devices already on screen stay on screen.
            for tile in tiles {
                approvals.request(session: tile.id, deviceID: deviceIDs[tile.id] ?? "", name: tile.name, model: "")
                approvals.approve(tile.id)
            }
        } else {
            for request in approvals.waiting {
                approve(request.session)
            }
        }
    }

    /// Lets a waiting device on screen, and remembers it.
    func approve(_ session: SessionID) {
        let deviceID = deviceIDs[session] ?? ""
        let name = deviceNames[session] ?? "iPad"
        approvals.approve(session)
        hub?.setMuted(false, for: session)
        if heldBack.remove(session) != nil {
            addTile(session)
        }
        if remembersApprovals, !deviceID.isEmpty {
            var stored = UserDefaults.standard.dictionary(forKey: SettingsKey.allowedDevices) as? [String: String] ?? [:]
            stored[deviceID] = name
            UserDefaults.standard.set(stored, forKey: SettingsKey.allowedDevices)
            allowedDeviceNames = Self.names(from: stored)
        }
    }

    func setRemembersApprovals(_ remembers: Bool) {
        remembersApprovals = remembers
        UserDefaults.standard.set(remembers, forKey: SettingsKey.rememberApprovals)
        loadAllowedDevices()
    }

    /// Forgets every remembered iPad; each has to ask again.
    func forgetAllowedDevices() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.allowedDevices)
        approvals.forgetDevices()
        allowedDeviceNames = []
    }

    private func loadAllowedDevices() {
        let stored = UserDefaults.standard.dictionary(forKey: SettingsKey.allowedDevices) as? [String: String] ?? [:]
        allowedDeviceNames = Self.names(from: stored)
        if remembersApprovals {
            approvals = ApprovalQueue(approvedDevices: Set(stored.keys))
        } else {
            approvals.forgetDevices()
        }
    }

    private static func names(from stored: [String: String]) -> [String] {
        stored.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Lets everyone waiting on screen at once.
    func approveAll() {
        for request in approvals.waiting {
            approve(request.session)
        }
    }

    /// Turns everyone waiting away; each can ask again.
    func declineAll() {
        for request in approvals.waiting {
            decline(request.session)
        }
    }

    /// Turns a waiting device away; it can ask again.
    func decline(_ session: SessionID) {
        approvals.decline(session)
        heldBack.remove(session)
        disconnect(session)
    }

    func setPlaysAudio(_ plays: Bool) {
        soundEnabled = plays
        UserDefaults.standard.set(plays, forKey: SettingsKey.playAudio)
        hub?.playsAudio = plays
    }

    func toggleSound() {
        setPlaysAudio(!soundEnabled)
    }

    /// Silences one device, leaving the rest as they are.
    func toggleMute(_ session: SessionID) {
        guard let tile = tile(session) else { return }
        tile.isMuted.toggle()
        hub?.setMuted(tile.isMuted, for: session)
    }

    /// Saves what a device is showing as a PNG in Pictures ▸ Flect.
    func snapshot(_ session: SessionID) {
        guard let tile = tile(session) else { return }
        guard #available(macOS 14.4, *), let picture = tile.view.renderer.displayedPixelBuffer() else {
            show(SavedFileNotice(message: "Flect couldn't capture that picture.", url: nil))
            return
        }
        let name = tile.name
        let carried = Unchecked(picture)
        Task.detached(priority: .userInitiated) { [weak self] in
            let notice: SavedFileNotice
            do {
                let url = try Snapshot.write(carried.value, deviceName: name)
                notice = SavedFileNotice(message: "Saved \(url.lastPathComponent)", url: url)
            } catch {
                notice = SavedFileNotice(message: error.localizedDescription, url: nil)
            }
            await MainActor.run { self?.show(notice) }
        }
    }

    /// Starts or stops recording one device to Movies ▸ Flect.
    func toggleRecording(_ session: SessionID) {
        guard let tile = tile(session), let hub else { return }
        if tile.recordingSince != nil {
            hub.stopRecording(session)
            return
        }
        do {
            try hub.startRecording(session, deviceName: tile.name)
        } catch {
            show(SavedFileNotice(message: error.localizedDescription, url: nil))
        }
    }

    func recordCommandTarget() {
        if let target = commandTarget {
            toggleRecording(target)
        }
    }

    var isRecordingCommandTarget: Bool {
        commandTarget.flatMap { tile($0)?.recordingSince } != nil
    }

    /// The device a menu command acts on: the enlarged one, or the only one.
    var commandTarget: SessionID? {
        focusedTile ?? (tiles.count == 1 ? tiles[0].id : nil)
    }

    func snapshotCommandTarget() {
        if let target = commandTarget {
            snapshot(target)
        }
    }

    /// Looks at the network and works out why iPads might not see Flect.
    func checkNetwork() {
        guard !isCheckingNetwork else { return }
        isCheckingNetwork = true
        let name = receiverName
        let port = receiver?.port ?? 0
        let running = receiver != nil && status == .ready
        Task { [weak self] in
            let facts = await NetworkCheck.gather(receiverName: name, port: port, receiverRunning: running)
            let findings = NetworkCheck.findings(for: facts)
            let summary = NetworkCheck.summary(for: facts, findings: findings)
            await MainActor.run {
                guard let self else { return }
                self.networkFindings = findings
                self.networkSummary = summary
                self.isCheckingNetwork = false
            }
        }
    }

    func copyNetworkSummary() {
        guard !networkSummary.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(networkSummary, forType: .string)
    }

    func revealSavedFile() {
        guard let url = savedFileNotice?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func show(_ notice: SavedFileNotice) {
        savedFileNotice = notice
        noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.savedFileNotice = nil
        }
    }

    private func setFocus(_ session: SessionID?) {
        focusedTile = session
        hub?.focus(session)
    }

    // MARK: Events

    private func handle(_ event: MirrorEvent) {
        switch event {
        case .connectionsChanged(let count):
            connections = count
        case .deviceConnecting(let id, let deviceID, let name, let model):
            let display = name.isEmpty ? nil : name
            deviceNames[id] = display
            deviceIDs[id] = deviceID
            if requiresApproval,
               approvals.request(session: id, deviceID: deviceID,
                                 name: display ?? "A device", model: model) == .waiting {
                // Not heard either, until it is let on.
                hub?.setMuted(true, for: id)
            }
            if tile(id) == nil {
                connectingSession = id
                connectingName = display ?? "a device"
            }
        case .showCode(let id, let code):
            codeRequest = CodeRequest(session: id, code: code, deviceName: deviceNames[id])
        case .videoStarted(let id):
            if requiresApproval, !approvals.isApproved(id) {
                heldBack.insert(id)  // its frames wait in the pipeline
            } else {
                addTile(id)
            }
        case .videoSize(let id, let size):
            tile(id)?.videoSize = size
        case .videoPaused(let id, let paused):
            tile(id)?.isPaused = paused
        case .videoStopped(let id):
            removeTile(id)
            heldBack.remove(id)
        case .sessionEnded(let id):
            removeTile(id)
            approvals.forget(id)
            heldBack.remove(id)
            deviceNames[id] = nil
            deviceIDs[id] = nil
            disconnectRequested[id] = nil
            if codeRequest?.session == id {
                codeRequest = nil
            }
            if connectingSession == id {
                connectingSession = nil
                connectingName = nil
            }
        case .connectionLost(let id):
            logger.notice("Lost the connection to \(self.deviceNames[id] ?? "a device", privacy: .public)")
            disconnect(id)
        case .recordingStarted(let id, _):
            tile(id)?.recordingSince = Date()
        case .recordingFinished(let id, let summary, let error):
            tile(id)?.recordingSince = nil
            if let summary {
                show(SavedFileNotice(
                    message: "Saved \(summary.url.lastPathComponent) (\(Self.length(summary.duration)))",
                    url: summary.url))
            } else if let error {
                show(SavedFileNotice(message: error, url: nil))
            }
        }
    }

    private func tile(_ id: SessionID) -> DeviceTile? {
        tiles.first { $0.id == id }
    }

    private func addTile(_ id: SessionID) {
        guard tile(id) == nil, let output = hub?.videoOutput(for: id) else { return }
        let tile = DeviceTile(id: id, name: deviceNames[id] ?? "iPad")
        output.attach(tile.view.renderer)
        tiles.append(tile)
        if codeRequest?.session == id {
            codeRequest = nil
        }
        if connectingSession == id {
            connectingSession = nil
            connectingName = nil
        }
        keepDisplayAwake(true)
    }

    private func removeTile(_ id: SessionID) {
        guard let index = tiles.firstIndex(where: { $0.id == id }) else { return }
        let tile = tiles.remove(at: index)
        hub?.videoOutput(for: id)?.attach(nil)
        tile.view.clear()
        if focusedTile == id {
            setFocus(nil)
        }
        if tiles.isEmpty {
            keepDisplayAwake(false)
        }
    }

    private func resetViewState() {
        for tile in tiles {
            tile.view.clear()
        }
        tiles = []
        focusedTile = nil
        codeRequest = nil
        connectingName = nil
        connectingSession = nil
        deviceNames = [:]
        deviceIDs = [:]
        approvals.removeAll()
        heldBack = []
        disconnectRequested = [:]
        connections = 0
        savedFileNotice = nil
        noticeTimer?.cancel()
        keepDisplayAwake(false)
    }

    /// Devices check in every two seconds. One that has gone quiet for 15
    /// (Wi-Fi dropped, battery died) would otherwise hold its place.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let hub = self.hub else { return }
                for id in hub.stalledSessions(timeout: 15) {
                    if let asked = self.disconnectRequested[id], Date().timeIntervalSince(asked) < 15 {
                        continue
                    }
                    self.logger.notice("\(self.deviceNames[id] ?? "A device", privacy: .public) stopped responding; freeing its place")
                    self.disconnect(id)
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

extension ReceiverController {
    /// "2:14", for recording lengths.
    static func length(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// Carries a picture from the main actor to a background task.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) { self.value = value }
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
