//
//  Theme.swift
//  YTAudioPlayer
//
//  Design system - Colors, Typography, Spacing
//
//  S18 / v1.6.6: the cyberpunk color definitions now live in
//  SharedCyberColors.swift (in Sources/) so the widget extension
//  can reference the same values. This file's `Theme` enum is
//  now a thin wrapper that aliases the shared colors — any
//  re-tune of the design system happens in exactly one place
//  and the main app + widgets stay in sync automatically.
//

import SwiftUI

// MARK: - Colors
enum Theme {
    // MARK: Cyberpunk Colors (Global Access)
    // Aliased to SharedCyberColors so widgets pick up the same
    // values. If you need to change a cyberpunk color, edit
    // SharedCyberColors.swift — both this enum and WidgetTheme
    // will reflect the change.
    static let cyberBackground = Color.cyberBackground
    static let cyberSurface = Color.cyberSurface
    static let cyberCyan = Color.cyberCyan
    static let cyberMagenta = Color.cyberMagenta
    static let cyberYellow = Color.cyberYellow
    static let cyberDim = Color.cyberDim

    // S18 (P0-3): AA-passing dim color for body/caption text on black.
    // cyberDim itself is 4.52:1, but `cyberDim.opacity(0.X)` in the
    // codebase drops to 2.32:1-3.66:1 (AA fail for body text). This
    // token is the safe replacement: 8.28:1 (AAA) at full opacity.
    // Use this for any foregroundColor on body / caption / hint text.
    static let cyberTextSecondary = Color.cyberTextSecondary

    // MARK: Widget-Safe Text Colors (aliased)
    // Was previously defined inline here as `Color.white`,
    // `Color.white.opacity(0.55)`, etc. Now aliased to the
    // shared tokens so the values match what the widgets use.
    //
    // `inverseText` is already declared in the MARK: Text Colors
    // block above (kept there for call-site compat — 200+ uses
    // in the main app reference `Theme.inverseText`). The new
    // tokens below are additions for the widget surface tints
    // and dim/subtle text variants.
    static let dimText = Color.widgetDimText
    static let subtleText = Color.widgetSubtleText
    static let strongText = Color.widgetStrongText
    static let shadowOverlay = Color.widgetShadowOverlay

    // MARK: Widget Surface Tints (aliased)
    static let subtleSurface = Color.widgetSubtleSurface
    static let faintSurface = Color.widgetFaintSurface
    static let softSurface = Color.widgetSoftSurface

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
// S13: Semantic system fonts that scale with the user's Dynamic Type preference.
// Custom fonts (Sora / Hanken Grotesk / JetBrains Mono) are deferred — when
// font files are added to the bundle and registered in Info.plist via
// `UIAppFonts`, a `registerFonts()` method can be wired here without
// changing any call site (tokens are the indirection point).
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

    // MARK: Sectioning (S15 — uses TextStyle so it scales with Dynamic Type)
    /// Section heading inside a content area (e.g. "Recently Played", "Quick Vibes").
    /// Was 13pt monospaced bold; now `.footnote` text style keeps the
    /// 13pt baseline but scales with the user's Dynamic Type setting.
    static let sectionHeader = Font.system(.footnote, design: .monospaced, weight: .bold)
    /// Large featured section title (e.g. "FOR YOU").
    /// Was 22pt bold; `.title2` is 22pt at the default text size.
    static let sectionTitle = Font.system(.title2, design: .default, weight: .bold)
    /// Small uppercase eyebrow tag (e.g. track-row sublabel).
    /// Was 11pt monospaced bold; `.caption2` is 11pt at the default.
    static let eyebrow = Font.system(.caption2, design: .monospaced, weight: .bold)

    // MARK: Player Specific (S15 — same Dynamic Type scale-up)
    /// Was 22pt bold; `.title2` matches the 22pt baseline and scales.
    static let playerTitle = Font.system(.title2, design: .default, weight: .bold)
    /// Was 16pt medium; `.callout` is 16pt at the default.
    static let playerArtist = Font.system(.callout, design: .default, weight: .medium)
    /// Was 12pt monospaced medium; `.caption` is 12pt at the default.
    static let playerTime = Font.system(.caption, design: .monospaced, weight: .medium)
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
