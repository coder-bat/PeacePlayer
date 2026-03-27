//
//  WaveformSeekBar.swift
//  YTAudioPlayer
//
//  SoundCloud-style symmetric waveform scrubber.
//  Renders 200 amplitude bars mirrored top+bottom, split at the current playback position:
//    - Left of position: cyberCyan with glow (played portion)
//    - Right of position: white at low opacity (unplayed)
//  Drag gesture replaces the flat progress bar from FullPlayer.
//

import SwiftUI

struct WaveformSeekBar: View {
    /// Normalized amplitude peaks (0.0 – 1.0), typically 200 values.
    let peaks: [Float]

    /// Current playback progress (0.0 – 1.0).
    @Binding var progress: Double

    /// Called when the user drags/taps to seek. Receives new progress 0..1.
    var onSeek: (Double) -> Void

    /// Called on drag start/end for thumb visibility control.
    var onDragChange: ((Bool) -> Void)?

    // MARK: - Layout

    private var barSpacing: CGFloat { 1.5 }

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                drawWaveform(context: context, size: size)
            }
            .drawingGroup()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let newProgress = min(max(0, Double(value.location.x / geo.size.width)), 1)
                        onSeek(newProgress)
                        onDragChange?(true)
                    }
                    .onEnded { _ in
                        onDragChange?(false)
                    }
            )
        }
    }

    // MARK: - Drawing

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        guard !peaks.isEmpty else { return }

        let count = peaks.count
        let totalSpacing = barSpacing * CGFloat(count - 1)
        let barWidth = max(1, (size.width - totalSpacing) / CGFloat(count))
        let centerY = size.height / 2
        let maxHalfHeight = centerY * 0.92

        let splitX = size.width * CGFloat(progress)

        for i in 0..<count {
            let amplitude = CGFloat(peaks[i])
            let halfHeight = max(1.5, amplitude * maxHalfHeight)
            let x = CGFloat(i) * (barWidth + barSpacing)
            let isPlayed = (x + barWidth / 2) <= splitX

            let topRect = CGRect(x: x, y: centerY - halfHeight, width: barWidth, height: halfHeight)
            let botRect = CGRect(x: x, y: centerY, width: barWidth, height: halfHeight)

            let cornerSize = CGSize(width: barWidth * 0.5, height: barWidth * 0.5)

            if isPlayed {
                // Played: cyberCyan with subtle glow
                let glowRect = CGRect(
                    x: x - barWidth * 0.5,
                    y: centerY - halfHeight - 2,
                    width: barWidth * 2,
                    height: halfHeight * 2 + 4
                )
                context.fill(
                    Path(roundedRect: glowRect, cornerSize: cornerSize),
                    with: .color(Color.cyberCyan.opacity(0.18))
                )
                context.fill(
                    Path { p in
                        p.addRoundedRect(in: topRect, cornerSize: cornerSize)
                        p.addRoundedRect(in: botRect, cornerSize: cornerSize)
                    },
                    with: .color(Color.cyberCyan.opacity(0.9))
                )
            } else {
                // Unplayed: dim white
                context.fill(
                    Path { p in
                        p.addRoundedRect(in: topRect, cornerSize: cornerSize)
                        p.addRoundedRect(in: botRect, cornerSize: cornerSize)
                    },
                    with: .color(Color.white.opacity(0.22))
                )
            }
        }

        // Scrub position line
        let lineX = splitX
        let lineRect = CGRect(x: lineX - 1, y: 0, width: 2, height: size.height)
        context.fill(Path(lineRect), with: .color(Color.white.opacity(0.9)))

        // Scrub knob
        let knobRadius: CGFloat = 5
        let knobRect = CGRect(
            x: lineX - knobRadius,
            y: centerY - knobRadius,
            width: knobRadius * 2,
            height: knobRadius * 2
        )
        context.fill(Path(ellipseIn: knobRect), with: .color(Color.white))
    }
}

// MARK: - Preview

#if DEBUG
struct WaveformSeekBar_Previews: PreviewProvider {
    @State static var progress: Double = 0.35

    static var previews: some View {
        let service = WaveformService.shared
        let peaks = service.pseudoWaveform(for: "dQw4w9WgXcQ", count: 200)

        ZStack {
            Color.black
            WaveformSeekBar(peaks: peaks, progress: $progress) { newProgress in
                progress = newProgress
            }
            .frame(height: 48)
            .padding(.horizontal, 24)
        }
        .preferredColorScheme(.dark)
        .frame(height: 120)
    }
}
#endif
