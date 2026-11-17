//
//  HapticManager.swift
//  YTAudioPlayer
//
//  Haptic feedback utilities
//

import SwiftUI

enum HapticManager {
    static func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
    
    static func medium() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }
    
    static func heavy() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()
    }
    
    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }
    
    static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
    }

    /// Selection feedback — the "tick" a detent makes when a control
    /// crosses a discrete step (a scrubber passing 10%, a segmented
    /// picker changing index).
    ///
    /// Distinct from `light()` on purpose: `light()` is a generic tap
    /// bump, and the Turntable deck uses it nowhere. The scrubber
    /// detent is the one place in the deck that should feel like a
    /// physical notch clicking past, so it gets its own generator
    /// rather than borrowing the impact styles.
    static func selectionChanged() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }
}
