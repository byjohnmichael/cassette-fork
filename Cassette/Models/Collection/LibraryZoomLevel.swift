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

    /// The grid index under `point`, given in content coordinates (scroll offset already added).
    /// Nil outside the grid. The caller still checks the index against the item count, since the
    /// last row may be short.
    static func index(at point: CGPoint, columns: Int, containerWidth width: CGFloat) -> Int? {
        guard columns > 0, point.x >= 0, point.y >= 0, point.x < width else { return nil }
        let pitch = tileSide(columns: columns, containerWidth: width) + tileSpacing
        guard pitch > 0 else { return nil }
        let column = min(columns - 1, Int(point.x / pitch))
        return Int(point.y / pitch) * columns + column
    }

    /// The top edge, in content coordinates, of the row holding `index`.
    static func rowTop(of index: Int, columns: Int, containerWidth width: CGFloat) -> CGFloat {
        guard columns > 0, index >= 0 else { return 0 }
        let pitch = tileSide(columns: columns, containerWidth: width) + tileSpacing
        return CGFloat(index / columns) * pitch
    }
}

// MARK: - Pinch

/// How a pinch maps onto zoom levels. The gesture reports a magnification: above 1 the fingers
/// spread, below 1 they pinch together.
nonisolated enum LibraryPinch {
    /// Spreading two fingers makes tiles larger (Songs → Albums → Artists), as in Photos.
    static let spreadZoomsIn = false

    /// Lifting the fingers past this fraction of a step commits it; short of it springs back.
    static let commitProgress: CGFloat = 0.5

    /// How far, on a log scale, a pinch with nowhere to go still follows the fingers.
    static let rubberBand: CGFloat = 0.08

    /// The level a pinch at `magnification` heads towards from `level`. Nil when there is
    /// nowhere to go in that direction.
    static func candidate(from level: LibraryZoomLevel, magnification: CGFloat) -> LibraryZoomLevel? {
        guard magnification != 1 else { return nil }
        let spreading = magnification > 1
        return spreading == spreadZoomsIn ? level.zoomedIn : level.zoomedOut
    }

    /// How much larger a tile at `target` is than one at `level`.
    static func sizeRatio(from level: LibraryZoomLevel, to target: LibraryZoomLevel) -> CGFloat {
        CGFloat(LibraryGridMetrics.baseColumns(level)) / CGFloat(LibraryGridMetrics.baseColumns(target))
    }

    /// How far, from 0 to 1, the pinch has carried the grid towards the next level. Spreading
    /// the fingers by exactly the tiles' size ratio completes the step, so tiles track the fingers.
    static func progress(from level: LibraryZoomLevel, magnification: CGFloat) -> CGFloat {
        guard magnification > 0, let target = candidate(from: level, magnification: magnification) else { return 0 }
        let needed = abs(log(Double(sizeRatio(from: level, to: target))))
        guard needed > 0 else { return 0 }
        return CGFloat(min(1, abs(log(Double(magnification))) / needed))
    }

    /// The level to settle on when the fingers lift: the next level once past halfway,
    /// otherwise `level` itself.
    static func resolve(from level: LibraryZoomLevel, magnification: CGFloat) -> LibraryZoomLevel {
        guard progress(from: level, magnification: magnification) >= commitProgress,
              let target = candidate(from: level, magnification: magnification) else { return level }
        return target
    }

    /// The scale for a pinch with nowhere to go: it follows the fingers a little, then resists.
    static func rubberBandScale(magnification: CGFloat) -> CGFloat {
        let stretch = log(Double(max(magnification, 0.01)))
        let band = Double(rubberBand)
        return CGFloat(exp(band * tanh(stretch / band)))
    }
}
