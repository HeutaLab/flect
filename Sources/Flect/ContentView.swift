// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(ReceiverController.self) private var controller
    @State private var controlsVisible = false
    @State private var hideControls: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(view: controller.videoView)

            if let code = controller.code {
                CodeView(code: code, deviceName: controller.deviceName)
            } else if !controller.isMirroring {
                WaitingView()
            } else {
                MirroringOverlay(controlsVisible: controlsVisible)
            }
        }
        .onContinuousHover { phase in
            guard controller.isMirroring else { return }
            switch phase {
            case .active:
                showControlsBriefly()
            case .ended:
                hideControls?.cancel()
                controlsVisible = false
            }
        }
        .onChange(of: controller.isMirroring) {
            controlsVisible = false
        }
    }

    /// Controls appear when the pointer moves and fade out when it rests,
    /// taking the pointer with them, so the class sees only the iPad.
    private func showControlsBriefly() {
        controlsVisible = true
        hideControls?.cancel()
        hideControls = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

// MARK: - Waiting for an iPad

private struct WaitingView: View {
    @Environment(ReceiverController.self) private var controller

    var body: some View {
        VStack(spacing: 36) {
            VStack(spacing: 14) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.tint)
                Text(controller.receiverName)
                    .font(.system(size: 38, weight: .semibold))
                    .multilineTextAlignment(.center)
                StatusLine()
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("To show an iPad here:")
                    .font(.headline)
                Step(number: 1, text: "On the iPad, swipe down from the top-right corner to open Control Centre.")
                Step(number: 2, text: "Tap Screen Mirroring.")
                Step(number: 3, text: "Choose “\(controller.receiverName)”.")
                if controller.requiresCode {
                    Step(number: 4, text: "Type the code that appears on this screen.")
                }
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

private struct StatusLine: View {
    @Environment(ReceiverController.self) private var controller

    var body: some View {
        switch controller.status {
        case .starting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting…")
            }
            .foregroundStyle(.secondary)
        case .ready:
            HStack(spacing: 8) {
                Circle().fill(.green).frame(width: 9, height: 9)
                if let device = controller.deviceName {
                    Text("Connecting to \(device)…")
                } else {
                    Text("Ready")
                }
            }
            .foregroundStyle(.secondary)
        case .failed(let reason):
            VStack(spacing: 10) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Try Again") { controller.restart() }
            }
        }
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .frame(width: 24, height: 24)
                .background(.tint.opacity(0.15), in: Circle())
            Text(text)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Code

private struct CodeView: View {
    let code: String
    let deviceName: String?

    var body: some View {
        VStack(spacing: 24) {
            Text(deviceName.map { "Type this code on “\($0)”" } ?? "Type this code on the iPad")
                .font(.system(size: 30, weight: .medium))
                .multilineTextAlignment(.center)
            Text(code)
                .font(.system(size: 140, weight: .bold, design: .rounded))
                .monospacedDigit()
                .kerning(24)
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

// MARK: - Mirroring

private struct MirroringOverlay: View {
    @Environment(ReceiverController.self) private var controller
    let controlsVisible: Bool

    var body: some View {
        VStack {
            HStack(spacing: 12) {
                Label(controller.deviceName ?? "iPad", systemImage: "ipad.landscape")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 20)
                Button("Disconnect", systemImage: "xmark.circle") {
                    controller.disconnect()
                }
                Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(12)
            .opacity(controlsVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: controlsVisible)

            Spacer()

            if controller.isPaused {
                Label("Paused on the iPad", systemImage: "pause.circle")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(24)
            }
        }
    }
}
