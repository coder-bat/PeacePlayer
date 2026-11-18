//
//  TonearmView.swift
//  YTAudioPlayer
//
//  The tonearm is the Turntable Home's scrub control.
//
//  A real tonearm rests at the outer edge of the record and travels
//  inward as the track plays. We use the same mapping: progress 0 is
//  the arm at rest, progress 1 is the arm over the run-out groove.
//  Dragging the arm therefore scrubs, and the arm's position is
//  always an honest readout of where in the track we are.
//
//  The pivot assembly sits at the deck's back-RIGHT corner, the way
//  it does on every real turntable (Technics SL-1200, Rega, Pro-Ject
//  all mount the arm on the right and the start/stop lever on the
//  left). The arm reaches across the record to the left-hand side,
//  where the headshell travels down the grooves toward the label.
//
//  The stylus rides a circular arc about the pivot, exactly as a real
//  arm does: the arm's length is fixed, so the stylus cannot travel
//  in a straight line into the label. The angles below are calibrated
//  so the stylus starts on the outer groove and finishes at the edge
//  of the paper label, and TurntableGeometryTests asserts both.
//

import SwiftUI

// MARK: - Geometry

enum TonearmGeometry {
    /// The frame the geometry is calibrated against — the platter's
    /// own diameter. Positions are expressed as fractions of the frame
    /// so the assembly scales with the platter as one part.
    static let nominalFrame: CGFloat = 320

    /// The pivot, as a fraction of the frame, measured from the top-left.
    ///
    /// Back-RIGHT: the arm assembly lives on the right of the platter
    /// on a real deck, and the cue lever takes the left.
    static let pivotFraction = CGPoint(x: 0.89375, y: 0.09375)

    /// The arm's length as a fraction of the frame.
    static let armLengthFraction: CGFloat = 0.671875

    /// Arm angle at the outer groove (the arm at rest).
    ///
    /// Calibrated so the stylus lands ~130pt from the record's centre
    /// in a 320pt frame — just inside the record's 138pt edge.
    ///
    /// The angles are measured from the +x axis. With the pivot on the
    /// right the arm points leftwards, so the sweep runs backwards
    /// through 180°: 171.2° at the outer groove down to 142.9° at the
    /// label's edge.
    static let startAngle: Double = 171.2 * .pi / 180

    /// Arm angle over the label's edge (the end of the track).
    ///
    /// Calibrated so the stylus lands ~45pt from the record's centre,
    /// which is the edge of the 96pt paper label.
    static let endAngle: Double = 142.9 * .pi / 180

    /// Arm angle for a given playback progress.
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
    let isScrubbing: Bool
    var onScrub: (Double) -> Void
    var onScrubEnded: (Double) -> Void

    @State private var dragProgress: Double?

    /// The progress the arm is showing right now — the live drag
    /// value if the user is dragging, otherwise the playback progress.
    private var displayedProgress: Double {
        dragProgress ?? progress
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pivot = TonearmGeometry.pivot(in: size)
            let angle = TonearmGeometry.angle(forProgress: displayedProgress)
            let stylus = TonearmGeometry.stylusPoint(forProgress: displayedProgress, in: size)
            let centre = TonearmGeometry.recordCentre(in: size)

            // The stylus meets the record head-on: the headshell sits
            // between the arm and the needle.
            let inward = unitVector(from: stylus, to: centre)
            let armEnd = CGPoint(
                x: stylus.x - inward.x * 14,
                y: stylus.y - inward.y * 14
            )

            ZStack {
                // Counterweight — the fat cylinder at the back of the arm.
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                TurntableTokens.aluminium,
                                TurntableTokens.aluminium.opacity(0.35),
                                TurntableTokens.aluminium.opacity(0.75)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 5, y: 2)
                    .position(
                        x: pivot.x - 15 * CGFloat(cos(angle)),
                        y: pivot.y - 15 * CGFloat(sin(angle))
                    )

                // Pivot base.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [TurntableTokens.aluminium.opacity(0.85), TurntableTokens.aluminium.opacity(0.2)],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 24
                        )
                    )
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.55), radius: 6, y: 2)
                    .position(pivot)

                // The arm tube.
                Path { path in
                    path.move(to: pivot)
                    path.addLine(to: armEnd)
                }
                .stroke(
                    LinearGradient(
                        colors: [
                            TurntableTokens.aluminium,
                            TurntableTokens.edgeHighlight,
                            TurntableTokens.aluminium.opacity(0.55)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .shadow(color: .black.opacity(0.5), radius: 4, y: 2)

                // Headshell + stylus at the far end.
                headshell
                    .rotationEffect(.radians(angle))
                    .position(
                        x: stylus.x - inward.x * 7,
                        y: stylus.y - inward.y * 7
                    )

                // The stylus itself — the needle touching the groove.
                Circle()
                    .fill(TurntableTokens.edgeHighlight)
                    .frame(width: 4, height: 4)
                    .shadow(color: .black.opacity(0.8), radius: 2)
                    .position(stylus)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let newProgress = TonearmGeometry.progress(
                            forAngle: angleOf(point: value.location, around: pivot)
                        )
                        if let previous = dragProgress {
                            let previousDetent = TonearmGeometry.detent(forProgress: previous)
                            let currentDetent = TonearmGeometry.detent(forProgress: newProgress)
                            if let currentDetent, currentDetent != previousDetent {
                                HapticManager.selectionChanged()
                            }
                        } else {
                            HapticManager.selectionChanged()
                        }
                        dragProgress = newProgress
                        onScrub(newProgress)
                    }
                    .onEnded { value in
                        let finalProgress = TonearmGeometry.progress(
                            forAngle: angleOf(point: value.location, around: pivot)
                        )
                        dragProgress = nil
                        onScrubEnded(finalProgress)
                    }
            )
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: displayedProgress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tone arm")
        .accessibilityValue("\(Int(displayedProgress * 100)) percent through track")
        .accessibilityAdjustableAction { direction in
            // VoiceOver users get a coarse scrub. The full gesture is
            // unavailable to them, so this is the accessible path to
            // the same control.
            let step = 0.05
            switch direction {
            case .increment: onScrubEnded(min(1, progress + step))
            case .decrement: onScrubEnded(max(0, progress - step))
            default: break
            }
        }
    }

    // MARK: - Headshell

    private var headshell: some View {
        ZStack {
            // Headshell body — a small angled block.
            RoundedRectangle(cornerRadius: 3)
                .fill(
                    LinearGradient(
                        colors: [TurntableTokens.amberLamp, TurntableTokens.amberLamp.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 24, height: 13)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.black.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
        }
    }

    // MARK: - Helpers

    /// Angle of a point relative to a pivot, measured from the +x axis.
    private func angleOf(point: CGPoint, around pivot: CGPoint) -> Double {
        atan2(point.y - pivot.y, point.x - pivot.x)
    }

    /// A unit vector pointing from `origin` to `target`.
    private func unitVector(from origin: CGPoint, to target: CGPoint) -> CGPoint {
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return CGPoint(x: 0, y: 1) }
        return CGPoint(x: dx / length, y: dy / length)
    }
}
