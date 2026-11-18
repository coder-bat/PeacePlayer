//
//  QueueStackView.swift
//  YTAudioPlayer
//
//  The queue, drawn as a shelf of records resting on the deck.
//
//  Each item is a miniature PICTURE DISC: the track's album art
//  printed across a small black vinyl, with the spindle hole in the
//  middle and a chrome rim. The current track's disc is ringed in
//  cyan and lifts slightly, so the deck shows at a glance what is
//  coming next and what is playing.
//
//

import SwiftUI

struct QueueStackView: View {
    let queue: [QueueItem]
    let currentIndex: Int
    var onSelect: (Int) -> Void

    /// How many discs the shelf holds. A queue of 40 is noise, so the
    /// shelf shows the next few — but it is a scrolling shelf now, not
    /// a fixed row of four.
    private var visible: [QueueItem] {
        Array(queue.prefix(12))
    }

    var body: some View {
        Group {
            if !visible.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    QueueDiscRow(
                        items: visible,
                        currentIndex: currentIndex,
                        onSelect: onSelect
                    )
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: queue.count)
    }
}

// MARK: - Queue row

/// The discs themselves, without the scroll view.
///
/// Split out so the shelf can be rendered on its own — the offscreen
/// renderer does not draw a scroll view's contents.
struct QueueDiscRow: View {
    let items: [QueueItem]
    let currentIndex: Int
    var onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    HapticManager.selectionChanged()
                    onSelect(index)
                } label: {
                    QueueDisc(
                        item: item,
                        isCurrent: index == currentIndex,
                        isPlaying: index == currentIndex
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.track.title)
                .accessibilityValue(index == currentIndex ? "Now playing" : "In queue")
            }
        }
    }
}

// MARK: - Queue disc

/// One queued track, drawn as a small picture disc.
private struct QueueDisc: View {
    let item: QueueItem
    let isCurrent: Bool
    let isPlaying: Bool

    /// The disc's diameter. The artwork disc inside it is a touch
    /// smaller so a ring of vinyl shows, the way a real record's
    /// art stops short of the edge.
    static let diameter: CGFloat = 46

    var body: some View {
        ZStack {
            // Vinyl body.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(white: 0.13),
                            TurntableTokens.vinyl
                        ],
                        center: .center,
                        startRadius: 2,
                        endRadius: Self.diameter / 2
                    )
                )

            // The album art, printed across the disc.
            artwork

            // Spindle hole.
            Circle()
                .fill(.black.opacity(0.9))
                .frame(width: 7, height: 7)

            // Chrome rim + the current track's cyan ring.
            Circle()
                .strokeBorder(
                    isCurrent
                        ? Theme.cyberCyan.opacity(0.9)
                        : TurntableTokens.aluminium.opacity(0.22),
                    lineWidth: isCurrent ? 2 : 1
                )
                .shadow(color: isCurrent ? Theme.cyberCyan.opacity(0.55) : .clear, radius: 5)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .scaleEffect(isCurrent ? 1.06 : 1)
        .shadow(color: .black.opacity(isCurrent ? 0.7 : 0.45), radius: isCurrent ? 7 : 4, y: 3)
        .contentShape(Circle())
    }

    private var artwork: some View {
        Group {
            if let url = item.track.artworkURL {
                CachedAsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle().fill(TurntableTokens.vinyl)
                }
            } else {
                // No artwork: the source colour still identifies the
                // track, as a blank record label does.
                Circle()
                    .fill(item.contentSource.tintColor.opacity(0.85))
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        // A hairline that reads as the groove edge.
        .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}
