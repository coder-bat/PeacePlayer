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
    // 2026-11-21: the queue sheet on the Deck design system
    // (docs/design/deck-design-system.md): Deck drawing with the
    // Turntable Home flag on, the old drawing with it off.
    @ObservedObject private var featureFlags = FeatureFlags.shared
    private var deck: Bool { featureFlags.turntableHome }

    init() {
        // Subscribe to the store that lives on PlayerState.
        // The store is a `let` on PlayerState; the lifetime is
        // tied to the singleton.
        self._queueStore = ObservedObject(initialValue: PlayerState.shared.queueStore)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if deck {
                    DeckRoom()
                } else {
                    Theme.cyberBackground.ignoresSafeArea()
                }

                List {
                    // Now Playing Section
                    Section(header: nowPlayingHeader) {
                        if let currentItem = playerState.currentItem {
                            QueueItemRow(item: currentItem, isPlaying: true)
                                .listRowBackground(deck ? Color.clear : Color.cyberSurface)
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

                    Section(header: upNextHeader(count: upcoming.count)) {
                        if upcoming.isEmpty {
                            Group {
                            if deck {
                                VStack(spacing: 6) {
                                    Text("Nothing up next")
                                        .font(DeckType.title)
                                        .foregroundColor(TurntableTokens.cream)
                                    Text("Play something, or press Dig on the deck.")
                                        .font(DeckType.subtitle)
                                        .foregroundColor(TurntableTokens.cream.opacity(0.55))
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 30)
                                .listRowSeparator(.hidden)
                            } else {
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
                            }
                            }
                            .listRowBackground(deck ? Color.clear : Color.cyberSurface)
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
                                .listRowBackground(deck ? Color.clear : Color.cyberSurface)
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
                .modifier(QueueListStyle(deck: deck))
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
            // Deck: the sheet's own header replaces the system bar.
            .toolbar(deck ? .hidden : .visible, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if deck { deckHeader }
            }
            .environment(\.deckStyle, deck)
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

    // MARK: - Deck parts

    /// Deck: the sheet's head is the edge of a walnut board — the
    /// name in print, Clear and Done as keys.
    private var deckHeader: some View {
        HStack(spacing: 10) {
            Text("Queue")
                .font(DeckType.screenTitle)
                .foregroundColor(TurntableTokens.cream)
            if playerState.isShuffled {
                HStack(spacing: 5) {
                    DeckLamp(color: DeckSignal.power, state: .lit, size: 4.5)
                    Text("SHUFFLED")
                        .font(DeckType.engraved)
                        .tracking(DeckType.engravedTracking)
                        .foregroundColor(TurntableTokens.cream.opacity(0.6))
                }
                .padding(.leading, 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Shuffled")
            }
            Spacer(minLength: 8)
            DeckButton(title: "Clear") {
                HapticManager.light()
                showClearConfirmation = true
            }
            .disabled(queueStore.items.isEmpty)
            .opacity(queueStore.items.isEmpty ? 0.4 : 1)
            DeckButton(title: "Done", kind: .card) {
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .deckPlinth(cornerRadius: 0)
    }

    @ViewBuilder
    private var nowPlayingHeader: some View {
        if deck {
            DeckLedge(title: "Now playing")
                .padding(.top, 10)
                .padding(.bottom, 4)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        } else {
            Text("NOW PLAYING")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.cyberDim)
        }
    }

    @ViewBuilder
    private func upNextHeader(count: Int) -> some View {
        if deck {
            DeckLedge(title: "Up next", count: count)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        } else {
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
        }
    }
}

/// The queue's list: plain rows on the wall (Deck) or the system's
/// grouped cards (legacy).
private struct QueueListStyle: ViewModifier {
    let deck: Bool

    func body(content: Content) -> some View {
        if deck {
            content
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .listRowSeparatorTint(TurntableTokens.cream.opacity(0.08))
        } else {
            content.listStyle(.insetGrouped)
        }
    }
}

struct QueueItemRow: View {
    let item: QueueItem
    let isPlaying: Bool
    var onTap: (() -> Void)? = nil
    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck {
            DeckTrackRow(
                title: item.track.title,
                subtitle: item.track.displayArtist,
                artworkURL: item.track.artworkURL,
                smallPrint: DeckFormat.runtime(item.track.durationSeconds),
                isPlaying: isPlaying
            )
            .onTapGesture { onTap?() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isPlaying ? "Now playing" : "")
        } else {
            legacyRow
        }
    }

    private var legacyRow: some View {
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
