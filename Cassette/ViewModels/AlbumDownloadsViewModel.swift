// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import OSLog
import SwiftData
import SwiftSonic

/// How much of one album is on the device.
nonisolated enum AlbumDownloadStatus: Hashable, Sendable {
    case notDownloaded
    case partial(downloaded: Int, total: Int)
    case downloaded

    /// `downloaded` tracks on disk out of the album's `songCount`. An album the server reports
    /// as empty counts as downloaded only when something of it is on disk.
    init(downloaded: Int, songCount: Int) {
        if downloaded <= 0 {
            self = .notDownloaded
        } else if downloaded >= songCount {
            self = .downloaded
        } else {
            self = .partial(downloaded: downloaded, total: songCount)
        }
    }

    var isComplete: Bool { self == .downloaded }
    var hasAnything: Bool { self != .notDownloaded }
}

/// The filter chips on the Manage Downloads page.
nonisolated enum AlbumDownloadFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case downloaded
    case notDownloaded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return String(localized: "All")
        case .downloaded: return String(localized: "Downloaded")
        case .notDownloaded: return String(localized: "Not Downloaded")
        }
    }

    /// Partly downloaded albums count as not downloaded: there is still something to fetch.
    func includes(_ status: AlbumDownloadStatus) -> Bool {
        switch self {
        case .all: return true
        case .downloaded: return status.isComplete
        case .notDownloaded: return !status.isComplete
        }
    }
}

/// Every album on the server, set against what is downloaded, with whole-library download and
/// delete. Downloaded counts come from the view's live query, so this only holds the album list
/// and the state of the bulk actions.
@Observable
@MainActor
final class AlbumDownloadsViewModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var albums: [AlbumID3] = []
    private(set) var loadState: LoadState = .loading

    /// Albums finished during the current Download All, out of `bulkTotal`.
    private(set) var bulkDone = 0
    private(set) var bulkTotal = 0
    private(set) var bulkCurrentName: String?
    private(set) var bulkCurrentId: String?
    private(set) var isDeletingAll = false
    /// Albums with a single-album download in flight from this page.
    private(set) var downloadingIds: Set<String> = []

    private(set) var downloadAllTask: Task<Void, Never>?
    var isDownloadingAll: Bool { downloadAllTask != nil }

    private let libraryService: any LibraryServiceProtocol
    private let downloadService: any DownloadServiceProtocol
    private let modelContainer: ModelContainer
    private let serverId: UUID

    init(
        libraryService: any LibraryServiceProtocol,
        downloadService: any DownloadServiceProtocol,
        modelContainer: ModelContainer,
        serverId: UUID
    ) {
        self.libraryService = libraryService
        self.downloadService = downloadService
        self.modelContainer = modelContainer
        self.serverId = serverId
    }

    func load() async {
        if albums.isEmpty { loadState = .loading }
        do {
            let all = try await libraryService.allAlbums()
            albums = all.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            loadState = .loaded
        } catch {
            if albums.isEmpty { loadState = .failed(error.localizedDescription) }
        }
    }

    // MARK: - Single album

    func download(_ album: AlbumID3) async {
        guard !downloadingIds.contains(album.id) else { return }
        downloadingIds.insert(album.id)
        defer { downloadingIds.remove(album.id) }
        await fetchAndDownload(album)
    }

    func delete(albumId: String) async {
        await remove(albumIds: [albumId])
    }

    // MARK: - Bulk

    /// Downloads `albums` one after another; each album fans out over its own tracks.
    func downloadAll(_ albums: [AlbumID3]) {
        guard downloadAllTask == nil, !albums.isEmpty else { return }
        bulkDone = 0
        bulkTotal = albums.count
        downloadAllTask = Task { [weak self] in
            for album in albums {
                guard let self, !Task.isCancelled else { break }
                self.bulkCurrentName = album.name
                self.bulkCurrentId = album.id
                await self.fetchAndDownload(album)
                self.bulkDone += 1
            }
            self?.bulkCurrentName = nil
            self?.bulkCurrentId = nil
            self?.downloadAllTask = nil
        }
    }

    /// Stops after the album in progress; tracks already on disk stay.
    func cancelDownloadAll() {
        downloadAllTask?.cancel()
    }

    /// Removes every downloaded track that belongs to an album.
    func deleteAll() async {
        guard !isDeletingAll else { return }
        isDeletingAll = true
        defer { isDeletingAll = false }
        let sid = serverId
        let context = ModelContext(modelContainer)
        let tracks = (try? context.fetch(FetchDescriptor<DownloadedTrack>(
            predicate: #Predicate { $0.serverId == sid && $0.albumId != nil }
        ))) ?? []
        await remove(albumIds: Set(tracks.compactMap(\.albumId)))
    }

    // MARK: - Private

    private func fetchAndDownload(_ album: AlbumID3) async {
        do {
            // The list endpoint carries no tracks; the album endpoint does.
            let full = try await libraryService.album(id: album.id)
            try await downloadService.download(album: full, serverId: serverId)
        } catch {
            Logger.download.error("Download failed for album '\(album.id, privacy: .public)': \(error, privacy: .public)")
        }
    }

    /// Album records first, which also clears their tracks; then any track downloaded on its own.
    private func remove(albumIds: Set<String>) async {
        let sid = serverId
        for albumId in albumIds {
            try? await downloadService.remove(albumId: albumId, serverId: sid)
            let aid: String? = albumId
            let context = ModelContext(modelContainer)
            let leftovers = (try? context.fetch(FetchDescriptor<DownloadedTrack>(
                predicate: #Predicate { $0.serverId == sid && $0.albumId == aid }
            ))) ?? []
            for track in leftovers {
                try? await downloadService.remove(songId: track.songId, serverId: sid)
            }
        }
    }
}
