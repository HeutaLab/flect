// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import Testing

@testable import FlectKit

@Suite("Letting devices on screen")
struct ApprovalTests {
    @Test("A new device waits until it is let on")
    func waitsThenShows() {
        var queue = ApprovalQueue()
        #expect(queue.request(session: 1, deviceID: "aa:bb", name: "Red7", model: "iPad") == .waiting)
        #expect(queue.waiting.map(\.name) == ["Red7"])
        #expect(!queue.isApproved(1))

        queue.approve(1)
        #expect(queue.isApproved(1))
        #expect(queue.isEmpty)
    }

    @Test("A device that dropped out comes straight back")
    func remembersDevices() {
        var queue = ApprovalQueue()
        queue.request(session: 1, deviceID: "aa:bb", name: "Red7", model: "iPad")
        queue.approve(1)
        queue.forget(1)  // the Wi-Fi dropped

        // It reconnects as a new session.
        #expect(queue.request(session: 2, deviceID: "aa:bb", name: "Red7", model: "iPad") == .alreadyApproved)
        #expect(queue.isApproved(2))
        #expect(queue.isEmpty)
    }

    @Test("A device turned away has to ask again")
    func decliningIsNotRemembered() {
        var queue = ApprovalQueue()
        queue.request(session: 1, deviceID: "aa:bb", name: "Red7", model: "iPad")
        queue.decline(1)
        #expect(queue.isEmpty)
        #expect(!queue.isApproved(1))

        #expect(queue.request(session: 2, deviceID: "aa:bb", name: "Red7", model: "iPad") == .waiting)
    }

    @Test("Asking twice doesn't queue the same device twice")
    func noDuplicates() {
        var queue = ApprovalQueue()
        queue.request(session: 1, deviceID: "aa:bb", name: "Red7", model: "iPad")
        queue.request(session: 1, deviceID: "aa:bb", name: "Red7", model: "iPad")
        #expect(queue.waiting.count == 1)
    }

    @Test("A device with no identity is let on for this connection only")
    func withoutDeviceID() {
        var queue = ApprovalQueue()
        queue.request(session: 1, deviceID: "", name: "Unknown", model: "")
        queue.approve(1)
        #expect(queue.isApproved(1))
        // A later connection is a stranger again.
        #expect(queue.request(session: 2, deviceID: "", name: "Unknown", model: "") == .waiting)
    }

    @Test("Several devices wait in the order they arrived")
    func order() {
        var queue = ApprovalQueue()
        for (index, name) in ["Red7", "Red8", "Red19"].enumerated() {
            queue.request(session: SessionID(index + 1), deviceID: "id\(index)", name: name, model: "iPad")
        }
        #expect(queue.waiting.map(\.name) == ["Red7", "Red8", "Red19"])
        queue.approve(2)
        #expect(queue.waiting.map(\.name) == ["Red7", "Red19"])
    }

    @Test("Letting all on at once clears the queue and remembers them")
    func approveAll() {
        var queue = ApprovalQueue()
        for (index, name) in ["Red7", "Red8", "Red19", "Red20"].enumerated() {
            queue.request(session: SessionID(index + 1), deviceID: "id\(index)", name: name, model: "iPad")
        }
        queue.approveAll()
        #expect(queue.isEmpty)
        #expect((1...4).allSatisfy { queue.isApproved(SessionID($0)) })
        // They come back without asking.
        #expect(queue.request(session: 9, deviceID: "id2", name: "Red19", model: "iPad") == .alreadyApproved)
    }

    @Test("Remembered iPads are let on again after a restart")
    func remembersBetweenLaunches() {
        var queue = ApprovalQueue()
        queue.request(session: 1, deviceID: "aa:bb", name: "Red7", model: "iPad")
        queue.request(session: 2, deviceID: "cc:dd", name: "Red8", model: "iPad")
        queue.approveAll()
        let remembered = queue.approvedDeviceIDs
        #expect(remembered == ["aa:bb", "cc:dd"])

        // Flect quits and starts again with that list.
        var afterRestart = ApprovalQueue(approvedDevices: remembered)
        #expect(afterRestart.request(session: 5, deviceID: "aa:bb", name: "Red7", model: "iPad") == .alreadyApproved)
        #expect(afterRestart.request(session: 6, deviceID: "ee:ff", name: "A stranger", model: "iPad") == .waiting)

        afterRestart.forgetDevices()
        #expect(afterRestart.request(session: 7, deviceID: "aa:bb", name: "Red7", model: "iPad") == .waiting)
    }

    @Test("Starting afresh forgets everyone")
    func removeAll() {
        var queue = ApprovalQueue()
        queue.request(session: 1, deviceID: "aa:bb", name: "Red7", model: "iPad")
        queue.approve(1)
        queue.removeAll()
        #expect(queue.request(session: 2, deviceID: "aa:bb", name: "Red7", model: "iPad") == .waiting)
    }
}
