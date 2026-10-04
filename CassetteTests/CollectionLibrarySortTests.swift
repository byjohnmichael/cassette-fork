// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftSonic
@testable import Cassette

/// Fixtures shared by the collection library suites. The locale is pinned so the ordering does
/// not depend on the machine running the tests.
nonisolated enum CollectionFixtures {
    static let locale = Locale(identifier: "en_US")

    static func artist(_ id: String, _ name: String, cover: String? = nil) -> ArtistID3 {
        ArtistID3(id: id, name: name, coverArt: cover)
    }

    static func album(_ id: String, _ name: String, artist: String, year: Int?, songCount: Int = 0) -> AlbumID3 {
        AlbumID3(id: id, name: name, songCount: songCount, duration: 0, artistId: artist, coverArt: "c-\(id)", year: year)
    }

    static func song(
        _ id: String, album: String?, artist: String? = nil,
        disc: Int? = nil, track: Int?, title: String? = nil, albumName: String? = nil, year: Int? = nil
    ) -> Song {
        Song(
            id: id, title: title ?? id, album: albumName, track: track, year: year,
            duration: 200, discNumber: disc, albumId: album, artistId: artist
        )
    }

    static func build(artists: [ArtistID3], albums: [AlbumID3], songs: [Song]) -> CollectionLibrary {
        CollectionLibrary.build(artists: artists, albums: albums, songs: songs, locale: locale)
    }
}

@Suite("Collection library — sort rules")
struct CollectionLibrarySortTests {
    typealias F = CollectionFixtures

    // MARK: Artists

    @Test("artists sort A–Z ignoring a leading \"The\"")
    func artistsIgnoreLeadingThe() {
        let lib = F.build(
            artists: [F.artist("1", "The Beatles"), F.artist("2", "Abba"), F.artist("3", "Coldplay")],
            albums: [
                F.album("a1", "x", artist: "1", year: 1965),
                F.album("a2", "x", artist: "2", year: 1975),
                F.album("a3", "x", artist: "3", year: 2000),
            ],
            songs: []
        )
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
        let lib = F.build(
            artists: [F.artist("1", "beck"), F.artist("2", "Air"), F.artist("3", "BLUR")],
            albums: ["1", "2", "3"].map { F.album("a\($0)", "x", artist: $0, year: 2000) },
            songs: []
        )
        #expect(lib.artists.map(\.name) == ["Air", "beck", "BLUR"])
    }

    @Test("artist comparison is localized: accented letters file with their base letter")
    func localized() {
        let lib = F.build(
            artists: [F.artist("1", "Zola"), F.artist("2", "Émilie Simon"), F.artist("3", "Daft Punk")],
            albums: ["1", "2", "3"].map { F.album("a\($0)", "x", artist: $0, year: 2000) },
            songs: []
        )
        #expect(lib.artists.map(\.name) == ["Daft Punk", "Émilie Simon", "Zola"])
    }

    @Test("same sort key is broken by full name, then id, so order is stable")
    func stableTies() {
        let lib = F.build(
            artists: [F.artist("9", "The Band"), F.artist("2", "Band"), F.artist("1", "Band")],
            albums: ["9", "2", "1"].map { F.album("a\($0)", "x", artist: $0, year: 2000) },
            songs: []
        )
        #expect(lib.artists.map(\.id) == ["1", "2", "9"])
    }

    @Test("artists with no albums are left out")
    func artistsWithoutAlbumsDropped() {
        let lib = F.build(
            artists: [F.artist("1", "Alpha"), F.artist("2", "Empty")],
            albums: [F.album("a1", "x", artist: "1", year: 2000)],
            songs: []
        )
        #expect(lib.artists.map(\.id) == ["1"])
    }

    // MARK: Albums

    @Test("albums sort by release year, oldest first, within each artist")
    func albumsOldestFirst() {
        let lib = F.build(
            artists: [F.artist("1", "Alpha"), F.artist("2", "Bravo")],
            albums: [
                F.album("b-new", "Late", artist: "2", year: 2020),
                F.album("a-mid", "Middle", artist: "1", year: 2005),
                F.album("a-old", "Debut", artist: "1", year: 1999),
                F.album("b-old", "Early", artist: "2", year: 2001),
                F.album("a-new", "Latest", artist: "1", year: 2021),
            ],
            songs: []
        )
        #expect(lib.albums.map(\.id) == ["a-old", "a-mid", "a-new", "b-old", "b-new"])
        #expect(lib.artists[0].albums == 0..<3)
        #expect(lib.artists[1].albums == 3..<5)
    }

    @Test("albums without a year go after dated ones; same year ties by title")
    func albumYearTies() {
        let lib = F.build(
            artists: [F.artist("1", "Alpha")],
            albums: [
                F.album("undated", "Aardvark", artist: "1", year: nil),
                F.album("y-b", "Beta", artist: "1", year: 2010),
                F.album("y-a", "alpha", artist: "1", year: 2010),
                F.album("old", "Zulu", artist: "1", year: 1990),
            ],
            songs: []
        )
        #expect(lib.albums.map(\.id) == ["old", "y-a", "y-b", "undated"])
    }

    @Test("an album with no year takes its earliest song's year")
    func albumYearFromSongs() {
        let lib = F.build(
            artists: [F.artist("1", "Alpha")],
            albums: [
                F.album("undated", "A", artist: "1", year: nil),
                F.album("dated", "B", artist: "1", year: 2000),
            ],
            songs: [F.song("s1", album: "undated", track: 1, year: 1980)]
        )
        #expect(lib.albums.map(\.id) == ["undated", "dated"])
        #expect(lib.albums[0].year == 1980)
    }

    // MARK: Songs

    @Test("songs follow the track list: disc, then track")
    func songsTrackListOrder() {
        let lib = F.build(
            artists: [F.artist("1", "Alpha")],
            albums: [F.album("a", "Double", artist: "1", year: 2000)],
            songs: [
                F.song("d2t1", album: "a", disc: 2, track: 1),
                F.song("d1t2", album: "a", disc: 1, track: 2),
                F.song("d1t10", album: "a", disc: 1, track: 10),
                F.song("d1t1", album: "a", disc: 1, track: 1),
            ]
        )
        #expect(lib.songs.map(\.id) == ["d1t1", "d1t2", "d1t10", "d2t1"])
    }

    @Test("a missing disc counts as disc 1; a missing track number sorts last on its disc")
    func songMissingNumbers() {
        let lib = F.build(
            artists: [F.artist("1", "Alpha")],
            albums: [F.album("a", "A", artist: "1", year: 2000)],
            songs: [
                F.song("d2t1", album: "a", disc: 2, track: 1),
                F.song("untracked", album: "a", disc: 1, track: nil),
                F.song("nodisc-t2", album: "a", disc: nil, track: 2),
                F.song("d1t1", album: "a", disc: 1, track: 1),
            ]
        )
        #expect(lib.songs.map(\.id) == ["d1t1", "nodisc-t2", "untracked", "d2t1"])
    }

    @Test("the whole flow is artist, then album year, then track — one continuous order")
    func continuousFlow() {
        let lib = F.build(
            artists: [F.artist("b", "The Bravo"), F.artist("a", "Alpha")],
            albums: [
                F.album("b1", "B Second", artist: "b", year: 2010),
                F.album("a1", "A Only", artist: "a", year: 2015),
                F.album("b0", "B First", artist: "b", year: 2001),
            ],
            songs: [
                F.song("b1-2", album: "b1", track: 2),
                F.song("a1-1", album: "a1", track: 1),
                F.song("b0-1", album: "b0", track: 1),
                F.song("b1-1", album: "b1", track: 1),
                F.song("b0-2", album: "b0", track: 2),
            ]
        )
        #expect(lib.songs.map(\.id) == ["a1-1", "b0-1", "b0-2", "b1-1", "b1-2"])
        #expect(lib.playbackOrder.map(\.id) == lib.songs.map(\.id))
        #expect(lib.artists[1].songs == 1..<5)
        #expect(lib.albums[1].songs == 1..<3)
    }

    // MARK: Grouping

    @Test("songs group under their album's artist, not the track artist")
    func compilationTracksStayWithAlbum() {
        let lib = F.build(
            artists: [F.artist("va", "Various Artists"), F.artist("guest", "Guest")],
            albums: [
                F.album("comp", "Compilation", artist: "va", year: 2000),
                F.album("solo", "Solo", artist: "guest", year: 2001),
            ],
            songs: [F.song("t1", album: "comp", artist: "guest", track: 1)]
        )
        let song = lib.songs[0]
        #expect(lib.artists[song.artistIndex].id == "va")
    }

    @Test("records whose parent is missing get a stand-in rather than vanishing")
    func orphansGetStandIns() {
        let lib = F.build(
            artists: [F.artist("1", "Alpha")],
            albums: [F.album("a", "Listed", artist: "1", year: 2000),
                     F.album("lost", "Unlisted Artist Album", artist: "ghost", year: 2001)],
            songs: [F.song("s", album: "missing-album", artist: "1", track: 1, albumName: "Single")]
        )
        #expect(lib.songs.map(\.id) == ["s"])
        #expect(lib.albums.contains { $0.title == "Single" })
        #expect(lib.albums.contains { $0.id == "lost" })
        #expect(lib.artists.contains { $0.id == "ghost" })
    }

    @Test("duplicate records from paging are kept once")
    func duplicatesCollapse() {
        let lib = F.build(
            artists: [F.artist("1", "Alpha"), F.artist("1", "Alpha")],
            albums: [F.album("a", "A", artist: "1", year: 2000), F.album("a", "A", artist: "1", year: 2000)],
            songs: [F.song("s", album: "a", track: 1), F.song("s", album: "a", track: 1)]
        )
        #expect(lib.count(at: .artists) == 1)
        #expect(lib.count(at: .albums) == 1)
        #expect(lib.count(at: .songs) == 1)
    }
}
