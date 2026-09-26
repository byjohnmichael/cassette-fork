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
/// This is the source of truth for the precise value. Subsonic's `setRating` only stores whole
/// stars (1–5), so the server receives a rounded copy (see `RatingScale.serverStars`) and the
/// decimal lives here.
@Model
final class RatingRecord {
    @Attribute(.unique) var id: String  // "{serverId}:{type}:{itemId}"
    var itemType: String
    var itemId: String
    var serverId: UUID
    var value: Double
    var updatedAt: Date

    init(itemType: RatedItemType, itemId: String, serverId: UUID, value: Double, updatedAt: Date = Date()) {
        self.id = RatingRecord.compositeId(itemType: itemType, itemId: itemId, serverId: serverId)
        self.itemType = itemType.rawValue
        self.itemId = itemId
        self.serverId = serverId
        self.value = value
        self.updatedAt = updatedAt
    }

    nonisolated static func compositeId(itemType: RatedItemType, itemId: String, serverId: UUID) -> String {
        "\(serverId.uuidString):\(itemType.rawValue):\(itemId)"
    }
}
