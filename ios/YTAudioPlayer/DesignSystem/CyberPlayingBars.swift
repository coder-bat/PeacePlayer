//
//  CyberPlayingBars.swift
//  YTAudioPlayer
//
//  Cyberpunk-styled "now playing" indicator: three cyan bars that
//  pulse in a staggered loop. Use this for any row / cell that
//  represents a track currently playing (Library, Search, Home,
//  Playlist Detail, etc).
//
//  S18 / P1-15: consolidated from two parallel components
//  (CyberPlayingBars in MiniPlayer.swift + PlayingBarsIndicator
//  in HomeView.swift). Both rendered nearly identical 3-bar
//  animations with slightly different bar-height ranges (4-16
//  vs 6-16). The 4-16 range is the canonical one. This component
//  is the single source of truth.
//

import SwiftUI

struct CyberPlayingBars: View {
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.cyberCyan)
                    .frame(width: 3, height: animate ? 16 : 4)
                    .animation(
                        reduceMotion ? .none : Animation.easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .onAppear {
            if !reduceMotion {
                animate = true
            }
        }
        // S15 + S18 / a11y: hide from VoiceOver. The bars are
        // decorative; the row's track title already conveys "this
        // is the currently playing track".
        .accessibilityHidden(true)
    }
}
