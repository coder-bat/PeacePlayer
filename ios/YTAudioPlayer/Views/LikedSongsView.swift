//
//  LikedSongsView.swift
//  PeacePlayer
//
//  v1.6.8 (CV-13): Liked Songs is no longer its own tab —
//  it lives as a featured card at the top of Library. The
//  content of the Liked Songs screen (custom header +
//  PlaylistDetailView) is extracted into `LikedSongsContent`
//  so LibraryView can push it onto its own NavigationStack
//  without a nested NavigationStack. `LikedSongsView` is
//  kept as a thin wrapper that hosts the content in its own
//  stack — used as a fallback if a future surface needs to
//  present Liked Songs standalone (e.g. a search-result
//  jump-to).
//
//  History:
//  S18 / v1.6.1 — Liked Songs became a real tab (was a
//  sheet at the app root).
//  v1.6.8 — Liked Songs merged into Library.
//

import SwiftUI

struct LikedSongsContent: View {
    @StateObject private var playlistManager = PlaylistManager.shared

    var body: some View {
        ZStack(alignment: .top) {
            Theme.cyberBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                customHeader

                if let liked = playlistManager.playlists
                    .first(where: { $0.isLikedSongsPlaylist }) {
                    // v1.6.2: hide the chevron.down dismiss
                    // button. The PlaylistDetailView's sticky
                    // nav bar includes a dismiss chevron by
                    // default for its sheet use case; in the
                    // Liked Songs flow (now pushed from
                    // Library) there's no parent sheet to
                    // dismiss, and the user navigates back
                    // via the back button in Library's
                    // NavigationStack.
                    PlaylistDetailView(
                        playlist: liked,
                        showsDismissButton: false
                    )
                } else {
                    LikedSongsEmptyState()
                }
            }
        }
    }

    // S18 / v1.6.1: matches the AntiAlgorithmScreen + RadioView
    // headers — 22-24pt monospaced title, dim subtitle, no
    // system nav bar (the parent NavigationStack supplies the
    // back button when Liked Songs is pushed from Library).
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

struct LikedSongsView: View {
    var body: some View {
        NavigationStack {
            LikedSongsContent()
                .toolbar(.hidden, for: .navigationBar)
        }
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
