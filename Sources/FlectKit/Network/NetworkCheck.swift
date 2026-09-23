// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import CoreWLAN
import Foundation
import Network
import SystemConfiguration

/// What the Mac can tell about its own network, gathered before judging it.
public struct NetworkFacts: Sendable, Equatable {
    public struct Address: Sendable, Equatable {
        public let interface: String
        public let ip: String
        public let isWiFi: Bool

        public init(interface: String, ip: String, isWiFi: Bool) {
            self.interface = interface
            self.ip = ip
            self.isWiFi = isWiFi
        }
    }

    /// What this Mac calls itself in the Screen Mirroring list.
    public var receiverName: String
    public var port: UInt16
    /// The Mac's own name, which its built-in AirPlay Receiver would use.
    public var computerName: String
    public var addresses: [Address]
    /// AirPlay names seen on the network, Flect's own included.
    public var airPlayNames: [String]
    /// Looking for AirPlay devices failed outright.
    public var browsingFailed: Bool
    /// Nil when the firewall's state couldn't be read.
    public var firewallOn: Bool?
    public var receiverRunning: Bool

    public init(receiverName: String, port: UInt16, computerName: String, addresses: [Address],
                airPlayNames: [String], browsingFailed: Bool, firewallOn: Bool?, receiverRunning: Bool) {
        self.receiverName = receiverName
        self.port = port
        self.computerName = computerName
        self.addresses = addresses
        self.airPlayNames = airPlayNames
        self.browsingFailed = browsingFailed
        self.firewallOn = firewallOn
        self.receiverRunning = receiverRunning
    }
}

public struct NetworkFinding: Sendable, Equatable, Identifiable {
    public enum Level: Sendable, Equatable {
        case good
        case problem
        case note
    }

    /// A System Settings page that fixes it.
    public enum Fix: String, Sendable, Equatable {
        case localNetwork = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        case firewall = "x-apple.systempreferences:com.apple.preference.security?Firewall"
        case airPlayReceiver = "x-apple.systempreferences:com.apple.preferences.sharing"
        case network = "x-apple.systempreferences:com.apple.preference.network"

        public var url: URL? { URL(string: rawValue) }
    }

    public let level: Level
    public let title: String
    public let detail: String
    public let fix: Fix?
    public let fixTitle: String?

    public var id: String { title }

    public init(level: Level, title: String, detail: String, fix: Fix? = nil, fixTitle: String? = nil) {
        self.level = level
        self.title = title
        self.detail = detail
        self.fix = fix
        self.fixTitle = fixTitle
    }
}

/// Turns what the Mac knows into plain-English findings, and gathers those
/// facts in the first place.
public enum NetworkCheck {
    /// The judgement, kept separate from the gathering so it can be tested.
    public static func findings(for facts: NetworkFacts) -> [NetworkFinding] {
        var findings: [NetworkFinding] = []

        // 1. Is this Mac on a network at all?
        if facts.addresses.isEmpty {
            findings.append(NetworkFinding(
                level: .problem,
                title: "This Mac isn't on a network",
                detail: "Join the same Wi-Fi network as the iPads. Without it, nothing can reach Flect.",
                fix: .network, fixTitle: "Open Network Settings"))
        } else {
            let wired = facts.addresses.filter { !$0.isWiFi }
            let wireless = facts.addresses.filter(\.isWiFi)
            let where_ = (wireless.map { "Wi-Fi (\($0.ip))" } + wired.map { "cable (\($0.ip))" })
                .joined(separator: " and ")
            findings.append(NetworkFinding(
                level: .good,
                title: "On the network by \(where_)",
                detail: "iPads must be on this same network. If yours are on a separate school network, they won't see Flect however well it's working."))
        }

        // 2. Is the receiver even running?
        if !facts.receiverRunning {
            findings.append(NetworkFinding(
                level: .problem,
                title: "Flect isn't listening yet",
                detail: "The receiver hasn't started. Quit Flect and open it again, and if it still doesn't start, the message on the main screen says why."))
            return findings
        }

        // 3. Can Flect see its own advertisement? That's what iPads look for.
        let ownName = facts.airPlayNames.first { matches($0, name: facts.receiverName) }
        let seesItself = ownName != nil
        if let ownName {
            if ownName == facts.receiverName {
                findings.append(NetworkFinding(
                    level: .good,
                    title: "iPads on this network can see “\(facts.receiverName)”",
                    detail: "Flect is announcing itself and can see its own announcement, so the Screen Mirroring list should show it."))
            } else {
                // Bonjour adds a number when the name is already taken.
                findings.append(NetworkFinding(
                    level: .note,
                    title: "iPads see this Mac as “\(ownName)”",
                    detail: "The name “\(facts.receiverName)” was already in use on this network, so it has been given a number. Something else is using the name: another Mac running Flect, or this Mac's earlier announcement that hasn't expired yet. Give this one its own name in Settings, such as the room it's in."))
            }
        } else if facts.browsingFailed || facts.airPlayNames.isEmpty {
            findings.append(NetworkFinding(
                level: .problem,
                title: "Flect can't see itself on the network",
                detail: "Either macOS is blocking Flect from the local network, or this network doesn't pass Bonjour, which is how iPads find AirPlay devices. Check that Flect is turned on under Local Network, then ask IT whether Bonjour (mDNS) is allowed between the iPads and this Mac. Apple TVs need exactly the same thing.",
                fix: .localNetwork, fixTitle: "Open Local Network Settings"))
        } else {
            findings.append(NetworkFinding(
                level: .problem,
                title: "Flect isn't showing up on the network",
                detail: "Other AirPlay devices are visible here, so the network passes Bonjour, but Flect's own announcement isn't getting through. Check that Flect is turned on under Local Network, then quit Flect and open it again.",
                fix: .localNetwork, fixTitle: "Open Local Network Settings"))
        }

        // 4. The firewall can block the iPads' connection even when they see Flect.
        if facts.firewallOn == true {
            findings.append(NetworkFinding(
                level: .note,
                title: "The Mac's firewall is on",
                detail: "That's fine as long as Flect is allowed to accept incoming connections. If an iPad finds Flect but can't connect, this is the first thing to check.",
                fix: .firewall, fixTitle: "Open Firewall Settings"))
        }

        // 5. Two entries in the list confuses everyone.
        if facts.airPlayNames.contains(where: { matches($0, name: facts.computerName) }) {
            findings.append(NetworkFinding(
                level: .note,
                title: "This Mac also offers its own AirPlay Receiver",
                detail: "iPads will see two entries: “\(facts.receiverName)” (Flect) and “\(facts.computerName)” (macOS's own). You can turn the built-in one off in System Settings under General ▸ AirDrop & Handoff.",
                fix: .airPlayReceiver, fixTitle: "Open Sharing Settings"))
        }

        // 6. A sign of how healthy Bonjour is here.
        let others = facts.airPlayNames.filter { !matches($0, name: facts.receiverName) && !matches($0, name: facts.computerName) }
        if others.isEmpty, seesItself {
            findings.append(NetworkFinding(
                level: .note,
                title: "No other AirPlay devices are visible",
                detail: "Not a fault in itself, but on a school network it often means Bonjour doesn't travel far. If iPads still can't see Flect, that's the thing to ask IT about."))
        } else if !others.isEmpty {
            findings.append(NetworkFinding(
                level: .good,
                title: "\(others.count) other AirPlay \(others.count == 1 ? "device is" : "devices are") visible",
                detail: "Bonjour is working on this network: \(others.prefix(4).joined(separator: ", "))."))
        }

        return findings
    }

    /// Bonjour renames a service when the name is taken: "Room 12 (2)".
    static func matches(_ advertised: String, name: String) -> Bool {
        if advertised == name { return true }
        let pattern = "^\(NSRegularExpression.escapedPattern(for: name)) \\(\\d+\\)$"
        return advertised.range(of: pattern, options: .regularExpression) != nil
    }

    /// A summary to paste into an email to IT.
    public static func summary(for facts: NetworkFacts, findings: [NetworkFinding]) -> String {
        var lines = ["Flect network check", ""]
        lines.append("Receiver name: \(facts.receiverName)")
        lines.append("Listening on port: \(facts.port)")
        lines.append("Mac name: \(facts.computerName)")
        for address in facts.addresses {
            lines.append("Address: \(address.ip) on \(address.interface)\(address.isWiFi ? " (Wi-Fi)" : "")")
        }
        lines.append("AirPlay devices visible: \(facts.airPlayNames.isEmpty ? "none" : facts.airPlayNames.joined(separator: ", "))")
        if let firewallOn = facts.firewallOn {
            lines.append("Mac firewall: \(firewallOn ? "on" : "off")")
        }
        lines.append("")
        for finding in findings {
            let mark = switch finding.level {
            case .good: "OK"
            case .problem: "PROBLEM"
            case .note: "NOTE"
            }
            lines.append("[\(mark)] \(finding.title)")
            lines.append("    \(finding.detail)")
        }
        lines.append("")
        lines.append("iPads find AirPlay receivers with Bonjour (mDNS, UDP port 5353) and then connect to the port above.")
        return lines.joined(separator: "\n")
    }

    // MARK: Gathering

    /// Looks at the network around this Mac. Takes a few seconds, because
    /// it waits to see which AirPlay devices answer.
    public static func gather(receiverName: String, port: UInt16, receiverRunning: Bool,
                              browseFor seconds: Double = 3) async -> NetworkFacts {
        async let names = airPlayNames(seconds: seconds)
        let found = await names
        return NetworkFacts(
            receiverName: receiverName,
            port: port,
            computerName: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "This Mac",
            addresses: addresses(),
            airPlayNames: found.names,
            browsingFailed: found.failed,
            firewallOn: firewallOn(),
            receiverRunning: receiverRunning)
    }

    private static func airPlayNames(seconds: Double) async -> (names: [String], failed: Bool) {
        let collector = NameCollector()
        let browser = NWBrowser(for: .bonjour(type: "_airplay._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint {
                    collector.add(name)
                }
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed = state { collector.markFailed() }
            if case .waiting = state { collector.markFailed() }
        }
        browser.start(queue: .global(qos: .userInitiated))
        try? await Task.sleep(for: .seconds(seconds))
        browser.cancel()
        return collector.result
    }

    private static func addresses() -> [NetworkFacts.Address] {
        let wifiNames = CWWiFiClient.interfaceNames() ?? []
        var found: [NetworkFacts.Address] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var entry = list
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let interface = String(cString: current.pointee.ifa_name)
            found.append(NetworkFacts.Address(interface: interface,
                                              ip: String(cString: host),
                                              isWiFi: wifiNames.contains(interface)))
        }
        return found
    }

    private static func firewallOn() -> Bool? {
        let tool = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return nil }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["--getglobalstate"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).lowercased()
        if output.contains("state = 0") || output.contains("disabled") { return false }
        if output.contains("state = 1") || output.contains("state = 2") || output.contains("enabled") { return true }
        return nil
    }

    private final class NameCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []
        private var failed = false

        func add(_ name: String) {
            lock.withLock { names.insert(name) }
        }

        func markFailed() {
            lock.withLock { failed = true }
        }

        var result: (names: [String], failed: Bool) {
            lock.withLock {
                (names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, failed && names.isEmpty)
            }
        }
    }
}
