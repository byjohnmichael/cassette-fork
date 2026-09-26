// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// The 0.0–10.0 rating scale and its mapping onto Subsonic's 1–5 star ratings.
nonisolated enum RatingScale {
    static let range: ClosedRange<Double> = 0...10
    static let step: Double = 0.1
    /// Where the dial starts for an item that has never been rated.
    static let defaultValue: Double = 5

    /// Clamps to 0–10 and snaps to one decimal place.
    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        // Divide an integer count of tenths rather than multiply by `step`: n / 10 is the double
        // closest to the decimal, so 8.4 compares equal to the literal 8.4.
        return (clamped * 10).rounded() / 10
    }

    /// The whole-star value mirrored to the server. Subsonic reserves `0` for "no rating", so
    /// every real rating — 0.0 included — maps to at least one star.
    static func serverStars(for value: Double) -> Int {
        let stars = Int((normalized(value) / 2).rounded(.toNearestOrAwayFromZero))
        return min(max(stars, 1), 5)
    }

    /// Converts a server star rating (1–5) into the 0–10 scale. `nil` for 0 / missing, which
    /// Subsonic uses to mean "not rated".
    static func value(fromServerStars stars: Int?) -> Double? {
        guard let stars, (1...5).contains(stars) else { return nil }
        return Double(stars * 2)
    }

    /// "8.4" — always one decimal, locale-aware separator.
    static func formatted(_ value: Double) -> String {
        normalized(value).formatted(.number.precision(.fractionLength(1)))
    }

    /// A short verdict shown under the dial.
    static func verdict(for value: Double) -> String {
        switch normalized(value) {
        case ..<2:    String(localized: "Unlistenable")
        case ..<4:    String(localized: "Not For Me")
        case ..<5.5:  String(localized: "Mixed Feelings")
        case ..<7:    String(localized: "Decent")
        case ..<8:    String(localized: "Good")
        case ..<9:    String(localized: "Great")
        case ..<9.7:  String(localized: "Excellent")
        default:      String(localized: "Masterpiece")
        }
    }
}
