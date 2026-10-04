// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftSonic
@testable import Cassette

/// The item under the user's fingers must stay under them across a level change. These pin the
/// mapping the grid relies on to do that.
@Suite("Collection library — anchor mapping")
struct CollectionLibraryAnchorTests {
    typealias F = CollectionFixtures

    /// Alpha: 1999 "First" (2 songs), 2005 "Second" (1 song)
    /// Bravo: 2010 "Only" (2 songs)
    private let lib = F.build(
        artists: [F.artist("alpha", "Alpha"), F.artist("bravo", "Bravo")],
        albums: [
            F.album("second", "Second", artist: "alpha", year: 2005),
            F.album("first", "First", artist: "alpha", year: 1999),
            F.album("only", "Only", artist: "bravo", year: 2010),
        ],
        songs: [
            F.song("second-1", album: "second", track: 1),
            F.song("first-2", album: "first", track: 2),
            F.song("first-1", album: "first", track: 1),
            F.song("only-2", album: "only", track: 2),
            F.song("only-1", album: "only", track: 1),
        ]
    )

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

    @Test("an album whose songs did not load anchors on the next song instead of failing")
    func emptyAlbumFallsForward() {
        let lib = F.build(
            artists: [F.artist("1", "Alpha")],
            albums: [
                F.album("empty", "Empty", artist: "1", year: 1990),
                F.album("full", "Full", artist: "1", year: 2000),
            ],
            songs: [F.song("full-1", album: "full", track: 1)]
        )
        #expect(lib.anchor(.album("empty"), to: .songs) == .song("full-1"))
    }

    @Test("a trailing album with no songs anchors on the last song")
    func trailingEmptyAlbumClamps() {
        let lib = F.build(
            artists: [F.artist("1", "Alpha")],
            albums: [
                F.album("full", "Full", artist: "1", year: 1990),
                F.album("empty", "Empty", artist: "1", year: 2000),
            ],
            songs: [F.song("full-1", album: "full", track: 1)]
        )
        #expect(lib.anchor(.album("empty"), to: .songs) == .song("full-1"))
    }

    @Test("no songs at all: nothing to land on")
    func noTargets() {
        let lib = F.build(
            artists: [F.artist("1", "Alpha")],
            albums: [F.album("a", "A", artist: "1", year: 2000)],
            songs: []
        )
        #expect(lib.anchor(.album("a"), to: .songs) == nil)
    }

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
        #expect(lib.subtitle(forTopIndex: 2, level: .songs) == "Alpha · Second")
    }

    @Test("tiles carry spoken labels")
    func accessibilityLabels() {
        let lib = F.build(
            artists: [F.artist("nh", "Neon Harbor")],
            albums: [F.album("nf", "Night Ferry", artist: "nh", year: 2024)],
            songs: [F.song("s", album: "nf", track: 1, title: "Lanterns")]
        )
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

    @Test("a pinch short of the threshold springs back")
    func pinchSpringsBack() {
        #expect(LibraryPinch.resolve(from: .albums, magnification: 1.1) == .albums)
        #expect(LibraryPinch.resolve(from: .albums, magnification: 0.9) == .albums)
    }

    @Test("past the threshold a pinch commits in the mapped direction")
    func pinchCommits() {
        let spreadTarget: LibraryZoomLevel = LibraryPinch.spreadZoomsIn ? .songs : .artists
        let pinchTarget: LibraryZoomLevel = LibraryPinch.spreadZoomsIn ? .artists : .songs
        #expect(LibraryPinch.resolve(from: .albums, magnification: 1.5) == spreadTarget)
        #expect(LibraryPinch.resolve(from: .albums, magnification: 0.6) == pinchTarget)
    }

    @Test("pinching past the end of the levels stays put")
    func pinchAtEnds() {
        let innermost: LibraryZoomLevel = .songs
        let spreadAtInnermost = LibraryPinch.spreadZoomsIn ? 2.0 : 0.5
        #expect(LibraryPinch.resolve(from: innermost, magnification: spreadAtInnermost) == innermost)
    }

    @Test("progress is symmetric for spread and pinch and caps at 1")
    func pinchProgress() {
        let spread = LibraryPinch.progress(magnification: 1.14)
        let pinch = LibraryPinch.progress(magnification: 1 / 1.14)
        #expect(abs(spread - pinch) < 0.0001)
        #expect(spread > 0 && spread < 1)
        #expect(LibraryPinch.progress(magnification: 1) == 0)
        #expect(LibraryPinch.progress(magnification: 3) == 1)
    }
}
