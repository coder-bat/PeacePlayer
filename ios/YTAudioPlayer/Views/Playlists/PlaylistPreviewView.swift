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
    
    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    PlaylistLoadingView()
                } else if let error = error {
                    PlaylistErrorView(message: error, onRetry: loadDetails)
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
            
            APIService.shared.getStreamUrl(videoId: track.videoId)
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
            if playerState.currentItem == nil {
                playerState.queue.removeAll()
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
    
    var body: some View {
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
                        color: .orange,
                        action: onShuffle
                    )
                    
                    ActionButton(
                        title: "Clone",
                        icon: "plus.square",
                        color: .green,
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
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = selectedTrack {
                AddToPlaylistSheet(track: track)
            }
        }
    }
    
    private func playTrack(_ track: Track) {
        APIService.shared.getStreamUrl(videoId: track.videoId)
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
        APIService.shared.getStreamUrl(videoId: track.videoId)
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
        APIService.shared.getStreamUrl(videoId: track.videoId)
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
    
    var body: some View {
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
    
    var body: some View {
        HStack(spacing: 12) {
            // Index or Artwork
            ZStack(alignment: .center) {
                if isPlaying {
                    PlayingBars()
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
                        .foregroundColor(.green)
                        .background(Circle().fill(Color.white))
                        .offset(x: 2, y: 2)
                }
            }
            
            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 15, weight: isPlaying ? .bold : .semibold))
                    .lineLimit(1)
                    .foregroundColor(isPlaying ? .accentColor : .primary)
                
                Text(track.displayArtist)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
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
                        .foregroundColor(isPlaying ? .accentColor : .accentColor)
                }
            }
        }
        .padding(.vertical, 6)
        .background(isPlaying ? Color.accentColor.opacity(0.05) : Color.clear)
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
            .tint(.green)
            
            Button(action: onAddToQueue) {
                Label("Queue", systemImage: "plus")
            }
            .tint(.blue)
        }
    }
}

// MARK: - Loading View

struct PlaylistLoadingView: View {
    var body: some View {
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
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.orange)
            
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
