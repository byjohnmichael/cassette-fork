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

    @Test func serverStars_mapsEveryRatingToOneThroughFive() {
        #expect(RatingScale.serverStars(for: 0) == 1)
        #expect(RatingScale.serverStars(for: 2.9) == 1)
        #expect(RatingScale.serverStars(for: 3) == 2)
        #expect(RatingScale.serverStars(for: 5) == 3)
        #expect(RatingScale.serverStars(for: 7.4) == 4)
        #expect(RatingScale.serverStars(for: 9) == 5)
        #expect(RatingScale.serverStars(for: 10) == 5)
    }

    @Test func valueFromServerStars_treatsZeroAsUnrated() {
        #expect(RatingScale.value(fromServerStars: nil) == nil)
        #expect(RatingScale.value(fromServerStars: 0) == nil)
        #expect(RatingScale.value(fromServerStars: 4) == 8)
    }
}

@Suite("RatingService")
@MainActor
struct RatingServiceTests {

    /// Records every server push so tests can assert on what was sent.
    nonisolated final class PushRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(itemId: String, stars: Int)] = []
        var calls: [(itemId: String, stars: Int)] { lock.withLock { _calls } }
        func record(_ itemId: String, _ stars: Int) { lock.withLock { _calls.append((itemId, stars)) } }
    }

    nonisolated struct PushFailure: Error {}

    private func makeState(serverId: UUID = UUID()) -> ServerState {
        let state = ServerState()
        state.activeServer = ServerSnapshot(from: ServerConfig(
            id: serverId, displayName: "S", baseURL: "https://s.example.com", username: "u", isActive: true
        ))
        return state
    }

    @Test func setRating_storesNormalizedValueAndPushesStars() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let recorder = PushRecorder()
        let service = RatingService(modelContainer: container, serverState: makeState()) { id, stars in
            recorder.record(id, stars)
        }

        service.setRating(8.44, for: .album, itemId: "al-1")
        await service.syncTask?.value

        #expect(service.rating(for: .album, itemId: "al-1") == 8.4)
        #expect(service.rating(for: .song, itemId: "al-1") == nil)
        #expect(recorder.calls.map(\.itemId) == ["al-1"])
        #expect(recorder.calls.map(\.stars) == [4])
    }

    @Test func setRating_twiceUpdatesInPlace() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let service = RatingService(modelContainer: container, serverState: makeState()) { _, _ in }

        service.setRating(3, for: .song, itemId: "s-1")
        service.setRating(9.1, for: .song, itemId: "s-1")
        await service.syncTask?.value

        #expect(service.rating(for: .song, itemId: "s-1") == 9.1)
        let count = try ModelContext(container).fetchCount(FetchDescriptor<RatingRecord>())
        #expect(count == 1)
    }

    @Test func clearRating_removesValueAndPushesZero() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let recorder = PushRecorder()
        let service = RatingService(modelContainer: container, serverState: makeState()) { id, stars in
            recorder.record(id, stars)
        }

        service.setRating(6, for: .artist, itemId: "ar-1")
        service.clearRating(for: .artist, itemId: "ar-1")
        await service.syncTask?.value

        #expect(service.rating(for: .artist, itemId: "ar-1") == nil)
        #expect(recorder.calls.map(\.stars) == [3, 0])
    }

    @Test func ratings_surviveANewServiceInstance() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let state = makeState()
        let first = RatingService(modelContainer: container, serverState: state) { _, _ in }
        first.setRating(7.7, for: .album, itemId: "al-2")
        await first.syncTask?.value

        let second = RatingService(modelContainer: container, serverState: state) { _, _ in }
        #expect(second.rating(for: .album, itemId: "al-2") == 7.7)
    }

    @Test func ratings_areScopedToTheActiveServer() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let state = makeState()
        let service = RatingService(modelContainer: container, serverState: state) { _, _ in }
        service.setRating(9, for: .song, itemId: "shared-id")
        await service.syncTask?.value

        state.activeServer = ServerSnapshot(from: ServerConfig(
            displayName: "Other", baseURL: "https://o.example.com", username: "u", isActive: true
        ))

        #expect(service.rating(for: .song, itemId: "shared-id") == nil)
    }

    @Test func serverFailure_keepsTheLocalRating() async throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let service = RatingService(modelContainer: container, serverState: makeState()) { _, _ in
            throw PushFailure()
        }

        service.setRating(4.2, for: .song, itemId: "s-2")
        await service.syncTask?.value

        #expect(service.rating(for: .song, itemId: "s-2") == 4.2)
    }
}
