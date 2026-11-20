//
//  PlaylistPreviewView.swift
//  YTAudioPlayer
//
//  Preview YouTube playlists with clone/play options
//

import SwiftUI
import Combine

struct PlaylistPreviewView: View {
    let playlist: YouTubePlaylist
    @StateObject private var playerState = PlayerState.shared
    @StateObject private var playlistManager = PlaylistManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var details: YouTubePlaylistDetails?
    @State private var isLoading = false
    @State private var error: String?
    @State private var showCloneConfirmation = false
    @State private var clonedPlaylistId: UUID?

    // Deck design system (docs/design/deck-design-system.md §8). Drawn
    // on the Deck when the turntable flag is on; the old drawing stays
    // as `legacyContent` until the flag retires.
    @ObservedObject private var featureFlags = FeatureFlags.shared
    private var deck: Bool { featureFlags.turntableHome }

    private var state: some View {
        Group {
            if isLoading {
                PlaylistLoadingView()
                    .transition(.opacity)
            } else if let error = error {
                PlaylistErrorView(message: error, onRetry: loadDetails)
                    .transition(.opacity)
            } else if let details = details {
                PlaylistContentView(
                    details: details,
                    onPlayAll: { playAll(shuffle: false) },
                    onShuffle: { playAll(shuffle: true) },
                    onClone: { showCloneConfirmation = true }
                )
            } else {
                PlaylistLoadingView()
            }
        }
    }

    /// Deck: a walnut board with the playlist's name and Done over
    /// the same room as everywhere else.
    private var deckContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(playlist.title)
                    .font(DeckType.title)
                    .foregroundColor(TurntableTokens.cream)
                    .lineLimit(1)
                Spacer(minLength: 8)
                DeckButton(title: "Done", kind: .card) { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .deckPlinth(cornerRadius: 0)

            state
        }
        .background(DeckRoom())
        .environment(\.deckStyle, true)
    }

    var body: some View {
        Group {
            if deck { deckContent } else { legacyContent }
        }
        .preferredColorScheme(deck ? .dark : nil)
        .onAppear {
            loadDetails()
        }
        .alert("Clone Playlist?", isPresented: $showCloneConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clone") {
                clonePlaylist()
            }
        } message: {
            Text("This will create a copy of '\(playlist.title)' with \(playlist.videoCount) tracks in your playlists.")
        }
        .sheet(item: Binding<IdentifiablePlaylist?>(
            get: { clonedPlaylistId.map { IdentifiablePlaylist(id: $0) } },
            set: { _ in clonedPlaylistId = nil }
        )) { identifiable in
            if let playlist = playlistManager.playlist(withId: identifiable.id) {
                PlaylistDetailView(playlist: playlist)
            }
        }
    }

    private var legacyContent: some View {
        NavigationStack {
            Group {
                if isLoading {
                    PlaylistLoadingView()
                        .transition(.opacity)
                } else if let error = error {
                    PlaylistErrorView(message: error, onRetry: loadDetails)
                        .transition(.opacity)
                } else if let details = details {
                    PlaylistContentView(
                        details: details,
                        onPlayAll: { playAll(shuffle: false) },
                        onShuffle: { playAll(shuffle: true) },
                        onClone: { showCloneConfirmation = true }
                    )
                } else {
                    PlaylistLoadingView()
                }
            }
            .navigationTitle(playlist.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private struct IdentifiablePlaylist: Identifiable {
        let id: UUID
    }
    
    private func loadDetails() {
        isLoading = true
        error = nil
        
        APIService.shared.getPlaylistDetails(playlistId: playlist.playlistId, limit: 50)
            .handleErrors(with: .shared, retry: loadDetails)
            .sink(receiveCompletion: { completion in
                isLoading = false
                if case .failure = completion {
                    error = "Failed to load playlist"
                }
            }, receiveValue: { details in
                self.details = details
            })
            .store(in: &cancellables)
    }
    
    private func playAll(shuffle: Bool) {
        guard let tracks = details?.tracks, !tracks.isEmpty else { return }
        
        let tracksToPlay = shuffle ? tracks.shuffled() : tracks
        let tracksToFetch = Array(tracksToPlay.prefix(20)) // Limit to 20 for performance
        
        // Show loading state
        isLoading = true
        
        // Process tracks one by one to ensure proper ordering
        var streamInfos: [(track: Track, streamUrl: String)] = []
        let processingQueue = DispatchQueue(label: "com.ytaudio.playlistload", attributes: .concurrent)
        let group = DispatchGroup()
        
        for track in tracksToFetch {
            group.enter()
            
            StreamURLCache.shared.getStreamUrl(videoId: track.videoId)
                .sink(receiveCompletion: { _ in
                    group.leave()
                }, receiveValue: { streamInfo in
                    processingQueue.async(flags: .barrier) {
                        streamInfos.append((track, streamInfo.streamUrl))
                    }
                })
                .store(in: &cancellables)
        }
        
        group.notify(queue: .main) {
            self.isLoading = false
            
            guard !streamInfos.isEmpty else {
                self.error = "Could not load any tracks"
                return
            }
            
            // Sort streamInfos by original track order
            let orderedInfos = tracksToFetch.compactMap { track in
                streamInfos.first { $0.track.videoId == track.videoId }
            }
            
            // Clear existing queue if needed and add new tracks
            // S17-G: queue is a computed property. Use the store.
            if playerState.currentItem == nil {
                playerState.queueStore.clear()
            }
            
            // Add tracks in order
            for info in orderedInfos {
                let item = QueueItem(
                    track: info.track,
                    streamUrl: info.streamUrl,
                    source: .stream
                )
                playerState.addToQueue(item)
            }
            
            // Start playing first track
            if playerState.currentItem == nil && !playerState.queue.isEmpty {
                playerState.playQueue(at: 0)
                playerState.showFullPlayer = true
            }
            
            self.dismiss()
        }
    }
    
    private func clonePlaylist() {
        guard let details = details else { return }
        
        // Save track metadata to TrackStore first
        TrackStore.shared.saveTracks(details.tracks)
        
        // Get the best thumbnail URL
        let thumbnailURL = details.thumbnails.last?.url.absoluteString
        
        let newPlaylist = playlistManager.createPlaylist(
            name: details.title,
            description: "Cloned from YouTube • by \(details.author)",
            thumbnailURL: thumbnailURL
        )
        
        playlistManager.addTracks(details.tracks, to: newPlaylist.id)
        
        HapticManager.success()
        clonedPlaylistId = newPlaylist.id
    }
    
    @State private var cancellables = Set<AnyCancellable>()
}

// MARK: - Playlist Content View

struct PlaylistContentView: View {
    let details: YouTubePlaylistDetails
    let onPlayAll: () -> Void
    let onShuffle: () -> Void
    let onClone: () -> Void
    @StateObject private var playerState = PlayerState.shared
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var selectedTrack: Track?
    @State private var showAddToPlaylist = false
    @State private var cancellables = Set<AnyCancellable>()

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck { deckBody } else { legacyBody }
    }

    /// Deck: the header, Play (the one card) and Shuffle, Clone as a
    /// key, then a "Tracks" ledge with the rows hanging under it.
    private var deckBody: some View {
        List {
            VStack(spacing: 18) {
                PlaylistHeaderView(details: details)

                HStack(spacing: 12) {
                    DeckButton(title: "Play all", symbol: "play.fill", kind: .card, fillsWidth: true, action: onPlayAll)
                    DeckButton(title: "Shuffle", symbol: "shuffle", fillsWidth: true, action: onShuffle)
                }
                DeckButton(title: "Clone to my playlists", symbol: "plus", fillsWidth: true, action: onClone)

                DeckLedge(title: "Tracks", count: details.tracks.count)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, 16)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            ForEach(Array(details.tracks.enumerated()), id: \.element.id) { index, track in
                TrackListRow(
                    index: index + 1,
                    track: track,
                    onPlay: { playTrack(track) },
                    onAddToQueue: { addToQueue(track) },
                    onPlayNext: { playNext(track) },
                    onAddToPlaylist: {
                        selectedTrack = track
                        showAddToPlaylist = true
                    },
                    onDownload: { downloadTrack(track) }
                )
                .padding(.horizontal, 16)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Color.clear
                .frame(height: 40)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .task(id: details.tracks.map(\.videoId)) {
            StreamURLCache.shared.prefetchBatch(videoIds: details.tracks.prefix(5).map(\.videoId))
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = selectedTrack {
                AddToPlaylistSheet(track: track)
            }
        }
    }

    private var legacyBody: some View {
        List {
            // Header
            Section {
                PlaylistHeaderView(details: details)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            
            // Actions
            Section {
                HStack(spacing: 12) {
                    ActionButton(
                        title: "Play All",
                        icon: "play.fill",
                        color: .accentColor,
                        action: onPlayAll
                    )
                    
                    ActionButton(
                        title: "Shuffle",
                        icon: "shuffle",
                        color: .cyberYellow,
                        action: onShuffle
                    )

                    ActionButton(
                        title: "Clone",
                        icon: "plus.square",
                        color: .cyberCyan,
                        action: onClone
                    )
                }
            }
            .listRowBackground(Color.clear)
            
            // Tracks
            Section("Tracks") {
                ForEach(Array(details.tracks.enumerated()), id: \.element.id) { index, track in
                    TrackListRow(
                        index: index + 1,
                        track: track,
                        onPlay: { playTrack(track) },
                        onAddToQueue: { addToQueue(track) },
                        onPlayNext: { playNext(track) },
                        onAddToPlaylist: {
                            selectedTrack = track
                            showAddToPlaylist = true
                        },
                        onDownload: { downloadTrack(track) }
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .task(id: details.tracks.map(\.videoId)) {
            StreamURLCache.shared.prefetchBatch(videoIds: details.tracks.prefix(5).map(\.videoId))
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = selectedTrack {
                AddToPlaylistSheet(track: track)
            }
        }
    }
    
    private func playTrack(_ track: Track) {
        StreamURLCache.shared.getStreamUrl(videoId: track.videoId)
            .handleErrors(with: .shared)
            .sink(receiveValue: { streamInfo in
                let item = QueueItem(
                    track: track,
                    streamUrl: streamInfo.streamUrl,
                    source: .stream
                )
                playerState.play(item: item)
            })
            .store(in: &cancellables)
    }
    
    private func addToQueue(_ track: Track) {
        StreamURLCache.shared.getStreamUrl(videoId: track.videoId)
            .handleErrors(with: .shared)
            .sink(receiveValue: { streamInfo in
                let item = QueueItem(
                    track: track,
                    streamUrl: streamInfo.streamUrl,
                    source: .stream
                )
                playerState.addToQueue(item)
                HapticManager.light()
            })
            .store(in: &cancellables)
    }
    
    private func playNext(_ track: Track) {
        StreamURLCache.shared.getStreamUrl(videoId: track.videoId)
            .handleErrors(with: .shared)
            .sink(receiveValue: { streamInfo in
                let item = QueueItem(
                    track: track,
                    streamUrl: streamInfo.streamUrl,
                    source: .stream
                )
                playerState.addToQueueNext(item)
                HapticManager.light()
            })
            .store(in: &cancellables)
    }
    
    private func downloadTrack(_ track: Track) {
        let task = downloadManager.taskForTrack(track)
        if task != nil && task?.status != .completed {
            downloadManager.cancelDownload(for: track)
        } else if task?.status != .completed {
            downloadManager.download(track)
        }
    }
}

// MARK: - Header View

struct PlaylistHeaderView: View {
    let details: YouTubePlaylistDetails

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck { deckBody } else { legacyBody }
    }

    /// Deck: the sleeve, the name in print, the author and count in
    /// small print.
    private var deckBody: some View {
        VStack(spacing: 14) {
            CachedAsyncImage(url: details.thumbnails.last?.url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                TurntableTokens.walnut
            }
            .frame(width: 180, height: 180)
            .deckCover(cornerRadius: 3)

            VStack(spacing: 6) {
                Text(details.title)
                    .font(DeckType.screenTitle)
                    .foregroundColor(TurntableTokens.cream)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("by \(details.author)")
                    .font(DeckType.subtitle)
                    .foregroundColor(TurntableTokens.cream.opacity(0.55))
                Text(DeckFormat.tracks(details.videoCount).uppercased())
                    .font(DeckType.smallPrint)
                    .foregroundColor(TurntableTokens.brass)
                    .padding(.top, 2)
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var legacyBody: some View {
        VStack(spacing: 16) {
            // Artwork
            ArtworkImage(url: details.thumbnails.last?.url, size: 180)
                .shadow(radius: 10)
            
            // Info
            VStack(spacing: 6) {
                Text(details.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                
                Text("by \(details.author)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Text("\(details.videoCount) tracks")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                Text(title)
                    .font(.caption.bold())
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .background(color)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Track List Row

struct TrackListRow: View {
    let index: Int
    let track: Track
    @StateObject private var downloadManager = DownloadManager.shared
    @StateObject private var playerState = PlayerState.shared
    let onPlay: () -> Void
    let onAddToQueue: () -> Void
    let onPlayNext: () -> Void
    let onAddToPlaylist: () -> Void
    let onDownload: () -> Void
    
    private var isPlaying: Bool {
        playerState.currentItem?.track.videoId == track.videoId
    }
    
    private var downloadTask: DownloadTask? {
        downloadManager.taskForTrack(track)
    }
    
    private var isDownloaded: Bool {
        downloadTask?.status == .completed
    }

    @Environment(\.deckStyle) private var deck

    var body: some View {
        face
            .contentShape(Rectangle())
            .onTapGesture {
                onPlay()
            }
            .contextMenu {
                Button(action: onPlay) {
                    Label(isPlaying ? "Now Playing" : "Play", systemImage: "play.fill")
                }

                Button(action: onPlayNext) {
                    Label("Play Next", systemImage: "text.badge.plus")
                }

                Button(action: onAddToQueue) {
                    Label("Add to Queue", systemImage: "plus")
                }

                Button(action: onAddToPlaylist) {
                    Label("Add to Playlist", systemImage: "music.note.list")
                }

                Divider()

                Button(action: onDownload) {
                    if let task = downloadTask, task.status.isActive {
                        Label("Cancel Download", systemImage: "xmark")
                    } else {
                        Label(isDownloaded ? "Downloaded" : "Download",
                              systemImage: isDownloaded ? "checkmark" : "arrow.down")
                    }
                }
                .disabled(isDownloaded)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(action: onDownload) {
                    Label("Download", systemImage: "arrow.down")
                }
                .tint(deck ? TurntableTokens.aluminium : .cyberCyan)

                Button(action: onAddToQueue) {
                    Label("Queue", systemImage: "plus")
                }
                .tint(deck ? TurntableTokens.brass : .cyberMagenta)
            }
    }

    @ViewBuilder
    private var face: some View {
        if deck { deckFace } else { legacyFace }
    }

    /// Deck: the shared track row. Amber pulsing while it downloads,
    /// a small arrow once it is on the device.
    private var deckFace: some View {
        DeckTrackRow(
            title: track.title,
            subtitle: track.displayArtist,
            artworkURL: track.artworkURL,
            smallPrint: DeckFormat.runtime(track.durationSeconds),
            isPlaying: isPlaying
        ) {
            if downloadTask?.status.isActive ?? false {
                DeckLamp(color: DeckSignal.power, state: .working)
                    .accessibilityLabel("Downloading")
            } else if isDownloaded {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(TurntableTokens.aluminium.opacity(0.7))
                    .accessibilityLabel("Downloaded")
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(TurntableTokens.cream.opacity(0.08)).frame(height: 1)
        }
        .accessibilityAddTraits(.isButton)
    }

    private var legacyFace: some View {
        HStack(spacing: 12) {
            // Index or Artwork
            ZStack(alignment: .center) {
                if isPlaying {
                    CyberPlayingBars()
                        .frame(width: 20, height: 20)
                } else {
                    Text("\(index)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 24, alignment: .center)
                }
            }
            
            // Artwork thumbnail
            ZStack(alignment: .bottomTrailing) {
                ArtworkThumbnail(url: track.artworkURL)
                    .frame(width: 44, height: 44)
                
                // Download badge
                if let task = downloadTask, task.status.isActive {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.7))
                            .frame(width: 16, height: 16)
                        
                        CircularProgressView(progress: task.progress)
                            .frame(width: 12, height: 12)
                    }
                    .offset(x: 2, y: 2)
                } else if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.cyberCyan)
                        .background(Circle().fill(Color.white))
                        .offset(x: 2, y: 2)
                }
            }
            
            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 15, weight: isPlaying ? .bold : .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundColor(isPlaying ? .accentColor : .primary)
                
                Text(track.displayArtist)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            
            Spacer()
            
            // Duration and play button
            HStack(spacing: 8) {
                Text(track.durationText)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "waveform" : "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(isPlaying ? .cyberCyan : .cyberDim)
                }
            }
        }
        .padding(.vertical, 6)
        .background(isPlaying ? Color.accentColor.opacity(0.05) : Color.clear)
    }
}

// MARK: - Loading View

struct PlaylistLoadingView: View {
    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck {
            VStack(spacing: 14) {
                DeckLamp(color: DeckSignal.power, state: .working, size: 8)
                Text("Loading playlist")
                    .font(DeckType.engraved)
                    .tracking(DeckType.engravedTracking)
                    .foregroundColor(TurntableTokens.cream.opacity(0.55))
                    .textCase(.uppercase)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading playlist...")
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Error View

struct PlaylistErrorView: View {
    let message: String
    let onRetry: () -> Void

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck {
            VStack(spacing: 18) {
                DeckLamp(color: DeckSignal.attention, state: .lit, size: 8)
                Text(message)
                    .font(DeckType.subtitle)
                    .foregroundColor(TurntableTokens.cream.opacity(0.7))
                    .multilineTextAlignment(.center)
                DeckButton(title: "Try again", symbol: "arrow.clockwise", kind: .card, action: onRetry)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.cyberYellow)

            Text(message)
                .multilineTextAlignment(.center)
            
            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}



// MARK: - Preview

struct PlaylistPreviewView_Previews: PreviewProvider {
    static var previews: some View {
        PlaylistPreviewView(
            playlist: YouTubePlaylist(
                playlistId: "test",
                title: "Summer Vibes 2024",
                author: "Music Channel",
                videoCount: 42,
                thumbnails: [],
                description: "Best summer hits"
            )
        )
    }
}
