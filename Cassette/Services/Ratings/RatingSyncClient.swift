// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import CryptoKit
import Foundation
import SwiftSonic

/// A rating as the ratings service reports it. `value` is nil for a deletion (`deleted == true`).
nonisolated struct RemoteRating: Codable, Sendable, Equatable {
    let type: String
    let id: String
    let value: Double?
    /// Milliseconds since 1970, set by the device that made the change. Newest wins.
    let updatedAt: Int64
    let deleted: Bool
}

/// One pull: every change after the cursor passed in, and the cursor to pass next time.
nonisolated struct RatingSyncPage: Codable, Sendable, Equatable {
    let ratings: [RemoteRating]
    let cursor: Int64
}

/// A local change to send. `value == nil` deletes the rating.
nonisolated struct RatingChange: Sendable, Equatable {
    let itemType: RatedItemType
    let itemId: String
    let value: Double?
    let updatedAt: Int64
}

nonisolated enum RatingSyncError: Error, Equatable {
    /// The server has no ratings service at `/ratings/` — ratings stay on the device.
    case notAvailable
    case unauthorized
    case http(Int)
}

/// Talks to the cassette-ratings service (`server/cassette-ratings`), mounted beside Navidrome.
nonisolated protocol RatingSyncing: Sendable {
    func fetch(since cursor: Int64?) async throws -> RatingSyncPage
    func push(_ change: RatingChange) async throws
}

/// HTTP client for the ratings service at `<server base URL>/ratings/v1`.
///
/// Not a Subsonic endpoint, so it cannot go through SwiftSonicClient; it reuses SwiftSonic's
/// `HTTPTransport` instead, so `CustomHeadersTransport` still adds the user's custom headers
/// (e.g. Cloudflare Access). Authenticates with Subsonic token credentials, which the service
/// verifies against Navidrome — the password itself never leaves the device.
nonisolated struct RatingServerClient: RatingSyncing {
    private let endpoint: URL
    private let username: String
    private let token: String
    private let salt: String
    private let transport: any HTTPTransport

    init(baseURL: URL, username: String, password: String, transport: any HTTPTransport) {
        self.endpoint = baseURL.appending(path: "ratings/v1/ratings")
        self.username = username
        let salt = Self.makeSalt()
        self.salt = salt
        self.token = Self.md5Hex(password + salt)
        self.transport = transport
    }

    func fetch(since cursor: Int64?) async throws -> RatingSyncPage {
        var url = endpoint
        if let cursor {
            url.append(queryItems: [URLQueryItem(name: "since", value: String(cursor))])
        }
        let data = try await send(request(url: url, method: "GET"))
        return try JSONDecoder().decode(RatingSyncPage.self, from: data)
    }

    func push(_ change: RatingChange) async throws {
        var url = endpoint
            .appending(component: change.itemType.rawValue)
            .appending(component: change.itemId)
        var req: URLRequest
        if let value = change.value {
            req = request(url: url, method: "PUT")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["value": value, "updatedAt": change.updatedAt])
        } else {
            url.append(queryItems: [URLQueryItem(name: "updatedAt", value: String(change.updatedAt))])
            req = request(url: url, method: "DELETE")
        }
        _ = try await send(req)
    }

    // MARK: - Private

    private func request(url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(username, forHTTPHeaderField: "X-Cassette-User")
        req.setValue(token, forHTTPHeaderField: "X-Cassette-Token")
        req.setValue(salt, forHTTPHeaderField: "X-Cassette-Salt")
        return req
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.data(for: request)
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403:  throw RatingSyncError.unauthorized
        // 404 from the proxy (no /ratings route) or a non-JSON page means the service isn't there.
        case 404:       throw RatingSyncError.notAvailable
        default:        throw RatingSyncError.http(response.statusCode)
        }
    }

    private static func makeSalt() -> String {
        (0..<16).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined()
    }

    private static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
