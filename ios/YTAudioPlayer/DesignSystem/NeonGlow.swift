//
//  NeonGlow.swift
//  PeacePlayer
//
//  S15: reusable "neon glow shadow" helper. The audit identified
//  25+ call sites that independently re-implemented the same
//  neon-colored shadow recipe (a soft colored shadow under an
//  artwork / pill / button). The most common pattern was:
//
//      .shadow(color: Theme.cyberCyan.opacity(0.4), radius: 10)
//
//  but the values drifted: some used 0.3 / 12, some 0.5 / 8,
//  some 0.6 / 6. This helper gives them a single source.
//
//  Use as `.neonGlow(.cyan)` or `.neonGlow(.magenta, radius: 12)`.
//

import SwiftUI

enum NeonGlowColor {
    case cyan
    case magenta
    case yellow
    case dim

    var color: Color {
        switch self {
        case .cyan:    return Theme.cyberCyan
        case .magenta: return Theme.cyberMagenta
        case .yellow:  return Theme.cyberYellow
        case .dim:     return Theme.cyberDim
        }
    }
}

extension View {
    /// Apply the canonical neon glow shadow. Defaults to cyan
    /// at 0.4 opacity, radius 10 — the most common setting.
    func neonGlow(
        _ glow: NeonGlowColor = .cyan,
        opacity: Double = 0.4,
        radius: CGFloat = 10,
        y: CGFloat = 0
    ) -> some View {
        self.shadow(
            color: glow.color.opacity(opacity),
            radius: radius,
            x: 0,
            y: y
        )
    }
}
