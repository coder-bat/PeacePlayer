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
//  The pivot sits at the top-right of the platter; the arm sweeps
//  clockwise from about -18 degrees (rest, outer edge) to +26 degrees
//  (inner). The headshell carries the stylus that touches the record.
//

import SwiftUI

// MARK: - Geometry

enum TonearmGeometry {
    /// Arm angle at the outer edge of the record (radians).
    static let startAngle: Double = -18 * .pi / 180

    /// Arm angle over the inner run-out groove (radians).
    static let endAngle: Double = 26 * .pi / 180

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
    /// Returns the detent index (1...9) so the caller can fire a
    /// haptic exactly once per boundary crossing.
    static func detent(forProgress progress: Double) -> Int? {
        let clamped = max(0, min(1, progress))
        let index = Int((clamped * 10).rounded(.down))
        guard index >= 1, index <= 9 else { return nil }
        // Only fire when we are within the last 20% of the band, so a
        // value that sits exactly on a boundary (0.10) reports the
        // boundary it just reached rather than repeating it.
        let fractional = clamped * 10 - Double(index)
        guard fractional >= 0.8 else { return nil }
        return index
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
            let pivot = CGPoint(x: size.width - 26, y: 30)
            let armLength = min(size.width, size.height) * 0.62
            let angle = TonearmGeometry.angle(forProgress: displayedProgress)
            let stylus = CGPoint(
                x: pivot.x + armLength * cos(angle),
                y: pivot.y + armLength * sin(angle)
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
                    .frame(width: 30, height: 30)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 5, y: 2)
                    .position(x: pivot.x - 12, y: pivot.y)

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
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.55), radius: 6, y: 2)
                    .position(pivot)

                // The arm tube.
                Path { path in
                    path.move(to: pivot)
                    path.addLine(to: stylus)
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
                    .position(x: stylus.x, y: stylus.y)
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
                .frame(width: 22, height: 14)
                .rotationEffect(.degrees(28))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.black.opacity(0.35), lineWidth: 1)
                        .rotationEffect(.degrees(28))
                )
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)

            // The stylus — the actual needle that touches the record.
            Circle()
                .fill(TurntableTokens.edgeHighlight)
                .frame(width: 4, height: 4)
                .offset(y: 9)
        }
    }

    // MARK: - Helpers

    /// Angle of a point relative to a pivot, measured from the +x axis.
    private func angleOf(point: CGPoint, around pivot: CGPoint) -> Double {
        atan2(point.y - pivot.y, point.x - pivot.x)
    }
}
