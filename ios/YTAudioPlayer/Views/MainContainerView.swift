//
//  MainContainerView.swift
//  YTAudioPlayer
//
//  Main container with custom icon-only tab bar and mini player.
//
//  2026-06-28: this file is no longer the active container —
//  ContentView.swift owns the TabView + CyberpunkTabBar (the
//  real one used by the running app). Kept here for legacy
//  references and to avoid breaking the project; the body's
//  drawn tab bar is a no-op so it never overlays the real one.
//

import SwiftUI

struct MainContainerView: View {
    @StateObject private var playerState = PlayerState.shared
    @State private var selectedTab: Int = 0
    @State private var showFullPlayer: Bool = false

    var body: some View {
        // Legacy entry point — ContentView is the real entry. Render
        // a transparent placeholder so any code path that still uses
        // MainContainerView doesn't crash.
        Color.clear
    }
}

struct MainContainerView_Previews: PreviewProvider {
    static var previews: some View {
        MainContainerView()
    }
}
