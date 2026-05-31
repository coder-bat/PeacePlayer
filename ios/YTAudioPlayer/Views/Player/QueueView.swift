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
    @State private var showClearConfirmation = false

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
                            VStack(spacing: 16) {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 40))
                                    .foregroundColor(.cyberDim.opacity(0.5))
                                Text("Queue is empty")
                                    .foregroundColor(.cyberDim)
                                    .font(.system(size: 14, design: .monospaced))
                                Text("Play a track or browse your library to get started")
                                    .foregroundColor(.cyberDim.opacity(0.6))
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
                                .swipeActions(edge: .trailing) {
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
                        showClearConfirmation = true
                    }) {
                        Text("Clear")
                            .foregroundColor(.red)
                    }
                    .disabled(playerState.queue.isEmpty)
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
                    .minimumScaleFactor(0.8)

                Text(item.track.displayArtist)
                    .font(.system(size: 14))
                    .foregroundColor(.cyberDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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
