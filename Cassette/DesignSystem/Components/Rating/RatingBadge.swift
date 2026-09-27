// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// A small capsule showing a 0.0–10.0 rating, tinted by `RatingPalette`.
struct RatingBadge: View {
    let value: Double
    var font: Font = .cassetteCaption2

    var body: some View {
        let tint = RatingPalette.color(for: value)
        Text(RatingScale.formatted(value))
            .font(font.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, CassetteSpacing.s)
            .padding(.vertical, CassetteSpacing.xs / 2)
            .background(tint.opacity(0.16), in: Capsule())
            .accessibilityLabel("Rated \(RatingScale.formatted(value)) out of 10")
    }
}

/// Shows the user's rating for an item, or nothing when it is unrated.
/// Reads `RatingService`, so it updates as soon as a new rating is saved.
struct ItemRatingBadge: View {
    let itemType: RatedItemType
    let itemId: String
    var font: Font = .cassetteCaption2

    @Environment(\.appContainer) private var container

    var body: some View {
        if let value = container?.ratingService.rating(for: itemType, itemId: itemId) {
            RatingBadge(value: value, font: font)
        }
    }
}

#Preview {
    HStack {
        RatingBadge(value: 1.2)
        RatingBadge(value: 5.0)
        RatingBadge(value: 7.4)
        RatingBadge(value: 9.1)
        RatingBadge(value: 10)
    }
    .padding()
}
