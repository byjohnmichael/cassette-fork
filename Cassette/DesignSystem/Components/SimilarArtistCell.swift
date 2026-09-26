// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// A similar artist from the library: circular cover and name.
struct SimilarArtistCell: View {
    let recommendation: SimilarArtistRecommendation

    var body: some View {
        VStack(spacing: CassetteSpacing.xs) {
            Group {
                if let coverArt = recommendation.coverArt {
                    CoverArtView(id: coverArt, size: 128, placeholderSystemImage: "person.fill")
                } else {
                    ArtistPlaceholderView(name: recommendation.name, size: 64)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())

            Text(recommendation.name)
                .font(.cassetteCaption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }
}
