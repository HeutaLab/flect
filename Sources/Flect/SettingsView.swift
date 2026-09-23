// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import FlectKit
import SwiftUI

struct SettingsView: View {
    @Environment(ReceiverController.self) private var controller
    @AppStorage(SettingsKey.name) private var name = ""
    @AppStorage(SettingsKey.requireCode) private var requireCode = false
    @AppStorage(SettingsKey.requireApproval) private var requireApproval = false
    @AppStorage(SettingsKey.rememberApprovals) private var rememberApprovals = true
    @AppStorage(SettingsKey.playAudio) private var playAudio = true
    @AppStorage(SettingsKey.maxDevices) private var maxDevices = 4
    @State private var draftName = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draftName, prompt: Text(ReceiverName.suggested))
                    .onSubmit(applyName)
            } footer: {
                Text("What iPads see in their Screen Mirroring list. A room name works well, like “Room 12”. Press Return to apply.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Ask before showing an iPad", isOn: $requireApproval)
                if requireApproval {
                    Toggle("Remember iPads I've allowed", isOn: $rememberApprovals)
                    if !controller.allowedDeviceNames.isEmpty {
                        LabeledContent {
                            Button("Forget All") { controller.forgetAllowedDevices() }
                        } label: {
                            Text("\(controller.allowedDeviceNames.count) remembered")
                            Text(controller.allowedDeviceNames.prefix(6).joined(separator: ", "))
                                .lineLimit(2)
                        }
                    }
                }
            } footer: {
                Text("A card appears when an iPad connects, and it only reaches the screen when you say so. Several at once share one card with Show All. Remembered iPads come back without asking, this lesson and the next.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Ask for a code shown on this screen", isOn: $requireCode)
            } footer: {
                Text("Each iPad must type a new four-digit code before it can mirror, so only people in the room can connect.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("iPads on screen at once", selection: $maxDevices) {
                    Text("One at a time").tag(1)
                    ForEach([2, 3, 4, 6, 9, 12, 16, 24], id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
            } footer: {
                Text("More than one appear side by side; click one to enlarge it. Above four, each iPad sends a smaller picture so the Wi-Fi keeps up. Beyond about twelve, put this Mac on wired Ethernet if you can: the Wi-Fi, not the Mac, is what runs out first.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play the iPad's sound on this Mac", isOn: $playAudio)
            } footer: {
                Text("With several iPads, you hear the enlarged one, or else the first to connect.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { draftName = name }
        .onDisappear(perform: applyName)
        .onChange(of: requireCode) { controller.restart() }
        .onChange(of: requireApproval) { controller.setRequiresApproval(requireApproval) }
        .onChange(of: rememberApprovals) { controller.setRemembersApprovals(rememberApprovals) }
        .onChange(of: maxDevices) { controller.restart() }
        .onChange(of: playAudio) { controller.setPlaysAudio(playAudio) }
    }

    private func applyName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.isEmpty ? "" : ReceiverName.sanitized(trimmed)
        draftName = cleaned
        guard cleaned != name else { return }
        name = cleaned
        controller.restart()
    }
}
