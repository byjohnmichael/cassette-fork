// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// One artist in the collection grid. `albums` and `songs` are the artist's contiguous runs in
/// `CollectionLibrary.albums` / `.songs` — the library is one flat flow, so a run is a range.
nonisolated struct CollectionArtist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Artist photo id for the artwork cache. Nil when there is none to show.
    let coverArtId: String?
    let albums: Range<Int>
    let songs: Range<Int>
}

nonisolated struct CollectionAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let year: Int?
    let coverArtId: String?
    let artistIndex: Int
    let songs: Range<Int>
    /// Downloaded songs on this album — the collection shows only what is on the device.
    let songCount: Int
    let duration: TimeInterval
}

nonisolated struct CollectionSong: Identifiable, Hashable, Sendable {
    /// The playback model; `PlayerService` takes these as-is.
    let song: DisplayableSong
    let discNumber: Int?
    let albumIndex: Int
    let artistIndex: Int

    var id: String { song.id }
}

/// Identity of a tile at any level, independent of its grid position.
nonisolated enum CollectionItemID: Hashable, Sendable {
    case artist(String)
    case album(String)
    case song(String)

    var level: LibraryZoomLevel {
        switch self {
        case .artist: return .artists
        case .album: return .albums
        case .song: return .songs
        }
    }
}

/// The whole library as one continuous, ordered flow at three zoom levels, plus the mapping
/// between levels that keeps the item under the user's fingers in place across a pinch.
///
/// Order, identical at every level:
/// 1. artists A–Z, ignoring a leading "The", localized and case-insensitive;
/// 2. within an artist, albums by release year, oldest first (no year last);
/// 3. within an album, songs by disc number, then track number.
///
/// Grid index at a level is the index into `artists`, `albums` or `songs`.
nonisolated struct CollectionLibrary: Sendable {
    let artists: [CollectionArtist]
    let albums: [CollectionAlbum]
    let songs: [CollectionSong]

    private let artistIndexByID: [String: Int]
    private let albumIndexByID: [String: Int]
    private let songIndexByID: [String: Int]

    static let empty = CollectionLibrary(artists: [], albums: [], songs: [])

    private init(artists: [CollectionArtist], albums: [CollectionAlbum], songs: [CollectionSong]) {
        self.artists = artists
        self.albums = albums
        self.songs = songs
        artistIndexByID = Self.indexByID(artists.map(\.id))
        albumIndexByID = Self.indexByID(albums.map(\.id))
        songIndexByID = Self.indexByID(songs.map(\.id))
    }

    private static func indexByID(_ ids: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        map.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() { map[id] = index }
        return map
    }

    var isEmpty: Bool { artists.isEmpty }

    func count(at level: LibraryZoomLevel) -> Int {
        switch level {
        case .artists: return artists.count
        case .albums: return albums.count
        case .songs: return songs.count
        }
    }

    // MARK: - Identity ↔ position

    func itemID(at index: Int, level: LibraryZoomLevel) -> CollectionItemID? {
        guard index >= 0, index < count(at: level) else { return nil }
        switch level {
        case .artists: return .artist(artists[index].id)
        case .albums: return .album(albums[index].id)
        case .songs: return .song(songs[index].id)
        }
    }

    func index(of item: CollectionItemID) -> Int? {
        switch item {
        case .artist(let id): return artistIndexByID[id]
        case .album(let id): return albumIndexByID[id]
        case .song(let id): return songIndexByID[id]
        }
    }

    // MARK: - Anchor mapping

    /// The tile at `level` that should sit under the fingers after zooming from `item`:
    /// an artist lands on its first album / first song, an album on itself or its first song,
    /// a song on its album, then its artist.
    func anchor(_ item: CollectionItemID, to level: LibraryZoomLevel) -> CollectionItemID? {
        guard let index = index(of: item),
              let target = anchorIndex(index, from: item.level, to: level) else { return nil }
        return itemID(at: target, level: level)
    }

    /// Index form of ``anchor(_:to:)`` — what the grid uses, since it already holds positions.
    func anchorIndex(_ index: Int, from source: LibraryZoomLevel, to target: LibraryZoomLevel) -> Int? {
        guard index >= 0, index < count(at: source), count(at: target) > 0 else { return nil }
        switch (source, target) {
        case (.artists, .artists), (.albums, .albums), (.songs, .songs):
            return index
        case (.artists, .albums):
            return artists[index].albums.lowerBound
        case (.artists, .songs):
            return firstSong(in: artists[index].songs)
        case (.albums, .songs):
            return firstSong(in: albums[index].songs)
        case (.albums, .artists):
            return albums[index].artistIndex
        case (.songs, .albums):
            return songs[index].albumIndex
        case (.songs, .artists):
            return songs[index].artistIndex
        }
    }

    /// An album or artist whose songs did not load has an empty run; its lower bound is where the
    /// next run starts, which is the nearest song that follows — clamped for a trailing empty run.
    private func firstSong(in run: Range<Int>) -> Int {
        min(run.lowerBound, songs.count - 1)
    }

    // MARK: - Grid annotations

    /// True for the first tile of each artist's run at Albums and Songs — where the frosted artist
    /// pill goes. Never true at Artists, where every tile already is the artist.
    func startsArtistRun(at index: Int, level: LibraryZoomLevel) -> Bool {
        guard index >= 0, index < count(at: level) else { return false }
        switch level {
        case .artists:
            return false
        case .albums:
            return index == 0 || albums[index - 1].artistIndex != albums[index].artistIndex
        case .songs:
            return index == 0 || songs[index - 1].artistIndex != songs[index].artistIndex
        }
    }

    /// The artist whose run contains the tile.
    func artist(forIndex index: Int, level: LibraryZoomLevel) -> CollectionArtist? {
        guard index >= 0, index < count(at: level) else { return nil }
        switch level {
        case .artists: return artists[index]
        case .albums: return artists[albums[index].artistIndex]
        case .songs: return artists[songs[index].artistIndex]
        }
    }

    /// Header subtitle for the tile at the top of the visible grid: the artist, and at Songs
    /// "Artist · Album".
    func subtitle(forTopIndex index: Int, level: LibraryZoomLevel) -> String? {
        guard let artist = artist(forIndex: index, level: level) else { return nil }
        guard level == .songs else { return artist.name }
        return "\(artist.name) · \(albums[songs[index].albumIndex].title)"
    }

    /// VoiceOver label for a tile, e.g. "Album, Night Ferry by Neon Harbor, 2024".
    func accessibilityLabel(at index: Int, level: LibraryZoomLevel) -> String? {
        guard index >= 0, index < count(at: level) else { return nil }
        switch level {
        case .artists:
            let artist = artists[index]
            let albumCount = artist.albums.count == 1
                ? String(localized: "1 album")
                : String(localized: "\(artist.albums.count) albums")
            return String(localized: "Artist, \(artist.name), \(albumCount)")
        case .albums:
            let album = albums[index]
            let artistName = artists[album.artistIndex].name
            guard let year = album.year else {
                return String(localized: "Album, \(album.title) by \(artistName)")
            }
            return String(localized: "Album, \(album.title) by \(artistName), \(String(year))")
        case .songs:
            let song = songs[index]
            let artistName = artists[song.artistIndex].name
            let albumTitle = albums[song.albumIndex].title
            return String(localized: "Song, \(song.song.title) by \(artistName), from \(albumTitle)")
        }
    }

    // MARK: - Queues

    /// Every song in library order — the default queue, so playback runs on past an album's last
    /// track into the artist's next album.
    var playbackOrder: [DisplayableSong] { songs.map(\.song) }

    /// The songs of one album, in track-list order.
    func songs(ofAlbumAt index: Int) -> [DisplayableSong] {
        guard index >= 0, index < albums.count else { return [] }
        return songs[albums[index].songs].map(\.song)
    }

    /// The songs of one artist, albums oldest first.
    func songs(ofArtistAt index: Int) -> [DisplayableSong] {
        guard index >= 0, index < artists.count else { return [] }
        return songs[artists[index].songs].map(\.song)
    }

    /// The albums of one artist, oldest first.
    func albums(ofArtistAt index: Int) -> ArraySlice<CollectionAlbum> {
        guard index >= 0, index < artists.count else { return [] }
        return albums[artists[index].albums]
    }
}

// MARK: - Input

/// One downloaded track as the collection sees it: the playback model plus the fields the
/// ordering needs that `DisplayableSong` does not carry. Those extra fields are optional because
/// downloads made so far never recorded them — every rule below has a fallback for nil.
nonisolated struct CollectionTrackRecord: Sendable, Hashable {
    let song: DisplayableSong
    let discNumber: Int?
    /// Release year of the track's album.
    let year: Int?
    /// The album's artist, which differs from `song.artistId` on compilations and guest tracks.
    let albumArtistId: String?
    let albumArtistName: String?

    init(
        song: DisplayableSong,
        discNumber: Int? = nil,
        year: Int? = nil,
        albumArtistId: String? = nil,
        albumArtistName: String? = nil
    ) {
        self.song = song
        self.discNumber = discNumber
        self.year = year
        self.albumArtistId = albumArtistId
        self.albumArtistName = albumArtistName
    }
}

extension CollectionTrackRecord {
    @MainActor
    init(from track: DownloadedTrack) {
        self.init(song: DisplayableSong(from: track))
    }
}

// MARK: - Building

nonisolated extension CollectionLibrary {
    /// Stand-in artist for an album whose tracks name several artists and no album artist.
    static let variousArtistsID = "collection:various-artists"

    /// Builds the ordered library from downloaded tracks. Albums and artists are derived from the
    /// tracks themselves, since only what is on the device is shown.
    ///
    /// Each album goes under one artist, so a compilation stays together instead of scattering
    /// across its guests: the album artist when a track records one, else the single artist all
    /// its tracks share, else a "Various Artists" stand-in.
    static func build(tracks: [CollectionTrackRecord], locale: Locale = .current) -> CollectionLibrary {
        let order = CollectionSortOrder(locale: locale)

        // Group tracks into albums; order does not matter yet, everything is sorted below.
        var seenSongs = Set<String>()
        var albumDrafts: [String: AlbumDraft] = [:]
        for record in tracks where seenSongs.insert(record.song.id).inserted {
            let key = albumKey(for: record.song)
            albumDrafts[key, default: AlbumDraft(id: key)].tracks.append(record)
        }

        // Resolve each album's artist, title, year and cover; collect artists.
        var artistNames: [String: String] = [:]
        var albumIDsByArtist: [String: [String]] = [:]
        for key in albumDrafts.keys {
            guard var draft = albumDrafts[key] else { continue }
            let artist = albumArtist(of: draft.tracks)
            draft.artistID = artist.id
            draft.title = draft.tracks.lazy.compactMap(\.song.albumName).first
                ?? String(localized: "Unknown Album")
            draft.year = draft.tracks.compactMap(\.year).min()
            draft.coverArtId = draft.tracks.lazy.compactMap(\.song.coverArtId).first
            albumDrafts[key] = draft
            if artistNames[artist.id] == nil { artistNames[artist.id] = artist.name }
            albumIDsByArtist[artist.id, default: []].append(key)
        }

        let sortedArtistIDs = artistNames.keys.sorted {
            order.artistPrecedes(artistNames[$0] ?? "", $0, artistNames[$1] ?? "", $1)
        }

        var artists: [CollectionArtist] = []
        var albums: [CollectionAlbum] = []
        var songs: [CollectionSong] = []
        artists.reserveCapacity(sortedArtistIDs.count)
        albums.reserveCapacity(albumDrafts.count)
        songs.reserveCapacity(seenSongs.count)

        for artistID in sortedArtistIDs {
            let artistIndex = artists.count
            let albumStart = albums.count
            let songStart = songs.count

            let artistAlbums = (albumIDsByArtist[artistID] ?? [])
                .compactMap { albumDrafts[$0] }
                .sorted {
                    order.albumPrecedes(year: $0.year, title: $0.title, id: $0.id,
                                        year: $1.year, title: $1.title, id: $1.id)
                }

            for album in artistAlbums {
                let albumIndex = albums.count
                let ordered = album.tracks.sorted { order.songPrecedes($0, $1) }
                let songStartForAlbum = songs.count
                for record in ordered {
                    songs.append(CollectionSong(
                        song: record.song,
                        discNumber: record.discNumber,
                        albumIndex: albumIndex,
                        artistIndex: artistIndex
                    ))
                }
                albums.append(CollectionAlbum(
                    id: album.id,
                    title: album.title,
                    year: album.year,
                    coverArtId: album.coverArtId,
                    artistIndex: artistIndex,
                    songs: songStartForAlbum..<songs.count,
                    songCount: ordered.count,
                    duration: ordered.reduce(TimeInterval(0)) { $0 + $1.song.duration }
                ))
            }

            artists.append(CollectionArtist(
                id: artistID,
                name: artistNames[artistID] ?? "",
                // Downloads keep no artist photo; the view falls back to a monogram.
                coverArtId: nil,
                albums: albumStart..<albums.count,
                songs: songStart..<songs.count
            ))
        }

        return CollectionLibrary(artists: artists, albums: albums, songs: songs)
    }

    /// The album a track belongs to. A track with no album id is grouped with the other tracks
    /// that name the same artist and album.
    private static func albumKey(for song: DisplayableSong) -> String {
        if let albumId = song.albumId { return albumId }
        let artist = song.artistId ?? song.artist ?? ""
        return "collection:unlisted-album:\(artist)|\(song.albumName ?? "")"
    }

    private static func albumArtist(of tracks: [CollectionTrackRecord]) -> (id: String, name: String) {
        if let record = tracks.first(where: { $0.albumArtistId != nil }), let id = record.albumArtistId {
            return (id, record.albumArtistName ?? record.song.artist ?? String(localized: "Unknown Artist"))
        }
        // No album artist recorded: use the track artist when every track agrees on it.
        let keys = Set(tracks.map { record -> String in
            if let id = record.song.artistId { return id }
            guard let name = record.song.artist else { return "" }
            return "collection:artist:\(name)"
        })
        if keys.count == 1, let key = keys.first {
            let name = tracks.lazy.compactMap(\.song.artist).first
            guard !key.isEmpty, let name else {
                return ("collection:unknown-artist", String(localized: "Unknown Artist"))
            }
            return (key, name)
        }
        return (variousArtistsID, String(localized: "Various Artists"))
    }

    private struct AlbumDraft {
        let id: String
        var tracks: [CollectionTrackRecord] = []
        var artistID = ""
        var title = ""
        var year: Int?
        var coverArtId: String?
    }
}

// MARK: - Sort rules

/// The collection's ordering rules, kept separate from building so each can be tested alone.
nonisolated struct CollectionSortOrder: Sendable {
    let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    /// The name artists sort by: a leading "The " is ignored ("The Beatles" files under B). An
    /// artist called just "The", or "The " followed by nothing, keeps its name.
    static func artistSortKey(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let article = trimmed.range(of: "the ", options: [.anchored, .caseInsensitive]) else {
            return trimmed
        }
        let rest = trimmed[article.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? trimmed : rest
    }

    /// Localized, case-insensitive comparison. Numeric runs compare by value, so "2Pac" precedes
    /// "10cc" the way a person would file them.
    func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.caseInsensitive, .numeric], range: nil, locale: locale)
    }

    func artistPrecedes(_ lhsName: String, _ lhsID: String, _ rhsName: String, _ rhsID: String) -> Bool {
        switch compare(Self.artistSortKey(lhsName), Self.artistSortKey(rhsName)) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame:
            // Same key: full name next ("Beatles" before "The Beatles"), then id so equal names
            // still land in a stable order between loads.
            switch compare(lhsName, rhsName) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhsID < rhsID
            }
        }
    }

    /// Release year, oldest first; albums with no year go after dated ones. Ties by title, then id.
    func albumPrecedes(
        year lhsYear: Int?, title lhsTitle: String, id lhsID: String,
        year rhsYear: Int?, title rhsTitle: String, id rhsID: String
    ) -> Bool {
        if lhsYear != rhsYear {
            guard let lhsYear else { return false }
            guard let rhsYear else { return true }
            return lhsYear < rhsYear
        }
        switch compare(lhsTitle, rhsTitle) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhsID < rhsID
        }
    }

    /// Track-list order: disc, then track. A missing disc number counts as disc 1; a missing track
    /// number sorts after numbered tracks on its disc. Ties by title, then id.
    func songPrecedes(_ lhs: CollectionTrackRecord, _ rhs: CollectionTrackRecord) -> Bool {
        let lhsDisc = lhs.discNumber ?? 1, rhsDisc = rhs.discNumber ?? 1
        if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }
        let lhsTrack = lhs.song.trackNumber ?? Int.max, rhsTrack = rhs.song.trackNumber ?? Int.max
        if lhsTrack != rhsTrack { return lhsTrack < rhsTrack }
        switch compare(lhs.song.title, rhs.song.title) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.song.id < rhs.song.id
        }
    }
}
