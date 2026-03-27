//
//  NeuralFreqVisualizer.swift
//  YTAudioPlayer
//
//  Cyberpunk-styled real-time audio frequency visualizer.
//  Renders AudioVisualizerEngine's 32 band magnitudes as neon bars
//  using SwiftUI Canvas for zero-overhead layout.
//

import SwiftUI

// MARK: - Style

enum VisualizerStyle {
    /// Bars rise from bottom, gradient glow — used as ambient backdrop behind artwork
    case neural
    /// Thin single-color bars from bottom — lightweight option
    case minimal
    /// Symmetric bars from center (top + bottom mirror)
    case mirror
}

// MARK: - NeuralFreqVisualizer

struct NeuralFreqVisualizer: View {
    @ObservedObject var engine: AudioVisualizerEngine
    var style: VisualizerStyle = .neural
    var barSpacing: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            switch style {
            case .neural:
                drawNeural(context: context, size: size)
            case .minimal:
                drawMinimal(context: context, size: size)
            case .mirror:
                drawMirror(context: context, size: size)
            }
        }
        .drawingGroup() // Rasterize entire canvas as a single Metal layer
    }

    // MARK: - Neural (default) — bars from bottom, cyan→magenta gradient with glow

    private func drawNeural(context: GraphicsContext, size: CGSize) {
        let bands = engine.bands
        let count = bands.count
        guard count > 0 else { return }

        let totalSpacing = barSpacing * CGFloat(count - 1)
        let barWidth = (size.width - totalSpacing) / CGFloat(count)
        let maxBarHeight = size.height

        for i in 0..<count {
            let magnitude = CGFloat(bands[i])
            guard magnitude > 0.005 else { continue }

            let barHeight = magnitude * maxBarHeight
            let x = CGFloat(i) * (barWidth + barSpacing)
            let y = size.height - barHeight
            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)

            // Color: interpolate cyan → magenta based on frequency band position
            let t = Double(i) / Double(count - 1)
            let barColor = interpolateCyberColor(t: t, magnitude: Double(magnitude))

            // Glow pass (wider, lower opacity)
            let glowRect = CGRect(
                x: x - barWidth * 0.5,
                y: y - 4,
                width: barWidth * 2,
                height: barHeight + 4
            )
            context.fill(
                Path(roundedRect: glowRect, cornerRadius: barWidth),
                with: .color(barColor.opacity(0.18))
            )

            // Main bar
            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth * 0.4),
                with: .color(barColor.opacity(0.85 + 0.15 * Double(magnitude)))
            )
        }
    }

    // MARK: - Minimal — thin white bars

    private func drawMinimal(context: GraphicsContext, size: CGSize) {
        let bands = engine.bands
        let count = bands.count
        guard count > 0 else { return }

        let barWidth = max(1, (size.width - barSpacing * CGFloat(count - 1)) / CGFloat(count))

        for i in 0..<count {
            let magnitude = CGFloat(bands[i])
            guard magnitude > 0.01 else { continue }

            let barHeight = max(2, magnitude * size.height)
            let x = CGFloat(i) * (barWidth + barSpacing)
            let rect = CGRect(x: x, y: size.height - barHeight, width: barWidth, height: barHeight)

            context.fill(
                Path(roundedRect: rect, cornerRadius: 1),
                with: .color(.white.opacity(0.6 + 0.4 * Double(magnitude)))
            )
        }
    }

    // MARK: - Mirror — symmetric bars from center

    private func drawMirror(context: GraphicsContext, size: CGSize) {
        let bands = engine.bands
        let count = bands.count
        guard count > 0 else { return }

        let totalSpacing = barSpacing * CGFloat(count - 1)
        let barWidth = (size.width - totalSpacing) / CGFloat(count)
        let center = size.height / 2
        let maxHalfHeight = center * 0.9

        for i in 0..<count {
            let magnitude = CGFloat(bands[i])
            guard magnitude > 0.005 else { continue }

            let halfHeight = magnitude * maxHalfHeight
            let x = CGFloat(i) * (barWidth + barSpacing)
            let t = Double(i) / Double(count - 1)
            let barColor = interpolateCyberColor(t: t, magnitude: Double(magnitude))

            // Top half (above center)
            let topRect = CGRect(x: x, y: center - halfHeight, width: barWidth, height: halfHeight)
            // Bottom half (below center)
            let botRect = CGRect(x: x, y: center, width: barWidth, height: halfHeight)

            let path = Path { p in
                p.addRoundedRect(in: topRect, cornerSize: CGSize(width: barWidth * 0.4, height: barWidth * 0.4))
                p.addRoundedRect(in: botRect, cornerSize: CGSize(width: barWidth * 0.4, height: barWidth * 0.4))
            }

            // Glow
            let glowPath = Path { p in
                p.addRoundedRect(
                    in: CGRect(x: x - barWidth * 0.4, y: center - halfHeight - 3, width: barWidth * 1.8, height: halfHeight * 2 + 6),
                    cornerSize: CGSize(width: barWidth, height: barWidth)
                )
            }
            context.fill(glowPath, with: .color(barColor.opacity(0.15)))
            context.fill(path, with: .color(barColor.opacity(0.85)))
        }
    }

    // MARK: - Color helpers

    private func interpolateCyberColor(t: Double, magnitude: Double) -> Color {
        // Low freq: cyberCyan, mid: mix, high: cyberMagenta
        // Also brightness boost at high magnitude
        let cyan = Color.cyberCyan
        let magenta = Color.cyberMagenta
        let yellow = Color.cyberYellow

        if t < 0.5 {
            // Cyan → Yellow
            return lerp(from: cyan, to: yellow, t: t * 2)
        } else {
            // Yellow → Magenta
            return lerp(from: yellow, to: magenta, t: (t - 0.5) * 2)
        }
    }

    private func lerp(from: Color, to: Color, t: Double) -> Color {
        // Interpolate in RGB space
        let clampedT = max(0, min(1, t))
        return Color(
            red: lerp(from.components.red, to.components.red, t: clampedT),
            green: lerp(from.components.green, to.components.green, t: clampedT),
            blue: lerp(from.components.blue, to.components.blue, t: clampedT)
        )
    }

    private func lerp(_ a: Double, _ b: Double, t: Double) -> Double {
        a + (b - a) * t
    }
}

// MARK: - Color component extraction

private extension Color {
    var components: (red: Double, green: Double, blue: Double, opacity: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
    }
}

// MARK: - Preview

#if DEBUG
struct NeuralFreqVisualizer_Previews: PreviewProvider {
    static var previews: some View {
        let engine = AudioVisualizerEngine.shared
        ZStack {
            Color.black
            NeuralFreqVisualizer(engine: engine, style: .neural)
                .frame(height: 120)
                .padding()
        }
        .preferredColorScheme(.dark)
    }
}
#endif
