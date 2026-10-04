// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
@testable import Cassette

@Suite("Manage Downloads — album status and filters")
struct AlbumDownloadStatusTests {

    @Test("nothing on disk is not downloaded")
    func none() {
        #expect(AlbumDownloadStatus(downloaded: 0, songCount: 10) == .notDownloaded)
    }

    @Test("some tracks on disk is partial, with the counts")
    func partial() {
        #expect(AlbumDownloadStatus(downloaded: 3, songCount: 10) == .partial(downloaded: 3, total: 10))
    }

    @Test("every track on disk is downloaded, even if the server count is lower")
    func complete() {
        #expect(AlbumDownloadStatus(downloaded: 10, songCount: 10) == .downloaded)
        #expect(AlbumDownloadStatus(downloaded: 11, songCount: 10) == .downloaded)
    }

    @Test("an album the server reports empty is downloaded only with something on disk")
    func emptyAlbum() {
        #expect(AlbumDownloadStatus(downloaded: 0, songCount: 0) == .notDownloaded)
        #expect(AlbumDownloadStatus(downloaded: 1, songCount: 0) == .downloaded)
    }

    @Test("partial albums show under Not Downloaded, not Downloaded")
    func filters() {
        let partial = AlbumDownloadStatus.partial(downloaded: 1, total: 2)
        #expect(AlbumDownloadFilter.notDownloaded.includes(partial))
        #expect(!AlbumDownloadFilter.downloaded.includes(partial))
        #expect(AlbumDownloadFilter.downloaded.includes(.downloaded))
        #expect(!AlbumDownloadFilter.notDownloaded.includes(.downloaded))
        #expect(AlbumDownloadFilter.notDownloaded.includes(.notDownloaded))
        for status in [AlbumDownloadStatus.notDownloaded, partial, .downloaded] {
            #expect(AlbumDownloadFilter.all.includes(status))
        }
    }
}
