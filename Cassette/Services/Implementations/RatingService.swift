// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Observation
import SwiftData
import OSLog

/// Stores the user's 0.0–10.0 ratings of songs, albums and artists.
///
/// The precise value is kept locally in SwiftData; a rounded 1–5 star copy is pushed to the
/// server with Subsonic's `setRating`, so other clients (Navidrome's web UI, etc.) see an
/// approximation. Server writes are best-effort: a failure is logged and the local rating stays.
///
/// Observable so rating badges in rows update as soon as a rating is saved. Every record is
/// mirrored into `values` on init — the table holds one small row per rated item.
@MainActor
@Observable
final class RatingService {
    typealias ServerPush = @Sendable (_ itemId: String, _ stars: Int) async throws -> Void

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let serverState: ServerState
    @ObservationIgnored private let pushToServer: ServerPush

    /// Composite id → value, across all servers.
    private var values: [String: Double] = [:]

    /// The latest server write. Exposed so tests can await it rather than sleep.
    @ObservationIgnored private(set) var syncTask: Task<Void, Never>?

    init(modelContainer: ModelContainer, serverState: ServerState, pushToServer: @escaping ServerPush) {
        // Own context, like PinService: saves here must not flush the main context's @Query users.
        let ctx = ModelContext(modelContainer)
        ctx.autosaveEnabled = false
        self.modelContext = ctx
        self.serverState = serverState
        self.pushToServer = pushToServer

        let records = (try? ctx.fetch(FetchDescriptor<RatingRecord>())) ?? []
        values = Dictionary(records.map { ($0.id, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    // MARK: - Query

    /// The active server's rating for an item, or nil when it has not been rated.
    func rating(for itemType: RatedItemType, itemId: String) -> Double? {
        guard let serverId = serverState.activeServer?.id else { return nil }
        return values[RatingRecord.compositeId(itemType: itemType, itemId: itemId, serverId: serverId)]
    }

    // MARK: - Write

    func setRating(_ value: Double, for itemType: RatedItemType, itemId: String) {
        guard let serverId = serverState.activeServer?.id else { return }
        let normalized = RatingScale.normalized(value)
        let compositeId = RatingRecord.compositeId(itemType: itemType, itemId: itemId, serverId: serverId)

        if let existing = fetchRecord(id: compositeId) {
            existing.value = normalized
            existing.updatedAt = Date()
        } else {
            modelContext.insert(RatingRecord(itemType: itemType, itemId: itemId, serverId: serverId, value: normalized))
        }
        try? modelContext.save()
        values[compositeId] = normalized

        Logger.ratings.info("Rated \(itemType.rawValue, privacy: .public) \(itemId, privacy: .public) \(normalized, privacy: .public)")
        push(stars: RatingScale.serverStars(for: normalized), itemId: itemId)
    }

    func clearRating(for itemType: RatedItemType, itemId: String) {
        guard let serverId = serverState.activeServer?.id else { return }
        let compositeId = RatingRecord.compositeId(itemType: itemType, itemId: itemId, serverId: serverId)

        if let existing = fetchRecord(id: compositeId) {
            modelContext.delete(existing)
            try? modelContext.save()
        }
        values[compositeId] = nil

        Logger.ratings.info("Cleared rating for \(itemType.rawValue, privacy: .public) \(itemId, privacy: .public)")
        push(stars: 0, itemId: itemId)
    }

    // MARK: - Private

    private func fetchRecord(id compositeId: String) -> RatingRecord? {
        var descriptor = FetchDescriptor<RatingRecord>(
            predicate: #Predicate<RatingRecord> { $0.id == compositeId }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func push(stars: Int, itemId: String) {
        let push = pushToServer
        let previous = syncTask
        // Chained so two quick edits of the same item reach the server in order.
        syncTask = Task {
            await previous?.value
            do {
                try await push(itemId, stars)
            } catch {
                Logger.ratings.warning("Server rating sync failed for \(itemId, privacy: .public): \(error, privacy: .public)")
            }
        }
    }
}
