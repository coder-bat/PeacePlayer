//
//  SharedCyberColors.swift
//  PeacePlayer
//
//  S18 / v1.6.6: CV-6 + CV-7 — shared cyber color palette.
//
//  This file is the SINGLE source of truth for the app's color
//  tokens. Both the main app target (which uses `Theme.cyberCyan`,
//  `Theme.cyberBackground`, etc.) and the widget extension
//  (which uses `WidgetTheme.cyberCyan`, `WidgetTheme.cyberBackground`,
//  etc.) reference this file. The two enums in each target are
//  now thin wrappers — they just alias the shared tokens below.
//
//  Why a shared file instead of two parallel enums?
//  The previous design (CV-6) had two parallel color definitions:
//  one in Theme.swift, one in WidgetTheme.swift. Every brand tweak
//  had to be applied in two places, and the audit's "WidgetTheme
//  is a 4-color fork of the 30-token Theme" was the natural
//  consequence — they drifted. With this file, the colors live
//  in ONE place; the wrappers in each target just expose them
//  under their existing names so all call sites keep compiling.
//
//  Adding the file to both targets happens via project.yml:
//
//      PeacePlayerWidget:
//        sources:
//          - path: PeacePlayerWidget
//          - path: Sources/SharedNowPlayingState.swift
//          - path: Sources/SharedCyberColors.swift   # NEW
//
//  After `xcodegen --spec ios/project.yml`, the file is
//  registered in both targets' Sources build phases. The
//  pbxproj is auto-regenerated; no hand-edits needed.
//
//  The text-color tokens (inverseText, dimText, etc.) used to
//  live in WidgetTheme as raw `Color.white.opacity(...)` values.
//  They're now here too, so the next re-tune of the design system
//  happens in exactly one place.
//

import SwiftUI

// MARK: - Cyberpunk Brand Colors
// AA-passing values verified in S18 (P0-3). Don't tune these
// without re-checking the WCAG contrast ratios in
// analysis/01-ui-consistency.md.

extension Color {
    /// Pure black surface for the app's chrome. Background of
    /// the Now Playing bar, mini player, and widget bodies.
    static let cyberBackground = Color(red: 0, green: 0, blue: 0)

    /// Off-black raised surface (0.08 / 0.08 / 0.12). Used for
    /// cards, sheets, and any element that needs to sit "above"
    /// the background without becoming too bright.
    static let cyberSurface = Color(red: 0.08, green: 0.08, blue: 0.12)

    /// Primary accent — bright cyan. Used for selected state,
    /// active progress, link/affordance text, and any "do this"
    /// call to action. Stands out at 100% on the dark surface.
    static let cyberCyan = Color(red: 0, green: 0.9, blue: 1)

    /// Secondary accent — magenta. Used for liked/active state
    /// and to break up cyan-only sections. Pairs with cyan for
    /// gradient overlays.
    static let cyberMagenta = Color(red: 1, green: 0, blue: 0.6)

    /// Tertiary accent — yellow. Used for warnings, "queued /
    /// future" state, and any "this needs your attention" signal.
    static let cyberYellow = Color(red: 1, green: 0.8, blue: 0)

    /// Dim secondary text. 4.52:1 on cyberBackground (AA for body).
    /// For dim labels / hint text where the text is still
    /// readable but should not compete with primary content.
    static let cyberDim = Color(red: 0.45, green: 0.45, blue: 0.55)

    /// S18 (P0-3): AA-passing dim for body/caption text. cyberDim
    /// itself is 4.52:1, but `cyberDim.opacity(0.X)` in the
    /// codebase drops to 2.32:1-3.66:1 (AA fail for body text).
    /// This token is the safe replacement: 8.28:1 (AAA) at full
    /// opacity. Use this for any foregroundColor on body /
    /// caption / hint text.
    static let cyberTextSecondary = Color(red: 0.62, green: 0.62, blue: 0.72)
}

// MARK: - Widget-Safe Text Colors
// These existed in WidgetTheme before this commit but were raw
// `Color.white.opacity(...)` values. They now reference the
// shared definitions above so any future re-tune applies to
// both the main app and the widgets simultaneously.

extension Color {
    /// Pure white. Use for primary text on the dark background
    /// (track title, large featured content, button labels).
    static let widgetInverseText = Color.white

    /// 55% white. Use for secondary text (artist, album,
    /// timestamp). AA-passing for body text on the dark surface.
    static let widgetDimText = Color.white.opacity(0.55)

    /// 35% white. Use for tertiary / hint text (footer
    /// captions, "tap to play" hints). AA-fail for body — use
    /// for non-essential text only.
    static let widgetSubtleText = Color.white.opacity(0.35)

    /// 85% white. Use for primary text where you want it slightly
    /// softer than pure white (e.g. an unselected but emphasized
    /// label). Falls back to inverseText in the main app.
    static let widgetStrongText = Color.white.opacity(0.85)

    /// 50% black. Standard shadow / scrim overlay for sheets,
    /// pickers, and the Now Playing card on the home screen.
    static let widgetShadowOverlay = Color.black.opacity(0.5)
}

// MARK: - Widget Surface Tints
// Subtle white wash for inactive surfaces and slightly more
// visible fills for separators / hover. Naming: opacity is
// embedded in the name so a quick scan of the call site tells
// you what you're getting.

extension Color {
    /// 10% white. Inactive button / chip fill.
    static let widgetSubtleSurface = Color.white.opacity(0.1)

    /// 6% white. Faintest visible fill — pressed state on a
    /// subtle surface, or a barely-there background highlight.
    static let widgetFaintSurface = Color.white.opacity(0.06)

    /// 15% white. Slightly more visible than subtleSurface — used
    /// for separators that need to read as a thin line, not a
    /// wash.
    static let widgetSoftSurface = Color.white.opacity(0.15)
}

// MARK: - Inactive / Disabled Tints
// Used for "this thing is off" affordances — a play icon in
// paused state, a disabled toggle, etc. Distinct from the
// subtleText token (which is for text); these are for the
// icon / shape itself when the state is inactive.

extension Color {
    /// Stock `.gray`. The standard "this control is off" tint.
    /// Lives here so any re-tune of the design system (e.g.
    /// switching to a dimmer brand-neutral gray) happens once.
    static let widgetInactiveTint = Color.gray
}

// MARK: - Vinyl / Decorative Highlight Tints
// Pure white at varying opacities. Used by the vinyl record
// rendering and any other decorative effect (edge bevels, groove
// rings, subtle sparkles) where the visual is a translucent
// highlight rather than text. Text should use the text tokens
// (inverseText / dimText / subtleText), not these.

extension Color {
    /// 28% white. Strong edge highlight — used for the top
    /// edge of the vinyl record's bevel.
    static let widgetHighlightStrong = Color.white.opacity(0.28)

    /// 5% white. Soft edge highlight — used for the bottom edge
    /// of the vinyl record's bevel.
    static let widgetHighlightSoft = Color.white.opacity(0.05)
}
