// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// What each tile of the collection grid represents. Zooming in steps Artists → Albums → Songs,
/// so every step in shows more, smaller tiles.
nonisolated enum LibraryZoomLevel: Int, CaseIterable, Sendable, Hashable {
    case artists
    case albums
    case songs

    /// The next level in (more, smaller tiles), or nil at Songs.
    var zoomedIn: LibraryZoomLevel? { LibraryZoomLevel(rawValue: rawValue + 1) }

    /// The next level out (fewer, larger tiles), or nil at Artists.
    var zoomedOut: LibraryZoomLevel? { LibraryZoomLevel(rawValue: rawValue - 1) }

    var label: String {
        switch self {
        case .artists: return String(localized: "Artists")
        case .albums: return String(localized: "Albums")
        case .songs: return String(localized: "Songs")
        }
    }
}

// MARK: - Grid metrics

/// Column counts and spacing for the collection grid — the one place they are defined.
nonisolated enum LibraryGridMetrics {
    /// Columns at each level on an iPhone in portrait.
    static func baseColumns(_ level: LibraryZoomLevel) -> Int {
        switch level {
        case .artists: return 3
        case .albums: return 4
        case .songs: return 5
        }
    }

    /// The container width the base counts are designed for (iPhone portrait).
    static let referenceWidth: CGFloat = 390

    /// Gap between tiles, Photos-style hairline.
    static let tileSpacing: CGFloat = 1.5

    /// Columns for `level` in a container `width` points wide. Wider containers (iPad, landscape)
    /// scale the base count up proportionally; narrower ones never go below it.
    static func columns(for level: LibraryZoomLevel, containerWidth width: CGFloat) -> Int {
        let base = baseColumns(level)
        guard width > referenceWidth else { return base }
        let scaled = (CGFloat(base) * width / referenceWidth).rounded()
        return max(base, Int(scaled))
    }

    /// Side length of one square tile.
    static func tileSide(columns: Int, containerWidth width: CGFloat) -> CGFloat {
        guard columns > 0 else { return width }
        let gaps = CGFloat(columns - 1) * tileSpacing
        return max(0, (width - gaps) / CGFloat(columns))
    }
}

// MARK: - Pinch

/// How a pinch maps onto zoom levels. The gesture reports a magnification: above 1 the fingers
/// spread, below 1 they pinch together.
nonisolated enum LibraryPinch {
    /// Spreading two fingers zooms in (Artists → Albums → Songs). Flip to `false` to match Photos,
    /// where spreading makes tiles larger.
    static let spreadZoomsIn = true

    /// Magnification past which lifting the fingers commits the level change: spreading beyond
    /// this, or pinching below its reciprocal. Anything short of it springs back.
    static let commitMagnification: CGFloat = 1.3

    /// The level a pinch at `magnification` heads towards from `level`, whether or not it has
    /// passed the commit threshold. Nil when there is nowhere to go in that direction.
    static func candidate(from level: LibraryZoomLevel, magnification: CGFloat) -> LibraryZoomLevel? {
        guard magnification != 1 else { return nil }
        let spreading = magnification > 1
        return spreading == spreadZoomsIn ? level.zoomedIn : level.zoomedOut
    }

    /// How far, from 0 to 1, the gesture has travelled towards the commit threshold. Drives the
    /// live interpolation between the current and candidate layouts.
    static func progress(magnification: CGFloat) -> CGFloat {
        guard magnification > 0 else { return 0 }
        // Log scale, so pinching to 1/1.3 counts the same as spreading to 1.3.
        let travelled = abs(log(Double(magnification)))
        let needed = log(Double(commitMagnification))
        return CGFloat(min(1, travelled / needed))
    }

    /// The level to settle on when the fingers lift: the candidate once the threshold is passed,
    /// otherwise `level` itself (spring back).
    static func resolve(from level: LibraryZoomLevel, magnification: CGFloat) -> LibraryZoomLevel {
        guard progress(magnification: magnification) >= 1,
              let target = candidate(from: level, magnification: magnification) else { return level }
        return target
    }
}
