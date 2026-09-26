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
/// SwiftData on the device is what the UI reads: writes land there first, so a rating shows
/// immediately and works offline. `sync()` then pushes pending changes to the cassette-ratings
/// service beside Navidrome and pulls changes made on other devices. Conflicts go to the newest
/// `updatedAt`. When the service is missing or unreachable, pending changes simply wait.
///
/// Observable so rating badges in rows update as soon as a rating changes. Every live record for
/// every server is mirrored into `values` — the table holds one small row per rated item.
@MainActor
@Observable
final class RatingService {
    /// Builds a client for the active server, or nil when there is no server to sync with.
    typealias SyncClientFactory = @Sendable () async -> (any RatingSyncing)?

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let serverState: ServerState
    @ObservationIgnored private let makeSyncClient: SyncClientFactory
    @ObservationIgnored private let defaults: UserDefaults

    /// Composite id → value, across all servers. Excludes pending deletions.
    private var values: [String: Double] = [:]

    /// The running sync. Exposed so tests can await it rather than sleep.
    @ObservationIgnored private(set) var syncTask: Task<Void, Never>?
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var syncRequestedWhileRunning = false

    init(
        modelContainer: ModelContainer,
        serverState: ServerState,
        makeSyncClient: @escaping SyncClientFactory = { nil },
        defaults: UserDefaults = .standard
    ) {
        // Own context, like PinService: saves here must not flush the main context's @Query users.
        let ctx = ModelContext(modelContainer)
        ctx.autosaveEnabled = false
        self.modelContext = ctx
        self.serverState = serverState
        self.makeSyncClient = makeSyncClient
        self.defaults = defaults

        let records = (try? ctx.fetch(FetchDescriptor<RatingRecord>(
            predicate: #Predicate<RatingRecord> { !$0.isDeleted }
        ))) ?? []
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
            existing.isDeleted = false
            existing.needsSync = true
        } else {
            modelContext.insert(RatingRecord(
                itemType: itemType, itemId: itemId, serverId: serverId, value: normalized, needsSync: true
            ))
        }
        try? modelContext.save()
        values[compositeId] = normalized

        Logger.ratings.info("Rated \(itemType.rawValue, privacy: .public) \(itemId, privacy: .public) \(normalized, privacy: .public)")
        requestSync()
    }

    func clearRating(for itemType: RatedItemType, itemId: String) {
        guard let serverId = serverState.activeServer?.id else { return }
        let compositeId = RatingRecord.compositeId(itemType: itemType, itemId: itemId, serverId: serverId)

        // Kept as a tombstone until the server has the deletion, so other devices learn of it.
        if let existing = fetchRecord(id: compositeId) {
            existing.isDeleted = true
            existing.updatedAt = Date()
            existing.needsSync = true
            try? modelContext.save()
        }
        values[compositeId] = nil

        Logger.ratings.info("Cleared rating for \(itemType.rawValue, privacy: .public) \(itemId, privacy: .public)")
        requestSync()
    }

    // MARK: - Sync

    /// Starts a sync, or queues one more pass if a sync is already running so changes made
    /// mid-sync are not left waiting for the next trigger.
    func requestSync() {
        if isSyncing {
            syncRequestedWhileRunning = true
            return
        }
        isSyncing = true
        syncTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.syncRequestedWhileRunning = false
                await self.syncOnce()
            } while self.syncRequestedWhileRunning
            self.isSyncing = false
        }
    }

    private func syncOnce() async {
        guard let serverId = serverState.activeServer?.id,
              let client = await makeSyncClient() else { return }
        do {
            try await pushPending(serverId: serverId, client: client)
            try await pull(serverId: serverId, client: client)
        } catch RatingSyncError.notAvailable {
            Logger.ratings.debug("Ratings service not found on this server — ratings stay on the device")
        } catch {
            Logger.ratings.warning("Rating sync failed: \(error, privacy: .public)")
        }
    }

    private func pushPending(serverId: UUID, client: any RatingSyncing) async throws {
        let pending = (try? modelContext.fetch(FetchDescriptor<RatingRecord>(
            predicate: #Predicate<RatingRecord> { $0.serverId == serverId && $0.needsSync }
        ))) ?? []
        // Snapshot first: the records can change while a push is in flight.
        let changes: [(id: String, change: RatingChange)] = pending.compactMap { record in
            guard let type = RatedItemType(rawValue: record.itemType) else { return nil }
            return (id: record.id, change: RatingChange(
                itemType: type,
                itemId: record.itemId,
                value: record.isDeleted ? nil : record.value,
                updatedAt: Self.milliseconds(record.updatedAt)
            ))
        }

        for (compositeId, change) in changes {
            try await client.push(change)
            // Only settle the record if nobody changed it during the push; otherwise the newer
            // change stays pending and goes out on the next pass.
            guard let record = fetchRecord(id: compositeId),
                  Self.milliseconds(record.updatedAt) == change.updatedAt else { continue }
            if record.isDeleted {
                modelContext.delete(record)
            } else {
                record.needsSync = false
            }
            try? modelContext.save()
        }
        if !changes.isEmpty {
            Logger.ratings.info("Pushed \(changes.count, privacy: .public) rating change(s)")
        }
    }

    private func pull(serverId: UUID, client: any RatingSyncing) async throws {
        let cursorKey = Self.cursorKey(serverId)
        let since = (defaults.object(forKey: cursorKey) as? Int).map(Int64.init)
        let page = try await client.fetch(since: since)

        for remote in page.ratings {
            apply(remote, serverId: serverId)
        }
        try? modelContext.save()
        defaults.set(Int(page.cursor), forKey: cursorKey)
        if !page.ratings.isEmpty {
            Logger.ratings.info("Pulled \(page.ratings.count, privacy: .public) rating change(s)")
        }
    }

    private func apply(_ remote: RemoteRating, serverId: UUID) {
        guard let type = RatedItemType(rawValue: remote.type) else { return }
        let compositeId = RatingRecord.compositeId(itemType: type, itemId: remote.id, serverId: serverId)
        let local = fetchRecord(id: compositeId)

        // Newest wins. A newer local copy is either still pending (and will be pushed) or already
        // on the server, so an older remote row never overwrites it.
        if let local, Self.milliseconds(local.updatedAt) > remote.updatedAt { return }

        let updatedAt = Date(timeIntervalSince1970: Double(remote.updatedAt) / 1000)
        if remote.deleted || remote.value == nil {
            if let local { modelContext.delete(local) }
            values[compositeId] = nil
            return
        }
        let value = RatingScale.normalized(remote.value ?? 0)
        if let local {
            local.value = value
            local.updatedAt = updatedAt
            local.isDeleted = false
            local.needsSync = false
        } else {
            modelContext.insert(RatingRecord(
                itemType: type, itemId: remote.id, serverId: serverId, value: value, updatedAt: updatedAt
            ))
        }
        values[compositeId] = value
    }

    // MARK: - Private

    private func fetchRecord(id compositeId: String) -> RatingRecord? {
        var descriptor = FetchDescriptor<RatingRecord>(
            predicate: #Predicate<RatingRecord> { $0.id == compositeId }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    nonisolated static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    nonisolated static func cursorKey(_ serverId: UUID) -> String {
        "cassette.ratings.cursor.\(serverId.uuidString)"
    }
}
