import SwiftUI

// Widget theme - values should match Theme.swift for visual consistency
// Widget extensions are separate targets and cannot import Theme.swift directly
enum WidgetTheme {
    // Match Theme.swift - Cyberpunk Colors
    static let cyberCyan = Color(red: 0, green: 0.9, blue: 1)
    static let cyberMagenta = Color(red: 1, green: 0, blue: 0.6)
    static let cyberBg = Color.black  // Matches Theme.cyberBackground
    static let cyberSurface = Color(red: 0.08, green: 0.08, blue: 0.12)  // Matches Theme.cyberSurface
}