//
//  DeckFasciaView.swift
//  YTAudioPlayer
//
//  The brushed-aluminium strip across the top of the deck.
//
//  It replaces the current Home header (profile chip + 5 nav chips).
//
//  The strip is ONE row: the deck's etched wordmark on the left and
//  the app's five destinations in the top-right corner, where the old
//  Home put its nav icons. The deck's instrumentation (the RPM chip
//  and the three pilot lamps) was removed — the record itself is the
//  instrument now, and a row of status dots above it was just chrome.
//
//  The profile chip moved out of the deck entirely (revision
//  2026-11-18): the deck is a record player, not an account screen.
//  The avatar, display name and sign-out sheet now live in Settings,
//  behind the email row.
//
//  The only thing below the row is the pair of ACTIONABLE lamps
//  (Smart Library review, scheduled cleanup). They stand in for the
//  SmartLibraryCard and the CleanupScheduledBanner from the old Home
//  and only appear when there is something to act on, so the strip
//  normally stays a single row.
//

import SwiftUI

struct DeckFasciaView<Chips: View>: View {
    let hasSmartLibraryCandidates: Bool
    let hasPendingCleanup: Bool
    var onSmartLibrary: () -> Void
    var onCleanup: () -> Void
    private let navChips: () -> Chips

    /// The nav chips are injected rather than owned so Home keeps
    /// control of its NavigationStack routes — the fascia only draws
    /// the buttons.
    init(
        hasSmartLibraryCandidates: Bool,
        hasPendingCleanup: Bool,
        onSmartLibrary: @escaping () -> Void,
        onCleanup: @escaping () -> Void,
        @ViewBuilder navChips: @escaping () -> Chips
    ) {
        self.hasSmartLibraryCandidates = hasSmartLibraryCandidates
        self.hasPendingCleanup = hasPendingCleanup
        self.onSmartLibrary = onSmartLibrary
        self.onCleanup = onCleanup
        self.navChips = navChips
    }

    var body: some View {
        VStack(spacing: 8) {
            // Row 1 — the deck's own brand on the left, navigation in
            // the top-right corner.
            HStack(spacing: 10) {
                // Etched into the metal, the way a deck carries its
                // maker's mark. The profile chip used to live here;
                // it moved to Settings (tapping the email row opens
                // the avatar / display name / sign-out sheet).
                Text("PEACEPLAYER")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundColor(TurntableTokens.aluminium.opacity(0.45))

                Spacer(minLength: 4)

                navChips()
            }

            // Row 2 — only when there is something to act on.
            if hasSmartLibraryCandidates || hasPendingCleanup {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)

                    if hasSmartLibraryCandidates {
                        PilotLamp(color: Theme.cyberYellow, isOn: true, action: onSmartLibrary)
                            .accessibilityLabel("Smart Library needs review")
                    }
                    if hasPendingCleanup {
                        PilotLamp(color: Theme.cyberMagenta, isOn: true, action: onCleanup)
                            .accessibilityLabel("Scheduled cleanup pending")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ZStack {
                // Brushed aluminium. The texture is pinned in an
                // overlay: a resizable image with
                // `.aspectRatio(contentMode: .fill)` reports its natural
                // size as its ideal size, and that size can leak into
                // the strip's layout and push the controls off screen.
                Color.clear
                    .overlay(
                        Image(TurntableTexture.brushedAluminium)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .opacity(0.30)
                    )

                // Machined gradient over the texture so the strip reads
                // as a solid metal part rather than a photo.
                LinearGradient(
                    colors: [
                        TurntableTokens.aluminium.opacity(0.16),
                        TurntableTokens.aluminium.opacity(0.05),
                        Color.black.opacity(0.30)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Bright machined edge along the top.
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [TurntableTokens.edgeHighlight, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    LinearGradient(
                        colors: [TurntableTokens.aluminium.opacity(0.45), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
    }
}

// MARK: - Pilot lamp

/// A small indicator lamp on the fascia. Optionally tappable — used
/// for the Smart Library and cleanup lamps, which stand in for the
/// cards they replaced.
struct PilotLamp: View {
    let color: Color
    let isOn: Bool
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button {
                    action()
                } label: {
                    lampBody
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            } else {
                lampBody
            }
        }
    }

    private var lampBody: some View {
        ZStack {
            // The chrome bezel the lamp sits in.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [TurntableTokens.aluminium.opacity(0.5), TurntableTokens.aluminium.opacity(0.1)],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 10
                    )
                )
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.black.opacity(0.45), lineWidth: 1))

            // The lens.
            Circle()
                .fill(isOn ? color : color.opacity(0.18))
                .frame(width: 8, height: 8)
                .shadow(color: isOn ? color.opacity(0.85) : .clear, radius: 4)
        }
    }
}
