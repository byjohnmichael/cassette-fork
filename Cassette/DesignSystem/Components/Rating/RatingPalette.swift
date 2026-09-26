// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// The rating color scale: red at 0, through orange and amber, to green at 10.
/// Used by the rating dial's fill and the rating badges. See `CassetteColors.md`.
enum RatingPalette {
    private struct Stop {
        let value: Double
        let red: Double
        let green: Double
        let blue: Double
    }

    private static let stops: [Stop] = [
        Stop(value: 0,   red: 0.898, green: 0.282, blue: 0.302),  // #E5484D
        Stop(value: 3,   red: 0.969, green: 0.420, blue: 0.082),  // #F76B15
        Stop(value: 5.5, red: 1.000, green: 0.698, blue: 0.141),  // #FFB224
        Stop(value: 7.5, red: 0.961, green: 0.851, blue: 0.039),  // #F5D90A
        Stop(value: 9,   red: 0.275, green: 0.655, blue: 0.345),  // #46A758
        Stop(value: 10,  red: 0.071, green: 0.647, blue: 0.580),  // #12A594
    ]

    /// The color for a 0–10 rating, interpolated between the stops.
    static func color(for value: Double) -> Color {
        let v = RatingScale.normalized(value)
        guard let upperIndex = stops.firstIndex(where: { $0.value >= v }), upperIndex > 0 else {
            return color(of: stops[0])
        }
        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let t = (v - lower.value) / (upper.value - lower.value)
        return Color(
            red: lower.red + (upper.red - lower.red) * t,
            green: lower.green + (upper.green - lower.green) * t,
            blue: lower.blue + (upper.blue - lower.blue) * t
        )
    }

    private static func color(of stop: Stop) -> Color {
        Color(red: stop.red, green: stop.green, blue: stop.blue)
    }
}
