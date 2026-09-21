// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import FlectKit
import SwiftUI

struct SettingsView: View {
    @Environment(ReceiverController.self) private var controller
    @AppStorage(SettingsKey.name) private var name = ""
    @AppStorage(SettingsKey.requireCode) private var requireCode = false
    @AppStorage(SettingsKey.playAudio) private var playAudio = true
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
                Toggle("Ask for a code shown on this screen", isOn: $requireCode)
            } footer: {
                Text("Each iPad must type a new four-digit code before it can mirror, so only people in the room can connect.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play the iPad's sound on this Mac", isOn: $playAudio)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { draftName = name }
        .onDisappear(perform: applyName)
        .onChange(of: requireCode) { controller.restart() }
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
