import SwiftUI

// Widget theme - values should match Theme.swift for visual consistency.
// S15: widget extensions are separate targets and cannot import
// Theme.swift directly. The previous fork only had 4 tokens
// (cyberCyan/Magenta/Bg/Surface) and 30+ raw `Color.white` /
// `Color.black` calls littered the widget files because the
// text-color tokens (inverseText, dimText) didn't exist. Now we
// expose the full palette the widgets need (cyberYellow, cyberDim,
// inverseText, dimText, subtleText, strongText, shadowOverlay).
// Drift risk: any future re-tune in Theme.swift must be mirrored
// here. Track this with a unit test (see WidgetThemeDriftTests
// when added) — or, better, lift the palette into a shared file
// in both targets' Sources in a follow-up.
enum WidgetTheme {
    // Match Theme.swift - Cyberpunk Colors
    static let cyberCyan = Color(red: 0, green: 0.9, blue: 1)
    static let cyberMagenta = Color(red: 1, green: 0, blue: 0.6)
    static let cyberYellow = Color(red: 1, green: 0.8, blue: 0)
    static let cyberDim = Color(red: 0.45, green: 0.45, blue: 0.55)
    static let cyberBg = Color.black  // Matches Theme.cyberBackground
    static let cyberSurface = Color(red: 0.08, green: 0.08, blue: 0.12)  // Matches Theme.cyberSurface

    // Text colors — used to replace the 30+ `Color.white` / `Color.black`
    // raw calls that lived in widget files because the previous
    // WidgetTheme didn't define them.
    static let inverseText = Color.white
    static let dimText = Color.white.opacity(0.55)
    static let subtleText = Color.white.opacity(0.35)
    static let strongText = Color.white.opacity(0.85)
    static let shadowOverlay = Color.black.opacity(0.5)

    // Background tints — subtle white wash for inactive surfaces
    // and slightly more visible fills for separators / hover.
    static let subtleSurface = Color.white.opacity(0.1)
    static let faintSurface = Color.white.opacity(0.06)
    static let softSurface = Color.white.opacity(0.15)
}