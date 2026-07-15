//
//  NeonTextField.swift
//  PeacePlayer
//
//  S15: reusable "neon text field" style. The audit identified
//  4+ files that independently re-implemented the same
//  dark-background + neon-stroke + neon-focus-glow text field
//  (CreatePlaylistSheet, AddToPlaylistSheet, SettingsView's
//  Server Host, AvatarPickerSheet).
//
//  `NeonTextFieldStyle` is the single source of truth. Wraps
//  the system `TextField` with the standard cyberpunk
//  look:
//   - dark background
//   - 1pt stroke
//   - cyan focus ring
//   - placeholder tint matches cyberDim
//
//  Use as `.neonTextFieldStyle()` on a `TextField`.
//

import SwiftUI

struct NeonTextFieldStyle: TextFieldStyle {
    var focused: Bool = false

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.cyberSurface)
            .foregroundColor(.white)
            .tint(Theme.cyberCyan)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        focused ? Theme.cyberCyan : Theme.cyberDim.opacity(0.3),
                        lineWidth: focused ? 1.5 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .font(.system(size: 15))
    }
}

extension TextFieldStyle where Self == NeonTextFieldStyle {
    /// Apply the canonical neon text field look.
    static var neon: NeonTextFieldStyle { NeonTextFieldStyle() }
}
