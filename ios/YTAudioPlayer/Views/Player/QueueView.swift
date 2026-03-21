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
            ZStack {
                Theme.cyberBackground.ignoresSafeArea()

                List {
                    // Now Playing Section
                    Section(header:
                        Text("NOW PLAYING")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyberDim)
                    ) {
                        if let currentItem = playerState.currentItem {
                            QueueItemRow(item: currentItem, isPlaying: true)
                                .listRowBackground(Color.cyberSurface)
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
                            Text("UP NEXT")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyberDim)
                            Spacer()
                            if playerState.isShuffled {
                                Label("Shuffled", systemImage: "shuffle")
                                    .font(.caption)
                                    .foregroundColor(.cyberCyan)
                            }
                        }
                    ) {
                        if upcoming.isEmpty {
                            Text("Queue is empty")
                                .foregroundColor(.cyberDim)
                                .font(.system(size: 14, design: .monospaced))
                                .listRowBackground(Color.cyberSurface)
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
                                .listRowBackground(Color.cyberSurface)
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
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: playerState.queue.count)
                .onAppear {
                    UITableView.appearance().backgroundColor = .clear
                }
                .onDisappear {
                    UITableView.appearance().backgroundColor = .systemGroupedBackground
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.cyberCyan)
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
                    .foregroundColor(isPlaying ? .cyberCyan : .white)
                    .lineLimit(1)

                Text(item.track.displayArtist)
                    .font(.system(size: 14))
                    .foregroundColor(.cyberDim)
                    .lineLimit(1)
            }

            Spacer()

            if isPlaying {
                CyberPlayingBars()
                    .frame(width: 20, height: 20)
            }
        }
        .padding(.vertical, 4)
        .background(isPlaying ? Color.cyberCyan.opacity(0.08) : Color.clear)
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
            .fill(Color.cyberDim.opacity(0.3))
            .overlay(
                Image(systemName: "music.note")
                    .foregroundColor(.cyberDim)
            )
    }
}


// MARK: - Preview
struct QueueView_Previews: PreviewProvider {
    static var previews: some View {
        QueueView()
    }
}
