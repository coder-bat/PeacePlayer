//
//  WidgetTheme.swift
//  PeacePlayerWidget
//
//  S18 / v1.6.6: thin wrapper around the shared cyber color tokens.
//
//  Before v1.6.6, this file was a parallel definition of the
//  cyberpunk color palette that drifted from Theme.swift in the
//  main app (CV-6 — "WidgetTheme is a 4-color fork of the
//  30-token Theme"). Every brand tweak had to be applied in
//  two places.
//
//  Now all the actual color values live in
//  Sources/SharedCyberColors.swift, which is part of both
//  targets. This file just aliases the shared tokens under
//  the historical WidgetTheme.* names so all call sites keep
//  compiling.
//
//  Adding new widget-only tokens? Add them to
//  SharedCyberColors.swift and alias here.
//

import SwiftUI

enum WidgetTheme {
    // MARK: Cyberpunk Brand Colors (aliased to SharedCyberColors)
    static let cyberBackground = Color.cyberBackground
    static let cyberSurface = Color.cyberSurface
    static let cyberCyan = Color.cyberCyan
    static let cyberMagenta = Color.cyberMagenta
    static let cyberYellow = Color.cyberYellow
    static let cyberDim = Color.cyberDim
    /// Historical alias — pre-v1.6.6 some code referenced
    /// `WidgetTheme.cyberBg`. Kept as an alias so old call sites
    /// don't break.
    static let cyberBg = Color.cyberBackground

    // MARK: Widget-Safe Text Colors
    // These used to be raw `Color.white.opacity(...)` values
    // defined in this file. Now they're aliased to the shared
    // tokens so a re-tune of the design system happens once.
    static let inverseText = Color.widgetInverseText
    static let dimText = Color.widgetDimText
    static let subtleText = Color.widgetSubtleText
    static let strongText = Color.widgetStrongText
    static let shadowOverlay = Color.widgetShadowOverlay

    // MARK: Widget Surface Tints
    static let subtleSurface = Color.widgetSubtleSurface
    static let faintSurface = Color.widgetFaintSurface
    static let softSurface = Color.widgetSoftSurface

    // MARK: Inactive / Disabled Tints
    static let inactiveTint = Color.widgetInactiveTint

    // MARK: Vinyl / Decorative Highlight Tints
    static let highlightStrong = Color.widgetHighlightStrong
    static let highlightSoft = Color.widgetHighlightSoft
}
