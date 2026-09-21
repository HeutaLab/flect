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
                Button("Disconnect iPad") { controller.disconnect() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(controller.connections == 0)
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
