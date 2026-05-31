//
//  Theme.swift
//  YTAudioPlayer
//
//  Design system - Colors, Typography, Spacing
//

import SwiftUI

// MARK: - Cyberpunk Colors
extension Color {
    static let cyberBackground = Color.black
    static let cyberSurface = Color(red: 0.08, green: 0.08, blue: 0.12)
    static let cyberCyan = Color(red: 0, green: 0.9, blue: 1)
    static let cyberMagenta = Color(red: 1, green: 0, blue: 0.6)
    static let cyberYellow = Color(red: 1, green: 0.8, blue: 0)
    static let cyberDim = Color(red: 0.45, green: 0.45, blue: 0.55)
}

// MARK: - Colors
enum Theme {
    // MARK: Cyberpunk Colors (Global Access)
    static let cyberBackground = Color.cyberBackground
    static let cyberSurface = Color.cyberSurface
    static let cyberCyan = Color.cyberCyan
    static let cyberMagenta = Color.cyberMagenta
    static let cyberYellow = Color.cyberYellow
    static let cyberDim = Color.cyberDim

    // MARK: Background Colors
    static let background = Color(.systemBackground)
    static let secondaryBackground = Color(.secondarySystemBackground)
    static let groupedBackground = Color(.systemGroupedBackground)
    static let secondaryGroupedBackground = Color(.secondarySystemGroupedBackground)
    
    // MARK: Brand Colors
    static let primary = Color.accentColor
    static let primaryLight = Color.accentColor.opacity(0.8)
    static let primaryDark = Color.accentColor.opacity(1.0)
    
    // MARK: Semantic Colors
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    static let info = Color.blue
    
    // MARK: Text Colors
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.gray
    static let inverseText = Color.white
    
    // MARK: Player Colors
    static let playerBackground = Color.black.opacity(0.9)
    static let playerControls = Color.white
    static let progressTrack = Color.white.opacity(0.3)
    static let progressFill = Color.white

    // MARK: Player Text Colors (Semantic aliases for player context)
    static let playerTitleText = Color.white
    static let playerSubtitleText = Color.white.opacity(0.8)
    static let playerBackgroundOverlay = Color.black.opacity(0.5)
    
    // MARK: UI Element Colors
    static let divider = Color.gray.opacity(0.2)
    static let overlay = Color.black.opacity(0.5)
    static let shadow = Color.black.opacity(0.15)
}

// MARK: - Typography
// Uses semantic system fonts so all text scales with the user's Dynamic Type preference.
enum Typography {
    // MARK: Large Titles
    static let largeTitle: Font = .largeTitle
    static let title1: Font = .title
    static let title2: Font = .title2
    static let title3: Font = .title3

    // MARK: Headlines
    static let headline: Font = .headline
    static let subheadline: Font = .subheadline

    // MARK: Body
    static let body: Font = .body
    static let bodyBold: Font = .body.bold()
    static let callout: Font = .callout

    // MARK: Small
    static let footnote: Font = .footnote
    static let caption1: Font = .caption
    static let caption2: Font = .caption2

    // MARK: Player Specific (fixed sizes — controlled visual context)
    static let playerTitle = Font.system(size: 22, weight: .bold, design: .default)
    static let playerArtist = Font.system(size: 16, weight: .medium, design: .default)
    static let playerTime = Font.system(size: 12, weight: .medium, design: .monospaced)
}

// MARK: - Spacing
enum Spacing {
    static let xxxs: CGFloat = 2
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    static let xxxl: CGFloat = 64
}

// MARK: - Corner Radius
enum CornerRadius {
    static let none: CGFloat = 0
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let smd: CGFloat = 10
    static let md: CGFloat = 12
    static let mdd: CGFloat = 14
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let round: CGFloat = 9999
}

// MARK: - Icon Sizes
enum IconSize {
    static let xs: CGFloat = 12
    static let sm: CGFloat = 16
    static let md: CGFloat = 20
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 44
    static let xxxl: CGFloat = 56
}

// MARK: - Mood Category
struct MoodCategory: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let color: Color
}

// MARK: - Shadows
enum ShadowStyle {
    static let sm = Shadow(color: Theme.shadow, radius: 2, x: 0, y: 1)
    static let md = Shadow(color: Theme.shadow, radius: 4, x: 0, y: 2)
    static let lg = Shadow(color: Theme.shadow, radius: 8, x: 0, y: 4)
    static let xl = Shadow(color: Theme.shadow, radius: 16, x: 0, y: 8)
    
    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }
}

// MARK: - Opacity Levels
enum OpacityLevel {
    static let faint: Double = 0.1
    static let subtle: Double = 0.15
    static let light: Double = 0.3
    static let medium: Double = 0.5
    static let strong: Double = 0.7
    static let heavy: Double = 0.85
    static let full: Double = 1.0
}

// MARK: - Animation Durations
enum AnimationDuration {
    static let fast: Double = 0.1
    static let normal: Double = 0.2
    static let slow: Double = 0.3
    static let verySlow: Double = 0.4
    static let shimmer: Double = 1.5
}
