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

            if controller.isMirroring {
                MirrorGrid(controlsVisible: controlsVisible)
                MirroringBar(visible: controlsVisible)
                if let request = controller.codeRequest {
                    CodeCard(request: request)
                }
            } else if let request = controller.codeRequest {
                CodeView(request: request)
            } else {
                WaitingView()
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
    /// taking the pointer with them, so the class sees only the devices.
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

// MARK: - Waiting for a device

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
                if controller.maxDevices > 1 {
                    Text("Up to \(controller.maxDevices) iPads can show side by side. Click one to enlarge it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
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
                if let device = controller.connectingName {
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
    let request: CodeRequest

    var body: some View {
        VStack(spacing: 24) {
            CodeText(request: request, size: 140)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// The code over devices already showing.
private struct CodeCard: View {
    let request: CodeRequest

    var body: some View {
        VStack(spacing: 16) {
            CodeText(request: request, size: 96)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .shadow(radius: 24)
    }
}

private struct CodeText: View {
    let request: CodeRequest
    let size: CGFloat

    var body: some View {
        Text(request.deviceName.map { "Type this code on “\($0)”" } ?? "Type this code on the iPad")
            .font(.system(size: size * 0.22, weight: .medium))
            .multilineTextAlignment(.center)
        Text(request.code)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .kerning(size / 6)
            .accessibilityLabel(request.code.map(String.init).joined(separator: " "))
    }
}

// MARK: - Mirroring

private struct MirroringBar: View {
    @Environment(ReceiverController.self) private var controller
    let visible: Bool

    var body: some View {
        let tiles = controller.tiles
        VStack {
            HStack(spacing: 12) {
                Label(tiles.count == 1 ? tiles[0].name : "\(tiles.count) devices",
                      systemImage: tiles.count == 1 ? "ipad.landscape" : "rectangle.split.2x1")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 20)
                if controller.focusedTile != nil {
                    Button("Show All", systemImage: "square.grid.2x2") {
                        controller.showAll()
                    }
                }
                Button(tiles.count > 1 ? "Disconnect All" : "Disconnect", systemImage: "xmark.circle") {
                    if tiles.count == 1 {
                        controller.disconnect(tiles[0].id)
                    } else {
                        controller.disconnectAll()
                    }
                }
                Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(12)

            Spacer()
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeInOut(duration: 0.2), value: visible)
    }
}
