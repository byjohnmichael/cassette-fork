// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
@testable import Cassette

/// Fixtures shared by the collection library suites. The locale is pinned so the ordering does
/// not depend on the machine running the tests.
nonisolated enum CollectionFixtures {
    static let locale = Locale(identifier: "en_US")

    /// A downloaded track. `artist` is the track artist's id; its name defaults to the id.
    static func track(
        _ id: String,
        album: String?,
        albumName: String? = nil,
        artist: String?,
        artistName: String? = nil,
        disc: Int? = nil,
        track: Int?,
        year: Int? = nil,
        title: String? = nil,
        albumArtist: String? = nil,
        albumArtistName: String? = nil
    ) -> CollectionTrackRecord {
        let song = DisplayableSong(
            id: id, title: title ?? id, artist: artistName ?? artist, albumId: album,
            albumName: albumName ?? album, artistId: artist, genre: nil, duration: 200,
            trackNumber: track, isDownloaded: true, coverArtId: album.map { "c-\($0)" },
            audioFormat: nil, replayGainTrackGain: nil, replayGainTrackPeak: nil,
            replayGainAlbumGain: nil, replayGainAlbumPeak: nil,
            replayGainBaseGain: nil, replayGainFallbackGain: nil
        )
        return CollectionTrackRecord(
            song: song, discNumber: disc, year: year,
            albumArtistId: albumArtist, albumArtistName: albumArtistName
        )
    }

    /// One single-track album per artist, for tests that only care about artist order.
    static func oneAlbumEach(_ artists: [(id: String, name: String)]) -> [CollectionTrackRecord] {
        artists.map { track("t-\($0.id)", album: "a-\($0.id)", artist: $0.id, artistName: $0.name, track: 1) }
    }

    static func build(_ tracks: [CollectionTrackRecord]) -> CollectionLibrary {
        CollectionLibrary.build(tracks: tracks, locale: locale)
    }
}

@Suite("Collection library — sort rules")
struct CollectionLibrarySortTests {
    typealias F = CollectionFixtures

    // MARK: Artists

    @Test("artists sort A–Z ignoring a leading \"The\"")
    func artistsIgnoreLeadingThe() {
        let lib = F.build(F.oneAlbumEach([("1", "The Beatles"), ("2", "Abba"), ("3", "Coldplay")]))
        #expect(lib.artists.map(\.name) == ["Abba", "The Beatles", "Coldplay"])
    }

    @Test("article stripping only removes a whole leading word", arguments: [
        ("The Beatles", "Beatles"),
        ("the national", "national"),
        ("THE  Cure", "Cure"),
        ("Theatre of Tragedy", "Theatre of Tragedy"),
        ("Them Crooked Vultures", "Them Crooked Vultures"),
        ("The", "The"),
        ("The The", "The"),
        ("  The Strokes ", "Strokes"),
        ("Pretty Things, The", "Pretty Things, The"),
    ])
    func articleStripping(name: String, key: String) {
        #expect(CollectionSortOrder.artistSortKey(name) == key)
    }

    @Test("artist comparison is case-insensitive")
    func caseInsensitive() {
        let lib = F.build(F.oneAlbumEach([("1", "beck"), ("2", "Air"), ("3", "BLUR")]))
        #expect(lib.artists.map(\.name) == ["Air", "beck", "BLUR"])
    }

    @Test("artist comparison is localized: accented letters file with their base letter")
    func localized() {
        let lib = F.build(F.oneAlbumEach([("1", "Zola"), ("2", "Émilie Simon"), ("3", "Daft Punk")]))
        #expect(lib.artists.map(\.name) == ["Daft Punk", "Émilie Simon", "Zola"])
    }

    @Test("same sort key is broken by full name, then id, so order is stable")
    func stableTies() {
        let lib = F.build(F.oneAlbumEach([("9", "The Band"), ("2", "Band"), ("1", "Band")]))
        #expect(lib.artists.map(\.id) == ["1", "2", "9"])
    }

    // MARK: Albums

    @Test("albums sort by release year, oldest first, within each artist")
    func albumsOldestFirst() {
        let lib = F.build([
            F.track("1", album: "b-new", artist: "2", artistName: "Bravo", track: 1, year: 2020),
            F.track("2", album: "a-mid", artist: "1", artistName: "Alpha", track: 1, year: 2005),
            F.track("3", album: "a-old", artist: "1", artistName: "Alpha", track: 1, year: 1999),
            F.track("4", album: "b-old", artist: "2", artistName: "Bravo", track: 1, year: 2001),
            F.track("5", album: "a-new", artist: "1", artistName: "Alpha", track: 1, year: 2021),
        ])
        #expect(lib.albums.map(\.id) == ["a-old", "a-mid", "a-new", "b-old", "b-new"])
        #expect(lib.artists[0].albums == 0..<3)
        #expect(lib.artists[1].albums == 3..<5)
    }

    @Test("albums without a year go after dated ones; same year ties by title")
    func albumYearTies() {
        let lib = F.build([
            F.track("1", album: "undated", albumName: "Aardvark", artist: "1", track: 1),
            F.track("2", album: "y-b", albumName: "Beta", artist: "1", track: 1, year: 2010),
            F.track("3", album: "y-a", albumName: "alpha", artist: "1", track: 1, year: 2010),
            F.track("4", album: "old", albumName: "Zulu", artist: "1", track: 1, year: 1990),
        ])
        #expect(lib.albums.map(\.id) == ["old", "y-a", "y-b", "undated"])
    }

    @Test("an album takes the earliest year among its tracks")
    func albumYearFromTracks() {
        let lib = F.build([
            F.track("1", album: "a", artist: "1", track: 1, year: 1985),
            F.track("2", album: "a", artist: "1", track: 2, year: 1980),
            F.track("3", album: "a", artist: "1", track: 3),
        ])
        #expect(lib.albums[0].year == 1980)
    }

    // MARK: Songs

    @Test("songs follow the track list: disc, then track")
    func songsTrackListOrder() {
        let lib = F.build([
            F.track("d2t1", album: "a", artist: "1", disc: 2, track: 1),
            F.track("d1t2", album: "a", artist: "1", disc: 1, track: 2),
            F.track("d1t10", album: "a", artist: "1", disc: 1, track: 10),
            F.track("d1t1", album: "a", artist: "1", disc: 1, track: 1),
        ])
        #expect(lib.songs.map(\.id) == ["d1t1", "d1t2", "d1t10", "d2t1"])
    }

    @Test("a missing disc counts as disc 1; a missing track number sorts last on its disc")
    func songMissingNumbers() {
        let lib = F.build([
            F.track("d2t1", album: "a", artist: "1", disc: 2, track: 1),
            F.track("untracked", album: "a", artist: "1", disc: 1, track: nil),
            F.track("nodisc-t2", album: "a", artist: "1", disc: nil, track: 2),
            F.track("d1t1", album: "a", artist: "1", disc: 1, track: 1),
        ])
        #expect(lib.songs.map(\.id) == ["d1t1", "nodisc-t2", "untracked", "d2t1"])
    }

    @Test("the whole flow is artist, then album year, then track — one continuous order")
    func continuousFlow() {
        let lib = F.build([
            F.track("b1-2", album: "b1", artist: "b", artistName: "The Bravo", track: 2, year: 2010),
            F.track("a1-1", album: "a1", artist: "a", artistName: "Alpha", track: 1, year: 2015),
            F.track("b0-1", album: "b0", artist: "b", artistName: "The Bravo", track: 1, year: 2001),
            F.track("b1-1", album: "b1", artist: "b", artistName: "The Bravo", track: 1, year: 2010),
            F.track("b0-2", album: "b0", artist: "b", artistName: "The Bravo", track: 2, year: 2001),
        ])
        #expect(lib.songs.map(\.id) == ["a1-1", "b0-1", "b0-2", "b1-1", "b1-2"])
        #expect(lib.playbackOrder.map(\.id) == lib.songs.map(\.id))
        #expect(lib.artists[1].songs == 1..<5)
        #expect(lib.albums[1].songs == 1..<3)
    }

    // MARK: Grouping

    @Test("an album with a recorded album artist files under it, guests included")
    func albumArtistWins() {
        let lib = F.build([
            F.track("1", album: "comp", artist: "x", track: 1, albumArtist: "va", albumArtistName: "Curator"),
            F.track("2", album: "comp", artist: "y", track: 2),
        ])
        #expect(lib.artists.map(\.name) == ["Curator"])
        #expect(lib.albums[0].songs == 0..<2)
    }

    @Test("an album whose tracks name several artists and no album artist goes under Various Artists")
    func mixedArtistsAreVarious() {
        let lib = F.build([
            F.track("1", album: "comp", artist: "x", track: 1),
            F.track("2", album: "comp", artist: "y", track: 2),
        ])
        #expect(lib.artists.map(\.id) == [CollectionLibrary.variousArtistsID])
        #expect(lib.songs.map(\.id) == ["1", "2"])
    }

    @Test("tracks with no album id group by artist and album name")
    func unlistedAlbumsGroupByName() {
        let lib = F.build([
            F.track("1", album: nil, albumName: "Demos", artist: "1", track: 2),
            F.track("2", album: nil, albumName: "Demos", artist: "1", track: 1),
            F.track("3", album: nil, albumName: "Live", artist: "1", track: 1),
        ])
        #expect(lib.count(at: .albums) == 2)
        #expect(lib.songs(ofAlbumAt: lib.albums.firstIndex { $0.title == "Demos" } ?? -1).map(\.id) == ["2", "1"])
    }

    @Test("a track downloaded twice is kept once")
    func duplicatesCollapse() {
        let lib = F.build([
            F.track("s", album: "a", artist: "1", track: 1),
            F.track("s", album: "a", artist: "1", track: 1),
        ])
        #expect(lib.count(at: .artists) == 1)
        #expect(lib.count(at: .albums) == 1)
        #expect(lib.count(at: .songs) == 1)
    }

    @Test("no downloads: an empty library")
    func empty() {
        let lib = F.build([])
        #expect(lib.isEmpty)
        #expect(LibraryZoomLevel.allCases.allSatisfy { lib.count(at: $0) == 0 })
    }
}
