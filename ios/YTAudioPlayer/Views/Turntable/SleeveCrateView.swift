//
//  SleeveCrateView.swift
//  Views/Turntable
//
//  The record crate. Each sleeve is an album cover standing in a
//  felt-lined wooden crate; tapping one plays it.
//
//  The crate is THREE ROWS deep — a single row read as a shelf, not
//  as a crate. Every row stands on its own rail, the way records sit
//  on the slats of a real bin, and the rows live in one vertical
//  scroll so the deck stays one screen tall: you see three rows at a
//  time and flip down through the rest, the way you would work
//  through a bin of records.
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
        ScrollView(.vertical, showsIndicators: false) {
            CrateShelf(
                sleeves: sleeves,
                onPlay: onPlay,
                onQueue: onQueue
            )
            .padding(.vertical, 2)
        }
        .frame(height: CrateGrid.visibleHeight)
    }
}

// MARK: - Crate shelf

/// The rows of sleeves, without the scroll view.
///
/// Split out so the shelf can be rendered on its own — the offscreen
/// renderer does not draw a scroll view's contents.
struct CrateShelf: View {
    let sleeves: [Track]
    var onPlay: (Track) -> Void
    var onQueue: (Track) -> Void

    var body: some View {
        VStack(spacing: CrateGrid.rowSpacing) {
            ForEach(Array(CrateGrid.rows(from: sleeves).enumerated()), id: \.offset) { _, row in
                CrateRow(
                    sleeves: row,
                    onPlay: onPlay,
                    onQueue: onQueue
                )
            }
        }
    }
}

// MARK: - Crate geometry

/// The crate's dimensions and its row layout.
///
/// Split out as pure geometry so the layout can be asserted in a
/// test without rendering anything.
enum CrateGrid {
    /// One sleeve's edge length.
    static let sleeveSize: CGFloat = 56
    /// Gap between sleeves across a row.
    static let spacing: CGFloat = 8
    /// The rail a row stands on.
    static let railHeight: CGFloat = 4
    /// Gap between the rail and the sleeves above it.
    static let railGap: CGFloat = 3
    /// Gap between one row's rail and the next row.
    ///
    /// The rows are bins of records, not a spreadsheet: each rail needs
    /// air under it or the crate reads as one crowded shelf
    /// (revision 2026-11-18).
    static let rowSpacing: CGFloat = 20
    /// How many sleeves fit across the deck.
    static let columnCount: Int = 5
    /// How many rows the crate shows at once.
    static let visibleRows: Int = 3

    /// The height of one row: the sleeves plus their rail.
    static var rowHeight: CGFloat {
        sleeveSize + railGap + railHeight
    }

    /// The height of the crate's window.
    static var visibleHeight: CGFloat {
        CGFloat(visibleRows) * rowHeight + CGFloat(visibleRows - 1) * rowSpacing
    }

    /// Chops the crate's contents into rows of `columnCount`.
    ///
    /// The last row is short when the crate is not full — that is fine,
    /// and the row is centred rather than left-aligned.
    static func rows(from sleeves: [Track]) -> [[Track]] {
        stride(from: 0, to: sleeves.count, by: columnCount).map { start in
            Array(sleeves[start..<min(start + columnCount, sleeves.count)])
        }
    }
}

// MARK: - Crate row

/// One row of sleeves, standing on its own rail.
struct CrateRow: View {
    let sleeves: [Track]
    var onPlay: (Track) -> Void
    var onQueue: (Track) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: CrateGrid.spacing) {
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
                    // Identifier so the UI test can find and tap a
                    // specific sleeve on the device.
                    .accessibilityIdentifier("crate.sleeve.\(track.videoId)")
                }
            }
            // The row is centred, so a short last row sits in the
            // middle of the crate rather than hanging off the left.
            .frame(maxWidth: .infinity, alignment: .center)

            // The rail the row stands on — walnut, catching the key
            // light along its top edge.
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
                .frame(height: CrateGrid.railHeight)
                .overlay(
                    Rectangle()
                        .fill(TurntableTokens.keyLight.opacity(0.18))
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .top)
                )
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(.top, CrateGrid.railGap)
        }
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
    }
}
