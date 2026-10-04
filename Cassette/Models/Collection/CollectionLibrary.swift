// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// One artist in the collection grid. `albums` and `songs` are the artist's contiguous runs in
/// `CollectionLibrary.albums` / `.songs` — the library is one flat flow, so a run is a range.
nonisolated struct CollectionArtist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Artist photo id for `getCoverArt` (Navidrome serves `ar-…` ids). Nil when the server has none.
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
    /// From the server's album record when there is one, so a partially loaded song list does not
    /// shrink the count shown on the album page.
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

// MARK: - Building

nonisolated extension CollectionLibrary {
    /// Builds the ordered library from the server's artist, album and song lists.
    ///
    /// Songs are grouped under their album, and albums under the album's artist — so a compilation
    /// track stays with its album rather than scattering across guest artists. Records that point
    /// at a parent the server did not list (a song whose album is missing, an album whose artist
    /// is missing) get a stand-in parent built from their own metadata instead of being dropped.
    /// Artists with no albums are left out: they have nothing to show at the other two levels.
    static func build(
        artists artistDTOs: [ArtistID3],
        albums albumDTOs: [AlbumID3],
        songs songDTOs: [Song],
        locale: Locale = .current
    ) -> CollectionLibrary {
        let order = CollectionSortOrder(locale: locale)

        // Artists, keyed by id.
        var artistDrafts: [String: ArtistDraft] = [:]
        for dto in artistDTOs where artistDrafts[dto.id] == nil {
            artistDrafts[dto.id] = ArtistDraft(id: dto.id, name: dto.name, coverArtId: dto.coverArt)
        }

        // Albums, keyed by id, each attached to an artist.
        var albumDrafts: [String: AlbumDraft] = [:]
        for dto in albumDTOs where albumDrafts[dto.id] == nil {
            let artistID = ensureArtist(id: dto.artistId, name: dto.artist, in: &artistDrafts)
            albumDrafts[dto.id] = AlbumDraft(
                id: dto.id, title: dto.name, year: dto.year, coverArtId: dto.coverArt,
                artistID: artistID, declaredSongCount: dto.songCount,
                declaredDuration: TimeInterval(dto.duration)
            )
        }

        // Songs, each attached to an album.
        var seenSongs = Set<String>()
        for dto in songDTOs where seenSongs.insert(dto.id).inserted {
            let albumID: String
            if let id = dto.albumId, albumDrafts[id] != nil {
                albumID = id
            } else {
                let artistID = ensureArtist(id: dto.artistId, name: dto.artist, in: &artistDrafts)
                albumID = dto.albumId ?? "unlisted-album:\(artistID)|\(dto.album ?? "")"
                if albumDrafts[albumID] == nil {
                    albumDrafts[albumID] = AlbumDraft(
                        id: albumID, title: dto.album ?? String(localized: "Unknown Album"),
                        year: dto.year, coverArtId: dto.coverArt, artistID: artistID,
                        declaredSongCount: nil, declaredDuration: nil
                    )
                }
            }
            albumDrafts[albumID]?.songs.append(dto)
        }

        // Albums per artist.
        var albumIDsByArtist: [String: [String]] = [:]
        for album in albumDrafts.values {
            albumIDsByArtist[album.artistID, default: []].append(album.id)
        }

        let sortedArtists = artistDrafts.values
            .filter { albumIDsByArtist[$0.id] != nil }
            .sorted { order.artistPrecedes($0.name, $0.id, $1.name, $1.id) }

        var artists: [CollectionArtist] = []
        var albums: [CollectionAlbum] = []
        var songs: [CollectionSong] = []
        artists.reserveCapacity(sortedArtists.count)
        albums.reserveCapacity(albumDrafts.count)
        songs.reserveCapacity(seenSongs.count)

        for artist in sortedArtists {
            let artistIndex = artists.count
            let albumStart = albums.count
            let songStart = songs.count

            let artistAlbums = (albumIDsByArtist[artist.id] ?? [])
                .compactMap { albumDrafts[$0] }
                .map { draft -> AlbumDraft in
                    var draft = draft
                    // An album with no year of its own takes its earliest song's.
                    if draft.year == nil { draft.year = draft.songs.compactMap(\.year).min() }
                    return draft
                }
                .sorted { order.albumPrecedes($0, $1) }

            for album in artistAlbums {
                let albumIndex = albums.count
                let ordered = album.songs.sorted { order.songPrecedes($0, $1) }
                let songStartForAlbum = songs.count
                for dto in ordered {
                    songs.append(CollectionSong(
                        song: DisplayableSong(from: dto),
                        discNumber: dto.discNumber,
                        albumIndex: albumIndex,
                        artistIndex: artistIndex
                    ))
                }
                let loadedDuration = ordered.reduce(TimeInterval(0)) { $0 + TimeInterval($1.duration ?? 0) }
                albums.append(CollectionAlbum(
                    id: album.id,
                    title: album.title,
                    year: album.year,
                    coverArtId: album.coverArtId ?? ordered.first?.coverArt,
                    artistIndex: artistIndex,
                    songs: songStartForAlbum..<songs.count,
                    songCount: album.declaredSongCount ?? ordered.count,
                    duration: album.declaredDuration ?? loadedDuration
                ))
            }

            artists.append(CollectionArtist(
                id: artist.id,
                name: artist.name,
                coverArtId: artist.coverArtId,
                albums: albumStart..<albums.count,
                songs: songStart..<songs.count
            ))
        }

        return CollectionLibrary(artists: artists, albums: albums, songs: songs)
    }

    /// Returns the id of an artist record for `id`/`name`, creating a stand-in when the server
    /// did not list one.
    private static func ensureArtist(
        id: String?, name: String?, in drafts: inout [String: ArtistDraft]
    ) -> String {
        let displayName = name ?? String(localized: "Unknown Artist")
        let key = id ?? "unlisted-artist:\(displayName)"
        if drafts[key] == nil {
            drafts[key] = ArtistDraft(id: key, name: displayName, coverArtId: nil)
        }
        return key
    }

    private struct ArtistDraft {
        let id: String
        let name: String
        let coverArtId: String?
    }

    fileprivate struct AlbumDraft {
        let id: String
        let title: String
        var year: Int?
        let coverArtId: String?
        let artistID: String
        let declaredSongCount: Int?
        let declaredDuration: TimeInterval?
        var songs: [Song] = []
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
    fileprivate func albumPrecedes(_ lhs: CollectionLibrary.AlbumDraft, _ rhs: CollectionLibrary.AlbumDraft) -> Bool {
        albumPrecedes(year: lhs.year, title: lhs.title, id: lhs.id, year: rhs.year, title: rhs.title, id: rhs.id)
    }

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
    func songPrecedes(_ lhs: Song, _ rhs: Song) -> Bool {
        let lhsDisc = lhs.discNumber ?? 1, rhsDisc = rhs.discNumber ?? 1
        if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }
        let lhsTrack = lhs.track ?? Int.max, rhsTrack = rhs.track ?? Int.max
        if lhsTrack != rhsTrack { return lhsTrack < rhsTrack }
        switch compare(lhs.title, rhs.title) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id < rhs.id
        }
    }
}
