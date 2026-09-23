// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import AppKit
import FlectKit
import SwiftUI

/// Every device showing, side by side, or one enlarged.
struct MirrorGrid: View {
    @Environment(ReceiverController.self) private var controller
    let controlsVisible: Bool
    @State private var hovered: SessionID?

    var body: some View {
        let tiles = controller.tiles
        let several = tiles.count > 1
        MirrorGridLayout(
            aspectRatios: tiles.map(\.aspectRatio),
            focusedIndex: tiles.firstIndex { $0.id == controller.focusedTile },
            spacing: several ? 6 : 0
        ) {
            ForEach(tiles) { tile in
                DeviceTileView(
                    tile: tile,
                    showsName: several || controller.focusedTile != nil,
                    showsControls: controlsVisible && hovered == tile.id,
                    showsEnlarge: several || controller.focusedTile != nil,
                    isFocused: controller.focusedTile == tile.id)
                .onHover { inside in
                    if inside {
                        hovered = tile.id
                    } else if hovered == tile.id {
                        hovered = nil
                    }
                }
            }
        }
    }
}

private struct DeviceTileView: View {
    @Environment(ReceiverController.self) private var controller
    let tile: DeviceTile
    let showsName: Bool
    let showsControls: Bool
    let showsEnlarge: Bool
    let isFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            // The video layer letterboxes the picture; labels go on the picture itself.
            let picture = TileGrid.pictureFrame(aspectRatio: tile.aspectRatio, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.black
                VideoSurface(view: tile.view)
                pictureOverlays
                    .frame(width: picture.width, height: picture.height)
                    .offset(x: picture.minX, y: picture.minY)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            controller.toggleFocus(tile.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tile.name)
    }

    private var pictureOverlays: some View {
        ZStack {
            if tile.isPaused {
                Label("Paused on the device", systemImage: "pause.circle")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            if showsName || tile.isMuted {
                HStack(spacing: 6) {
                    if tile.isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .accessibilityLabel("Silenced")
                    }
                    if showsName {
                        Text(tile.name).lineLimit(1)
                    }
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsControls {
                HStack(spacing: 6) {
                    Button(tile.isMuted ? "Unmute" : "Mute",
                           systemImage: tile.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                        controller.toggleMute(tile.id)
                    }
                    .help(tile.isMuted ? "Let this device be heard" : "Silence this device")
                    if controller.canSnapshot {
                        Button("Snapshot", systemImage: "camera") {
                            controller.snapshot(tile.id)
                        }
                        .help("Save what this device shows, in Pictures ▸ Flect")
                    }
                    if showsEnlarge {
                        Button(isFocused ? "Show All" : "Enlarge",
                               systemImage: isFocused ? "square.grid.2x2" : "arrow.up.left.and.arrow.down.right") {
                            controller.toggleFocus(tile.id)
                        }
                        .help(isFocused ? "Show every device" : "Fill the window with this device")
                    }
                    Button("Disconnect", systemImage: "xmark") {
                        controller.disconnect(tile.id)
                    }
                    .help("Stop showing this device")
                }
                .labelStyle(.iconOnly)
                .padding(8)
            }
        }
    }
}

/// Arranges the tiles in whichever grid shows them largest (see `TileGrid`),
/// centring a part-filled last row. An enlarged tile fills everything; the
/// others shrink to nothing but keep decoding, so they're ready instantly.
struct MirrorGridLayout: Layout {
    var aspectRatios: [CGFloat]
    var focusedIndex: Int?
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }

        if let focusedIndex, subviews.indices.contains(focusedIndex) {
            for (index, subview) in subviews.enumerated() {
                if index == focusedIndex {
                    subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
                } else {
                    subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                                  proposal: ProposedViewSize(width: 0, height: 0))
                }
            }
            return
        }

        let grid = TileGrid.best(count: subviews.count, in: bounds.size,
                                 aspectRatios: aspectRatios, spacing: spacing)
        let cellWidth = (bounds.width - CGFloat(grid.columns - 1) * spacing) / CGFloat(grid.columns)
        let cellHeight = (bounds.height - CGFloat(grid.rows - 1) * spacing) / CGFloat(grid.rows)
        for (index, subview) in subviews.enumerated() {
            let row = index / grid.columns
            let column = index % grid.columns
            let inThisRow = min(grid.columns, subviews.count - row * grid.columns)
            let rowInset = CGFloat(grid.columns - inThisRow) * (cellWidth + spacing) / 2
            let origin = CGPoint(x: bounds.minX + rowInset + CGFloat(column) * (cellWidth + spacing),
                                 y: bounds.minY + CGFloat(row) * (cellHeight + spacing))
            subview.place(at: origin, proposal: ProposedViewSize(width: cellWidth, height: cellHeight))
        }
    }
}
