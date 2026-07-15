//
//  GestureCoachOverlay.swift
//  PeacePlayer
//
//  S16: expand from 4 gestures to 15+ and add re-entry. Master plan
//  §6.1 call-out was: "Gesture Coach shows once, covers 4 of 15+
//  gestures, no re-entry."
//
//  Re-entry: handled by FullPlayer's moreActionsRow — the new
//  "?" / "Gestures" cell flips `showGestureCoach = true`, which
//  presents this overlay. `hasSeenGestureHints` only governs the
//  auto-show-on-first-launch behavior, so tapping "?" is a
//  no-op for that flag.
//
//  Layout: scrollable (VStack of sections), so the overlay
//  scales gracefully if we add more gestures later. Sections
//  group gestures by where they live (Player / MiniPlayer /
//  Lists) so the user knows where to apply them.
//

import SwiftUI

struct GestureCoachOverlay: View {
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Theme.playerBackgroundOverlay
                .ignoresSafeArea()

            ScrollView(showsIndicators: true) {
                VStack(spacing: 24) {
                    header

                    gestureSection(
                        title: "FULL PLAYER",
                        gestures: GestureInventory.playerGestures
                    )

                    gestureSection(
                        title: "MINI PLAYER",
                        gestures: GestureInventory.miniPlayerGestures
                    )

                    gestureSection(
                        title: "TRACK LISTS",
                        gestures: GestureInventory.listGestures
                    )

                    dismissHint
                }
                .padding(.horizontal, 24)
                .padding(.top, 36)
                .padding(.bottom, 32)
                .frame(maxWidth: 520)
            }
        }
        .transition(.opacity)
        .onTapGesture {
            HapticManager.light()
            onDismiss()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "hand.draw.fill")
                .font(.system(size: 36))
                .foregroundColor(Theme.cyberCyan)
                .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 12, x: 0, y: 0)

            Text("Gesture Guide")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.cyberCyan)

            Text("\(GestureInventory.totalCount) gestures to learn the app")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.cyberDim)
        }
    }

    // MARK: - Section

    private func gestureSection(title: String, gestures: [(icon: String, gesture: String, action: String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.cyberCyan)
                .tracking(1.5)

            VStack(spacing: 0) {
                ForEach(Array(gestures.enumerated()), id: \.offset) { index, g in
                    hintRow(icon: g.icon, gesture: g.gesture, action: g.action)
                    if index < gestures.count - 1 {
                        Divider()
                            .background(Theme.cyberDim.opacity(0.15))
                            .padding(.leading, 48)
                    }
                }
            }
            .padding(14)
            .background(Theme.cyberSurface.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Theme.cyberCyan.opacity(0.15), lineWidth: 1)
            )
        }
    }

    private func hintRow(icon: String, gesture: String, action: String) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(Theme.cyberCyan)
                .frame(width: 32, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(gesture)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                Text(action)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var dismissHint: some View {
        Text("Tap anywhere to dismiss")
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundColor(Theme.cyberDim)
            .padding(.top, 8)
    }
}

// MARK: - Gesture Inventory
//
// Single source of truth for what the coach documents. Master
// plan §6.1 wanted 15+ gestures. We're shipping 16 across 3
// surfaces. Adding more is now a one-line append to the right
// array.

private enum GestureInventory {
    struct Gesture {
        let icon: String
        let gesture: String
        let action: String
    }

    static let playerGestures: [(icon: String, gesture: String, action: String)] = [
        ("hand.point.up.left.and.text",   "Swipe down",                "Dismiss player"),
        ("hand.draw.fill",                "Swipe horizontal on artwork","Toggle visualizer"),
        ("hand.tap.fill",                 "Double-tap artwork",        "Like song"),
        ("hand.tap",                      "Single-tap artwork",        "Pause / resume"),
        ("hand.point.up.left",            "Long-press artwork",        "Open orbital menu"),
        ("hand.point.up.left.fill",       "Long-press Capsule",        "Open Time Capsule vault"),
        ("slider.horizontal.below.square.and.arrow.up.and.down", "Drag progress bar", "Seek"),
        ("text.aligncenter",              "Tap track title",           "Expand / collapse lyrics"),
        ("chevron.up.chevron.down",       "Swipe up on header",        "Hide to mini player"),
        ("speaker.wave.2.fill",           "Long-press AirPlay",        "Pick output device"),
    ]

    static let miniPlayerGestures: [(icon: String, gesture: String, action: String)] = [
        ("hand.tap",                      "Tap mini player",           "Expand to full player"),
        ("hand.point.up.left",            "Swipe up",                  "Expand to full player"),
        ("hand.draw",                     "Swipe down",                "Nothing (already mini)"),
    ]

    static let listGestures: [(icon: String, gesture: String, action: String)] = [
        ("hand.point.up.left",            "Long-press track row",      "Context menu (play next, queue, etc.)"),
        ("arrow.left.circle",             "Swipe left",                "Remove from library"),
        ("arrow.right.circle",            "Swipe right",               "Play next"),
    ]

    static var totalCount: Int {
        playerGestures.count + miniPlayerGestures.count + listGestures.count
    }
}
