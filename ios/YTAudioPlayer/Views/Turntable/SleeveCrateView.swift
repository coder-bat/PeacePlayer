//
//  SleeveCrateView.swift
//  YTAudioPlayer
//
//  The record crate. Each sleeve is an album cover standing in a
//  felt-lined wooden crate; tapping one plays it.
//
//  This replaces the "FOR YOU" favorite-artist list from the old
//  Home. The crate is horizontal and scrollable, so the deck stays
//  one screen tall.
//

import SwiftUI

struct SleeveCrateView: View {
    let sleeves: [Track]
    var onPlay: (Track) -> Void
    var onQueue: (Track) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CRATE")
                .font(Typography.eyebrow)
                .foregroundColor(TurntableTokens.aluminium.opacity(0.7))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(sleeves) { track in
                        Button {
                            onPlay(track)
                        } label: {
                            SleeveView(track: track)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                onQueue(track)
                            } label: {
                                Label("Add to queue", systemImage: "text.badge.plus")
                            }
                        }
                        .accessibilityLabel("\(track.title) by \(track.artists.first ?? "unknown artist")")
                        .accessibilityHint("Double tap to play")
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }

            // The crate's front rail — walnut, catching the key light.
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            TurntableTokens.walnut.opacity(0.95),
                            TurntableTokens.walnut.opacity(0.55)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 7)
                .overlay(
                    Rectangle()
                        .fill(TurntableTokens.keyLight.opacity(0.18))
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .top)
                )
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}

// MARK: - Sleeve

private struct SleeveView: View {
    let track: Track

    var body: some View {
        ZStack {
            // The felt-lined interior behind the sleeve.
            Rectangle()
                .fill(TurntableTokens.felt.opacity(0.55))

            CachedAsyncImage(url: track.artworkURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    LinearGradient(
                        colors: [TurntableTokens.aluminium.opacity(0.25), TurntableTokens.walnut.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .light))
                        .foregroundColor(TurntableTokens.aluminium.opacity(0.6))
                }
            }
        }
        .frame(width: 62, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // The sleeve's card stock edge.
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(TurntableTokens.cream.opacity(0.22), lineWidth: 1)
        )
        // Sleeves sit in the crate, so they cast a shadow downward.
        .shadow(color: .black.opacity(0.55), radius: 5, y: 3)
    }
}
