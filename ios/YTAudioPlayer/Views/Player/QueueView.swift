//
//  QueueView.swift
//  YTAudioPlayer
//
//  Playback queue management
//

import SwiftUI

struct QueueView: View {
    @StateObject private var playerState = PlayerState.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                // Now Playing Section
                Section(header: Text("Now Playing")) {
                    if let currentItem = playerState.currentItem {
                        QueueItemRow(
                            item: currentItem,
                            isPlaying: true
                        )
                    }
                }

                // Up Next Section
                let upcoming: [QueueItem] = {
                    if playerState.currentIndex < playerState.queue.count - 1 {
                        return Array(playerState.queue[(playerState.currentIndex + 1)...])
                    } else {
                        return []
                    }
                }()

                Section(header:
                    HStack {
                        Text("Up Next")
                        Spacer()
                        if playerState.isShuffled {
                            Label("Shuffled", systemImage: "shuffle")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                    }
                ) {
                    if upcoming.isEmpty {
                        Text("No more songs in queue")
                            .foregroundColor(.secondary)
                            .font(.footnote)
                    } else {
                        ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, item in
                            QueueItemRow(
                                item: item,
                                isPlaying: false,
                                onTap: {
                                    let actualIndex = playerState.currentIndex + 1 + index
                                    HapticManager.medium()
                                    playerState.playQueue(at: actualIndex)
                                }
                            )
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    let actualIndex = playerState.currentIndex + 1 + index
                                    playerState.removeFromQueue(at: actualIndex)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let actualIndex = playerState.currentIndex + 1 + index
                                playerState.removeFromQueue(at: actualIndex)
                            }
                        }
                        .onMove { indexSet, destination in
                            let sourceIndices = Array(indexSet).map { playerState.currentIndex + 1 + $0 }
                            let destIndex = playerState.currentIndex + 1 + destination
                            if destIndex <= playerState.queue.count {
                                playerState.moveQueueItem(from: IndexSet(sourceIndices), to: destIndex)
                                HapticManager.light()
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        HapticManager.light()
                        playerState.clearQueue()
                    }) {
                        Text("Clear")
                            .foregroundColor(.red)
                    }
                    .disabled(playerState.queue.isEmpty)
                }
            }
        }
    }
}

// MARK: - Queue Item Row
struct QueueItemRow: View {
    let item: QueueItem
    let isPlaying: Bool
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let artworkURL = item.track.artworkURL {
                    CachedAsyncImage(url: artworkURL) {
                        placeholderView
                    }
                } else {
                    placeholderView
                }
            }
            .frame(width: 50, height: 50)
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.track.title)
                    .font(.system(size: 16, weight: isPlaying ? .semibold : .regular))
                    .lineLimit(1)

                Text(item.track.displayArtist)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isPlaying {
                PlayingIndicator()
                    .frame(width: 20, height: 20)
            }
        }
        .padding(.vertical, 4)
        .background(isPlaying ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if let onTap = onTap {
                onTap()
            }
        }
    }

    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.gray.opacity(0.2))
            .overlay(
                Image(systemName: "music.note")
                    .foregroundColor(.gray)
            )
    }
}

// MARK: - Playing Indicator
struct PlayingIndicator: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: animate ? 16 : 4)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .onAppear {
            animate = true
        }
    }
}

// MARK: - Preview
struct QueueView_Previews: PreviewProvider {
    static var previews: some View {
        QueueView()
    }
}
