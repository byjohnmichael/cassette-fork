// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// A circular slider for a 0.0–10.0 rating.
///
/// The ring fills clockwise from 12 o'clock as the rating rises. The whole arc takes the
/// current rating's `RatingPalette` color, so it shifts from red to green as it fills. Drag anywhere on the dial to set the value; the knob follows the finger.
/// A drag cannot wrap past 10 back to 0 (or the reverse) — it pins at the end instead.
struct RatingDial: View {
    @Binding var value: Double

    /// Ring thickness as a fraction of the dial's diameter.
    private let ringRatio: CGFloat = 0.12
    /// Touches this close to the center are ignored: the angle there is too unstable.
    private let deadZoneRatio: CGFloat = 0.08

    @State private var isDragging = false

    private var fraction: Double { RatingScale.normalized(value) / RatingScale.range.upperBound }
    private var tint: Color { RatingPalette.color(for: value) }

    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height)
            let ring = diameter * ringRatio
            let radius = (diameter - ring) / 2

            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: ring)

                ticks(radius: radius, ring: ring)

                if fraction > 0 {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(tint, style: StrokeStyle(lineWidth: ring, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }

                knob(ring: ring)
                    .offset(knobOffset(radius: radius))

                centerLabel(diameter: diameter, ring: ring)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            // Before .position, so gesture locations are in the dial's own diameter-sized space.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        update(from: gesture.location, center: CGPoint(x: diameter / 2, y: diameter / 2), diameter: diameter)
                    }
                    .onEnded { _ in isDragging = false }
            )
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: value)
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue("\(RatingScale.formatted(value)) out of 10")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = RatingScale.normalized(value + RatingScale.step * 5)
            case .decrement: value = RatingScale.normalized(value - RatingScale.step * 5)
            @unknown default: break
            }
        }
    }

    // MARK: - Pieces

    /// A dot at every whole number, sitting in the unfilled track like the reference design.
    private func ticks(radius: CGFloat, ring: CGFloat) -> some View {
        ForEach(1..<10, id: \.self) { mark in
            let angle = Angle.degrees(Double(mark) * 36 - 90)
            Circle()
                .fill(Color.primary.opacity(Double(mark) <= value ? 0.25 : 0.35))
                .frame(width: ring * 0.22, height: ring * 0.22)
                .offset(x: cos(angle.radians) * radius, y: sin(angle.radians) * radius)
        }
    }

    private func knob(ring: CGFloat) -> some View {
        Circle()
            .fill(tint)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: ring * 0.12))
            .frame(width: ring * 1.15, height: ring * 1.15)
            .shadow(color: .black.opacity(0.25), radius: ring * 0.15, y: ring * 0.05)
            .scaleEffect(isDragging ? 1.1 : 1)
    }

    private func centerLabel(diameter: CGFloat, ring: CGFloat) -> some View {
        VStack(spacing: CassetteSpacing.xs) {
            // Sized from the dial rather than a type style: the number is part of the graphic
            // and must fit inside the ring at any dial size.
            Text(RatingScale.formatted(value))
                .font(.system(size: diameter * 0.24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: value))
                .foregroundStyle(.primary)
            Text("out of 10")
                .font(.cassetteCaption)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: diameter - ring * 2.6)
        .minimumScaleFactor(0.5)
        .lineLimit(1)
    }

    // MARK: - Geometry

    private func knobOffset(radius: CGFloat) -> CGSize {
        let angle = Angle.degrees(360 * fraction - 90)
        return CGSize(width: cos(angle.radians) * radius, height: sin(angle.radians) * radius)
    }

    private func update(from location: CGPoint, center: CGPoint, diameter: CGFloat) {
        let dx = location.x - center.x
        let dy = location.y - center.y
        guard hypot(dx, dy) > diameter * deadZoneRatio else { return }

        // atan2 in screen space is clockwise from 3 o'clock; shift so 0 sits at 12 o'clock.
        var degrees = Double(atan2(dy, dx)) * 180 / .pi + 90
        if degrees < 0 { degrees += 360 }
        var newValue = RatingScale.normalized(degrees / 360 * RatingScale.range.upperBound)

        // Past the top of the dial mid-drag: pin to the end the finger came from.
        let upper = RatingScale.range.upperBound
        if isDragging {
            if value > upper * 0.75 && newValue < upper * 0.25 { newValue = upper }
            if value < upper * 0.25 && newValue > upper * 0.75 { newValue = RatingScale.range.lowerBound }
        }
        isDragging = true

        guard newValue != value else { return }
        if Int(newValue) != Int(value) || newValue == upper || newValue == RatingScale.range.lowerBound {
            HapticFeedback.selection.trigger()
        }
        value = newValue
    }
}

#Preview {
    @Previewable @State var value = 7.4
    RatingDial(value: $value)
        .padding(CassetteSpacing.xxxl)
}
