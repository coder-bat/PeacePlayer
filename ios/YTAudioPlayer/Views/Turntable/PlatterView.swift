//
//  PlatterView.swift
//  YTAudioPlayer
//
//  The record itself — the centrepiece of the Turntable Home.
//
//  Construction, outside in:
//
//    1. Platter         - lathe-turned aluminium, lit by the room
//    2. Strobe band     - the anodised edge with its ring of dots.
//                         It turns WITH the platter, so the deck's
//                         speed is legible even when the artwork is
//                         symmetrical.
//    3. Felt mat        - deep green, the record sits on it
//    4. The record face - a PICTURE DISC: the album art fills the
//                         whole 12". Fine grooves, the two opposed
//                         wedges of light every record throws, an
//                         edge bead and a vignette are laid OVER the
//                         artwork so it reads as pressed vinyl.
//    5. Spindle         - the chrome pin with a lit centre
//
//  Only the record and the strobe band rotate. The grooves are
//  concentric (they look the same at every angle) and the light
//  belongs to the room, so both stay still — drawing the highlight
//  inside the rotation is the classic tell of a fake record.
//
//  Rotation is a FUNCTION OF PLAYBACK POSITION. The record turns once
//  every `PlatterGeometry.secondsPerTurn` seconds of audio, and the
//  angle is derived from the player's own clock — there is no free-
//  running animation. What is drawn eases toward that angle the way a
//  heavy platter does, so the 1Hz clock, a seek or a pause never show
//  up as a jump: pause the audio and the record settles within a few
//  frames.
//
//  Changing track flips the record face in 3D: the outgoing artwork
//  rotates away around the vertical axis while the incoming artwork
//  rotates in.
//
//  The progress source is `PlayerState.playbackClock.progress`, NOT
//  `PlayerState.progress` — the latter is a legacy @Published mirror
//  that is no longer written on the hot path (see PlayerState.swift
//  "Sprint 2 / C-4 fix"), so it stays frozen at 0.
//

import SwiftUI

// MARK: - Geometry

enum PlatterGeometry {
    /// Revolutions over one track when the track's length is unknown.
    static let turnsPerTrack: Double = 1

    /// How long one revolution takes, in seconds of audio.
    ///
    /// A real LP turns every 1.8s. At that speed a picture disc is a
    /// smear; at eight seconds the cover stays readable and the deck
    /// is still unmistakably running.
    static let secondsPerTurn: Double = 8

    /// How quickly the drawn angle closes on the true one, in seconds.
    /// It is the platter's inertia: long enough to swallow the clock's
    /// one-second ticks, short enough that a pause reads as a stop.
    static let settleTime: Double = 0.16

    /// Rotation of the record surface, in degrees, for a track of
    /// unknown length.
    static func rotation(forProgress progress: Double) -> Double {
        let clamped = max(0, min(1, progress))
        return 360 * turnsPerTrack * clamped
    }

    /// How many times the record turns over a track of this length.
    ///
    /// A whole number, so every record ends the way it started.
    static func turns(forDuration duration: Double) -> Double {
        guard duration > 0 else { return turnsPerTrack }
        return max(1, (duration / secondsPerTurn).rounded())
    }

    /// Rotation of the record surface, in degrees, for a track of
    /// known length. Still a pure function of the playback position.
    static func rotation(forProgress progress: Double, duration: Double) -> Double {
        let clamped = max(0, min(1, progress))
        return 360 * turns(forDuration: duration) * clamped
    }

    /// The signed shortest way round from one angle to another, in
    /// degrees (-180...180).
    static func shortestArc(from current: Double, to target: Double) -> Double {
        var delta = (target - current).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    /// One step of the platter easing toward its true angle.
    ///
    /// Only the angle modulo a full turn matters, so a seek across
    /// the whole track is at most half a turn of correction.
    static func follow(current: Double, target: Double, elapsed: Double) -> Double {
        guard elapsed > 0 else { return current }
        let gain = 1 - exp(-elapsed / settleTime)
        return current + shortestArc(from: current, to: target) * gain
    }

    /// Position of the specular sheen along its sweep, 0...1.
    /// The sheen completes one pass per revolution.
    static func sheenAngle(forProgress progress: Double) -> Double {
        let clamped = max(0, min(1, progress))
        return (clamped * turnsPerTrack).truncatingRemainder(dividingBy: 1)
    }
}

/// The angle the platter was last drawn at.
///
/// A reference type on purpose: it is advanced from inside the
/// timeline's body, and a value in `@State` cannot be written there.
private final class PlatterSpin {
    var angle: Double = 0
    var date: Date?
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
    /// The player is fetching or buffering the track. The deck says so
    /// with a lamp that runs round the platter's edge — on Home there
    /// is no other place a slow start would show.
    var isLoading: Bool = false
    let progress: Double
    /// The track's length in seconds; 0 when unknown (live radio).
    var duration: Double = 0
    let reduceMotion: Bool
    /// Fine-grained progress source.
    ///
    /// The player's clock ticks once a second. This closure is sampled
    /// at display rate so the rotation is smooth; it still derives
    /// from the player's own clock, so the record still tells the
    /// truth about where the audio is.
    var progressAt: ((Date) -> Double)?
    var onTapPlatter: () -> Void
    var onLongPress: () -> Void

    /// The platter's outer diameter. Every other dimension below is
    /// derived from it, so the whole assembly scales as one part.
    static let diameter: CGFloat = 300

    /// The record's diameter — smaller than the platter, so a ring of
    /// felt shows around it.
    static let recordDiameter: CGFloat = 270

    /// The paper label's diameter — about a third of the record, the
    /// way a real 12" label sits on a 12" record.
    static let labelDiameter: CGFloat = 96

    /// The artwork currently on the record face.
    @State private var displayedArt: URL?
    /// False for the first frame, before `displayedArt` has been set.
    /// The record wears the track's own art until then.
    @State private var hasAppeared = false
    private var shownArt: URL? { hasAppeared ? displayedArt : artworkURL }
    /// The artwork that is flipping away.
    @State private var outgoingArt: URL?
    /// 0 = edge-on, 1 = flat. Drives the 3D flip.
    @State private var flipProgress: Double = 1
    /// The track the record is currently showing.
    @State private var displayedTrack: String = ""
    /// 0 = the record is on the platter, 1 = it has been lifted clear.
    /// A record change lifts the old one off, swaps, and sets the new
    /// one down.
    @State private var lift: Double = 0
    @State private var changeToken = 0

    /// How long the old record takes to come off.
    static let liftTime: Double = 0.24
    @State private var spin = PlatterSpin()
    /// Keeps the timeline running for a moment after a pause, so the
    /// platter can settle instead of freezing mid-correction.
    @State private var isSettling = false

    var body: some View {
        TimelineView(timelineSchedule) { timeline in
            platterBody(
                angle: spinAngle(at: timeline.date),
                date: timeline.date
            )
        }
    }

    /// 60fps while the record is turning, stopped entirely when it is
    /// not.
    private var timelineSchedule: AnimationTimelineSchedule {
        if reduceMotion {
            return .animation(minimumInterval: 1.0, paused: !isLoading)
        }
        return .animation(
            minimumInterval: 1.0 / 60.0,
            paused: !(isPlaying || isLoading || isSettling)
        )
    }

    // MARK: - Rotation

    /// The angle to draw the record at.
    private func spinAngle(at date: Date) -> Double {
        // With `reduceMotion` on the record holds still — the arm
        // still shows where in the track we are.
        guard !reduceMotion else { return 0 }

        let target: Double
        if duration > 0 {
            target = PlatterGeometry.rotation(
                forProgress: progressAt?(date) ?? progress,
                duration: duration
            )
        } else if isPlaying {
            // Live radio has no length to be a fraction of. The record
            // still turns, at the same speed, off the wall clock.
            target = date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: PlatterGeometry.secondsPerTurn)
                / PlatterGeometry.secondsPerTurn * 360
        } else {
            return spin.angle
        }

        guard let last = spin.date else {
            spin.angle = target.truncatingRemainder(dividingBy: 360)
            spin.date = date
            return spin.angle
        }
        spin.angle = PlatterGeometry.follow(
            current: spin.angle,
            target: target,
            elapsed: date.timeIntervalSince(last)
        )
        spin.date = date
        return spin.angle
    }

    private func platterBody(angle: Double, date: Date) -> some View {
        ZStack {
            PlatterRim(isLit: isPlaying)

            StrobeBand()
                .rotationEffect(.degrees(angle))

            if isLoading {
                loadingLamp(date: date)
            }

            FeltMat()
                .frame(width: Self.diameter - 20, height: Self.diameter - 20)

            // The record's own shadow on the mat: it is a 2mm slab of
            // vinyl, not a print.
            Circle()
                .fill(.black.opacity(0.55))
                .frame(width: Self.recordDiameter, height: Self.recordDiameter)
                .blur(radius: 5 + 9 * lift)
                .offset(x: 2.5 + 5 * lift, y: 4 + 9 * lift)
                .opacity(1 - 0.6 * lift)

            RecordFace(
                displayedArt: shownArt,
                outgoingArt: outgoingArt,
                flipProgress: flipProgress
            )
            .equatable()
            .frame(width: Self.recordDiameter, height: Self.recordDiameter)
            .rotationEffect(.degrees(angle))
            .modifier(RecordLift(lift: lift))

            RecordSurface(isPictureDisc: shownArt != nil)
                .frame(width: Self.recordDiameter, height: Self.recordDiameter)
                .opacity(0.25 + 0.75 * flipProgress)
                .modifier(RecordLift(lift: lift))

            // No record is perfectly flat. The light on it rocks a
            // degree or so each turn, and that is most of what makes
            // a spinning record look like it is spinning.
            RecordSheen()
                .frame(width: Self.recordDiameter, height: Self.recordDiameter)
                .rotationEffect(.degrees(sin(angle * .pi / 180) * 1.6))
                .opacity(0.25 + 0.75 * flipProgress)
                .modifier(RecordLift(lift: lift))

            Spindle()
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .contentShape(Circle())
        .onTapGesture { onTapPlatter() }
        .onLongPressGesture(minimumDuration: 0.5) { onLongPress() }
        .onAppear {
            displayedArt = artworkURL
            displayedTrack = trackIdentity
            hasAppeared = true
        }
        .onChange(of: isPlaying) { _, playing in
            guard !playing else {
                isSettling = false
                return
            }
            isSettling = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                isSettling = false
            }
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
            // Lift the old record off, swap while it is clear of the
            // platter, set the new one down. (This replaced a flip in
            // place, 2026-11-22: a record is picked up, not turned
            // over on the spindle.)
            changeToken += 1
            let token = changeToken
            let incoming = artworkURL
            outgoingArt = nil
            flipProgress = 1
            withAnimation(.easeIn(duration: Self.liftTime)) {
                lift = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.liftTime) {
                guard changeToken == token else { return }
                displayedArt = incoming
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                    lift = 0
                }
            }
        }
        // The artwork can arrive after the track does (a restored
        // queue, a track whose thumbnails are filled in late). Same
        // record, so no flip — the art just lands on it.
        .onChange(of: artworkURL) { _, newValue in
            // (Not while a change has the record in the air: the swap
            // puts the new art on when the old record is clear.)
            guard trackIdentity == displayedTrack, newValue != displayedArt, lift == 0 else { return }
            displayedArt = newValue
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Record")
        // Identifier so the UI test can grab the record's own
        // screenshot and prove it is animating between frames.
        .accessibilityIdentifier("turntable.record")
        .accessibilityValue(accessibilityState)
        .accessibilityHint("Opens the player")
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityState: String {
        if isPlaying { return "Spinning, \(Int(progress * 100)) percent through track" }
        if isLoading { return "Loading" }
        return "Stopped"
    }

    // MARK: - Loading lamp

    /// An amber lamp running round the strobe band while the track is
    /// being fetched. A cold start can take twenty seconds; without
    /// this the deck would sit there looking as if the tap had missed.
    private func loadingLamp(date: Date) -> some View {
        let turn = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 1.4) / 1.4
        return Circle()
            .trim(from: 0, to: 0.16)
            .stroke(
                AngularGradient(
                    colors: [TurntableTokens.amberLamp.opacity(0), TurntableTokens.amberLamp],
                    center: .center,
                    startAngle: .degrees(0),
                    endAngle: .degrees(58)
                ),
                style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
            )
            .frame(width: Self.diameter - 13.2, height: Self.diameter - 13.2)
            .shadow(color: TurntableTokens.amberLamp.opacity(0.9), radius: 5)
            .rotationEffect(.degrees(reduceMotion ? -90 : turn * 360))
            .allowsHitTesting(false)
    }
}

// MARK: - Platter rim

/// The platter: a lathe-turned aluminium disc. The alternating light
/// and dark sectors are what turned metal does under a single lamp.
private struct PlatterRim: View, Equatable {
    let isLit: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.6))
                .blur(radius: 12)
                .offset(x: 5, y: 10)

            Circle()
                .fill(
                    AngularGradient(
                        stops: [
                            .init(color: Color(white: 0.56), location: 0.00),
                            .init(color: Color(white: 0.86), location: 0.07),
                            .init(color: Color(white: 0.42), location: 0.17),
                            .init(color: Color(white: 0.70), location: 0.27),
                            .init(color: Color(white: 0.36), location: 0.40),
                            .init(color: Color(white: 0.62), location: 0.52),
                            .init(color: Color(white: 0.97), location: 0.63),
                            .init(color: Color(white: 0.50), location: 0.74),
                            .init(color: Color(white: 0.78), location: 0.86),
                            .init(color: Color(white: 0.56), location: 1.00)
                        ],
                        center: .center
                    )
                )
                .colorMultiply(TurntableTokens.aluminium)

            // The chamfer where the edge was cut.
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.85), .white.opacity(0.05), .black.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )

            // The strobe lamp's wash on the edge nearest the cue lever.
            Circle()
                .trim(from: 0.345, to: 0.405)
                .stroke(TurntableTokens.amberLamp, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .padding(6.6)
                .blur(radius: 5)
                .opacity(isLit ? 0.85 : 0)
                .animation(.easeInOut(duration: 0.35), value: isLit)
        }
        .frame(width: PlatterView.diameter, height: PlatterView.diameter)
        .allowsHitTesting(false)
    }
}

// MARK: - Strobe band

/// The anodised band on the platter's edge and its ring of dots.
private struct StrobeBand: View, Equatable {
    static let dotCount = 90

    var body: some View {
        Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            // The band sits inside a 3pt lip of bare aluminium.
            let radius = size.width / 2 - 6.6

            let band = Path(ellipseIn: CGRect(
                x: centre.x - radius, y: centre.y - radius,
                width: radius * 2, height: radius * 2
            ))
            context.stroke(band, with: .color(TurntableTokens.anodised), lineWidth: 7.2)

            for index in 0..<Self.dotCount {
                let angle = Double(index) / Double(Self.dotCount) * 2 * .pi
                let point = CGPoint(
                    x: centre.x + radius * CGFloat(cos(angle)),
                    y: centre.y + radius * CGFloat(sin(angle))
                )
                // Every fifth dot is a longer mark, so the eye has
                // something to follow round.
                let isMark = index % 5 == 0
                var dot = context
                dot.translateBy(x: point.x, y: point.y)
                dot.rotate(by: .radians(angle))
                let rect = isMark
                    ? CGRect(x: -2.1, y: -0.9, width: 4.2, height: 1.8)
                    : CGRect(x: -1.1, y: -0.8, width: 2.2, height: 1.6)
                dot.fill(
                    Path(roundedRect: rect, cornerRadius: 0.6),
                    with: .color(TurntableTokens.aluminium.opacity(isMark ? 0.95 : 0.6))
                )
            }
        }
        .frame(width: PlatterView.diameter, height: PlatterView.diameter)
        .allowsHitTesting(false)
    }
}

// MARK: - Felt mat

private struct FeltMat: View, Equatable {
    var body: some View {
        ZStack {
            Circle()
                .fill(TurntableTokens.felt)
                .overlay(
                    Image(TurntableTexture.felt)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(0.7)
                        .blendMode(.overlay)
                )
                // The texture is a square photograph; without this it
                // spills over the mat as a square of green felt.
                .clipShape(Circle())

            // The platter's lip stands a little proud of the mat.
            Circle()
                .strokeBorder(.black.opacity(0.75), lineWidth: 2)
                .blur(radius: 1.5)
                .clipShape(Circle())

            Circle()
                .strokeBorder(.white.opacity(0.30), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Record face

/// The part of the record that turns: the vinyl and what is printed
/// on it.
private struct RecordFace: View, Equatable {
    let displayedArt: URL?
    let outgoingArt: URL?
    let flipProgress: Double

    var body: some View {
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
            }

            if let displayedArt {
                artworkFace(url: displayedArt)
                    .rotation3DEffect(
                        .degrees(90 - 90 * flipProgress),
                        axis: (x: 0, y: 1, z: 0),
                        perspective: 0.55
                    )
                    .opacity(flipProgress)
            } else {
                // No track loaded: the record wears PeacePlayer's own
                // art instead of sitting there as a blank disc.
                idleArtFace
                    .opacity(flipProgress)

                blankLabel
                    .opacity(flipProgress)
            }
        }
        .clipShape(Circle())
        .allowsHitTesting(false)
    }

    /// PeacePlayer's own record art, printed across the whole disc.
    private var idleArtFace: some View {
        Image(TurntableTexture.idleArt)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: PlatterView.recordDiameter, height: PlatterView.recordDiameter)
            .clipped()
            .colorMultiply(Color(red: 0.78, green: 0.77, blue: 0.82))
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
        .frame(width: PlatterView.recordDiameter, height: PlatterView.recordDiameter)
        .clipped()
        // Printed vinyl is ink on a black disc: knock the artwork down
        // so the grooves and the sheen still read on top of it.
        .colorMultiply(Color(red: 0.84, green: 0.83, blue: 0.86))
    }

    /// An unprinted paper label, so an unloaded deck still looks like
    /// a record with a label rather than a slab of art.
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
                .frame(width: PlatterView.labelDiameter, height: PlatterView.labelDiameter)
                .shadow(color: .black.opacity(0.55), radius: 6, y: 2)

            // The imprint, set on an arc the way a pressed label is.
            CurvedText(
                text: "PEACEPLAYER",
                radius: 40,
                font: .system(size: 7, weight: .semibold, design: .monospaced),
                measurementFont: .monospacedSystemFont(ofSize: 7, weight: .semibold),
                tracking: 1.4,
                color: TurntableTokens.walnut.opacity(0.8)
            )
            .frame(width: PlatterView.labelDiameter, height: PlatterView.labelDiameter)
        }
    }
}

// MARK: - Record surface

/// Everything pressed INTO the record: the grooves, the gaps between
/// tracks, the run-out and the bead round the edge. All of it is
/// concentric, so none of it needs to turn.
private struct RecordSurface: View, Equatable {
    let isPictureDisc: Bool

    /// Where the gaps between tracks fall, as fractions of the grooved
    /// band. Uneven on purpose — no album has five songs of one length.
    private static let trackGaps: [Double] = [0.19, 0.37, 0.58, 0.81]

    var body: some View {
        ZStack {
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let edge = size.width / 2
                let inner = edge * 0.365
                let outer = edge * 0.965

                func ring(_ radius: CGFloat) -> Path {
                    Path(ellipseIn: CGRect(
                        x: centre.x - radius, y: centre.y - radius,
                        width: radius * 2, height: radius * 2
                    ))
                }

                // The grooves: fine lines, alternately catching and
                // losing the light.
                let count = 58
                for index in 0..<count {
                    let fraction = Double(index) / Double(count - 1)
                    let radius = inner + (outer - inner) * CGFloat(fraction)
                    let light = index % 2 == 0
                    let strength = 0.5 + 0.5 * sin(fraction * 23)
                    context.stroke(
                        ring(radius),
                        with: .color(light
                            ? .white.opacity(0.035 + 0.035 * strength)
                            : .black.opacity(0.10 + 0.08 * strength)),
                        lineWidth: 0.6
                    )
                }

                // The gaps between tracks: smooth bands with no groove,
                // which is why they shine.
                for gap in Self.trackGaps {
                    let radius = inner + (outer - inner) * CGFloat(gap)
                    context.stroke(ring(radius), with: .color(.black.opacity(0.30)), lineWidth: 1.6)
                    context.stroke(ring(radius + 1.1), with: .color(.white.opacity(0.10)), lineWidth: 0.5)
                }

                // The run-out, and the ring pressed round the label.
                context.stroke(ring(inner - 3), with: .color(.black.opacity(0.35)), lineWidth: 1.2)
                context.stroke(ring(inner - 4.4), with: .color(.white.opacity(0.14)), lineWidth: 0.5)
            }
            .opacity(isPictureDisc ? 0.9 : 1)

            // The record falls away from the light toward its edge.
            RadialGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.62),
                    .init(color: .black.opacity(0.34), location: 1)
                ],
                center: .center,
                startRadius: 0,
                endRadius: PlatterView.recordDiameter / 2
            )

            // The bead round the edge of the pressing.
            Circle()
                .strokeBorder(.black.opacity(0.75), lineWidth: 2.2)
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.03), .white.opacity(0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
                .padding(1.6)
        }
        .clipShape(Circle())
        .allowsHitTesting(false)
    }
}

// MARK: - Sheen

/// The light on the record.
///
/// Grooves are a diffraction grating: under one lamp a record does not
/// get a round highlight, it gets two opposed wedges of light that run
/// from the label to the edge. That bow-tie is what the eye reads as
/// "vinyl".
private struct RecordSheen: View, Equatable {
    var body: some View {
        ZStack {
            AngularGradient(
                stops: [
                    .init(color: .clear, location: 0.000),
                    .init(color: .clear, location: 0.070),
                    .init(color: TurntableTokens.fillLight.opacity(0.16), location: 0.125),
                    .init(color: .clear, location: 0.180),
                    .init(color: .clear, location: 0.545),
                    .init(color: TurntableTokens.keyLight.opacity(0.10), location: 0.590),
                    .init(color: TurntableTokens.keyLight.opacity(0.34), location: 0.625),
                    .init(color: TurntableTokens.keyLight.opacity(0.10), location: 0.660),
                    .init(color: .clear, location: 0.705),
                    .init(color: .clear, location: 1.000)
                ],
                center: .center
            )
            // The wedges live on the grooved band: they fade out over
            // the label and at the bead.
            .mask(
                RadialGradient(
                    stops: [
                        .init(color: .clear, location: 0.30),
                        .init(color: .white, location: 0.44),
                        .init(color: .white, location: 0.90),
                        .init(color: .clear, location: 1.00)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: PlatterView.recordDiameter / 2
                )
            )
            .blendMode(.plusLighter)

            // The lacquer's own soft gloss, under the key light.
            RadialGradient(
                colors: [.white.opacity(0.13), .white.opacity(0.03), .clear],
                center: UnitPoint(x: 0.28, y: 0.20),
                startRadius: 0,
                endRadius: 170
            )
            .blendMode(.screen)
        }
        .clipShape(Circle())
        .allowsHitTesting(false)
    }
}

// MARK: - Spindle

private struct Spindle: View, Equatable {
    var body: some View {
        ZStack {
            // The hole the record is pressed around.
            Circle()
                .fill(.black.opacity(0.9))
                .frame(width: 12, height: 12)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white, TurntableTokens.aluminium, Color(white: 0.28)],
                        center: UnitPoint(x: 0.34, y: 0.28),
                        startRadius: 0,
                        endRadius: 6.5
                    )
                )
                .frame(width: 8.5, height: 8.5)
                .shadow(color: .black.opacity(0.7), radius: 2, x: 1, y: 1.5)

            Circle()
                .fill(Theme.cyberCyan)
                .frame(width: 2.4, height: 2.4)
                .shadow(color: Theme.cyberCyan.opacity(0.9), radius: 2.5)
        }
        .allowsHitTesting(false)
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

/// A record being lifted off the platter, or set down on it: it comes
/// toward you, and it is gone from the platter by the time it is clear.
private struct RecordLift: ViewModifier {
    let lift: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 + 0.10 * lift)
            .offset(x: -6 * lift, y: -12 * lift)
            // Late, so the record is seen to rise before it is gone.
            .opacity(1 - lift * lift)
    }
}
