// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import CoreGraphics
import Foundation
@testable import Cassette

/// The pinch draws both levels at once and hands back to the real grid at a computed scroll
/// offset. These pin the geometry that makes the hand-back invisible.
@Suite("Collection zoom — interpolated transition")
struct CollectionZoomTransitionTests {
    typealias F = CollectionFixtures

    /// 6 artists × 5 albums × 10 songs: tall enough to scroll at the Songs level.
    private let lib = Self.library(artists: 6)

    /// `artists` × 5 albums × 10 songs.
    private static func library(artists count: Int) -> CollectionLibrary {
        var tracks: [CollectionTrackRecord] = []
        for artist in 0..<count {
            for album in 0..<5 {
                for song in 1...10 {
                    tracks.append(F.track(
                        "s\(artist)-\(album)-\(song)", album: "a\(artist)-\(album)",
                        artist: "r\(artist)", artistName: "Artist \(artist)", track: song, year: 2000 + album
                    ))
                }
            }
        }
        return F.build(tracks)
    }

    private let width: CGFloat = 390

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.001 && abs(a.minY - b.minY) < 0.001
            && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
    }
    private let viewport = CollectionViewport(offsetY: 600, insetTop: 100, insetBottom: 80, height: 874)

    @Test("the tile under the fingers ends under the fingers, at the same point within it")
    func anchorStaysPut() throws {
        let albums = CollectionGridGeometry(level: .albums, containerWidth: width)
        let anchor = 13
        let fingerY = albums.frame(of: anchor).minY + albums.side * 0.25
        let plan = try #require(CollectionZoomTransition.make(
            library: lib, from: .albums, to: .songs, anchor: anchor,
            fingerContentY: fingerY, viewport: viewport, containerWidth: width
        ))
        let songs = CollectionGridGeometry(level: .songs, containerWidth: width)
        let before = fingerY - viewport.offsetY
        let after = songs.frame(of: plan.anchorTo).minY - plan.toOffset + songs.side * 0.25
        #expect(abs(before - after) < 0.01)
        #expect(plan.anchorTo == lib.albums[anchor].songs.lowerBound)
    }

    @Test("near the top the hand-back offset never scrolls past the start")
    func clampsAtTop() throws {
        let top = CollectionViewport(offsetY: -100, insetTop: 100, insetBottom: 80, height: 874)
        let plan = try #require(CollectionZoomTransition.make(
            library: lib, from: .songs, to: .albums, anchor: 30,
            fingerContentY: 200, viewport: top, containerWidth: width
        ))
        #expect(plan.toOffset >= top.minOffset)
    }

    @Test("only adjacent levels get a transition")
    func adjacentOnly() {
        #expect(CollectionZoomTransition.make(
            library: lib, from: .artists, to: .songs, anchor: 0,
            fingerContentY: 0, viewport: viewport, containerWidth: width
        ) == nil)
    }

    @Test("at each end only that level shows, at its own layout")
    func endpoints() throws {
        let plan = try #require(CollectionZoomTransition.make(
            library: lib, from: .albums, to: .songs, anchor: 13,
            fingerContentY: 900, viewport: viewport, containerWidth: width
        ))
        let start = plan.tiles(at: 0, library: lib, height: viewport.height)
        for tile in start {
            let expected = tile.level == .albums ? 1.0 : 0.0
            #expect(tile.opacity == expected)
            if tile.level == .albums {
                let frame = plan.fromGeometry.frame(of: tile.index).offsetBy(dx: 0, dy: -plan.fromOffset)
                #expect(Self.close(tile.frame, frame))
            }
        }
        let end = plan.tiles(at: 1, library: lib, height: viewport.height)
        for tile in end where tile.level == .songs {
            #expect(tile.opacity == 1)
            #expect(Self.close(tile.frame, plan.toGeometry.frame(of: tile.index).offsetBy(dx: 0, dy: -plan.toOffset)))
        }
        #expect(end.contains { $0.level == .songs && $0.index == plan.anchorTo })
    }

    @Test("songs grow out of their album's tile, and gather back into it")
    func childrenStartOnTheirParent() throws {
        let plan = try #require(CollectionZoomTransition.make(
            library: lib, from: .albums, to: .songs, anchor: 13,
            fingerContentY: 900, viewport: viewport, containerWidth: width
        ))
        let tiles = plan.tiles(at: 0, library: lib, height: viewport.height)
        let albumFrames = Dictionary(uniqueKeysWithValues: tiles.filter { $0.level == .albums }.map { ($0.index, $0.frame) })
        for song in tiles where song.level == .songs {
            let album = lib.songs[song.index].albumIndex
            if let frame = albumFrames[album] { #expect(Self.close(song.frame, frame)) }
        }
        // Halfway, the anchor's first song sits between its album's tile and its own slot.
        let mid = plan.tiles(at: 0.5, library: lib, height: viewport.height)
        let anchorSong = try #require(mid.first { $0.level == .songs && $0.index == plan.anchorTo })
        #expect(anchorSong.opacity == 0.5)
        #expect(anchorSong.frame.width < plan.fromGeometry.side && anchorSong.frame.width > plan.toGeometry.side)
    }

    @Test("everything visible at either end is drawn, and little else")
    func coversTheScreen() throws {
        // Large enough that the album grid runs well past one screen.
        let lib = Self.library(artists: 30)
        let plan = try #require(CollectionZoomTransition.make(
            library: lib, from: .songs, to: .albums, anchor: 130,
            fingerContentY: 2_000, viewport: viewport, containerWidth: width
        ))
        let tiles = plan.tiles(at: 0.3, library: lib, height: viewport.height)
        let visibleSongs = plan.fromGeometry.indices(
            fromY: plan.fromOffset, toY: plan.fromOffset + viewport.height, count: lib.songs.count)
        for song in visibleSongs {
            #expect(tiles.contains { $0.level == .songs && $0.index == song })
        }
        // 1,500 songs in the library; a screenful plus its albums' songs is far fewer.
        #expect(tiles.filter { $0.level == .songs }.count < lib.songs.count / 2)
    }

    @Test("grid rows map to the tiles in them")
    func indicesForRows() {
        let albums = CollectionGridGeometry(level: .albums, containerWidth: width)
        #expect(albums.indices(fromY: 0, toY: 1, count: 30) == 0..<4)
        #expect(albums.indices(fromY: albums.pitch + 1, toY: albums.pitch * 2 + 1, count: 30) == 4..<12)
        #expect(albums.indices(fromY: 0, toY: 10_000, count: 30) == 0..<30)
        #expect(albums.contentHeight(count: 5) == albums.pitch * 2 - LibraryGridMetrics.tileSpacing)
    }
}
