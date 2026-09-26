// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import CryptoKit
import SwiftSonic
@testable import Cassette

/// Records the requests the client makes and answers each with a canned status and body.
private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let statusCode: Int
    let body: Data

    init(statusCode: Int = 200, body: Data = Data(#"{"ratings":[],"cursor":0}"#.utf8)) {
        self.statusCode = statusCode
        self.body = body
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

@Suite("RatingServerClient")
struct RatingServerClientTests {
    private let base = URL(string: "https://music.example.com")!

    @Test func fetch_hitsTheRatingsPathWithTokenCredentials() async throws {
        let transport = RecordingTransport(body: Data(#"{"ratings":[{"type":"song","id":"s-1","value":8.4,"updatedAt":5,"deleted":false}],"cursor":9}"#.utf8))
        let client = RatingServerClient(baseURL: base, username: "john", password: "secret", transport: transport)

        let page = try await client.fetch(since: 3)

        #expect(page == RatingSyncPage(ratings: [
            RemoteRating(type: "song", id: "s-1", value: 8.4, updatedAt: 5, deleted: false),
        ], cursor: 9))
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://music.example.com/ratings/v1/ratings?since=3")
        #expect(request.value(forHTTPHeaderField: "X-Cassette-User") == "john")
        let salt = try #require(request.value(forHTTPHeaderField: "X-Cassette-Salt"))
        let expected = Insecure.MD5.hash(data: Data(("secret" + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(request.value(forHTTPHeaderField: "X-Cassette-Token") == expected)
    }

    @Test func push_putsTheValueAndDeletesWithATimestamp() async throws {
        let transport = RecordingTransport(body: Data("{}".utf8))
        let client = RatingServerClient(baseURL: base, username: "john", password: "secret", transport: transport)

        try await client.push(RatingChange(itemType: .album, itemId: "al 1", value: 7.5, updatedAt: 42))
        try await client.push(RatingChange(itemType: .artist, itemId: "ar-1", value: nil, updatedAt: 43))

        let put = transport.requests[0]
        #expect(put.httpMethod == "PUT")
        #expect(put.url?.absoluteString == "https://music.example.com/ratings/v1/ratings/album/al%201")
        let body = try #require(put.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["value"] as? Double == 7.5)
        #expect(json["updatedAt"] as? Int == 42)

        let delete = transport.requests[1]
        #expect(delete.httpMethod == "DELETE")
        #expect(delete.url?.absoluteString == "https://music.example.com/ratings/v1/ratings/artist/ar-1?updatedAt=43")
    }

    @Test func statusCodes_mapToSyncErrors() async {
        for (status, expected) in [(404, RatingSyncError.notAvailable), (401, .unauthorized), (500, .http(500))] {
            let client = RatingServerClient(
                baseURL: base, username: "u", password: "p", transport: RecordingTransport(statusCode: status)
            )
            await #expect(throws: expected) { _ = try await client.fetch(since: nil) }
        }
    }
}
