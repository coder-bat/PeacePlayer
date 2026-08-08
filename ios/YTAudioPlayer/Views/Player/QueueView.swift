//
//  QueueView.swift
//  YTAudioPlayer
//
//  Playback queue management
//

import SwiftUI

struct QueueView: View {
    @StateObject private var playerState = PlayerState.shared
    // S17-G (perf 10 P0-F1): observe the queue store directly.
    // PlayerState no longer fires objectWillChange on queue
    // mutations, so the only way for QueueView to see queue
    // changes is to subscribe to the store. We use the underscored
    // wrapper initializer because @ObservedObject doesn't allow
    // default-value initialization from a singleton property.
    @ObservedObject private var queueStore: QueueStore
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirmation = false

    init() {
        // Subscribe to the store that lives on PlayerState.
        // The store is a `let` on PlayerState; the lifetime is
        // tied to the singleton.
        self._queueStore = ObservedObject(initialValue: PlayerState.shared.queueStore)
    }

    var body: some View {
        NavigationStack {
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
                    // S17-G: read from the queue store directly so
                    // the List animates with the queue. The store
                    // owns the items + currentIndex; we just slice
                    // the upcoming portion.
                    let upcoming: [QueueItem] = {
                        let q = queueStore.items
                        let idx = queueStore.currentIndex
                        if idx < q.count - 1 {
                            return Array(q[(idx + 1)...])
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
                            VStack(spacing: 16) {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 40))
                                    .foregroundColor(.cyberDim.opacity(0.5))
                                Text("Queue is empty")
                                    .foregroundColor(.cyberDim)
                                    .font(.system(size: 14, design: .monospaced))
                                Text("Play a track or browse your library to get started")
                                    .foregroundColor(Theme.cyberTextSecondary)
                                    .font(.system(size: 12, design: .monospaced))
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
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
                                .contextMenu {
                                    Button {
                                        ShareHelper.shareTrack(
                                            title: item.track.title,
                                            artist: item.track.displayArtist,
                                            videoId: item.track.videoId
                                        )
                                    } label: {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }

                                    Button {
                                        ShareHelper.copyTrackInfo(
                                            title: item.track.title,
                                            artist: item.track.displayArtist
                                        )
                                    } label: {
                                        Label("Copy Info", systemImage: "doc.on.doc")
                                    }

                                    Button {
                                        Task {
                                            if let card = await ShareCardGenerator.generateCard(for: item.track) {
                                                let activityVC = UIActivityViewController(activityItems: [card], applicationActivities: nil)
                                                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                                                   let rootVC = windowScene.windows.first?.rootViewController {
                                                    if let popover = activityVC.popoverPresentationController {
                                                        popover.sourceView = rootVC.view
                                                        popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
                                                        popover.permittedArrowDirections = []
                                                    }
                                                    rootVC.present(activityVC, animated: true)
                                                }
                                            }
                                        }
                                    } label: {
                                        Label("Share Card", systemImage: "rectangle.on.rectangle")
                                    }

                                    Button {
                                        NotificationCenter.default.post(name: .startSongRadio, object: item.track)
                                        HapticManager.light()
                                    } label: {
                                        Label("Start Radio", systemImage: "antenna.radiowaves.left.and.right")
                                    }

                                    Divider()

                                    Button(role: .destructive) {
                                        let actualIndex = playerState.currentIndex + 1 + index
                                        playerState.removeFromQueue(at: actualIndex)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        HapticManager.light()
                                        let actualIndex = playerState.currentIndex + 1 + index
                                        playerState.removeFromQueue(at: actualIndex)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                            .onDelete { indexSet in
                                for index in indexSet {
                                    HapticManager.light()
                                    let actualIndex = playerState.currentIndex + 1 + index
                                    playerState.removeFromQueue(at: actualIndex)
                                }
                            }
                            .onMove { indexSet, destination in
                                // S17-G: index the move against the
                                // store's queue, not the computed
                                // `playerState.queue` (which is the
                                // same value, but using the store
                                // keeps the access pattern consistent
                                // for the next maintainer).
                                let sourceIndices = Array(indexSet).map { queueStore.currentIndex + 1 + $0 }
                                let destIndex = queueStore.currentIndex + 1 + destination
                                if destIndex <= queueStore.items.count {
                                    playerState.moveQueueItem(from: IndexSet(sourceIndices), to: destIndex)
                                    HapticManager.light()
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: queueStore.items.count)
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
                        showClearConfirmation = true
                    }) {
                        Text("Clear")
                            .foregroundColor(.red)
                    }
                    .disabled(queueStore.items.isEmpty)
                }
            }
            .alert("Clear Queue?", isPresented: $showClearConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear All", role: .destructive) {
                    HapticManager.heavy()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        playerState.clearQueue()
                    }
                }
            } message: {
                Text("This will remove all upcoming tracks from the queue.")
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
        // S15: delegate to the unified TrackRow. Previously
        // QueueItemRow had its own 50pt artwork + 2-line text
        // + CyberPlayingBars accessory implementation, with
        // `Color.cyberCyan.opacity(0.08)` highlight that disagreed
        // with History/Library/RecentlyPlayed on the exact tint
        // and the title weight. Now all four row implementations
        // share TrackRow's `Theme.cyberCyan` highlight.
        TrackRow(
            title: item.track.title,
            subtitle: item.track.displayArtist,
            artworkURL: item.track.artworkURL,
            isPlaying: isPlaying,
            accessory: isPlaying ? .playingBars : .none,
            onTap: onTap
        )
    }
}


// MARK: - Preview
struct QueueView_Previews: PreviewProvider {
    static var previews: some View {
        QueueView()
    }
}
