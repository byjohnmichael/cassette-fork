// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
@testable import Cassette

/// The item under the user's fingers must stay under them across a level change. These pin the
/// mapping the grid relies on to do that.
@Suite("Collection library — anchor mapping")
struct CollectionLibraryAnchorTests {
    typealias F = CollectionFixtures

    /// Alpha: 1999 "first" (2 songs), 2005 "second" (1 song)
    /// Bravo: 2010 "only" (2 songs)
    private let lib = F.build([
        F.track("second-1", album: "second", artist: "alpha", artistName: "Alpha", track: 1, year: 2005),
        F.track("first-2", album: "first", artist: "alpha", artistName: "Alpha", track: 2, year: 1999),
        F.track("first-1", album: "first", artist: "alpha", artistName: "Alpha", track: 1, year: 1999),
        F.track("only-2", album: "only", artist: "bravo", artistName: "Bravo", track: 2, year: 2010),
        F.track("only-1", album: "only", artist: "bravo", artistName: "Bravo", track: 1, year: 2010),
    ])

    // MARK: Zooming in

    @Test("an artist lands on its first album")
    func artistToAlbum() {
        #expect(lib.anchor(.artist("alpha"), to: .albums) == .album("first"))
        #expect(lib.anchor(.artist("bravo"), to: .albums) == .album("only"))
    }

    @Test("an artist lands on its first song")
    func artistToSong() {
        #expect(lib.anchor(.artist("alpha"), to: .songs) == .song("first-1"))
        #expect(lib.anchor(.artist("bravo"), to: .songs) == .song("only-1"))
    }

    @Test("an album lands on its first song")
    func albumToSong() {
        #expect(lib.anchor(.album("first"), to: .songs) == .song("first-1"))
        #expect(lib.anchor(.album("second"), to: .songs) == .song("second-1"))
    }

    // MARK: Zooming out

    @Test("a song lands on its album, then its artist")
    func songOut() {
        #expect(lib.anchor(.song("first-2"), to: .albums) == .album("first"))
        #expect(lib.anchor(.song("second-1"), to: .artists) == .artist("alpha"))
        #expect(lib.anchor(.song("only-2"), to: .artists) == .artist("bravo"))
    }

    @Test("an album lands on its artist")
    func albumToArtist() {
        #expect(lib.anchor(.album("second"), to: .artists) == .artist("alpha"))
        #expect(lib.anchor(.album("only"), to: .artists) == .artist("bravo"))
    }

    @Test("same level maps to itself")
    func identity() {
        for level in LibraryZoomLevel.allCases {
            for index in 0..<lib.count(at: level) {
                #expect(lib.anchorIndex(index, from: level, to: level) == index)
            }
        }
    }

    // MARK: Round trips

    @Test("zooming in and back out returns to the same tile")
    func roundTripInOut() {
        for (outer, inner) in [(LibraryZoomLevel.artists, LibraryZoomLevel.albums),
                               (.artists, .songs), (.albums, .songs)] {
            for index in 0..<lib.count(at: outer) {
                let down = lib.anchorIndex(index, from: outer, to: inner)
                let back = down.flatMap { lib.anchorIndex($0, from: inner, to: outer) }
                #expect(back == index, "\(outer) \(index) → \(inner) → \(outer)")
            }
        }
    }

    @Test("every tile maps to a valid tile at every level")
    func totalMapping() {
        for from in LibraryZoomLevel.allCases {
            for to in LibraryZoomLevel.allCases {
                for index in 0..<lib.count(at: from) {
                    let target = lib.anchorIndex(index, from: from, to: to)
                    #expect(target.map { (0..<lib.count(at: to)).contains($0) } == true)
                }
            }
        }
    }

    // MARK: Edges

    @Test("unknown ids and out-of-range indices map to nil")
    func invalidInput() {
        #expect(lib.anchor(.album("nope"), to: .songs) == nil)
        #expect(lib.anchorIndex(99, from: .songs, to: .albums) == nil)
        #expect(lib.anchorIndex(-1, from: .artists, to: .albums) == nil)
    }

    // MARK: Grid annotations

    @Test("the artist pill marks the first tile of each artist's run, never at Artists")
    func artistRunStarts() {
        #expect((0..<3).map { lib.startsArtistRun(at: $0, level: .albums) } == [true, false, true])
        #expect((0..<5).map { lib.startsArtistRun(at: $0, level: .songs) } == [true, false, false, true, false])
        #expect((0..<2).map { lib.startsArtistRun(at: $0, level: .artists) } == [false, false])
    }

    @Test("the header subtitle names the artist, and at Songs the album too")
    func subtitles() {
        #expect(lib.subtitle(forTopIndex: 1, level: .artists) == "Bravo")
        #expect(lib.subtitle(forTopIndex: 1, level: .albums) == "Alpha")
        #expect(lib.subtitle(forTopIndex: 2, level: .songs) == "Alpha · second")
    }

    @Test("tiles carry spoken labels")
    func accessibilityLabels() {
        let lib = F.build([
            F.track("s", album: "nf", albumName: "Night Ferry", artist: "nh", artistName: "Neon Harbor",
                    track: 1, year: 2024, title: "Lanterns"),
        ])
        #expect(lib.accessibilityLabel(at: 0, level: .albums) == "Album, Night Ferry by Neon Harbor, 2024")
        #expect(lib.accessibilityLabel(at: 0, level: .artists) == "Artist, Neon Harbor, 1 album")
        #expect(lib.accessibilityLabel(at: 0, level: .songs) == "Song, Lanterns by Neon Harbor, from Night Ferry")
    }
}

@Suite("Collection library — zoom levels and grid metrics")
struct LibraryZoomLevelTests {

    @Test("zooming in steps Artists → Albums → Songs")
    func levelOrder() {
        #expect(LibraryZoomLevel.artists.zoomedIn == .albums)
        #expect(LibraryZoomLevel.albums.zoomedIn == .songs)
        #expect(LibraryZoomLevel.songs.zoomedIn == nil)
        #expect(LibraryZoomLevel.songs.zoomedOut == .albums)
        #expect(LibraryZoomLevel.artists.zoomedOut == nil)
    }

    @Test("iPhone portrait column counts are 3, 4, 5")
    func baseColumns() {
        #expect(LibraryGridMetrics.columns(for: .artists, containerWidth: 390) == 3)
        #expect(LibraryGridMetrics.columns(for: .albums, containerWidth: 390) == 4)
        #expect(LibraryGridMetrics.columns(for: .songs, containerWidth: 390) == 5)
        // Narrower and slightly wider iPhones keep the base counts.
        #expect(LibraryGridMetrics.columns(for: .artists, containerWidth: 375) == 3)
        #expect(LibraryGridMetrics.columns(for: .artists, containerWidth: 430) == 3)
    }

    @Test("wide containers scale columns up proportionally and keep levels distinct")
    func scaledColumns() {
        for width in [744.0, 852, 932, 1024, 1366] as [CGFloat] {
            let counts = LibraryZoomLevel.allCases.map {
                LibraryGridMetrics.columns(for: $0, containerWidth: width)
            }
            #expect(counts[0] < counts[1] && counts[1] < counts[2], "\(width): \(counts)")
            #expect(counts[0] > 3, "\(width): \(counts)")
        }
        #expect(LibraryGridMetrics.columns(for: .artists, containerWidth: 1024) == 8)
    }

    @Test("tiles fill the width exactly, gaps included")
    func tileSide() {
        let side = LibraryGridMetrics.tileSide(columns: 4, containerWidth: 390)
        let total = side * 4 + LibraryGridMetrics.tileSpacing * 3
        #expect(abs(total - 390) < 0.001)
    }

    @Test("a point in the grid finds the tile under it")
    func indexAtPoint() {
        let width: CGFloat = 390
        let pitch = LibraryGridMetrics.tileSide(columns: 4, containerWidth: width) + LibraryGridMetrics.tileSpacing
        #expect(LibraryGridMetrics.index(at: CGPoint(x: 1, y: 1), columns: 4, containerWidth: width) == 0)
        #expect(LibraryGridMetrics.index(at: CGPoint(x: pitch * 2 + 1, y: 1), columns: 4, containerWidth: width) == 2)
        #expect(LibraryGridMetrics.index(at: CGPoint(x: 1, y: pitch * 3 + 1), columns: 4, containerWidth: width) == 12)
        #expect(LibraryGridMetrics.index(at: CGPoint(x: width - 0.5, y: pitch + 1), columns: 4, containerWidth: width) == 7)
        #expect(LibraryGridMetrics.index(at: CGPoint(x: -1, y: 1), columns: 4, containerWidth: width) == nil)
        #expect(LibraryGridMetrics.index(at: CGPoint(x: 1, y: -1), columns: 4, containerWidth: width) == nil)
        #expect(LibraryGridMetrics.index(at: CGPoint(x: width, y: 1), columns: 4, containerWidth: width) == nil)
    }

    @Test("a tile's row top is the inverse of the point lookup")
    func rowTop() {
        let width: CGFloat = 390
        for index in [0, 3, 4, 9, 17] {
            let top = LibraryGridMetrics.rowTop(of: index, columns: 4, containerWidth: width)
            let found = LibraryGridMetrics.index(at: CGPoint(x: 1, y: top + 1), columns: 4, containerWidth: width)
            #expect(found == index / 4 * 4)
        }
    }

    @Test("spreading makes tiles larger, as in Photos")
    func spreadDirection() {
        #expect(LibraryPinch.candidate(from: .songs, magnification: 1.2) == .albums)
        #expect(LibraryPinch.candidate(from: .albums, magnification: 1.2) == .artists)
        #expect(LibraryPinch.candidate(from: .artists, magnification: 0.8) == .albums)
        #expect(LibraryPinch.candidate(from: .albums, magnification: 1) == nil)
    }

    @Test("a pinch short of halfway springs back")
    func pinchSpringsBack() {
        #expect(LibraryPinch.resolve(from: .albums, magnification: 1.1) == .albums)
        #expect(LibraryPinch.resolve(from: .albums, magnification: 0.95) == .albums)
    }

    @Test("past halfway a pinch commits in the mapped direction")
    func pinchCommits() {
        #expect(LibraryPinch.resolve(from: .albums, magnification: 1.25) == .artists)
        #expect(LibraryPinch.resolve(from: .albums, magnification: 0.85) == .songs)
    }

    @Test("pinching past the end of the levels stays put")
    func pinchAtEnds() {
        #expect(LibraryPinch.candidate(from: .artists, magnification: 2) == nil)
        #expect(LibraryPinch.resolve(from: .artists, magnification: 2) == .artists)
        #expect(LibraryPinch.resolve(from: .songs, magnification: 0.5) == .songs)
    }

    @Test("spreading by the tiles' size ratio completes the step, so tiles track the fingers")
    func progressTracksTileSize() {
        // Albums are 4 across, artists 3: an artist tile is 4/3 the size of an album tile.
        #expect(abs(LibraryPinch.progress(from: .albums, magnification: 4.0 / 3.0) - 1) < 0.0001)
        let half = LibraryPinch.progress(from: .albums, magnification: (4.0 / 3.0).squareRoot())
        #expect(abs(half - 0.5) < 0.0001)
        #expect(LibraryPinch.progress(from: .albums, magnification: 3) == 1)
        #expect(LibraryPinch.progress(from: .albums, magnification: 1) == 0)
        #expect(LibraryPinch.progress(from: .artists, magnification: 2) == 0)
    }

    @Test("past the last level the grid stretches a little, never far")
    func rubberBand() {
        #expect(LibraryPinch.rubberBandScale(magnification: 1) == 1)
        #expect(LibraryPinch.rubberBandScale(magnification: 1.05) > 1)
        #expect(LibraryPinch.rubberBandScale(magnification: 10) < 1 + LibraryPinch.rubberBand * 1.2)
        #expect(LibraryPinch.rubberBandScale(magnification: 0.1) > 1 - LibraryPinch.rubberBand * 1.2)
    }
}
