// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftData

nonisolated enum RatedItemType: String, CaseIterable, Sendable {
    case song
    case album
    case artist
}

/// A user's 0.0–10.0 rating of a song, album or artist.
///
/// The device copy is what the UI reads, so ratings show instantly and work offline. It is
/// synced with the cassette-ratings service beside Navidrome (`server/cassette-ratings`), not
/// with Subsonic's `setRating`, which holds nothing finer than whole 1–5 stars.
@Model
final class RatingRecord {
    @Attribute(.unique) var id: String  // "{serverId}:{type}:{itemId}"
    var itemType: String
    var itemId: String
    var serverId: UUID
    var value: Double
    /// When the rating last changed, on whichever device changed it. Newest wins on sync.
    var updatedAt: Date
    /// A local change the server has not acknowledged yet.
    var needsSync: Bool = false
    /// Cleared locally but not yet on the server. Kept until the deletion is pushed, then removed.
    var isDeleted: Bool = false

    init(
        itemType: RatedItemType,
        itemId: String,
        serverId: UUID,
        value: Double,
        updatedAt: Date = Date(),
        needsSync: Bool = false,
        isDeleted: Bool = false
    ) {
        self.id = RatingRecord.compositeId(itemType: itemType, itemId: itemId, serverId: serverId)
        self.itemType = itemType.rawValue
        self.itemId = itemId
        self.serverId = serverId
        self.value = value
        self.updatedAt = updatedAt
        self.needsSync = needsSync
        self.isDeleted = isDeleted
    }

    nonisolated static func compositeId(itemType: RatedItemType, itemId: String, serverId: UUID) -> String {
        "\(serverId.uuidString):\(itemType.rawValue):\(itemId)"
    }
}
