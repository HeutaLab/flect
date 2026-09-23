// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import Foundation
import Testing

@testable import FlectKit

@Suite("Network check")
struct NetworkCheckTests {
    private func facts(addresses: [NetworkFacts.Address] = [.init(interface: "en0", ip: "192.168.1.20", isWiFi: true)],
                       airPlayNames: [String] = ["Flect – Room 12"],
                       browsingFailed: Bool = false,
                       firewallOn: Bool? = false,
                       receiverRunning: Bool = true) -> NetworkFacts {
        NetworkFacts(receiverName: "Flect – Room 12", port: 54321, computerName: "Room 12 Mac",
                     addresses: addresses, airPlayNames: airPlayNames, browsingFailed: browsingFailed,
                     firewallOn: firewallOn, receiverRunning: receiverRunning)
    }

    @Test("All well: nothing is reported as a problem")
    func healthy() {
        let findings = NetworkCheck.findings(for: facts(airPlayNames: ["Flect – Room 12", "Hall Apple TV"]))
        #expect(!findings.contains { $0.level == .problem })
        #expect(findings.contains { $0.title.contains("can see “Flect – Room 12”") })
        #expect(findings.contains { $0.title.contains("1 other AirPlay device is visible") })
    }

    @Test("No network at all is the first thing said")
    func noNetwork() {
        let findings = NetworkCheck.findings(for: facts(addresses: []))
        #expect(findings.first?.level == .problem)
        #expect(findings.first?.title == "This Mac isn't on a network")
        #expect(findings.first?.fix == .network)
    }

    @Test("A receiver that never started is reported, and nothing else guessed at")
    func notRunning() {
        let findings = NetworkCheck.findings(for: facts(receiverRunning: false))
        #expect(findings.last?.title == "Flect isn't listening yet")
        #expect(!findings.contains { $0.title.contains("can see") })
    }

    @Test("Seeing nothing at all points at permission and at Bonjour")
    func seesNothing() {
        let findings = NetworkCheck.findings(for: facts(airPlayNames: [], browsingFailed: true))
        let problem = try! #require(findings.first { $0.level == .problem })
        #expect(problem.title == "Flect can't see itself on the network")
        #expect(problem.fix == .localNetwork)
        #expect(problem.detail.contains("Bonjour"))
    }

    @Test("Seeing others but not itself points at Flect, not the network")
    func othersButNotItself() {
        let findings = NetworkCheck.findings(for: facts(airPlayNames: ["Hall Apple TV", "Library Apple TV"]))
        let problem = try! #require(findings.first { $0.level == .problem })
        #expect(problem.title == "Flect isn't showing up on the network")
        #expect(problem.fix == .localNetwork)
    }

    @Test("The firewall and the Mac's own receiver are notes, not problems")
    func notes() {
        let findings = NetworkCheck.findings(for: facts(
            airPlayNames: ["Flect – Room 12", "Room 12 Mac"], firewallOn: true))
        #expect(!findings.contains { $0.level == .problem })
        #expect(findings.contains { $0.title == "The Mac's firewall is on" && $0.fix == .firewall })
        let duplicate = findings.first { $0.title.contains("its own AirPlay Receiver") }
        #expect(duplicate?.level == .note)
        #expect(duplicate?.detail.contains("two entries") == true)
    }

    /// Looks at the real network this Mac is on. Off by default: browsing
    /// may ask for permission to find devices on the local network.
    ///
    ///     FLECT_NETWORK_LIVE=1 swift test --filter "Network check"
    @Test("Live: what this Mac's network actually looks like",
          .enabled(if: ProcessInfo.processInfo.environment["FLECT_NETWORK_LIVE"] != nil))
    func live() async {
        let facts = await NetworkCheck.gather(receiverName: "Flect – test", port: 7000, receiverRunning: true)
        print("LIVE addresses: \(facts.addresses.map { "\($0.ip) on \($0.interface)\($0.isWiFi ? " (Wi-Fi)" : "")" })")
        print("LIVE AirPlay devices: \(facts.airPlayNames)")
        print("LIVE browsing failed: \(facts.browsingFailed), firewall: \(String(describing: facts.firewallOn))")
        for finding in NetworkCheck.findings(for: facts) {
            print("LIVE [\(finding.level)] \(finding.title)")
        }
    }

    @Test("A name already in use shows up as a numbered one")
    func renamedByBonjour() {
        let findings = NetworkCheck.findings(for: facts(airPlayNames: ["Flect – Room 12 (2)"]))
        #expect(!findings.contains { $0.level == .problem })
        let note = try! #require(findings.first { $0.title.contains("see this Mac as") })
        #expect(note.title.contains("Flect – Room 12 (2)"))
        #expect(note.detail.contains("already in use"))
        // The numbered name is Flect itself, not another device.
        #expect(findings.contains { $0.title == "No other AirPlay devices are visible" })
    }

    @Test("The Mac's own receiver counts even when Bonjour has numbered it")
    func numberedComputerName() {
        let findings = NetworkCheck.findings(for: facts(airPlayNames: ["Flect – Room 12", "Room 12 Mac (2)"]))
        #expect(findings.contains { $0.title.contains("its own AirPlay Receiver") })
        #expect(findings.contains { $0.title == "No other AirPlay devices are visible" })
    }

    @Test("A quiet network is worth mentioning, gently")
    func quietNetwork() {
        let findings = NetworkCheck.findings(for: facts())
        #expect(findings.contains { $0.title == "No other AirPlay devices are visible" && $0.level == .note })
    }

    @Test("The summary carries what IT needs")
    func summary() {
        let facts = facts(airPlayNames: ["Flect – Room 12", "Hall Apple TV"], firewallOn: true)
        let text = NetworkCheck.summary(for: facts, findings: NetworkCheck.findings(for: facts))
        #expect(text.contains("Listening on port: 54321"))
        #expect(text.contains("192.168.1.20 on en0 (Wi-Fi)"))
        #expect(text.contains("Mac firewall: on"))
        #expect(text.contains("Bonjour (mDNS, UDP port 5353)"))
        #expect(text.contains("[NOTE] The Mac's firewall is on"))
    }
}
