// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import Foundation

/// Devices waiting for the teacher to let them on screen.
///
/// A device that has been let on once is remembered, so an iPad that drops
/// off the Wi-Fi and comes back doesn't have to be approved again. The app
/// can keep that list between launches: see `approvedDeviceIDs`.
public struct ApprovalQueue: Sendable {
    public struct Request: Sendable, Equatable, Identifiable {
        public let session: SessionID
        public let deviceID: String
        public let name: String
        public let model: String

        public var id: SessionID { session }
    }

    public enum Outcome: Sendable, Equatable {
        /// Already known: let it straight on.
        case alreadyApproved
        /// Waiting for the teacher.
        case waiting
    }

    public private(set) var waiting: [Request] = []
    private var approvedDevices: Set<String> = []
    private var approvedSessions: Set<SessionID> = []

    public init(approvedDevices: Set<String> = []) {
        self.approvedDevices = approvedDevices
    }

    /// The devices let on so far, for keeping between launches.
    public var approvedDeviceIDs: Set<String> { approvedDevices }

    /// Forgets the remembered devices; anyone connecting has to ask again.
    public mutating func forgetDevices() {
        approvedDevices.removeAll()
    }

    public var isEmpty: Bool { waiting.isEmpty }

    /// Asks about a device. Devices approved earlier are let through.
    @discardableResult
    public mutating func request(session: SessionID, deviceID: String, name: String, model: String) -> Outcome {
        if approvedSessions.contains(session) || (!deviceID.isEmpty && approvedDevices.contains(deviceID)) {
            approvedSessions.insert(session)
            waiting.removeAll { $0.session == session }
            return .alreadyApproved
        }
        if !waiting.contains(where: { $0.session == session }) {
            waiting.append(Request(session: session, deviceID: deviceID, name: name, model: model))
        }
        return .waiting
    }

    public func isApproved(_ session: SessionID) -> Bool {
        approvedSessions.contains(session)
    }

    public func isWaiting(_ session: SessionID) -> Bool {
        waiting.contains { $0.session == session }
    }

    /// Lets a device on screen, and remembers it.
    public mutating func approve(_ session: SessionID) {
        if let request = waiting.first(where: { $0.session == session }), !request.deviceID.isEmpty {
            approvedDevices.insert(request.deviceID)
        }
        approvedSessions.insert(session)
        waiting.removeAll { $0.session == session }
    }

    /// Lets everyone waiting on screen: the usual case in a classroom,
    /// where the teacher knows the iPads in the room.
    public mutating func approveAll() {
        for request in waiting {
            approve(request.session)
        }
    }

    /// Turns a device away. It isn't remembered, so it can ask again.
    public mutating func decline(_ session: SessionID) {
        waiting.removeAll { $0.session == session }
        approvedSessions.remove(session)
    }

    /// The device has gone.
    public mutating func forget(_ session: SessionID) {
        waiting.removeAll { $0.session == session }
        approvedSessions.remove(session)
    }

    /// Starts afresh, e.g. when the receiver restarts.
    public mutating func removeAll() {
        waiting.removeAll()
        approvedDevices.removeAll()
        approvedSessions.removeAll()
    }
}
