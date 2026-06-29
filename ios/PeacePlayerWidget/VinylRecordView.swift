//
//  VinylRecordView.swift
//  PeacePlayerWidget
//
//  Pure-SwiftUI vinyl record: black disc with concentric grooves,
//  album artwork as the center label. Drawn entirely with shapes
//  (no asset images required).
//

import SwiftUI
import UIKit

struct VinylRecordView: View {
    let artwork: UIImage?
    /// Side length of the (square) view.
    var size: CGFloat = 100
    /// Static base rotation in degrees (poses the record "mid-spin").
    var baseRotation: Double = -8
    /// Live rotation amount driven by the parent's TimelineView when playing.
    var spin: Double = 0
    /// Whether the disc is currently spinning (gates any future glow flicker).
    var isPlaying: Bool = false

    var body: some View {
        ZStack {
            // ── 1. Outer disc: deep black with subtle radial gradient ──
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.22), .black],
                        center: .center,
                        startRadius: size * 0.05,
                        endRadius: size * 0.5
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    // Edge highlight: gives the disc a tactile bevel feel.
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.28),
                                    Color.clear,
                                    Color.clear,
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: isPlaying
                        ? WidgetTheme.cyberCyan.opacity(0.55)
                        : Color.black.opacity(0.6),
                    radius: isPlaying ? 10 : 6,
                    x: 0,
                    y: 3
                )
                .rotationEffect(.degrees(baseRotation + spin))
                .animation(.easeOut(duration: 0.2), value: baseRotation)

            // ── 2. Concentric grooves (subtle white rings) ──
            ZStack {
                ForEach(0..<14, id: \.self) { i in
                    let radius = size * (0.18 + CGFloat(i) * 0.028)
                    Circle()
                        .stroke(
                            Color.white.opacity(0.04 + Double(13 - i) * 0.0025),
                            lineWidth: 0.5
                        )
                        .frame(width: radius * 2, height: radius * 2)
                }
            }
            .rotationEffect(.degrees(baseRotation + spin))
            .animation(.easeOut(duration: 0.2), value: baseRotation)

            // ── 3. Centre label with album art or fallback gradient ──
            ZStack {
                // Outer thin black ring around the label
                Circle()
                    .fill(.black)
                    .frame(width: size * 0.38, height: size * 0.38)

                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size * 0.34, height: size * 0.34)
                        .clipShape(Circle())
                } else {
                    // Brand fallback: same magenta→cyan gradient Stitch generated
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    WidgetTheme.cyberMagenta,
                                    WidgetTheme.cyberCyan
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: size * 0.34, height: size * 0.34)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: size * 0.16, weight: .bold))
                                .foregroundColor(.white.opacity(0.85))
                        )
                }

                // Spindle hole
                Circle()
                    .fill(.black)
                    .frame(width: 4, height: 4)
            }
            .rotationEffect(.degrees(baseRotation + spin))
            .animation(.easeOut(duration: 0.2), value: baseRotation)
        }
        .frame(width: size, height: size)
    }
}
