//
//  PlatterView.swift
//  YTAudioPlayer
//
//  The record itself — the centrepiece of the Turntable Home.
//
//  Construction, outside in:
//
//    1. Machined rim    - the aluminium edge of the platter
//    2. Felt mat        - deep green, the record sits on it
//    3. Groove surface  - the generated macro photograph of vinyl
//                         grooves, clipped to a circle
//    4. Groove rings    - concentric specular lines drawn on top so
//                         the surface still reads as vinyl when the
//                         texture is compressed on a small screen
//    5. Specular sheen  - a soft off-centre highlight that catches the
//                         light as the record turns
//    6. Centre label    - the album art on a paper label, with the
//                         label's own curved type ring
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

    /// The platter's outer diameter. Every other dimension below is
    /// derived from it, so the whole assembly scales as one part.
    static let diameter: CGFloat = 320

    /// The record's diameter — smaller than the platter, so a ring of
    /// felt shows around it. A record that fills the platter edge to
    /// edge does not read as a record on a turntable.
    static let recordDiameter: CGFloat = 276

    /// The paper label's diameter — about a third of the record, the
    /// way a real 12" label sits on a 12" record.
    static let labelDiameter: CGFloat = 96

    var body: some View {
        ZStack {
            // 1. Machined rim.
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            TurntableTokens.edgeHighlight,
                            TurntableTokens.aluminium.opacity(0.35),
                            TurntableTokens.aluminium.opacity(0.85),
                            TurntableTokens.edgeHighlight
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 6
                )
                .frame(width: Self.diameter, height: Self.diameter)
                .shadow(color: .black.opacity(0.55), radius: 14, y: 8)

            // 2. Felt mat.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [TurntableTokens.felt, TurntableTokens.felt.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: Self.diameter - 14, height: Self.diameter - 14)
                .overlay(
                    Image(TurntableTexture.felt)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(0.55)
                        .blendMode(.overlay)
                )
                // The texture is a square photograph; without this it
                // spills over the mat as a square of green felt.
                .clipShape(Circle())

            // 3 + 4 + 5. The record.
            record
                .frame(width: Self.recordDiameter, height: Self.recordDiameter)

            // 6. Centre label.
            labelArtwork

            // 7. Spindle.
            spindle
        }
        .frame(width: Self.diameter, height: Self.diameter)
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

    // MARK: - Record

    private var record: some View {
        Circle()
            .fill(TurntableTokens.vinyl)
            .overlay(
                Image(TurntableTexture.vinylGrooves)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .rotationEffect(.degrees(rotationDegrees))
                    // The generated macro photograph is a bright, silvery
                    // anisotropic sheen. Multiply it down so it reads as
                    // black vinyl catching a light rather than as
                    // brushed aluminium.
                    .colorMultiply(Color(red: 0.30, green: 0.29, blue: 0.33))
            )
            .overlay(grooveRings)
            .overlay(
                // Specular sheen — off-centre highlight.
                RadialGradient(
                    colors: [
                        .white.opacity(0.16),
                        .white.opacity(0.04),
                        .clear
                    ],
                    center: UnitPoint(x: 0.30, y: 0.22),
                    startRadius: 0,
                    endRadius: 220
                )
                .blendMode(.screen)
                .allowsHitTesting(false)
            )
            .overlay(
                // Inner shadow at the record's edge so it sits on the
                // felt rather than floating on it.
                Circle()
                    .strokeBorder(.black.opacity(0.5), lineWidth: 10)
                    .blur(radius: 7)
                    .padding(-4)
                    .allowsHitTesting(false)
            )
            .clipShape(Circle())
    }

    /// Concentric specular lines, drawn on top so the surface reads as
    /// vinyl even at low resolution or when the texture is compressed.
    private var grooveRings: some View {
        ZStack {
            ForEach(0..<16, id: \.self) { index in
                let fraction = Double(index) / 15.0
                let radius = 52 + fraction * 80
                Circle()
                    .strokeBorder(
                        TurntableTokens.grooveShadow.opacity(0.9 - fraction * 0.45),
                        lineWidth: 1
                    )
                    .frame(width: radius * 2, height: radius * 2)
            }
        }
        .allowsHitTesting(false)
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
                        endRadius: 52
                    )
                )
                .frame(width: Self.labelDiameter, height: Self.labelDiameter)
                .shadow(color: .black.opacity(0.55), radius: 6, y: 2)

            // Album art, circular crop, on the label.
            artworkDisc

            // Label type ring — the record's own typography, set on an
            // arc so it reads like a pressed paper label.
            CurvedText(
                text: "PEACEPLAYER",
                radius: 40,
                font: .system(size: 7, weight: .semibold, design: .monospaced),
                measurementFont: .monospacedSystemFont(ofSize: 7, weight: .semibold),
                tracking: 1.4,
                color: TurntableTokens.walnut.opacity(0.8)
            )
            .frame(width: Self.labelDiameter, height: Self.labelDiameter)
            .allowsHitTesting(false)
        }
        // The label spins with the record.
        .rotationEffect(.degrees(rotationDegrees))
    }

    /// The artwork that sits on the paper label.
    ///
    /// The image loader is only built when there is a URL to load. A
    /// `CachedAsyncImage` with a nil URL still owns `@State` and still
    /// writes to it on appear, and SwiftUI's graph can release that
    /// state twice when the platter is torn down — a crash that only
    /// shows up offscreen, exactly where it is hardest to diagnose.
    private var artworkDisc: some View {
        Group {
            if let artworkURL {
                CachedAsyncImage(url: artworkURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    blankLabel
                }
            } else {
                blankLabel
            }
        }
        .frame(width: 62, height: 62)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 3)
    }

    /// Placeholder: an unprinted label with a magenta ring, so an
    /// unloaded track still looks like a record with a blank label
    /// rather than a grey square — and the record's centre does not
    /// become a slab of neon.
    private var blankLabel: some View {
        ZStack {
            Circle().fill(TurntableTokens.walnut.opacity(0.22))
            Circle().strokeBorder(Theme.cyberMagenta.opacity(0.5), lineWidth: 2)
            Circle().fill(TurntableTokens.vinyl).frame(width: 22, height: 22)
        }
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

// MARK: - Curved text

/// Text set on a circular path.
///
/// The record label carries its own typography the way a real pressed
/// label does — the imprint runs around the top of the paper. SwiftUI
/// has no built-in for this, so the characters are drawn one at a
/// time onto a canvas, each rotated to its own point on the arc.
struct CurvedText: View {
    let text: String
    let radius: CGFloat
    /// The font the glyphs are drawn with.
    var font: Font
    /// The same font in UIKit terms — Canvas cannot measure a SwiftUI
    /// `Font`, and the arc length depends on each character's width.
    var measurementFont: UIFont
    var tracking: CGFloat = 1.4
    var color: Color = TurntableTokens.walnut

    var body: some View {
        Canvas { context, size in
            let characters = Array(text)
            guard !characters.isEmpty else { return }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: measurementFont,
                .kern: tracking
            ]
            let widths = characters.map { character in
                NSString(string: String(character)).size(withAttributes: attributes).width
            }
            let totalWidth = widths.reduce(0, +)
            guard totalWidth > 0 else { return }

            // The arc the whole imprint occupies.
            let totalAngle = totalWidth / radius
            var cursor = -totalAngle / 2
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)

            for (index, character) in characters.enumerated() {
                let step = widths[index] / radius
                let mid = cursor + step / 2

                var glyph = context
                glyph.translateBy(x: centre.x, y: centre.y)
                glyph.rotate(by: .radians(mid))
                glyph.translateBy(x: 0, y: -radius)
                glyph.draw(
                    Text(String(character)).font(font).foregroundColor(color),
                    at: .zero,
                    anchor: .center
                )

                cursor += step
            }
        }
        .accessibilityHidden(true)
    }
}
