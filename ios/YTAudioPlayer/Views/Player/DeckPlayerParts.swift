//
//  DeckPlayerParts.swift
//  YTAudioPlayer
//
//  The parts of the Deck full player's case (revision 2026-11-22).
//
//  The player is the same deck as Home with a case of controls open
//  under it (FullPlayer.swift, `deckCaseContent`). These are the
//  case's own instruments:
//
//    DeckSeekDial    a backlit glass window with the track's waveform
//                    (or a plain scale) etched in it and a needle that
//                    marks where you are. Drag the needle to move
//                    through the track.
//    DeckOnAirStrip  what the dial's place shows for a live station.
//

import SwiftUI

// MARK: - Seek dial

/// Pure helpers for the dial, so the arithmetic can be tested.
enum DeckDial {
    /// How many bars the waveform is drawn with.
    static let barCount = 84

    /// Peaks resampled to `count` bars, each the loudest sample in its
    /// slice, normalised so the loudest bar is 1.
    static func bars(from peaks: [Float], count: Int = barCount) -> [CGFloat] {
        guard !peaks.isEmpty, count > 0 else { return [] }
        var result: [CGFloat] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let lower = index * peaks.count / count
            let upper = max(lower + 1, (index + 1) * peaks.count / count)
            let slice = peaks[lower..<min(upper, peaks.count)]
            result.append(CGFloat(slice.max() ?? 0))
        }
        let top = result.max() ?? 0
        guard top > 0 else { return result.map { _ in 0.08 } }
        return result.map { max(0.08, $0 / top) }
    }

    /// The fraction of the track a touch at `x` points to.
    static func progress(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(0, x / width), 1))
    }

    /// "3:42" for a position; "0:00" for anything that is not a time.
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        return DeckFormat.runtime(Int(seconds)) ?? "0:00"
    }
}

struct DeckSeekDial: View {
    @ObservedObject var clock: PlaybackClock
    /// The track's waveform, when it is known.
    var peaks: [Float]?
    /// Called once, when the needle is let go.
    var onSeek: (Double) -> Void

    static let glassHeight: CGFloat = 50

    /// Where the finger has the needle, while it has it.
    @State private var scrub: Double?
    /// The needle is held where it was dropped until the player gets
    /// there, so it does not snap back for a beat.
    @State private var pending: Double?
    @State private var lastDetent: Int?

    private var duration: Double {
        clock.expectedDuration > 0 ? clock.expectedDuration : clock.duration
    }

    private var shown: Double {
        scrub ?? pending ?? min(1, max(0, clock.progress))
    }

    var body: some View {
        VStack(spacing: 6) {
            glass

            HStack {
                Text(DeckDial.time(shown * duration))
                    .foregroundColor(scrub == nil ? TurntableTokens.cream.opacity(0.8) : DeckSignal.live)
                Spacer()
                Text(duration > 0 ? "-" + DeckDial.time(max(0, duration - shown * duration)) : "--:--")
                    .foregroundColor(TurntableTokens.brass)
            }
            .font(DeckType.smallPrint)
            .monospacedDigit()
        }
        .onReceive(clock.$progress) { value in
            guard let target = pending, abs(value - target) < 0.02 else { return }
            pending = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue("\(DeckDial.time(shown * duration)) of \(DeckDial.time(duration))")
        .accessibilityAdjustableAction { direction in
            let step = duration > 0 ? 10 / duration : 0.05
            let target = min(1, max(0, clock.progress + (direction == .increment ? step : -step)))
            onSeek(target)
        }
    }

    private var glass: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return GeometryReader { geo in
            let width = geo.size.width
            let x = width * CGFloat(shown)

            ZStack(alignment: .leading) {
                // The lamp behind the glass.
                shape.fill(
                    LinearGradient(
                        colors: [Color(red: 0.10, green: 0.075, blue: 0.035), Color(red: 0.035, green: 0.028, blue: 0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Canvas { context, size in
                    draw(in: &context, size: size, needleX: x)
                }
                .padding(.horizontal, 7)

                // The needle.
                Rectangle()
                    .fill(DeckSignal.live)
                    .frame(width: 1.6)
                    .shadow(color: DeckSignal.live.opacity(0.9), radius: 4)
                    .offset(x: 7 + (width - 14) * CGFloat(shown) - 0.8)
                    .padding(.vertical, 3)

                // Reflection on the glass, and the bezel's shadow.
                shape
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.10), .clear],
                            startPoint: .top,
                            endPoint: UnitPoint(x: 0.5, y: 0.45)
                        )
                    )
                    .allowsHitTesting(false)
                shape
                    .strokeBorder(.black.opacity(0.85), lineWidth: 4)
                    .blur(radius: 3)
                    .mask(shape)
                    .allowsHitTesting(false)
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [.black.opacity(0.8), .white.opacity(0.05), .white.opacity(0.26)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let progress = DeckDial.progress(atX: value.location.x - 7, width: width - 14)
                        scrub = progress
                        let detent = Int(progress * 10)
                        if let lastDetent, lastDetent != detent {
                            HapticManager.selectionChanged()
                        }
                        lastDetent = detent
                    }
                    .onEnded { _ in
                        guard let target = scrub else { return }
                        scrub = nil
                        lastDetent = nil
                        pending = target
                        HapticManager.light()
                        onSeek(target)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            if pending == target { pending = nil }
                        }
                    }
            )
        }
        .frame(height: Self.glassHeight)
    }

    /// The scale etched in the glass: the track's waveform when it is
    /// known, a ruler when it is not. What has been played is lit.
    private func draw(in context: inout GraphicsContext, size: CGSize, needleX: CGFloat) {
        let lit = TurntableTokens.amberLamp
        let playedWidth = size.width * CGFloat(shown)
        if let peaks, !peaks.isEmpty {
            let bars = DeckDial.bars(from: peaks)
            let step = size.width / CGFloat(bars.count)
            let barWidth = max(1, step * 0.55)
            for (index, level) in bars.enumerated() {
                let centre = (CGFloat(index) + 0.5) * step
                let height = max(2, (size.height - 14) * level)
                let rect = CGRect(x: centre - barWidth / 2, y: (size.height - height) / 2, width: barWidth, height: height)
                let played = centre <= playedWidth
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(lit.opacity(played ? 0.92 : 0.26))
                )
            }
        } else {
            let ticks = 60
            for index in 0...ticks {
                let xPos = size.width * CGFloat(index) / CGFloat(ticks)
                let major = index % 10 == 0
                let mid = index % 5 == 0
                let height: CGFloat = major ? 20 : (mid ? 13 : 7)
                let rect = CGRect(x: xPos - 0.5, y: size.height - 8 - height, width: 1, height: height)
                context.fill(Path(rect), with: .color(lit.opacity(xPos <= playedWidth ? 0.9 : 0.3)))
            }
        }
    }
}

// MARK: - On air

/// What the dial shows for a live station: there is no position to
/// mark, only that it is on.
struct DeckOnAirStrip: View {
    var body: some View {
        HStack(spacing: 9) {
            DeckLamp(color: DeckSignal.live, state: .working, size: 7)
            Text("ON AIR")
                .font(DeckType.button)
                .tracking(2.4)
                .foregroundColor(DeckSignal.live)
        }
        .frame(maxWidth: .infinity)
        .frame(height: DeckSeekDial.glassHeight)
        .deckWell(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live")
    }
}
