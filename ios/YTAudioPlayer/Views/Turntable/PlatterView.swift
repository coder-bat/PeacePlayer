//
//  PlatterView.swift
//  YTAudioPlayer
//
//  The record itself — the centrepiece of the Turntable Home.
//
//  Construction, outside in:
//
//    1. Felt mat        - deep green, sits under the platter
//    2. Platter rim     - machined aluminium ring with a bright edge
//    3. Groove surface  - the generated macro photograph of vinyl
//                         grooves, clipped to a circle
//    4. Groove rings    - concentric specular lines drawn on top so
//                         the surface still reads as vinyl when the
//                         texture is compressed on a small screen
//    5. Specular sheen  - a soft off-centre highlight that catches the
//                         light as the record turns
//    6. Centre label    - the album art on a paper label
//    7. Spindle         - the metal pin with a lit centre
//
//  Rotation is a PURE FUNCTION of playback progress. There is no
//  independent animation clock and no CADisplayLink: the record turns
//  exactly once per track and stops dead the instant playback pauses.
//  That is what keeps the deck visually honest against the audio.
//
//  The progress source is `PlayerState.playbackClock.progress`, NOT
//  `PlayerState.progress` — the latter is a legacy @Published mirror
//  that is no longer written on the hot path (see PlayerState.swift
//  "Sprint 2 / C-4 fix"), so it stays frozen at 0.
//

import SwiftUI

// MARK: - Geometry

enum PlatterGeometry {
    /// How many full revolutions the platter makes over one track.
    /// One turn per track reads as "a record playing" without the
    /// motion blur of a real 33 RPM spin.
    static let turnsPerTrack: Double = 1

    /// Rotation of the record surface, in degrees.
    static func rotation(forProgress progress: Double) -> Double {
        let clamped = max(0, min(1, progress))
        return 360 * turnsPerTrack * clamped
    }

    /// Position of the specular sheen along its sweep, 0...1.
    /// The sheen completes one pass per revolution.
    static func sheenAngle(forProgress progress: Double) -> Double {
        let clamped = max(0, min(1, progress))
        return (clamped * turnsPerTrack).truncatingRemainder(dividingBy: 1)
    }
}

// MARK: - Platter

struct PlatterView: View {
    let artworkURL: URL?
    let isPlaying: Bool
    let progress: Double
    let reduceMotion: Bool
    var onTapSpindle: () -> Void
    var onLongPress: () -> Void

    var body: some View {
        ZStack {
            // 1. Felt mat
            Circle()
                .fill(
                    LinearGradient(
                        colors: [TurntableTokens.felt, TurntableTokens.felt.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Image(TurntableTexture.felt)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(0.5)
                        .blendMode(.overlay)
                )
                .shadow(color: .black.opacity(0.6), radius: 18, y: 8)

            // 2. Platter rim
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            TurntableTokens.edgeHighlight,
                            TurntableTokens.aluminium.opacity(0.35),
                            TurntableTokens.aluminium.opacity(0.8),
                            TurntableTokens.edgeHighlight
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
                .padding(1)

            // 3 + 4. Groove surface
            Circle()
                .fill(TurntableTokens.vinyl)
                .overlay(
                    Image(TurntableTexture.vinylGrooves)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .rotationEffect(.degrees(rotationDegrees))
                )
                .overlay(
                    // Concentric specular lines, drawn on top so the
                    // surface reads as vinyl even at low resolution.
                    Circle()
                        .strokeBorder(TurntableTokens.grooveShadow, lineWidth: 1)
                        .padding(26)
                        .overlay(
                            Circle()
                                .strokeBorder(TurntableTokens.grooveShadow.opacity(0.7), lineWidth: 1)
                                .padding(44)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(TurntableTokens.grooveShadow.opacity(0.5), lineWidth: 1)
                                .padding(64)
                        )
                )
                .overlay(
                    // 5. Specular sheen — off-centre highlight.
                    RadialGradient(
                        colors: [
                            .white.opacity(0.20),
                            .white.opacity(0.05),
                            .clear
                        ],
                        center: UnitPoint(x: 0.30, y: 0.22),
                        startRadius: 0,
                        endRadius: 260
                    )
                    .blendMode(.screen)
                    .allowsHitTesting(false)
                )
                .overlay(
                    // Inner shadow at the record's edge so it sits inside
                    // the platter rim rather than floating on it.
                    Circle()
                        .strokeBorder(.black.opacity(0.55), lineWidth: 10)
                        .blur(radius: 8)
                        .padding(-5)
                        .allowsHitTesting(false)
                )
                .clipShape(Circle())

            // 6. Centre label
            labelArtwork

            // 7. Spindle
            spindle
        }
        .frame(width: 320, height: 320)
        .contentShape(Circle())
        .onTapGesture { onTapSpindle() }
        .onLongPressGesture(minimumDuration: 0.5) { onLongPress() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Record")
        .accessibilityValue(
            isPlaying ? "Spinning, \(Int(progress * 100)) percent through track" : "Stopped"
        )
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Rotation

    /// The record turns as the track plays. With `reduceMotion` on we
    /// hold it still — the progress is still legible from the label
    /// and the tonearm, so nothing is lost.
    private var rotationDegrees: Double {
        guard !reduceMotion else { return 0 }
        return PlatterGeometry.rotation(forProgress: progress)
    }

    // MARK: - Label

    private var labelArtwork: some View {
        ZStack {
            // Paper label disc, slightly proud of the record.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [TurntableTokens.cream, TurntableTokens.cream.opacity(0.86)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 70
                    )
                )
                .frame(width: 132, height: 132)
                .shadow(color: .black.opacity(0.55), radius: 6, y: 2)

            // Album art, circular crop, on the label.
            CachedAsyncImage(url: artworkURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                // Placeholder: a magenta disc with a spindle hole, so an
                // unloaded track still looks like a record with a blank
                // label rather than a grey square.
                ZStack {
                    Circle().fill(Theme.cyberMagenta.opacity(0.55))
                    Circle().fill(TurntableTokens.vinyl).frame(width: 22, height: 22)
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 3)

            // Label type ring — the record's own typography.
            Text("PEACEPLAYER")
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .tracking(1.6)
                .foregroundColor(TurntableTokens.walnut.opacity(0.75))
                .rotationEffect(.degrees(-90))
                .offset(y: -56)
                .allowsHitTesting(false)
        }
        // The label spins with the record.
        .rotationEffect(.degrees(rotationDegrees))
    }

    // MARK: - Spindle

    private var spindle: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [TurntableTokens.aluminium, TurntableTokens.aluminium.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.6), radius: 2)

            Circle()
                .fill(Theme.cyberCyan)
                .frame(width: 5, height: 5)
                .shadow(color: Theme.cyberCyan.opacity(0.9), radius: 5)
        }
    }
}
