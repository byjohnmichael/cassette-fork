// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import CoreGraphics
import Foundation

/// One level's grid, laid out in content coordinates: tile `i` sits at row `i / columns`.
nonisolated struct CollectionGridGeometry: Equatable, Sendable {
    let columns: Int
    let width: CGFloat

    init(level: LibraryZoomLevel, containerWidth: CGFloat) {
        columns = LibraryGridMetrics.columns(for: level, containerWidth: containerWidth)
        width = containerWidth
    }

    var side: CGFloat { LibraryGridMetrics.tileSide(columns: columns, containerWidth: width) }
    var pitch: CGFloat { side + LibraryGridMetrics.tileSpacing }

    func frame(of index: Int) -> CGRect {
        guard columns > 0 else { return .zero }
        return CGRect(
            x: CGFloat(index % columns) * pitch,
            y: CGFloat(index / columns) * pitch,
            width: side,
            height: side
        )
    }

    func contentHeight(count: Int) -> CGFloat {
        guard columns > 0, count > 0 else { return 0 }
        let rows = (count + columns - 1) / columns
        return CGFloat(rows) * pitch - LibraryGridMetrics.tileSpacing
    }

    /// The tiles whose rows overlap `minY...maxY` (content coordinates).
    func indices(fromY minY: CGFloat, toY maxY: CGFloat, count: Int) -> Range<Int> {
        guard columns > 0, count > 0, pitch > 0, maxY >= minY else { return 0..<0 }
        let firstRow = max(0, Int((minY / pitch).rounded(.down)))
        let lastRow = max(0, Int((maxY / pitch).rounded(.down)))
        let lower = min(count, firstRow * columns)
        let upper = min(count, (lastRow + 1) * columns)
        return lower..<upper
    }
}

/// Where the scroll view stands: its offset and the room it has.
nonisolated struct CollectionViewport: Equatable, Sendable {
    var offsetY: CGFloat = 0
    var insetTop: CGFloat = 0
    var insetBottom: CGFloat = 0
    var height: CGFloat = 0

    /// The offset with the content scrolled all the way up.
    var minOffset: CGFloat { -insetTop }

    /// The tallest the grid content is laid out, so a pinch anywhere lands on it.
    var minContentHeight: CGFloat { max(0, height - insetTop - insetBottom) }

    func maxOffset(contentHeight: CGFloat) -> CGFloat {
        max(minOffset, max(contentHeight, minContentHeight) + insetBottom - height)
    }

    func clamp(_ offset: CGFloat, contentHeight: CGFloat) -> CGFloat {
        min(max(offset, minOffset), maxOffset(contentHeight: contentHeight))
    }
}

/// A pinch between two adjacent levels, as a blend of both layouts.
///
/// Every tile on screen at either end is drawn with its frame interpolated between the two, the
/// way Photos re-flows its grid under the fingers. The levels nest — an artist holds albums, an
/// album holds songs — so the finer level's tiles grow out of their parent's tile as it fades,
/// and gather back into it the other way.
nonisolated struct CollectionZoomTransition: Sendable {
    let from: LibraryZoomLevel
    let to: LibraryZoomLevel
    let fromGeometry: CollectionGridGeometry
    let toGeometry: CollectionGridGeometry
    /// The scroll offset each layout is shown at. `toOffset` keeps the anchor under the fingers.
    let fromOffset: CGFloat
    let toOffset: CGFloat
    let anchorFrom: Int
    let anchorTo: Int

    /// One tile drawn during the transition, in viewport coordinates (0 is the scroll view's top).
    struct Tile: Identifiable, Sendable {
        let level: LibraryZoomLevel
        let index: Int
        let frame: CGRect
        let opacity: Double

        var id: String { "\(level.rawValue)-\(index)" }
    }

    /// Plans the step from `from` to `to` around the tile at `anchor`, which the fingers touch at
    /// `fingerContentY` (content coordinates of the `from` layout). Nil unless the levels are
    /// adjacent and the anchor exists.
    static func make(
        library: CollectionLibrary,
        from: LibraryZoomLevel,
        to: LibraryZoomLevel,
        anchor: Int,
        fingerContentY: CGFloat,
        viewport: CollectionViewport,
        containerWidth: CGFloat
    ) -> CollectionZoomTransition? {
        guard abs(from.rawValue - to.rawValue) == 1, containerWidth > 0,
              let anchorTo = library.anchorIndex(anchor, from: from, to: to) else { return nil }
        let fromGeometry = CollectionGridGeometry(level: from, containerWidth: containerWidth)
        let toGeometry = CollectionGridGeometry(level: to, containerWidth: containerWidth)

        // Keep the same point of the anchor under the fingers: a finger a third of the way down
        // the tile stays a third of the way down the tile it becomes.
        let anchorFrame = fromGeometry.frame(of: anchor)
        let fraction = min(max((fingerContentY - anchorFrame.minY) / max(fromGeometry.side, 1), 0), 1)
        let fingerInViewport = fingerContentY - viewport.offsetY
        let wanted = toGeometry.frame(of: anchorTo).minY + fraction * toGeometry.side - fingerInViewport
        let toOffset = viewport.clamp(wanted, contentHeight: toGeometry.contentHeight(count: library.count(at: to)))

        return CollectionZoomTransition(
            from: from, to: to,
            fromGeometry: fromGeometry, toGeometry: toGeometry,
            fromOffset: viewport.offsetY, toOffset: toOffset,
            anchorFrom: anchor, anchorTo: anchorTo
        )
    }

    /// The coarser level of the two (fewer, larger tiles) — the one whose tiles hold the others.
    var parentLevel: LibraryZoomLevel { from.rawValue < to.rawValue ? from : to }
    var childLevel: LibraryZoomLevel { from.rawValue < to.rawValue ? to : from }

    private var parentGeometry: CollectionGridGeometry { parentLevel == from ? fromGeometry : toGeometry }
    private var childGeometry: CollectionGridGeometry { parentLevel == from ? toGeometry : fromGeometry }
    private var parentOffset: CGFloat { parentLevel == from ? fromOffset : toOffset }
    private var childOffset: CGFloat { parentLevel == from ? toOffset : fromOffset }

    /// The tiles to draw at `progress` (0 is the `from` layout, 1 the `to` layout), for a
    /// viewport `height` points tall. Values past either end are clamped.
    func tiles(at progress: CGFloat, library: CollectionLibrary, height: CGFloat) -> [Tile] {
        let t = min(max(progress, 0), 1)
        // How far into the finer layout: 0 shows only parents, 1 only children.
        let amount = parentLevel == from ? t : 1 - t
        let margin = max(parentGeometry.pitch, childGeometry.pitch)

        let parentCount = library.count(at: parentLevel)
        let childCount = library.count(at: childLevel)
        let visibleParents = parentGeometry.indices(
            fromY: parentOffset - margin, toY: parentOffset + height + margin, count: parentCount)
        let visibleChildren = childGeometry.indices(
            fromY: childOffset - margin, toY: childOffset + height + margin, count: childCount)

        // Everything on screen at either end, plus what it turns into.
        var parents = Set(visibleParents)
        var children = Set(visibleChildren)
        for child in visibleChildren {
            if let parent = Self.parent(of: child, level: childLevel, in: library) { parents.insert(parent) }
        }
        for parent in visibleParents {
            children.formUnion(Self.children(of: parent, level: parentLevel, in: library))
        }

        var tiles: [Tile] = []
        tiles.reserveCapacity(parents.count + children.count)
        for child in children.sorted() {
            guard let parent = Self.parent(of: child, level: childLevel, in: library) else { continue }
            let start = viewportFrame(parentGeometry.frame(of: parent), offset: parentOffset)
            let end = viewportFrame(childGeometry.frame(of: child), offset: childOffset)
            tiles.append(Tile(level: childLevel, index: child, frame: Self.lerp(start, end, amount), opacity: Double(amount)))
        }
        // Parents last, so they draw over the children growing out from under them.
        for parent in parents.sorted() {
            let start = viewportFrame(parentGeometry.frame(of: parent), offset: parentOffset)
            let firstChild = Self.children(of: parent, level: parentLevel, in: library).first
            let end = firstChild.map { viewportFrame(childGeometry.frame(of: $0), offset: childOffset) } ?? start
            tiles.append(Tile(level: parentLevel, index: parent, frame: Self.lerp(start, end, amount), opacity: Double(1 - amount)))
        }
        return tiles
    }

    private func viewportFrame(_ frame: CGRect, offset: CGFloat) -> CGRect {
        frame.offsetBy(dx: 0, dy: -offset)
    }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }

    static func parent(of child: Int, level: LibraryZoomLevel, in library: CollectionLibrary) -> Int? {
        switch level {
        case .artists: return nil
        case .albums: return child < library.albums.count ? library.albums[child].artistIndex : nil
        case .songs: return child < library.songs.count ? library.songs[child].albumIndex : nil
        }
    }

    static func children(of parent: Int, level: LibraryZoomLevel, in library: CollectionLibrary) -> Range<Int> {
        switch level {
        case .artists: return parent < library.artists.count ? library.artists[parent].albums : 0..<0
        case .albums: return parent < library.albums.count ? library.albums[parent].songs : 0..<0
        case .songs: return 0..<0
        }
    }
}
