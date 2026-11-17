//
//  DeckFasciaView.swift
//  YTAudioPlayer
//
//  The brushed-aluminium strip across the top of the deck.
//
//  It replaces the current Home header (profile chip + 5 nav chips).
//  Three pilot lamps sit on the left: amber for power, cyan for a
//  live connection, magenta for a queue with content. The greeting
//  and the RPM chip sit in the middle; the existing navigation chips
//  are passed in from HomeView so their routes stay owned by Home.
//

import SwiftUI

struct DeckFasciaView<Chips: View>: View {
    let greeting: String
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
        greeting: String,
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
        self.greeting = greeting
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
        HStack(spacing: 10) {
            // Pilot lamps.
            HStack(spacing: 6) {
                PilotLamp(color: TurntableTokens.amberLamp, isOn: true)
                PilotLamp(color: Theme.cyberCyan, isOn: isConnected)
                PilotLamp(color: Theme.cyberMagenta, isOn: isPlaying)
            }

            // Actionable-state lamps. These replace the Smart Library
            // card and the cleanup banner — both of which were the most
            // important decision surfaces on the old Home.
            if hasSmartLibraryCandidates {
                PilotLamp(color: Theme.cyberYellow, isOn: true, action: onSmartLibrary)
                    .accessibilityLabel("Smart Library needs review")
            }
            if hasPendingCleanup {
                PilotLamp(color: Theme.cyberMagenta, isOn: true, action: onCleanup)
                    .accessibilityLabel("Scheduled cleanup pending")
            }

            Spacer(minLength: 4)

            Text(greeting.uppercased())
                .font(Typography.eyebrow)
                .foregroundColor(TurntableTokens.aluminium.opacity(0.85))
                .lineLimit(1)

            // RPM chip.
            Button {
                onToggleRPM()
            } label: {
                Text(rpmLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(TurntableTokens.amberLamp)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
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

            navChips()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            ZStack {
                // Brushed aluminium.
                Image(TurntableTexture.brushedAluminium)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(0.30)

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
