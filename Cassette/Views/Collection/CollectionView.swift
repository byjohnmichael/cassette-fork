// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftData

/// The Collection tab: everything downloaded, as one Photos-style grid at three zoom levels.
/// Pinching moves between Artists, Albums and Songs and keeps the tile under the fingers in place.
struct CollectionView: View {
    @Environment(\.appContainer) private var container

    var body: some View {
        Group {
            if let serverId = container?.serverState.activeServer?.id {
                CollectionContent(serverId: serverId)
            } else {
                EmptyStateView(
                    systemImage: "square.grid.3x3",
                    title: "No Server",
                    subtitle: "Connect to a server to build your collection."
                )
            }
        }
        .navigationTitle("Collection")
    }
}

/// Where a tile in the collection leads.
nonisolated enum CollectionDestination: Hashable {
    case album(id: String, name: String, coverArtId: String?)
}

// MARK: - Content

private struct CollectionContent: View {
    @Environment(\.appContainer) private var container
    @Query private var tracks: [DownloadedTrack]

    @State private var library = CollectionLibrary.empty
    @State private var level: LibraryZoomLevel = .albums
    @State private var position = ScrollPosition(idType: CollectionItemID.self)
    @State private var viewport = CollectionViewport()
    @State private var containerWidth: CGFloat = 0
    /// The step being pinched or animated, drawn over the hidden grid until it settles.
    @State private var transition: CollectionZoomTransition?
    @State private var transitionProgress: CGFloat = 0
    @State private var isSettling = false
    /// The real grid is back underneath; the canvas stays on top until its artwork has drawn.
    @State private var isHandingOver = false
    /// A pinch with nowhere to go: the grid stretches a little and springs back.
    @State private var rubberBand: (scale: CGFloat, anchor: UnitPoint)?

    init(serverId: UUID) {
        let sid = serverId
        _tracks = Query(filter: #Predicate<DownloadedTrack> { $0.serverId == sid })
    }

    private var geometry: CollectionGridGeometry {
        CollectionGridGeometry(level: level, containerWidth: containerWidth)
    }

    /// The tile at the top of the visible grid, which names the header subtitle.
    private var topIndex: Int {
        if let id = position.viewID(type: CollectionItemID.self), let index = library.index(of: id) {
            return index
        }
        return 0
    }

    var body: some View {
        Group {
            if library.isEmpty {
                EmptyStateView(
                    systemImage: "square.grid.3x3",
                    title: "Nothing in your collection",
                    subtitle: "Albums and songs you download appear here, even offline."
                )
            } else {
                grid
            }
        }
        .onChange(of: tracks, initial: true) { _, tracks in
            library = CollectionLibrary.build(tracks: tracks.map(CollectionTrackRecord.init(from:)))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Zoom", selection: Binding(get: { level }, set: { pick($0) })) {
                    ForEach(LibraryZoomLevel.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .sensoryFeedback(.selection, trigger: level)
        .modifier(SubtitleModifier(subtitle: library.isEmpty ? nil : library.subtitle(forTopIndex: topIndex, level: level)))
        .navigationDestination(for: CollectionDestination.self) { destination in
            switch destination {
            case .album(let id, let name, let coverArtId):
                AlbumDetailView(albumId: id, albumName: name, coverArtId: coverArtId, mode: .downloadedOnly)
            }
        }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: LibraryGridMetrics.tileSpacing), count: max(geometry.columns, 1)),
                spacing: LibraryGridMetrics.tileSpacing
            ) {
                ForEach(0..<library.count(at: level), id: \.self) { index in
                    tile(at: index)
                        .id(library.itemID(at: index, level: level))
                }
            }
            .scrollTargetLayout()
            .id(level)
            // Hidden, not removed, while a step is drawn: the pinch lives on this view.
            .opacity(transition == nil || isHandingOver ? 1 : 0)
            // Fill the screen even when the grid is short, so a pinch anywhere lands on it.
            .frame(minHeight: viewport.minContentHeight, alignment: .top)
            .overlay(alignment: .topLeading) {
                if let transition {
                    ZoomTransitionCanvas(
                        progress: transitionProgress,
                        transition: transition,
                        library: library,
                        viewportHeight: viewport.height
                    )
                    // The canvas works in viewport coordinates; the overlay sits in content ones.
                    .offset(y: viewport.offsetY)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            // Ahead of the tiles' own taps, so two fingers landing on a song never play it.
            .highPriorityGesture(pinchGesture)
        }
        .scrollDisabled(transition != nil && !isHandingOver)
        .scrollPosition($position)
        .onScrollGeometryChange(for: CollectionViewport.self) { geometry in
            CollectionViewport(
                offsetY: geometry.contentOffset.y,
                insetTop: geometry.contentInsets.top,
                insetBottom: geometry.contentInsets.bottom,
                height: geometry.containerSize.height
            )
        } action: { _, new in
            viewport = new
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            containerWidth = width
        }
        .scaleEffect(rubberBand?.scale ?? 1, anchor: rubberBand?.anchor ?? .center)
        .miniPlayerBottomMargin()
    }

    @ViewBuilder
    private func tile(at index: Int) -> some View {
        let side = geometry.side
        let startsRun = library.startsArtistRun(at: index, level: level)
        Group {
            switch level {
            case .artists:
                Button { step(to: .albums, anchor: index) } label: {
                    CollectionTileArt(level: .artists, index: index, library: library, side: side)
                }
            case .albums:
                let album = library.albums[index]
                NavigationLink(value: CollectionDestination.album(id: album.id, name: album.title, coverArtId: album.coverArtId)) {
                    CollectionTileArt(level: .albums, index: index, library: library, side: side)
                }
            case .songs:
                Button { play(from: index) } label: {
                    CollectionTileArt(level: .songs, index: index, library: library, side: side)
                }
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if startsRun {
                if let artist = library.artist(forIndex: index, level: level) {
                    // Runs continue to the right, so the pill may spill over the artist's next tiles.
                    ArtistPill(name: artist.name)
                        .fixedSize()
                        .frame(maxWidth: containerWidth - CassetteSpacing.s * 2, alignment: .leading)
                        .padding(CassetteSpacing.xs)
                        .allowsHitTesting(false)
                }
            }
        }
        .zIndex(startsRun ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(library.accessibilityLabel(at: index, level: level) ?? "")
    }

    // MARK: Actions

    private func play(from index: Int) {
        let queue = library.playbackOrder
        Task { try? await container?.playerService.play(tracks: queue, startIndex: index) }
    }

    /// The level menu: one step animates like a pinch around the top tile; two steps jump.
    private func pick(_ target: LibraryZoomLevel) {
        guard target != level, transition == nil else { return }
        if abs(target.rawValue - level.rawValue) == 1 {
            step(to: target, anchor: topIndex)
        } else {
            jump(to: target)
        }
    }

    /// Animates one step to an adjacent level, keeping the tile at `anchor` where it is.
    private func step(to target: LibraryZoomLevel, anchor: Int) {
        guard transition == nil else { return }
        let frame = geometry.frame(of: anchor)
        let fingerY = max(frame.midY, viewport.offsetY + viewport.insetTop)
        guard let planned = CollectionZoomTransition.make(
            library: library, from: level, to: target, anchor: anchor,
            fingerContentY: fingerY, viewport: viewport, containerWidth: containerWidth
        ) else { return jump(to: target) }
        transitionProgress = 0
        transition = planned
        // Let the canvas appear at its start before animating, or it appears already finished.
        Task { @MainActor in settle(commit: true) }
    }

    /// Two levels at once, with no in-between to draw: swap and keep the top tile in view.
    private func jump(to target: LibraryZoomLevel) {
        let mapped = library.anchorIndex(topIndex, from: level, to: target)
        level = target
        guard let mapped, let id = library.itemID(at: mapped, level: target) else { return }
        Task { @MainActor in position.scrollTo(id: id, anchor: .top) }
    }

    /// Springs the current step to its end (`commit`) or back to its start, then hands over to
    /// the real grid at the matching scroll offset, so the swap is invisible.
    private func settle(commit: Bool) {
        guard let planned = transition else { return }
        isSettling = true
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            transitionProgress = commit ? 1 : 0
        } completion: {
            var handOver = Transaction()
            handOver.disablesAnimations = true
            withTransaction(handOver) {
                if commit {
                    level = planned.to
                    position.scrollTo(y: planned.toOffset)
                }
                isHandingOver = true
            }
            Task { @MainActor in
                // Long enough for the new grid's cached artwork to draw under the canvas.
                try? await Task.sleep(for: .milliseconds(200))
                withTransaction(handOver) {
                    transition = nil
                    transitionProgress = 0
                    isHandingOver = false
                    isSettling = false
                }
            }
        }
    }

    // MARK: Pinch

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !isSettling else { return }
                let magnification = value.magnification
                guard let target = LibraryPinch.candidate(from: level, magnification: magnification) else {
                    // Nowhere to go this way: stretch a little around the fingers.
                    if transition != nil { transition = nil }
                    rubberBand = (LibraryPinch.rubberBandScale(magnification: magnification), unitPoint(of: value.startLocation))
                    return
                }
                rubberBand = nil
                if transition?.to != target {
                    // Started, or reversed past where it began: plan the step this way.
                    guard let anchor = LibraryGridMetrics.index(at: value.startLocation, columns: geometry.columns, containerWidth: containerWidth)
                            .map({ min($0, library.count(at: level) - 1) }),
                          let planned = CollectionZoomTransition.make(
                              library: library, from: level, to: target, anchor: anchor,
                              fingerContentY: value.startLocation.y, viewport: viewport, containerWidth: containerWidth
                          ) else { return }
                    transition = planned
                }
                var live = Transaction()
                live.disablesAnimations = true
                withTransaction(live) {
                    transitionProgress = LibraryPinch.progress(from: level, magnification: magnification)
                }
            }
            .onEnded { _ in
                if rubberBand != nil {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { rubberBand = nil }
                }
                guard !isSettling, transition != nil else { return }
                settle(commit: transitionProgress >= LibraryPinch.commitProgress)
            }
    }

    /// A point in grid content coordinates as a fraction of the visible scroll view.
    private func unitPoint(of point: CGPoint) -> UnitPoint {
        guard containerWidth > 0, viewport.height > 0 else { return .center }
        return UnitPoint(x: point.x / containerWidth, y: (point.y - viewport.offsetY) / viewport.height)
    }
}

// MARK: - Transition canvas

/// The visible tiles of both levels, each at its blended frame. Animatable, so springing
/// `progress` to an end redraws every frame of the settle.
private struct ZoomTransitionCanvas: View, Animatable {
    var progress: CGFloat
    let transition: CollectionZoomTransition
    let library: CollectionLibrary
    let viewportHeight: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let tiles = transition.tiles(at: progress, library: library, height: viewportHeight)
        let artSide = max(transition.fromGeometry.side, transition.toGeometry.side)
        ZStack(alignment: .topLeading) {
            ForEach(tiles) { tile in
                CollectionTileArt(level: tile.level, index: tile.index, library: library, side: tile.frame.width, artworkSide: artSide)
                    .frame(width: tile.frame.width, height: tile.frame.height)
                    .opacity(tile.opacity)
                    .offset(x: tile.frame.minX, y: tile.frame.minY)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Tile art

/// What a tile shows, shared by the grid and the transition canvas.
private struct CollectionTileArt: View {
    let level: LibraryZoomLevel
    let index: Int
    let library: CollectionLibrary
    let side: CGFloat
    /// The size artwork is requested at. Fixed through a transition so images aren't refetched
    /// as tiles change size.
    var artworkSide: CGFloat?

    var body: some View {
        switch level {
        case .artists:
            artistTile(library.artists[index])
        case .albums:
            let album = library.albums[index]
            artwork(album.coverArtId ?? album.id)
        case .songs:
            songTile(library.songs[index])
        }
    }

    private func artwork(_ id: String) -> some View {
        CoverArtView(id: id, size: Int((artworkSide ?? side) * 2))
            .frame(width: side, height: side)
            .clipped()
    }

    private func artistTile(_ artist: CollectionArtist) -> some View {
        ZStack(alignment: .bottomLeading) {
            ArtistPlaceholderView(name: artist.name, size: side * 1.5)
                .frame(width: side, height: side)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            Text(artist.name)
                .font(.cassetteCellTitle)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(CassetteSpacing.s)
        }
        .frame(width: side, height: side)
    }

    private func songTile(_ song: CollectionSong) -> some View {
        artwork(song.song.coverArtId ?? song.song.albumId ?? song.id)
            .overlay(alignment: .bottomTrailing) {
                if let number = song.song.trackNumber {
                    Text(String(number))
                        .font(.cassetteCaption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, CassetteSpacing.xs)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(CassetteSpacing.xs)
                }
            }
    }
}

// MARK: - Pieces

/// Frosted capsule naming the artist at the start of each artist's run.
private struct ArtistPill: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.cassetteCaption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, CassetteSpacing.s)
            .padding(.vertical, CassetteSpacing.xs)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

/// The header subtitle under "Collection", where the platform has one.
private struct SubtitleModifier: ViewModifier {
    let subtitle: String?

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *), let subtitle {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
        #else
        if let subtitle {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
        #endif
    }
}
