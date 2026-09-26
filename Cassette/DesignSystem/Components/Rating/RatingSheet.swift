// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// What a `RatingSheet` rates. Identifiable so it can drive `.sheet(item:)`.
struct RatingTarget: Identifiable, Hashable {
    let itemType: RatedItemType
    let itemId: String
    let title: String
    var subtitle: String = ""

    var id: String { "\(itemType.rawValue):\(itemId)" }
}

/// Full-height sheet with a `RatingDial` for rating a song, album or artist 0.0–10.0.
/// Saving writes through `RatingService`; nothing is stored until Save is tapped.
struct RatingSheet: View {
    let target: RatingTarget

    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var value = RatingScale.defaultValue
    @State private var existingValue: Double?

    private var heading: LocalizedStringKey {
        switch target.itemType {
        case .song:   "Rate Song"
        case .album:  "Rate Album"
        case .artist: "Rate Artist"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.xxl) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Color.secondary.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
                Text(heading)
                    .font(.cassetteDetailTitle)
                    .foregroundStyle(.primary)
                Text(target.subtitle.isEmpty ? target.title : "\(target.title) · \(target.subtitle)")
                    .font(.cassetteBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            RatingDial(value: $value)
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity)
                .padding(.vertical, CassetteSpacing.s)

            HStack(alignment: .center, spacing: CassetteSpacing.l) {
                VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
                    Text(RatingScale.verdict(for: value))
                        .font(.cassetteSectionTitle)
                        .foregroundStyle(RatingPalette.color(for: value))
                        .contentTransition(.opacity)
                    if let existingValue {
                        Text("Currently rated \(RatingScale.formatted(existingValue))")
                            .font(.cassetteCaption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                fineTuneButton(systemImage: "minus", delta: -RatingScale.step)
                    .accessibilityLabel("Lower by 0.1")
                fineTuneButton(systemImage: "plus", delta: RatingScale.step)
                    .accessibilityLabel("Raise by 0.1")
            }

            Spacer(minLength: 0)

            HStack(spacing: CassetteSpacing.m) {
                if existingValue != nil {
                    Button {
                        HapticFeedback.light.trigger()
                        container?.ratingService.clearRating(for: target.itemType, itemId: target.itemId)
                        dismiss()
                    } label: {
                        Text("Clear")
                            .font(.cassetteCellTitle)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, CassetteSpacing.l)
                            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    HapticFeedback.success.trigger()
                    container?.ratingService.setRating(value, for: target.itemType, itemId: target.itemId)
                    dismiss()
                } label: {
                    Text("Save \(RatingScale.formatted(value))")
                        .font(.cassetteCellTitle)
                        .monospacedDigit()
                        .foregroundStyle(.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CassetteSpacing.l)
                        .background(Color.primary, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, CassetteSpacing.xxl)
        .padding(.vertical, CassetteSpacing.l)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 640)
        #endif
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            existingValue = container?.ratingService.rating(for: target.itemType, itemId: target.itemId)
            value = existingValue ?? RatingScale.defaultValue
        }
    }

    private func fineTuneButton(systemImage: String, delta: Double) -> some View {
        Button {
            HapticFeedback.selection.trigger()
            value = RatingScale.normalized(value + delta)
        } label: {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Color.secondary.opacity(0.18), in: Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }
}

// MARK: - Presenting

extension View {
    /// Presents a `RatingSheet` while `target` is non-nil.
    func ratingSheet(target: Binding<RatingTarget?>) -> some View {
        sheet(item: target) { RatingSheet(target: $0) }
    }
}

#Preview {
    RatingSheet(target: RatingTarget(itemType: .album, itemId: "1", title: "Golden Hour", subtitle: "Kacey Musgraves"))
}

// MARK: - Context menu entry

/// The "Rate…" context-menu item. Shows the current rating once the item has one.
struct RateMenuButton: View {
    let itemType: RatedItemType
    let itemId: String
    let action: () -> Void

    @Environment(\.appContainer) private var container

    private var rateTitle: LocalizedStringKey {
        switch itemType {
        case .song:   "Rate Song…"
        case .album:  "Rate Album…"
        case .artist: "Rate Artist…"
        }
    }

    var body: some View {
        Button(action: action) {
            if let current = container?.ratingService.rating(for: itemType, itemId: itemId) {
                Label("Rating: \(RatingScale.formatted(current))", systemImage: "gauge.with.needle.fill")
            } else {
                Label(rateTitle, systemImage: "gauge.with.needle")
            }
        }
    }
}
