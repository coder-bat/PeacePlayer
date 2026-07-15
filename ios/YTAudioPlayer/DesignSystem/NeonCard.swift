//
//  NeonCard.swift
//  PeacePlayer
//
//  S15: reusable "neon card chrome" component. The audit
//  identified 12+ files that independently re-implemented
//  the same dark-surface + neon-stroke + soft-shadow card
//  look (PlaylistDetailView, PlaylistsView, CreatePlaylistSheet,
//  AddToPlaylistSheet, etc.). The styles drifted: some had
//  `cornerRadius(8)`, some `cornerRadius(12)`, some used
//  `Theme.cyberCyan.opacity(0.1)` and some used `Theme.cyberSurface`,
//  some had shadows and some didn't.
//
//  `NeonCard` is the single source of truth. The variant enum
//  picks one of the 4 standard looks:
//   - .standard: 16pt corner, cyberCyan stroke 0.2, soft shadow
//   - .elevated:  16pt corner, cyberCyan stroke 0.3, heavier shadow
//   - .subtle:   16pt corner, cyberDim stroke 0.15, no shadow
//   - .outline:  12pt corner, cyberCyan stroke 0.4, no shadow
//
//  Use via `.neonCard()` or `.neonCard(.elevated)` on any view.
//

import SwiftUI

enum NeonCardStyle {
    case standard
    case elevated
    case subtle
    case outline

    var cornerRadius: CGFloat {
        switch self {
        case .standard, .elevated, .subtle: return 16
        case .outline: return 12
        }
    }

    var strokeColor: Color {
        switch self {
        case .standard: return Theme.cyberCyan.opacity(0.2)
        case .elevated: return Theme.cyberCyan.opacity(0.3)
        case .subtle:   return Theme.cyberDim.opacity(0.15)
        case .outline:  return Theme.cyberCyan.opacity(0.4)
        }
    }

    var strokeWidth: CGFloat {
        switch self {
        case .standard, .subtle, .outline: return 1
        case .elevated: return 1.5
        }
    }

    var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
        switch self {
        case .standard: return (Theme.cyberCyan.opacity(0.15), 8, 2)
        case .elevated: return (Theme.cyberCyan.opacity(0.3), 14, 4)
        case .subtle, .outline: return (.clear, 0, 0)
        }
    }
}

extension View {
    /// Apply the canonical neon-card chrome. Use as
    /// `SomeView().neonCard()` (default `.standard`) or
    /// `SomeView().neonCard(.elevated)`.
    func neonCard(_ style: NeonCardStyle = .standard) -> some View {
        self
            .padding(16)
            .background(Theme.cyberSurface)
            .overlay(
                RoundedRectangle(cornerRadius: style.cornerRadius)
                    .stroke(style.strokeColor, lineWidth: style.strokeWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius))
            .shadow(
                color: style.shadow.color,
                radius: style.shadow.radius,
                x: 0,
                y: style.shadow.y
            )
    }
}
