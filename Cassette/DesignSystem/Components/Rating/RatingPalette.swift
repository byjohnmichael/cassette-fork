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
        let c = rgb(for: value)
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    /// Two shades of a rating's color for the dial's arc: `deep` where the arc starts and `light`
    /// at the knob. Same hue, so the ring still reads as one color.
    static func arcShades(for value: Double) -> (deep: Color, light: Color) {
        let c = rgb(for: value)
        return (
            deep: mixed(c, with: (0, 0, 0), amount: 0.22),
            light: mixed(c, with: (1, 1, 1), amount: 0.38)
        )
    }

    private static func rgb(for value: Double) -> (red: Double, green: Double, blue: Double) {
        let v = RatingScale.normalized(value)
        guard let upperIndex = stops.firstIndex(where: { $0.value >= v }), upperIndex > 0 else {
            return (stops[0].red, stops[0].green, stops[0].blue)
        }
        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let t = (v - lower.value) / (upper.value - lower.value)
        return (
            lower.red + (upper.red - lower.red) * t,
            lower.green + (upper.green - lower.green) * t,
            lower.blue + (upper.blue - lower.blue) * t
        )
    }

    private static func mixed(
        _ c: (red: Double, green: Double, blue: Double),
        with target: (Double, Double, Double),
        amount: Double
    ) -> Color {
        Color(
            red: c.red + (target.0 - c.red) * amount,
            green: c.green + (target.1 - c.green) * amount,
            blue: c.blue + (target.2 - c.blue) * amount
        )
    }
}
