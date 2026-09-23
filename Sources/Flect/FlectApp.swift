// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AppKit
import SwiftUI

@main
struct FlectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = ReceiverController()

    var body: some Scene {
        Window("Flect", id: "main") {
            ContentView()
                .environment(controller)
                .frame(minWidth: 560, minHeight: 380)
                .task { controller.start() }
        }
        .defaultSize(width: 1024, height: 720)
        .commands {
            CommandMenu("Receiver") {
                Button("Show All") { controller.showAll() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(controller.focusedTile == nil)
                Button(controller.isRecordingCommandTarget ? "Stop Recording" : "Start Recording") {
                    controller.recordCommandTarget()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(controller.commandTarget == nil)
                Button("Save Snapshot") { controller.snapshotCommandTarget() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(controller.commandTarget == nil || !controller.canSnapshot)
                Button(controller.soundEnabled ? "Mute Sound" : "Turn Sound On") { controller.toggleSound() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(controller.tiles.isEmpty)
                Divider()
                Button("Disconnect All") { controller.disconnectAll() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(controller.connections == 0)
                Divider()
                Button("Restart Receiver") { controller.restart() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(controller)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Flect is one window; closing it means "stop receiving".
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
