//
//  SleeveCrateView.swift
//  Views/Turntable
//
//  The record crate. Each sleeve is an album cover standing in a
//  felt-lined wooden crate; tapping one plays it.
//
//  The crate is THREE ROWS deep — a single row read as a shelf, not
//  as a crate. The rows live in one vertical scroll so the deck stays
//  one screen tall: you see three rows at a time and flip down
//  through the rest, the way you would work through a bin of
//  records.
//
//  This replaces the "FOR YOU" favorite-artist list from the old
//  Home.
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

            ScrollView(.vertical, showsIndicators: false) {
                CrateGrid(
                    sleeves: sleeves,
                    onPlay: onPlay,
                    onQueue: onQueue
                )
                .padding(.vertical, 2)
            }
            .frame(height: CrateGrid.visibleHeight)

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

// MARK: - Crate grid

/// The sleeves themselves, laid out in a centred grid.
///
/// The grid is deliberately NOT inside a scroll view here — the
/// scroll view lives in `SleeveCrateView` so the crate can be
/// rendered on its own in a snapshot test.
struct CrateGrid: View {
    let sleeves: [Track]
    var onPlay: (Track) -> Void
    var onQueue: (Track) -> Void

    /// One sleeve's edge length.
    static let sleeveSize: CGFloat = 64
    /// Gap between sleeves, both across and down.
    static let spacing: CGFloat = 8
    /// How many rows the crate shows at once.
    static let visibleRows: Int = 3
    /// How many sleeves fit across the deck.
    static let columnCount: Int = 5

    /// The height of the crate's window.
    static var visibleHeight: CGFloat {
        CGFloat(visibleRows) * sleeveSize + CGFloat(visibleRows - 1) * spacing
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .center),
            count: Self.columnCount
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Self.spacing) {
            ForEach(sleeves) { track in
                Button {
                    HapticManager.medium()
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
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sleeve

struct SleeveView: View {
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
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(TurntableTokens.aluminium.opacity(0.6))
                }
            }
        }
        .frame(width: CrateGrid.sleeveSize, height: CrateGrid.sleeveSize)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // The sleeve's card stock edge.
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(TurntableTokens.cream.opacity(0.22), lineWidth: 1)
        )
        // Sleeves sit in the crate, so they cast a shadow downward.
        .shadow(color: .black.opacity(0.55), radius: 5, y: 3)
        // Centre each sleeve inside its grid cell.
        .frame(maxWidth: .infinity)
    }
}
