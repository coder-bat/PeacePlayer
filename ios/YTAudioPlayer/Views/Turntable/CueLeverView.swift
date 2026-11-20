//
//  CueLeverView.swift
//  YTAudioPlayer
//
//  The cue lever is the Turntable Home's play/pause control.
//
//  On a real turntable you lift the arm off the record to stop and
//  drop it back down to start. We use the same gesture: the lever
//  rises to pause and falls to play — and the tonearm rises and falls
//  with it.
//
//  The lever sits in a plate let into the plinth. The plate carries
//  the two positions as engraved marks, and the pilot lamp at its foot
//  is the deck's one status light: lit while a record plays, pulsing
//  while one is being fetched.
//

import SwiftUI

struct CueLeverView: View {
    let isPlaying: Bool
    /// The player is fetching or buffering. The lamp pulses.
    var isLoading: Bool = false
    var onToggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    /// How far the lever travels either side of the slot's centre.
    private static let travel: CGFloat = 10

    var body: some View {
        Button {
            onToggle()
        } label: {
            ZStack {
                plate

                // The two positions, engraved either end of the slot.
                mark("pause.fill", lit: !isPlaying)
                    .offset(x: -10.5, y: -Self.travel - 4)
                mark("play.fill", lit: isPlaying)
                    .offset(x: -10.5, y: Self.travel - 4)

                // The slot the lever travels in.
                Capsule()
                    .fill(.black.opacity(0.85))
                    .frame(width: 7, height: 38)
                    .overlay(
                        Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.6)
                    )
                    .offset(x: 3, y: -4)

                knob
                    .offset(x: 3, y: (isPlaying ? Self.travel : -Self.travel) - 4)

                lamp
                    .offset(y: 28)
            }
            .frame(width: 44, height: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(CueLeverButtonStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: isPlaying)
        .onAppear { updatePulse() }
        .onChange(of: isLoading) { _, _ in updatePulse() }
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .accessibilityHint("Cue lever")
    }

    // MARK: - Parts

    /// The plate: black anodised, let into the walnut.
    private var plate: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.17), TurntableTokens.anodised],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.34), .white.opacity(0.03), .black.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .frame(width: 36, height: 72)
            .shadow(color: .black.opacity(0.55), radius: 4, x: 1.5, y: 3)
    }

    private func mark(_ symbol: String, lit: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 6.5, weight: .bold))
            .foregroundColor(lit ? TurntableTokens.amberLamp : TurntableTokens.aluminium.opacity(0.32))
    }

    /// The lever's head: a knurled aluminium barrel.
    private var knob: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Color(white: 0.42), location: 0),
                        .init(color: Color(white: 0.98), location: 0.3),
                        .init(color: Color(white: 0.72), location: 0.55),
                        .init(color: Color(white: 0.30), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .colorMultiply(TurntableTokens.aluminium)
            .frame(width: 19, height: 13)
            .overlay(
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { _ in
                        Rectangle()
                            .fill(.black.opacity(0.22))
                            .frame(width: 0.8, height: 9)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.5), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.65), radius: 3, x: 1.5, y: isPlaying ? 2 : 4)
    }

    /// The pilot lamp.
    private var lamp: some View {
        let lit = isPlaying || isLoading
        let level: Double = isLoading ? (pulse ? 1 : 0.25) : (isPlaying ? 1 : 0.16)
        return Circle()
            .fill(TurntableTokens.amberLamp.opacity(level))
            .frame(width: 5, height: 5)
            .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 0.6))
            .shadow(color: lit ? TurntableTokens.amberLamp.opacity(0.9 * level) : .clear, radius: 4)
    }

    private func updatePulse() {
        guard isLoading, !reduceMotion else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
            return
        }
        pulse = false
        withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

/// The plate gives a little under the finger.
private struct CueLeverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
