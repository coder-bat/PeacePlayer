//
//  QueueStackView.swift
//  YTAudioPlayer
//
//  The queue, drawn as a stack of records resting on the deck.
//  Each disc is one queued track; the coloured centre is the
//  track's content source.
//

import SwiftUI

struct QueueStackView: View {
    let queue: [QueueItem]
    let currentIndex: Int
    var onSelect: (Int) -> Void

    /// Only the next few are drawn — a stack of 40 records is noise.
    private var visible: ArraySlice<QueueItem> {
        queue.prefix(4)
    }

    var body: some View {
        Group {
            if !visible.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        Button {
                            onSelect(index)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(
                                        RadialGradient(
                                            colors: [
                                                Color(white: 0.13),
                                                TurntableTokens.vinyl
                                            ],
                                            center: .center,
                                            startRadius: 2,
                                            endRadius: 24
                                        )
                                    )
                                    .overlay(
                                        Circle()
                                            .strokeBorder(
                                                index == currentIndex
                                                    ? Theme.cyberCyan.opacity(0.8)
                                                    : .white.opacity(0.08),
                                                lineWidth: index == currentIndex ? 2 : 1
                                            )
                                    )

                                Circle()
                                    .fill(item.contentSource.tintColor)
                                    .frame(width: 11, height: 11)
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.track.title)
                        .accessibilityValue(index == currentIndex ? "Now playing" : "In queue")
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: queue.count)
    }
}
