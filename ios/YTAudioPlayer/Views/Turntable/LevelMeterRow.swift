//
//  LevelMeterRow.swift
//  YTAudioPlayer
//
//  The level meter on the deck's front panel.
//
//  This is a peak meter, not the frequency spectrum — the deck's
//  meter shows output level, the way a turntable's aux VU meter
//  does. The bands come from AudioVisualizerEngine, which is the
//  same engine the existing NeuralFreqVisualizer reads.
//
//  Drawn with Canvas so the 32 bands cost one Metal layer rather
//  than 32 SwiftUI shapes.
//

import SwiftUI

struct LevelMeterRow: View {
    let levels: [Float]
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }

            let spacing: CGFloat = 2
            let barWidth = max(1, (size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            let floor = size.height

            for (index, level) in levels.enumerated() {
                let magnitude = max(0, min(1, CGFloat(level)))
                guard magnitude > 0.01 else { continue }

                let barHeight = magnitude * size.height
                let x = CGFloat(index) * (barWidth + spacing)
                let rect = CGRect(x: x, y: floor - barHeight, width: barWidth, height: barHeight)

                // Glow pass.
                context.fill(
                    Path(roundedRect: rect.insetBy(dx: -1, dy: 0), cornerRadius: barWidth / 2),
                    with: .color(accent.opacity(0.18))
                )

                // Bar.
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(accent)
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Output level meter")
    }
}
