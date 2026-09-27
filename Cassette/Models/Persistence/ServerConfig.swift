// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData

@Model
final class ServerConfig {
    var id: UUID
    var displayName: String
    var baseURL: String
    var username: String
    var isActive: Bool
    var serverVersion: String?
    var createdAt: Date
    /// The `getMusicFolders` id the user has scoped browsing to on THIS server, or `nil` for all
    /// of them. Per-server because the ids belong to one server.
    ///
    /// `nil` is both the default and the pre-existing behaviour, so servers that expose a single
    /// library — nearly all of them — are unaffected. Optional by design: SwiftData's lightweight
    /// migration adds it to existing stores as `nil` without a migration plan.
    var selectedMusicFolderId: String?
    /// Playlist kinds the user has hidden from the playlist list on THIS server, as a comma
    /// separated list of ``PlaylistKind`` raw values — `nil` or empty meaning nothing is hidden.
    ///
    /// Per-server like the two above: someone may want the generated playlists out of the way on a
    /// shared family server and not on their own. Storing the HIDDEN kinds rather than the visible
    /// ones is what makes the migration free — lightweight migration adds this as `nil` to every
    /// existing store, and `nil` decodes to "hide nothing", which is the behaviour that shipped
    /// before the filter existed.
    var hiddenPlaylistKinds: String?

    // password + customHeaders are stored in Keychain only.
    // Keychain key: ServerCredentials.keychainKey(for: id)

    init(
        id: UUID = UUID(),
        displayName: String,
        baseURL: String,
        username: String,
        isActive: Bool = false,
        serverVersion: String? = nil,
        createdAt: Date = Date(),
        selectedMusicFolderId: String? = nil,
        hiddenPlaylistKinds: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.username = username
        self.isActive = isActive
        self.serverVersion = serverVersion
        self.createdAt = createdAt
        self.selectedMusicFolderId = selectedMusicFolderId
        self.hiddenPlaylistKinds = hiddenPlaylistKinds
    }
}
