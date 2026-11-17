//
//  CueLeverView.swift
//  YTAudioPlayer
//
//  The cue lever is the Turntable Home's play/pause control.
//
//  On a real turntable you lift the arm off the record to stop and
//  drop it back down to start. We use the same gesture: the lever
//  rises to pause and falls to play.
//

import SwiftUI

struct CueLeverView: View {
    let isPlaying: Bool
    var onToggle: () -> Void

    var body: some View {
        Button {
            onToggle()
        } label: {
            ZStack {
                // The slot the lever travels in.
                Capsule()
                    .fill(.black.opacity(0.55))
                    .frame(width: 12, height: 62)

                // The lever itself.
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                TurntableTokens.aluminium,
                                TurntableTokens.edgeHighlight,
                                TurntableTokens.aluminium.opacity(0.55)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 9, height: 34)
                    .overlay(
                        Capsule().strokeBorder(.black.opacity(0.4), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.55), radius: 4, y: 2)
                    .offset(y: isPlaying ? 14 : -14)

                // Engraved state indicator: a lit amber dot when the
                // needle is down (playing).
                Circle()
                    .fill(isPlaying ? TurntableTokens.amberLamp : TurntableTokens.amberLamp.opacity(0.2))
                    .frame(width: 5, height: 5)
                    .shadow(color: isPlaying ? TurntableTokens.amberLamp.opacity(0.9) : .clear, radius: 4)
                    .offset(y: 30)
            }
            .frame(width: 44, height: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPlaying)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .accessibilityHint("Cue lever")
    }
}
