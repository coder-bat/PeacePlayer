//
//  TonearmView.swift
//  YTAudioPlayer
//
//  The tonearm is the Turntable Home's scrub control.
//
//  A real tonearm rests at the outer edge of the record and travels
//  inward as the track plays. We use the same mapping: progress 0 is
//  the stylus in the lead-in groove, progress 1 is the stylus at the
//  label. Dragging the headshell therefore scrubs, and the arm's
//  position is always an honest readout of where in the track we are.
//
//  The geometry is a real deck's, to scale. The pivot sits off the
//  platter at the back-right; the arm is a little longer than the
//  distance from pivot to spindle (the "overhang"), so it runs down
//  the right-hand side of the record and the stylus rides the
//  front-right quadrant. That leaves the artwork clear — an arm laid
//  across the middle of the record covers the one thing the deck is
//  there to show.
//
//  Three positions:
//
//    parked   - no record loaded: the arm sits in its rest, off the
//               platter
//    lifted   - a record is loaded but not playing: the arm hovers
//               over the groove it will drop into
//    playing  - the stylus is in the groove
//
//  The stylus rides a circular arc about the pivot, exactly as a real
//  arm does. TurntableGeometryTests pins that arc to the record.
//

import SwiftUI

// MARK: - Geometry

enum TonearmGeometry {
    /// The frame the geometry is calibrated against. Positions are
    /// expressed as fractions of the frame so the assembly scales with
    /// the platter as one part.
    static let nominalFrame: CGFloat = 320

    /// The pivot, as a fraction of the frame, measured from the top-left.
    ///
    /// Back-RIGHT, and outside the platter: the arm assembly lives on
    /// the right of a real deck, and the start/stop lever takes the
    /// left.
    static let pivotFraction = CGPoint(x: 0.97, y: 0.13)

    /// The arm's length as a fraction of the frame. 13pt longer than
    /// the pivot-to-spindle distance — the overhang.
    static let armLengthFraction: CGFloat = 0.64

    /// Arm angle with the stylus in the lead-in groove.
    ///
    /// The angles are measured from the +x axis, clockwise (y runs
    /// down the screen), so 90° is an arm pointing straight at the
    /// front of the deck. Calibrated so the stylus lands ~130pt from
    /// the record's centre in a 320pt frame — just inside the record's
    /// 144pt edge.
    static let startAngle: Double = 103.7 * .pi / 180

    /// Arm angle with the stylus at the label (the end of the track).
    ///
    /// Calibrated so the stylus lands ~46pt from the record's centre.
    static let endAngle: Double = 129.1 * .pi / 180

    /// Arm angle in its rest: swung out past the platter's edge.
    static let restAngle: Double = 84.0 * .pi / 180

    /// How far the headshell is cranked in from the arm tube, so the
    /// cartridge sits along the groove instead of across it.
    static let offsetAngle: Double = 24.0 * .pi / 180

    /// Arm angle for a given playback progress.
    /// The headshell's length, in points at any size.
    static let headshellLength: CGFloat = 30

    /// The arm tube's centre line, in the arm's own frame: x runs from
    /// the pivot toward the stylus, y across it. `t` is 0 at the pivot
    /// and 1 where the tube meets the headshell.
    ///
    /// The tube is S-shaped, so it does NOT lie on the straight line
    /// from pivot to stylus. Anything that has to sit under the tube —
    /// the rest post — is placed from this, not from that line.
    static func tubePoint(t: CGFloat, length: CGFloat) -> CGPoint {
        let end = tubeEnd(length: length)
        let c1 = CGPoint(x: length * 0.42, y: 4)
        let c2 = CGPoint(x: length * 0.62, y: -20)
        let u = 1 - t
        let b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t
        return CGPoint(
            x: b1 * c1.x + b2 * c2.x + b3 * end.x,
            y: b1 * c1.y + b2 * c2.y + b3 * end.y
        )
    }

    static func tubeEnd(length: CGFloat) -> CGPoint {
        CGPoint(
            x: length - headshellLength * CGFloat(cos(offsetAngle)),
            y: -headshellLength * CGFloat(sin(offsetAngle))
        )
    }

    /// How far along the tube the rest post holds it.
    static let restT: CGFloat = 0.9

    /// Where the rest post stands, relative to the pivot, on the deck:
    /// under the tube of a parked arm.
    static func restOffset(length: CGFloat) -> CGPoint {
        let local = tubePoint(t: restT, length: length)
        let c = CGFloat(cos(restAngle)), sn = CGFloat(sin(restAngle))
        return CGPoint(x: local.x * c - local.y * sn, y: local.x * sn + local.y * c)
    }

    static func angle(forProgress progress: Double) -> Double {
        let clamped = max(0, min(1, progress))
        return startAngle + (endAngle - startAngle) * clamped
    }

    /// Playback progress for a given arm angle. Inverse of `angle`.
    static func progress(forAngle angle: Double) -> Double {
        let span = endAngle - startAngle
        guard span != 0 else { return 0 }
        return max(0, min(1, (angle - startAngle) / span))
    }

    /// The 10% detent a progress value has just crossed, or nil if it
    /// has not crossed a boundary.
    ///
    /// Returns the index of the most recent boundary at or below the
    /// value (1...9). The caller compares consecutive calls to decide
    /// whether a boundary was newly crossed, so this must return the
    /// index of the boundary it *reached*, not the one it is heading
    /// toward — otherwise the haptic would fire late (at 18% instead
    /// of 10%) and the count would drift out of step with the arm.
    ///
    /// There is no detent at 0% (nothing was crossed) or at 100% (the
    /// track is over).
    static func detent(forProgress progress: Double) -> Int? {
        let clamped = max(0, min(1, progress))
        let index = Int((clamped * 10).rounded(.down))
        guard index >= 1, index <= 9 else { return nil }
        return index
    }

    // MARK: - Placement

    /// The pivot's position in a frame of the given size.
    static func pivot(in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width * pivotFraction.x,
            y: size.height * pivotFraction.y
        )
    }

    /// The arm's length in a frame of the given size.
    static func armLength(in size: CGSize) -> CGFloat {
        min(size.width, size.height) * armLengthFraction
    }

    /// The record's centre in a frame of the given size.
    static func recordCentre(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    /// Where the stylus sits for a given progress.
    ///
    /// The stylus rides the arm's arc about the pivot, so this is a
    /// pure function of the angle — the same angle the user drags
    /// through, which is what makes the scrub feel honest.
    static func stylusPoint(forProgress progress: Double, in size: CGSize) -> CGPoint {
        let angle = angle(forProgress: progress)
        let pivot = pivot(in: size)
        let length = armLength(in: size)
        return CGPoint(
            x: pivot.x + length * CGFloat(cos(angle)),
            y: pivot.y + length * CGFloat(sin(angle))
        )
    }
}

// MARK: - Tonearm

struct TonearmView: View {
    let progress: Double
    /// A record is on the platter. Without one the arm is parked.
    var isLoaded: Bool = true
    /// The needle is up: the record is loaded but not playing.
    var isLifted: Bool = false
    /// The track's length in seconds, for the scrub readout.
    var duration: Double = 0
    /// Fine-grained progress source, sampled while the record plays.
    var progressAt: ((Date) -> Double)?
    /// Called as the arm is dragged. The audio does not follow until
    /// the arm is put down.
    var onScrub: (Double) -> Void = { _ in }
    /// Called when the arm is put down: seek here.
    var onScrubEnded: (Double) -> Void

    @State private var dragProgress: Double?
    /// Where on the arm the finger landed, as an angle from the arm's
    /// own. The arm keeps that offset for the whole drag, so it never
    /// jumps to the finger.
    @State private var grabOffset: Double = 0

    /// Room round the frame for the parts that overhang it: the
    /// counterweight behind the pivot and the parked headshell.
    private static let overhang: CGFloat = 56

    /// The progress the arm is showing right now — the live drag
    /// value if the user is dragging, otherwise the playback progress.
    private var displayedProgress: Double {
        dragProgress ?? progress
    }

    var body: some View {
        TimelineView(timelineSchedule) { timeline in
            armBody(progress: dragProgress ?? progressAt?(timeline.date) ?? progress)
        }
    }

    /// The arm crosses the record once per track, so ten samples a
    /// second is already far finer than a pixel. Stopped whenever the
    /// needle is not in a groove.
    private var timelineSchedule: AnimationTimelineSchedule {
        .animation(
            minimumInterval: 0.1,
            paused: !isLoaded || isLifted || dragProgress != nil
        )
    }

    /// 0 with the needle in the groove, 1 with the arm in the air.
    private var lift: Double {
        (isLoaded && !isLifted && dragProgress == nil) ? 0 : 1
    }

    private func armBody(progress: Double) -> some View {
        GeometryReader { geo in
            let size = geo.size
            let pad = Self.overhang
            let pivot = TonearmGeometry.pivot(in: size)
            let length = TonearmGeometry.armLength(in: size)
            let angle = isLoaded
                ? TonearmGeometry.angle(forProgress: progress)
                : TonearmGeometry.restAngle
            let canvasPivot = CGPoint(x: pivot.x + pad, y: pivot.y + pad)
            let canvasSize = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
            let anchor = UnitPoint(
                x: canvasPivot.x / canvasSize.width,
                y: canvasPivot.y / canvasSize.height
            )
            let swing = Angle.radians(angle - TonearmGeometry.startAngle)

            ZStack(alignment: .topLeading) {
                ArmBase(length: length)
                    .position(pivot)

                // The arm's shadow. It is a separate layer so it can
                // slide away from the arm as the arm lifts — that gap
                // is the only thing that says "up" in a top-down view.
                ArmArtwork(mode: .shadow, pivot: canvasPivot, length: length)
                    .frame(width: canvasSize.width, height: canvasSize.height)
                    .rotationEffect(swing, anchor: anchor)
                    .blur(radius: 2.5 + 3.5 * lift)
                    .opacity(0.55 - 0.2 * lift)
                    .offset(x: -pad + 3 + 7 * lift, y: -pad + 4 + 10 * lift)
                    .allowsHitTesting(false)

                ZStack {
                    ArmArtwork(mode: .body, pivot: canvasPivot, length: length)
                        .allowsHitTesting(false)

                    // The grip: the headshell and the last third of
                    // the tube. Only this part of the arm takes a
                    // touch — the record underneath keeps its own tap.
                    Color.clear
                        .frame(width: 104, height: 64)
                        .contentShape(Rectangle())
                        .rotationEffect(.radians(TonearmGeometry.startAngle))
                        .position(
                            x: canvasPivot.x + (length - 26) * CGFloat(cos(TonearmGeometry.startAngle)),
                            y: canvasPivot.y + (length - 26) * CGFloat(sin(TonearmGeometry.startAngle))
                        )
                        .gesture(scrubGesture(pivot: pivot, armAngle: angle))
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
                .scaleEffect(1 + 0.022 * lift, anchor: anchor)
                .rotationEffect(swing, anchor: anchor)
                .offset(x: -pad, y: -pad)

                PivotCap()
                    .position(pivot)

                if let dragProgress {
                    ScrubReadout(progress: dragProgress, duration: duration)
                        .position(readoutPoint(forProgress: dragProgress, in: size))
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .coordinateSpace(name: Self.space)
            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: isLoaded)
            .animation(.spring(response: 0.34, dampingFraction: 0.68), value: lift)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tone arm")
        .accessibilityValue(isLoaded
            ? "\(Int(displayedProgress * 100)) percent through track"
            : "Parked")
        .accessibilityAdjustableAction { direction in
            // VoiceOver users get a coarse scrub. The full gesture is
            // unavailable to them, so this is the accessible path to
            // the same control.
            guard isLoaded else { return }
            let step = 0.05
            switch direction {
            case .increment: onScrubEnded(min(1, self.progress + step))
            case .decrement: onScrubEnded(max(0, self.progress - step))
            default: break
            }
        }
    }

    private static let space = "tonearm"

    // MARK: - Scrub

    private func scrubGesture(pivot: CGPoint, armAngle: Double) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard isLoaded else { return }
                let fingerAngle = angleOf(point: value.location, around: pivot)
                guard let previous = dragProgress else {
                    // First movement: pick the arm up where it is.
                    grabOffset = angleOf(point: value.startLocation, around: pivot) - armAngle
                    let start = TonearmGeometry.progress(forAngle: fingerAngle - grabOffset)
                    HapticManager.selectionChanged()
                    dragProgress = start
                    onScrub(start)
                    return
                }
                let newProgress = TonearmGeometry.progress(forAngle: fingerAngle - grabOffset)
                let previousDetent = TonearmGeometry.detent(forProgress: previous)
                let currentDetent = TonearmGeometry.detent(forProgress: newProgress)
                if let currentDetent, currentDetent != previousDetent {
                    HapticManager.selectionChanged()
                }
                dragProgress = newProgress
                onScrub(newProgress)
            }
            .onEnded { value in
                guard isLoaded, dragProgress != nil else { return }
                let finalProgress = TonearmGeometry.progress(
                    forAngle: angleOf(point: value.location, around: pivot) - grabOffset
                )
                dragProgress = nil
                onScrubEnded(finalProgress)
            }
    }

    /// Where the scrub readout sits: beside the stylus, on the record
    /// side, clear of the finger that is holding the headshell.
    private func readoutPoint(forProgress progress: Double, in size: CGSize) -> CGPoint {
        let stylus = TonearmGeometry.stylusPoint(forProgress: progress, in: size)
        return CGPoint(x: stylus.x - 58, y: stylus.y - 40)
    }

    /// Angle of a point relative to a pivot, measured from the +x axis.
    private func angleOf(point: CGPoint, around pivot: CGPoint) -> Double {
        atan2(point.y - pivot.y, point.x - pivot.x)
    }
}

// MARK: - Scrub readout

/// The time under the needle while the arm is in the hand. The arm
/// alone says "about two thirds in"; this says 2:41.
private struct ScrubReadout: View {
    let progress: Double
    let duration: Double

    var body: some View {
        HStack(spacing: 4) {
            Text(primary)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(TurntableTokens.cream)
            if duration > 0 {
                Text(Self.clock(duration))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(TurntableTokens.cream.opacity(0.55))
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(TurntableTokens.anodised.opacity(0.92))
                .overlay(Capsule().strokeBorder(TurntableTokens.amberLamp.opacity(0.55), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 8, y: 4)
        )
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var primary: String {
        duration > 0 ? Self.clock(progress * duration) : "\(Int(progress * 100))%"
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Arm base

/// What is bolted to the plinth: the base the pivot stands on, and the
/// rest the arm parks in.
private struct ArmBase: View, Equatable {
    let length: CGFloat

    var body: some View {
        ZStack {
            // Base plate.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.20), TurntableTokens.anodised],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 50, height: 50)
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.5), .white.opacity(0.04), .black.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                )
                .shadow(color: .black.opacity(0.6), radius: 5, x: 2, y: 4)

            // The collar the gimbal sits in.
            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            Color(white: 0.85), Color(white: 0.4), Color(white: 0.9),
                            Color(white: 0.45), Color(white: 0.85)
                        ],
                        center: .center
                    ),
                    lineWidth: 4
                )
                .frame(width: 34, height: 34)

            // The arm rest: a post with a cradle, most of the way down
            // the parked arm — far enough along to stand clear of the
            // platter's edge.
            // The post stands under the TUBE of a parked arm. (It used
            // to stand on the pivot-to-stylus line, which the S-shaped
            // tube does not follow, so the parked arm hung beside it.)
            armRest
                .rotationEffect(.radians(TonearmGeometry.restAngle))
                .offset(
                    x: TonearmGeometry.restOffset(length: length).x,
                    y: TonearmGeometry.restOffset(length: length).y
                )
        }
        .allowsHitTesting(false)
    }

    private var armRest: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.34), TurntableTokens.anodised],
                        center: UnitPoint(x: 0.35, y: 0.3),
                        startRadius: 0,
                        endRadius: 10
                    )
                )
                .frame(width: 17, height: 17)
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.6), radius: 3, x: 1.5, y: 2.5)

            // The cradle's two cheeks, either side of the tube.
            ForEach([-1.0, 1.0], id: \.self) { side in
                Capsule()
                    .fill(TurntableTokens.aluminium)
                    .frame(width: 9, height: 2.6)
                    .offset(y: side * 5.4)
            }
        }
    }
}

// MARK: - Pivot cap

/// The top of the gimbal, drawn over the arm tube.
private struct PivotCap: View, Equatable {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white, TurntableTokens.aluminium, Color(white: 0.32)],
                        center: UnitPoint(x: 0.32, y: 0.26),
                        startRadius: 0,
                        endRadius: 15
                    )
                )
                .frame(width: 21, height: 21)
                .overlay(Circle().strokeBorder(.black.opacity(0.45), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.55), radius: 2.5, x: 1, y: 2)

            Circle()
                .fill(TurntableTokens.anodised)
                .frame(width: 7, height: 7)
            Capsule()
                .fill(Color(white: 0.5))
                .frame(width: 5, height: 1)
                .rotationEffect(.degrees(-38))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Arm artwork

/// The moving part: counterweight, tube, headshell, cartridge.
///
/// Drawn once, at the lead-in angle, in the arm's own coordinates
/// (x runs from the pivot to the stylus). The view is then rotated
/// about the pivot, so swinging the arm never redraws it.
private struct ArmArtwork: View, Equatable {
    enum Mode { case body, shadow }

    let mode: Mode
    /// The pivot, in this view's own coordinates.
    let pivot: CGPoint
    let length: CGFloat

    var body: some View {
        Canvas { context, _ in
            var arm = context
            arm.translateBy(x: pivot.x, y: pivot.y)
            arm.rotate(by: .radians(TonearmGeometry.startAngle))
            switch mode {
            case .body: drawBody(arm)
            case .shadow: drawShadow(arm)
            }
        }
    }

    // In the arm's coordinates the lamp is on the +y side and the
    // record's centre is too; -y is the outside of the deck.

    private var tube: Path {
        var path = Path()
        path.move(to: .zero)
        path.addCurve(
            to: TonearmGeometry.tubeEnd(length: length),
            control1: CGPoint(x: length * 0.42, y: 4),
            control2: CGPoint(x: length * 0.62, y: -20)
        )
        return path
    }

    private var counterweight: Path {
        Path(roundedRect: CGRect(x: -47, y: -12.5, width: 30, height: 25), cornerRadius: 3.5)
    }

    private var stub: Path {
        Path(roundedRect: CGRect(x: -20, y: -3, width: 22, height: 6), cornerRadius: 2)
    }

    /// The headshell plate, in the headshell's coordinates (x runs
    /// along the cartridge, 0 at the stylus).
    private var headshell: Path {
        var path = Path()
        path.move(to: CGPoint(x: -29, y: -3.6))
        path.addLine(to: CGPoint(x: -15, y: -7.5))
        path.addLine(to: CGPoint(x: 4.5, y: -7.5))
        path.addLine(to: CGPoint(x: 6.5, y: -5.5))
        path.addLine(to: CGPoint(x: 6.5, y: 5.5))
        path.addLine(to: CGPoint(x: 4.5, y: 7.5))
        path.addLine(to: CGPoint(x: -15, y: 7.5))
        path.addLine(to: CGPoint(x: -29, y: 3.6))
        path.closeSubpath()
        return path
    }

    /// The finger lift: the hook you pick the arm up by.
    private var fingerLift: Path {
        var path = Path()
        path.move(to: CGPoint(x: -3, y: -7))
        path.addQuadCurve(to: CGPoint(x: 7, y: -21), control: CGPoint(x: -2, y: -18))
        return path
    }

    private func headshellContext(_ arm: GraphicsContext) -> GraphicsContext {
        var shell = arm
        shell.translateBy(x: length, y: 0)
        shell.rotate(by: .radians(TonearmGeometry.offsetAngle))
        return shell
    }

    private func drawShadow(_ arm: GraphicsContext) {
        let ink = GraphicsContext.Shading.color(.black)
        arm.fill(counterweight, with: ink)
        arm.fill(stub, with: ink)
        arm.stroke(tube, with: ink, style: StrokeStyle(lineWidth: 6.6, lineCap: .round))
        let shell = headshellContext(arm)
        shell.fill(headshell, with: ink)
        shell.stroke(fingerLift, with: ink, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
    }

    private func drawBody(_ arm: GraphicsContext) {
        let round = StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)

        // A cylinder seen from above: dark at both edges, a bright
        // band toward the lamp.
        let barrel = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: Color(white: 0.20), location: 0.00),
                .init(color: Color(white: 0.52), location: 0.28),
                .init(color: Color(white: 0.96), location: 0.66),
                .init(color: Color(white: 0.64), location: 0.84),
                .init(color: Color(white: 0.30), location: 1.00)
            ]),
            startPoint: CGPoint(x: 0, y: -12.5),
            endPoint: CGPoint(x: 0, y: 12.5)
        )

        // Counterweight.
        arm.fill(stub, with: .color(Color(white: 0.48)))
        arm.fill(counterweight, with: barrel)
        var knurl = Path()
        var x: CGFloat = -45
        while x <= -29 {
            knurl.move(to: CGPoint(x: x, y: -11.5))
            knurl.addLine(to: CGPoint(x: x, y: 11.5))
            x += 2
        }
        arm.stroke(knurl, with: .color(.black.opacity(0.20)), lineWidth: 0.7)
        // The tracking-force ring at the front of the weight.
        arm.fill(
            Path(CGRect(x: -24.5, y: -12.5, width: 1.2, height: 25)),
            with: .color(.black.opacity(0.35))
        )
        arm.stroke(counterweight, with: .color(.black.opacity(0.55)), lineWidth: 0.8)

        // Tube.
        arm.stroke(tube, with: .color(Color(white: 0.10)), style: StrokeStyle(lineWidth: 6.4, lineCap: .round))
        arm.stroke(tube, with: .color(Color(white: 0.60)), style: StrokeStyle(lineWidth: 5.0, lineCap: .round))
        var shade = arm
        shade.translateBy(x: 0, y: -1.5)
        shade.stroke(tube, with: .color(Color(white: 0.30)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        var glint = arm
        glint.translateBy(x: 0, y: 0.9)
        glint.stroke(tube, with: .color(.white.opacity(0.92)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

        let shell = headshellContext(arm)

        // Finger lift, under the plate it is screwed to.
        shell.stroke(fingerLift, with: .color(Color(white: 0.16)), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
        shell.stroke(fingerLift, with: .color(TurntableTokens.aluminium), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))

        // Headshell plate.
        shell.fill(
            headshell,
            with: .linearGradient(
                Gradient(colors: [Color(white: 0.10), Color(white: 0.24)]),
                startPoint: CGPoint(x: 0, y: -7.5),
                endPoint: CGPoint(x: 0, y: 7.5)
            )
        )
        shell.stroke(headshell, with: .color(.black.opacity(0.7)), style: round)
        var plateEdge = Path()
        plateEdge.move(to: CGPoint(x: -15, y: 6.9))
        plateEdge.addLine(to: CGPoint(x: 4.2, y: 6.9))
        shell.stroke(plateEdge, with: .color(.white.opacity(0.32)), lineWidth: 0.6)

        // The locking collar where the headshell plugs into the tube.
        let collar = Path(roundedRect: CGRect(x: -34, y: -4.6, width: 7, height: 9.2), cornerRadius: 1.4)
        shell.fill(
            collar,
            with: .linearGradient(
                Gradient(colors: [Color(white: 0.34), Color(white: 0.95), Color(white: 0.5)]),
                startPoint: CGPoint(x: 0, y: -4.6),
                endPoint: CGPoint(x: 0, y: 4.6)
            )
        )
        shell.stroke(collar, with: .color(.black.opacity(0.5)), lineWidth: 0.6)

        // Cartridge. Amber, the one coloured part on the arm.
        let cartridge = Path(roundedRect: CGRect(x: -11.5, y: -5.4, width: 16, height: 10.8), cornerRadius: 2)
        shell.fill(
            cartridge,
            with: .linearGradient(
                Gradient(colors: [
                    TurntableTokens.amberLamp.opacity(0.62),
                    TurntableTokens.amberLamp,
                    TurntableTokens.amberLamp.opacity(0.8)
                ]),
                startPoint: CGPoint(x: 0, y: -5.4),
                endPoint: CGPoint(x: 0, y: 5.4)
            )
        )
        shell.stroke(cartridge, with: .color(.black.opacity(0.5)), lineWidth: 0.7)
        for screw in [-21.0, -16.0] {
            shell.fill(
                Path(ellipseIn: CGRect(x: screw - 1.1, y: -1.1, width: 2.2, height: 2.2)),
                with: .color(Color(white: 0.7))
            )
        }

        // The stylus.
        shell.fill(
            Path(ellipseIn: CGRect(x: -1.5, y: -1.5, width: 3, height: 3)),
            with: .color(.white.opacity(0.95))
        )
    }
}
