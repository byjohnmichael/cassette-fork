// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import SwiftData
@testable import Cassette

@Suite("RatingScale")
struct RatingScaleTests {

    @Test func normalized_clampsAndSnapsToOneDecimal() {
        #expect(RatingScale.normalized(-3) == 0)
        #expect(RatingScale.normalized(12) == 10)
        #expect(RatingScale.normalized(7.44) == 7.4)
        #expect(RatingScale.normalized(7.46) == 7.5)
        #expect(RatingScale.normalized(.nan) == RatingScale.defaultValue)
    }
}

@Suite("RatingService")
@MainActor
struct RatingServiceTests {

    private func makeState(serverId: UUID = UUID()) -> ServerState {
        let state = ServerState()
        state.activeServer = ServerSnapshot(from: ServerConfig(
            id: serverId, displayName: "S", baseURL: "https://s.example.com", username: "u", isActive: true
        ))
        return state
    }

    @Test func setRating_storesNormalizedValuePerItemType() throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let service = RatingService(modelContainer: container, serverState: makeState())

        service.setRating(8.44, for: .album, itemId: "al-1")

        #expect(service.rating(for: .album, itemId: "al-1") == 8.4)
        #expect(service.rating(for: .song, itemId: "al-1") == nil)
    }

    @Test func setRating_twiceUpdatesInPlace() throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let service = RatingService(modelContainer: container, serverState: makeState())

        service.setRating(3, for: .song, itemId: "s-1")
        service.setRating(9.1, for: .song, itemId: "s-1")

        #expect(service.rating(for: .song, itemId: "s-1") == 9.1)
        let count = try ModelContext(container).fetchCount(FetchDescriptor<RatingRecord>())
        #expect(count == 1)
    }

    @Test func clearRating_hidesValueAndKeepsATombstoneUntilSynced() throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let service = RatingService(modelContainer: container, serverState: makeState())

        service.setRating(6, for: .artist, itemId: "ar-1")
        service.clearRating(for: .artist, itemId: "ar-1")

        #expect(service.rating(for: .artist, itemId: "ar-1") == nil)
        let records = try ModelContext(container).fetch(FetchDescriptor<RatingRecord>())
        #expect(records.count == 1)
        #expect(records.first?.isDeleted == true)
        #expect(records.first?.needsSync == true)

        // A fresh instance must not resurrect it.
        let reloaded = RatingService(modelContainer: container, serverState: makeState())
        #expect(reloaded.rating(for: .artist, itemId: "ar-1") == nil)
    }

    @Test func ratings_surviveANewServiceInstance() throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let state = makeState()
        let first = RatingService(modelContainer: container, serverState: state)
        first.setRating(7.7, for: .album, itemId: "al-2")

        let second = RatingService(modelContainer: container, serverState: state)
        #expect(second.rating(for: .album, itemId: "al-2") == 7.7)
    }

    @Test func ratings_areScopedToTheActiveServer() throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let state = makeState()
        let service = RatingService(modelContainer: container, serverState: state)
        service.setRating(9, for: .song, itemId: "shared-id")

        state.activeServer = ServerSnapshot(from: ServerConfig(
            displayName: "Other", baseURL: "https://o.example.com", username: "u", isActive: true
        ))

        #expect(service.rating(for: .song, itemId: "shared-id") == nil)
    }

    // MARK: - Sync

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "rating.tests.\(UUID().uuidString)"))
    }

    private func makeService(
        container: ModelContainer,
        state: ServerState,
        client: SyncStub,
        defaults: UserDefaults
    ) -> RatingService {
        RatingService(modelContainer: container, serverState: state, makeSyncClient: { client }, defaults: defaults)
    }

    @Test func sync_pushesALocalRatingAndSettlesIt() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let client = SyncStub()
        let service = makeService(container: container, state: makeState(), client: client, defaults: try makeDefaults())

        service.setRating(8.44, for: .album, itemId: "al-1")
        await service.syncTask?.value

        #expect(client.pushed.map(\.itemId) == ["al-1"])
        #expect(client.pushed.first?.value == 8.4)
        #expect(client.pushed.first?.itemType == .album)
        let record = try #require(try ModelContext(container).fetch(FetchDescriptor<RatingRecord>()).first)
        #expect(record.needsSync == false)
    }

    @Test func sync_pushesADeletionThenDropsTheTombstone() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let client = SyncStub()
        let service = makeService(container: container, state: makeState(), client: client, defaults: try makeDefaults())

        service.setRating(6, for: .artist, itemId: "ar-1")
        await service.syncTask?.value
        service.clearRating(for: .artist, itemId: "ar-1")
        await service.syncTask?.value

        #expect(client.pushed.map(\.value) == [6, nil])
        let count = try ModelContext(container).fetchCount(FetchDescriptor<RatingRecord>())
        #expect(count == 0)
    }

    @Test func sync_pullsRemoteRatingsAndDeletions() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let client = SyncStub()
        client.pages = [RatingSyncPage(ratings: [
            RemoteRating(type: "song", id: "s-1", value: 9.2, updatedAt: 1_000, deleted: false),
            RemoteRating(type: "album", id: "al-9", value: 7, updatedAt: 1_000, deleted: false),
        ], cursor: 5)]
        let defaults = try makeDefaults()
        let service = makeService(container: container, state: makeState(), client: client, defaults: defaults)

        service.requestSync()
        await service.syncTask?.value

        #expect(service.rating(for: .song, itemId: "s-1") == 9.2)
        #expect(service.rating(for: .album, itemId: "al-9") == 7)
        #expect(client.fetchedSince == [nil])

        client.pages = [RatingSyncPage(ratings: [
            RemoteRating(type: "song", id: "s-1", value: nil, updatedAt: 2_000, deleted: true),
        ], cursor: 6)]
        service.requestSync()
        await service.syncTask?.value

        #expect(service.rating(for: .song, itemId: "s-1") == nil)
        #expect(service.rating(for: .album, itemId: "al-9") == 7)
        #expect(client.fetchedSince == [nil, 5], "the second pull resumes from the stored cursor")
    }

    @Test func sync_anOlderRemoteRatingNeverOverwritesANewerLocalOne() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let client = SyncStub()
        // Another device rated it long ago; this device rates it now.
        client.pages = [RatingSyncPage(ratings: [
            RemoteRating(type: "song", id: "s-1", value: 9, updatedAt: 1, deleted: false),
        ], cursor: 1)]
        let service = makeService(container: container, state: makeState(), client: client, defaults: try makeDefaults())

        service.setRating(4, for: .song, itemId: "s-1")
        await service.syncTask?.value

        #expect(client.fetchedSince == [nil], "the pull must actually have run")
        #expect(service.rating(for: .song, itemId: "s-1") == 4)
    }

    @Test func sync_aNewerRemoteRatingReplacesTheLocalOne() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let client = SyncStub()
        let service = makeService(container: container, state: makeState(), client: client, defaults: try makeDefaults())
        service.setRating(4, for: .song, itemId: "s-1")
        await service.syncTask?.value

        let later = RatingService.milliseconds(Date()) + 60_000
        client.pages = [RatingSyncPage(ratings: [
            RemoteRating(type: "song", id: "s-1", value: 9.5, updatedAt: later, deleted: false),
        ], cursor: 2)]
        service.requestSync()
        await service.syncTask?.value

        #expect(service.rating(for: .song, itemId: "s-1") == 9.5)
    }

    @Test func sync_aFailedPushKeepsTheChangePending() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let client = SyncStub()
        client.failPushes = true
        let service = makeService(container: container, state: makeState(), client: client, defaults: try makeDefaults())

        service.setRating(5.5, for: .song, itemId: "s-2")
        await service.syncTask?.value

        #expect(service.rating(for: .song, itemId: "s-2") == 5.5)
        let record = try #require(try ModelContext(container).fetch(FetchDescriptor<RatingRecord>()).first)
        #expect(record.needsSync == true)

        client.failPushes = false
        service.requestSync()
        await service.syncTask?.value
        #expect(client.pushed.map(\.itemId) == ["s-2"])
    }
}

/// In-memory stand-in for the ratings service.
nonisolated private final class SyncStub: RatingSyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var _pushed: [RatingChange] = []
    private var _fetchedSince: [Int64?] = []
    private var _pages: [RatingSyncPage] = []
    private var _failPushes = false

    var pushed: [RatingChange] { lock.withLock { _pushed } }
    var fetchedSince: [Int64?] { lock.withLock { _fetchedSince } }
    var pages: [RatingSyncPage] {
        get { lock.withLock { _pages } }
        set { lock.withLock { _pages = newValue } }
    }
    var failPushes: Bool {
        get { lock.withLock { _failPushes } }
        set { lock.withLock { _failPushes = newValue } }
    }

    struct Failure: Error {}

    func fetch(since cursor: Int64?) async throws -> RatingSyncPage {
        lock.withLock {
            _fetchedSince.append(cursor)
            return _pages.isEmpty ? RatingSyncPage(ratings: [], cursor: cursor ?? 0) : _pages.removeFirst()
        }
    }

    func push(_ change: RatingChange) async throws {
        try lock.withLock {
            if _failPushes { throw Failure() }
            _pushed.append(change)
        }
    }
}
