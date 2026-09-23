// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AppKit
import FlectKit
import SwiftUI

/// Why an iPad might not see Flect, in plain English.
struct NetworkCheckView: View {
    @Environment(ReceiverController.self) private var controller
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Network check")
                    .font(.title2.weight(.semibold))
                Spacer()
                if controller.isCheckingNetwork {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if controller.networkFindings.isEmpty, controller.isCheckingNetwork {
                        Text("Looking around the network…")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(controller.networkFindings) { finding in
                        FindingRow(finding: finding)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Button("Copy Details for IT") { controller.copyNetworkSummary() }
                    .disabled(controller.networkFindings.isEmpty)
                Spacer()
                Button("Check Again") { controller.checkNetwork() }
                    .disabled(controller.isCheckingNetwork)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 560, height: 460)
        .task {
            if controller.networkFindings.isEmpty {
                controller.checkNetwork()
            }
        }
    }
}

private struct FindingRow: View {
    let finding: NetworkFinding

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(colour)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                Text(finding.title)
                    .font(.headline)
                Text(finding.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = finding.fix, let url = fix.url, let title = finding.fixTitle {
                    Button(title) { NSWorkspace.shared.open(url) }
                        .padding(.top, 2)
                }
            }
        }
    }

    private var symbol: String {
        switch finding.level {
        case .good: "checkmark.circle.fill"
        case .problem: "exclamationmark.triangle.fill"
        case .note: "info.circle.fill"
        }
    }

    private var colour: Color {
        switch finding.level {
        case .good: .green
        case .problem: .orange
        case .note: .secondary
        }
    }
}
