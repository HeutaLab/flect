// Flect — AirPlay receiver for Mac. GPL-3.0-or-later.

import CoreGraphics
import Foundation

/// How to arrange several devices' pictures in one window.
public enum TileGrid {
    /// The grid that shows the pictures largest. Each picture is scaled to
    /// fit its cell, so the best choice depends on their shapes (landscape
    /// iPads, portrait iPhones...) as well as the window's.
    public static func best(count: Int, in size: CGSize, aspectRatios: [CGFloat],
                            spacing: CGFloat) -> (columns: Int, rows: Int) {
        guard count > 1 else { return (1, max(count, 1)) }
        var best = (columns: 1, rows: count)
        var bestArea: CGFloat = -1
        for columns in 1...count {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let cellWidth = (size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            let cellHeight = (size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            guard cellWidth > 0, cellHeight > 0 else { continue }
            let area = (0..<count).reduce(CGFloat(0)) { total, index in
                let ratio = index < aspectRatios.count && aspectRatios[index] > 0 ? aspectRatios[index] : 4 / 3
                let width = min(cellWidth, cellHeight * ratio)
                return total + width * width / ratio
            }
            // Ties go to fewer columns (checked first).
            if area > bestArea + 0.5 {
                best = (columns, rows)
                bestArea = area
            }
        }
        return best
    }
}
