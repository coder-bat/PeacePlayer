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
//    3. The record face - a PICTURE DISC: the album art fills the
//                         whole 12", the way a custom-printed record
//                         does. Groove arcs, a vignette and a specular
//                         sheen are laid OVER the artwork so it still
//                         reads as pressed vinyl rather than a photo
//                         pasted on a circle. With no artwork the face
//                         falls back to black vinyl with a cream
//                         centre label.
//    4. Spindle         - the metal pin with a lit centre
//
//  Rotation is a PURE FUNCTION of playback progress. There is no
//  independent animation clock and no CADisplayLink: the record turns
//  exactly once per track and stops dead the instant playback pauses.
//  That is what keeps the deck visually honest against the audio.
//
//  Changing track flips the record face in 3D: the outgoing artwork
//  rotates away around the vertical axis while the incoming artwork
//  rotates in. That is the "cueing a new record" moment, and it gives
//  the eye something to follow when a track changes from the crate or
//  from the queue.
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
    /// Identity of the track on the record.
    ///
    /// The flip is keyed on the TRACK, not the artwork URL: two
    /// consecutive tracks can share the same cover, and the record
    /// still has to flip when the song changes.
    let trackIdentity: String
    let isPlaying: Bool
    let progress: Double
    let reduceMotion: Bool
    /// Fine-grained progress source.
    ///
    /// The player's clock ticks once a second, which makes a record
    /// that turns once per track move in visible one-degree jumps.
    /// This closure is sampled at display rate so the rotation is
    /// smooth; it still derives from the player's own clock, so the
    /// record still tells the truth about where the audio is.
    var progressAt: ((Date) -> Double)?
    var onTapPlatter: () -> Void
    var onLongPress: () -> Void

    /// The platter's outer diameter. Every other dimension below is
    /// derived from it, so the whole assembly scales as one part.
    static let diameter: CGFloat = 300

    /// The record's diameter — smaller than the platter, so a ring of
    /// felt shows around it. A record that fills the platter edge to
    /// edge does not read as a record on a turntable.
    static let recordDiameter: CGFloat = 270

    /// The paper label's diameter — about a third of the record, the
    /// way a real 12" label sits on a 12" record. Used only by the
    /// blank (no artwork) fallback.
    static let labelDiameter: CGFloat = 96

    /// The artwork currently on the record face.
    @State private var displayedArt: URL?
    /// The artwork that is flipping away.
    @State private var outgoingArt: URL?
    /// 0 = edge-on, 1 = flat. Drives the 3D flip.
    @State private var flipProgress: Double = 1
    /// The track the record is currently showing.
    @State private var displayedTrack: String = ""

    var body: some View {
        TimelineView(timelineSchedule) { timeline in
            platterBody(progress: progressAt?(timeline.date) ?? progress)
        }
    }

    /// The timeline's cadence: 30fps while the record is turning,
    /// stopped entirely when it is not.
    private var timelineSchedule: AnimationTimelineSchedule {
        if reduceMotion {
            return .animation(minimumInterval: 1.0, paused: true)
        }
        return .animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)
    }

    private func platterBody(progress: Double) -> some View {
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

            // 3. The record face.
            recordFace(progress: progress)
                .frame(width: Self.recordDiameter, height: Self.recordDiameter)

            // 3b. The specular sheen. It is NOT inside the rotating
            // face: the highlight belongs to the room, so it stays
            // still while the record turns under it. Drawing it inside
            // the rotation is the classic tell of a fake record.
            sheen
                .frame(width: Self.recordDiameter, height: Self.recordDiameter)

            // 4. Spindle.
            spindle
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .overlay(strobeDots)
        .contentShape(Circle())
        .onTapGesture { onTapPlatter() }
        .onLongPressGesture(minimumDuration: 0.5) { onLongPress() }
        .onAppear {
            displayedArt = artworkURL
            displayedTrack = trackIdentity
        }
        .onChange(of: trackIdentity) { _, newValue in
            guard newValue != displayedTrack else { return }
            displayedTrack = newValue
            if reduceMotion {
                displayedArt = artworkURL
                outgoingArt = nil
                flipProgress = 1
                return
            }
            outgoingArt = displayedArt
            displayedArt = artworkURL
            flipProgress = 0
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) {
                flipProgress = 1
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Record")
        // Identifier so the UI test can grab the record's own
        // screenshot and prove it is animating between frames.
        .accessibilityIdentifier("turntable.record")
        .accessibilityValue(
            isPlaying ? "Spinning, \(Int(progress * 100)) percent through track" : "Stopped"
        )
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Record face

    /// The picture disc: the artwork fills the record, and everything
    /// that makes it read as vinyl is layered on top of it.
    private func recordFace(progress: Double) -> some View {
        ZStack {
            // The vinyl body. It shows through around the artwork's
            // edges while the face is mid-flip, and it IS the record
            // when there is no artwork at all.
            Circle()
                .fill(TurntableTokens.vinyl)

            if let outgoingArt, flipProgress < 1 {
                artworkFace(url: outgoingArt)
                    .rotation3DEffect(
                        .degrees(-90 * flipProgress),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.55
                    )
                    .opacity(1 - flipProgress)
                    .allowsHitTesting(false)
            }

            if let displayedArt {
                artworkFace(url: displayedArt)
                    .rotation3DEffect(
                        .degrees(90 - 90 * flipProgress),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.55
                    )
                    .opacity(flipProgress)
                    .allowsHitTesting(false)
            } else {
                blankLabel
                    .opacity(flipProgress)
                    .allowsHitTesting(false)
            }

            // Groove arcs, laid over the artwork so a picture disc
            // still reads as pressed vinyl.
            grooveRings
                .opacity(displayedArt == nil ? 1 : 0.85)

            // Edge vignette — the record is darker at the rim where
            // the light falls off.
            RadialGradient(
                colors: [
                    .clear,
                    .clear,
                    .black.opacity(0.32)
                ],
                center: .center,
                startRadius: 0,
                endRadius: Self.recordDiameter / 2
            )
            .allowsHitTesting(false)

            // Inner shadow at the record's edge so it sits on the
            // felt rather than floating on it.
            Circle()
                .strokeBorder(.black.opacity(0.5), lineWidth: 10)
                .blur(radius: 7)
                .padding(-4)
                .allowsHitTesting(false)
        }
        .clipShape(Circle())
        .rotationEffect(.degrees(rotationDegrees(for: progress)))
    }

    /// The specular highlight. It is drawn OUTSIDE the record's
    /// rotation, so the record turns under a fixed light — the way a
    /// record on a real deck catches the room lamp.
    private var sheen: some View {
        ZStack {
            RadialGradient(
                colors: [
                    .white.opacity(0.18),
                    .white.opacity(0.05),
                    .clear
                ],
                center: UnitPoint(x: 0.30, y: 0.22),
                startRadius: 0,
                endRadius: 190
            )
            .blendMode(.screen)

            // A second, cooler highlight from the lower right.
            RadialGradient(
                colors: [
                    TurntableTokens.fillLight.opacity(0.10),
                    .clear
                ],
                center: UnitPoint(x: 0.74, y: 0.78),
                startRadius: 0,
                endRadius: 150
            )
            .blendMode(.screen)
        }
        .clipShape(Circle())
        .allowsHitTesting(false)
    }

    /// The strobe dots on the platter's rim.
    ///
    /// A row of small dots around the rim that appear to stand still
    /// when the platter is at the right speed. It is the cheapest
    /// possible proof that the deck is a real instrument.
    private var strobeDots: some View {
        GeometryReader { geo in
            let radius = geo.size.width / 2 - 2.5
            ZStack {
                ForEach(0..<24, id: \.self) { index in
                    let angle = Double(index) / 24.0 * 2 * .pi
                    Circle()
                        .fill(TurntableTokens.amberLamp.opacity(0.55))
                        .frame(width: 3, height: 3)
                        .shadow(color: TurntableTokens.amberLamp.opacity(0.5), radius: 2)
                        .position(
                            x: geo.size.width / 2 + radius * CGFloat(cos(angle)),
                            y: geo.size.height / 2 + radius * CGFloat(sin(angle))
                        )
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The artwork printed across the whole record.
    private func artworkFace(url: URL) -> some View {
        CachedAsyncImage(url: url) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            // While the artwork loads the record shows plain vinyl, so
            // the deck never flashes a grey square.
            Circle().fill(TurntableTokens.vinyl)
        }
        .frame(width: Self.recordDiameter, height: Self.recordDiameter)
        .clipped()
        // Printed vinyl is ink on a black disc: knock the artwork down
        // so the grooves and the sheen still read on top of it.
        .colorMultiply(Color(red: 0.76, green: 0.75, blue: 0.80))
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
    ///
    /// Takes the progress as an argument rather than reading the
    /// stored one: the timeline samples it at display rate, and the
    /// coarse stored value would undo that.
    private func rotationDegrees(for progress: Double) -> Double {
        guard !reduceMotion else { return 0 }
        return PlatterGeometry.rotation(forProgress: progress)
    }

    // MARK: - Blank label

    /// Placeholder: an unprinted label with a magenta ring, so an
    /// unloaded track still looks like a record with a blank label
    /// rather than a grey square — and the record's centre does not
    /// become a slab of neon.
    private var blankLabel: some View {
        ZStack {
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
    }

    // MARK: - Spindle

    private var spindle: some View {
        ZStack {
            // The hole the record is pressed around.
            Circle()
                .fill(.black.opacity(0.85))
                .frame(width: 11, height: 11)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [TurntableTokens.aluminium, TurntableTokens.aluminium.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 10, height: 10)
                .shadow(color: .black.opacity(0.6), radius: 2)

            Circle()
                .fill(Theme.cyberCyan)
                .frame(width: 4, height: 4)
                .shadow(color: Theme.cyberCyan.opacity(0.9), radius: 4)
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
