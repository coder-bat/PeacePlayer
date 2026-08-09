//
//  LikedSongsView.swift
//  PeacePlayer
//
//  S18 / v1.6.1
//
//  The Liked Songs tab. Shown when the user taps the heart icon
//  in the bottom bar (CyberpunkTabBar's tag-2 entry). Wraps the
//  Liked Songs smart playlist's PlaylistDetailView in a custom
//  header so the tab feels consistent with the other pushed
//  destinations (Radio, Anti-Algorithm) — same monospaced title
//  font, same back-chevron / icon rhythm — while still being
//  presented as a tab in the TabView.
//
//  The previous v1.6.0 design presented this as a sheet at the
//  app root (via .openLikedSongs notification). The user
//  preferred a real tab so the bottom-bar navigation is uniform:
//  Home / Liked / Library all behave the same way.
//

import SwiftUI

struct LikedSongsView: View {
    @StateObject private var playlistManager = PlaylistManager.shared

    var body: some View {
        // Same chrome as the other destination screens: a
        // NavigationStack wrapping the custom header + the
        // playlist detail. The NavigationStack here exists so
        // tapping a track or the playlist's context menu can
        // push a sub-screen (PlaylistDetailView's existing
        // behavior) — not because the Liked Songs view itself
        // is pushed onto a parent stack.
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.cyberBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    customHeader

                    if let liked = playlistManager.playlists
                        .first(where: { $0.isLikedSongsPlaylist }) {
                        PlaylistDetailView(playlist: liked)
                    } else {
                        // Fallback if the smart playlist hasn't
                        // seeded yet. Should be rare — see the
                        // matching fallback in the previous sheet
                        // presentation, same reasoning applies.
                        LikedSongsEmptyState()
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // S18 / v1.6.1: matches the AntiAlgorithmScreen + RadioView
    // headers — 22-24pt monospaced title, dim subtitle, no system
    // nav bar. The heart icon in the bottom bar provides
    // navigation back to other tabs.
    private var customHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LIKED SONGS")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text("tracks you've tapped the heart on")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - Empty state fallback

/// Shown only if the Liked Songs smart playlist hasn't been
/// seeded yet (rare). Reused from the previous v1.6.0 sheet
/// implementation — defined inline to keep the file self-contained.
private struct LikedSongsEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.slash")
                .font(.system(size: 32, weight: .regular))
                .foregroundColor(Theme.cyberDim)
            Text("Liked Songs")
                .font(.title3.bold())
                .foregroundColor(.white)
            Text("Tap the heart on any track to add it here.")
                .font(.footnote)
                .foregroundColor(Theme.cyberTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
