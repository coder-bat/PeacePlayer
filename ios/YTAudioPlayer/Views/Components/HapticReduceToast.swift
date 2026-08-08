//
//  HapticReduceToast.swift
//  YTAudioPlayer
//
//  S18 (P0-2): Non-blocking toast shown when the user taps the
//  Haptic Symphony cell while the "Reduce Haptics" preference is
//  on (or the system Reduce Motion setting is on). Points the
//  user to Settings → Accessibility → Reduce Haptics.
//
//  Auto-dismisses after 3s (the parent handles the timer via
//  .task). Cyberpunk-styled to match the rest of the app.
//

import SwiftUI

struct HapticReduceToast: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.slash.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Theme.cyberYellow)

            VStack(alignment: .leading, spacing: 2) {
                Text("Reduce Haptics is on")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text("Enable Haptic Symphony in Settings → Accessibility")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(Theme.cyberSurface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .stroke(Theme.cyberYellow.opacity(0.5), lineWidth: 1)
                )
                .shadow(color: Theme.cyberYellow.opacity(0.2), radius: 12, x: 0, y: 4)
        )
        .padding(.horizontal, 24)
        // VoiceOver: combine children into a single announcement
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reduce Haptics is on. Enable Haptic Symphony in Settings, Accessibility.")
    }
}
