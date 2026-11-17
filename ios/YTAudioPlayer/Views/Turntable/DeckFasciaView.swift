//
//  DeckFasciaView.swift
//  YTAudioPlayer
//
//  The brushed-aluminium strip across the top of the deck.
//
//  It replaces the current Home header (profile chip + 5 nav chips).
//  The strip is two rows because the deck is only 402pt wide:
//
//    Row 1 — the deck's own instrumentation. The profile chip on the
//            left, the pilot lamps (amber for power, cyan for a live
//            connection, magenta for a playing deck) and the RPM chip
//            on the right.
//    Row 2 — the app's navigation on the left, and the two actionable
//            state lamps (Smart Library review, scheduled cleanup) on
//            the right. Those two stand in for the SmartLibraryCard
//            and the CleanupScheduledBanner from the old Home.
//
//  The lamps that stand in for real cards keep a full 44x44 touch
//  target, which is why they get their own space rather than being
//  squeezed into the instruments row.
//

import SwiftUI

struct DeckFasciaView<Chips: View>: View {
    /// The profile chip, owned by Home so the avatar picker stays
    /// there.
    let profile: AnyView
    let isPlaying: Bool
    let isConnected: Bool
    let rpmLabel: String
    let hasSmartLibraryCandidates: Bool
    let hasPendingCleanup: Bool
    var onToggleRPM: () -> Void
    var onSmartLibrary: () -> Void
    var onCleanup: () -> Void
    private let navChips: () -> Chips

    /// The nav chips are injected rather than owned so Home keeps
    /// control of its NavigationStack routes — the fascia only draws
    /// the buttons.
    init(
        profile: AnyView,
        isPlaying: Bool,
        isConnected: Bool,
        rpmLabel: String,
        hasSmartLibraryCandidates: Bool,
        hasPendingCleanup: Bool,
        onToggleRPM: @escaping () -> Void,
        onSmartLibrary: @escaping () -> Void,
        onCleanup: @escaping () -> Void,
        @ViewBuilder navChips: @escaping () -> Chips
    ) {
        self.profile = profile
        self.isPlaying = isPlaying
        self.isConnected = isConnected
        self.rpmLabel = rpmLabel
        self.hasSmartLibraryCandidates = hasSmartLibraryCandidates
        self.hasPendingCleanup = hasPendingCleanup
        self.onToggleRPM = onToggleRPM
        self.onSmartLibrary = onSmartLibrary
        self.onCleanup = onCleanup
        self.navChips = navChips
    }

    var body: some View {
        VStack(spacing: 10) {
            // Row 1 — instruments.
            HStack(spacing: 10) {
                profile
                    .layoutPriority(1)

                Spacer(minLength: 8)

                // Pilot lamps.
                HStack(spacing: 6) {
                    PilotLamp(color: TurntableTokens.amberLamp, isOn: true)
                    PilotLamp(color: Theme.cyberCyan, isOn: isConnected)
                    PilotLamp(color: Theme.cyberMagenta, isOn: isPlaying)
                }

                // RPM chip.
                Button {
                    onToggleRPM()
                } label: {
                    Text(rpmLabel)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(TurntableTokens.amberLamp)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(TurntableTokens.amberLamp.opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(TurntableTokens.amberLamp.opacity(0.45), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Playback speed, \(rpmLabel)")
            }

            // Row 2 — navigation and anything that needs attention.
            HStack(spacing: 8) {
                navChips()

                Spacer(minLength: 0)

                // Actionable-state lamps. These replace the Smart
                // Library card and the cleanup banner — both of which
                // were the most important decision surfaces on the old
                // Home.
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
