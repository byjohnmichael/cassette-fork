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

    @Test func clearRating_removesValueAndRecord() throws {
        let container = try ModelContainer.cassette(inMemory: true)
        let service = RatingService(modelContainer: container, serverState: makeState())

        service.setRating(6, for: .artist, itemId: "ar-1")
        service.clearRating(for: .artist, itemId: "ar-1")

        #expect(service.rating(for: .artist, itemId: "ar-1") == nil)
        let count = try ModelContext(container).fetchCount(FetchDescriptor<RatingRecord>())
        #expect(count == 0)
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
}
