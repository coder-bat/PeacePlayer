//
//  PlaylistDetailView.swift
//  YTAudioPlayer
//
//  Reimagined playlist detail with Apple Music-style hero header and card tracks
//

import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist
    @StateObject private var playlistManager = PlaylistManager.shared
    @StateObject private var playerState = PlayerState.shared
    @StateObject private var trackStore = TrackStore.shared
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var isEditing = false
    @State private var showDeleteConfirmation = false
    @State private var showRenameSheet = false
    @State private var newName = ""
    @State private var missingTrackIds: [String] = []
    @State private var showAddToPlaylistSheet = false
    @State private var trackToAdd: Track?
    @State private var scrollOffset: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    private var currentPlaylist: Playlist? {
        playlistManager.playlist(withId: playlist.id)
    }

    private var isSpecialPlaylist: Bool {
        guard let playlist = currentPlaylist else { return false }
        return playlist.isLikedSongsPlaylist || playlist.smartCriteria?.type == .downloaded
    }

    private var tracks: [Track] {
        guard let playlist = currentPlaylist else { return [] }

        var resolvedTracks: [Track] = []
        var missing: [String] = []

        for videoId in playlist.trackIds {
            if let track = trackStore.getTrack(videoId: videoId) {
                resolvedTracks.append(track)
            } else {
                missing.append(videoId)
                resolvedTracks.append(Track(
                    videoId: videoId,
                    title: "Loading...",
                    artists: ["Unknown Artist"],
                    album: "Unknown Album",
                    durationSeconds: 0,
                    thumbnails: [],
                    isExplicit: false,
                    videoType: "MUSIC"
                ))
            }
        }

        DispatchQueue.main.async {
            self.missingTrackIds = missing
        }

        return resolvedTracks
    }

    private var headerOpacity: Double {
        let fadeStart: CGFloat = 0
        let fadeEnd: CGFloat = 150
        let opacity = 1 - Double((scrollOffset - fadeStart) / (fadeEnd - fadeStart))
        return max(0, min(1, opacity))
    }

    private var navTitleOpacity: Double {
        let fadeStart: CGFloat = 100
        let fadeEnd: CGFloat = 200
        let opacity = Double((scrollOffset - fadeStart) / (fadeEnd - fadeStart))
        return max(0, min(1, opacity))
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                // Cyberpunk background
                Theme.cyberBackground
                    .ignoresSafeArea()

                // Background glow that fades with scroll
                PlaylistBackgroundGlow(playlist: currentPlaylist ?? playlist, scrollOffset: scrollOffset)
                    .ignoresSafeArea()

                // Main content
                ScrollView(showsIndicators: false) {
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: ScrollOffsetPreferenceKey.self, value: proxy.frame(in: .named("scroll")).minY)
                    }
                    .frame(height: 0)

                    VStack(spacing: 0) {
                        // Hero Header
                        HeroPlaylistHeaderCyberpunk(
                            playlist: currentPlaylist ?? playlist,
                            trackCount: tracks.count,
                            scrollOffset: scrollOffset,
                            onPlay: { playPlaylist(shuffle: false) },
                            onShuffle: { playPlaylist(shuffle: true) }
                        )
                        .padding(.top, 20)

                        // Tracks Section
                        VStack(spacing: 0) {
                            if tracks.isEmpty {
                                EmptyPlaylistCyberpunk()
                            } else {
                                // Track list header
                                HStack {
                                    Text("TRACKS")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .foregroundColor(Theme.cyberCyan)

                                    Spacer()

                                    if !isSpecialPlaylist && !(currentPlaylist?.isSmart ?? true) {
                                        Button(isEditing ? "DONE" : "EDIT") {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                isEditing.toggle()
                                            }
                                        }
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundColor(Theme.cyberCyan)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.top, 24)
                                .padding(.bottom, 12)

                                // Track rows - each as individual card with spacing
                                LazyVStack(spacing: 8) {
                                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                        CyberpunkTrackRow(
                                            track: track,
                                            index: index + 1,
                                            isPlaying: playerState.currentItem?.track.videoId == track.videoId,
                                            isEditing: isEditing,
                                            downloadTask: downloadManager.taskForTrack(track),
                                            isDownloaded: downloadManager.taskForTrack(track)?.status == .completed,
                                            onPlay: { playTrack(track) },
                                            onDownload: {
                                                if let task = downloadManager.taskForTrack(track), task.status.isActive {
                                                    downloadManager.cancelDownload(for: track)
                                                } else if downloadManager.taskForTrack(track)?.status != .completed {
                                                    downloadManager.download(track)
                                                }
                                            },
                                            onAddToQueue: { addTrackToQueue(track) },
                                            onPlayNext: { playTrackNext(track) },
                                            onAddToPlaylist: {
                                                trackToAdd = track
                                                showAddToPlaylistSheet = true
                                            },
                                            onDelete: { deleteTrack(track) }
                                        )
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                        .background(
                            Theme.cyberBackground
                                .opacity(Double(min(1, max(0, (scrollOffset - 100) / 100))))
                        )

                        // Bottom padding for mini player
                        Color.clear
                            .frame(height: 100)
                    }
                }
                .coordinateSpace(name: "scroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                    scrollOffset = -value
                }

                // Sticky Navigation Bar
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 36, height: 36)
                                .background(Theme.cyberSurface)
                                .overlay(
                                    Circle()
                                        .stroke(Theme.cyberCyan.opacity(0.3), lineWidth: 1)
                                )
                                .clipShape(Circle())
                        }

                        Spacer()

                        Text((currentPlaylist?.name ?? playlist.name).uppercased())
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .opacity(navTitleOpacity)

                        Spacer()

                        if !isSpecialPlaylist {
                            Menu {
                                if !(currentPlaylist?.isSmart ?? true) {
                                    Button {
                                        isEditing.toggle()
                                    } label: {
                                        Label(isEditing ? "Done" : "Edit", systemImage: isEditing ? "checkmark" : "pencil")
                                    }

                                    Button {
                                        newName = currentPlaylist?.name ?? ""
                                        showRenameSheet = true
                                    } label: {
                                        Label("Rename", systemImage: "text.cursor")
                                    }
                                }

                                Button {
                                    // Share
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }

                                if !(currentPlaylist?.isSmart ?? true) {
                                    Divider()

                                    Button(role: .destructive) {
                                        showDeleteConfirmation = true
                                    } label: {
                                        Label("Delete Playlist", systemImage: "trash")
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Theme.cyberSurface)
                                    .overlay(
                                        Circle()
                                            .stroke(Theme.cyberCyan.opacity(0.3), lineWidth: 1)
                                    )
                                    .clipShape(Circle())
                            }
                        } else {
                            Color.clear
                                .frame(width: 36, height: 36)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                    Divider()
                        .background(Theme.cyberCyan.opacity(0.2))
                        .opacity(navTitleOpacity)
                }
                .background(
                    Theme.cyberBackground
                        .opacity(navTitleOpacity)
                        .ignoresSafeArea(edges: .top)
                )
            }
        }
        .preferredColorScheme(.dark)
        .alert("Delete Playlist?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                playlistManager.deletePlaylist(id: playlist.id)
                dismiss()
            }
        } message: {
            Text("This will delete the playlist '\(currentPlaylist?.name ?? "" )'. This action cannot be undone.")
        }
        .sheet(isPresented: $showRenameSheet) {
            RenamePlaylistSheet(
                currentName: currentPlaylist?.name ?? "",
                onRename: { newName in
                    playlistManager.renamePlaylist(id: playlist.id, newName: newName)
                }
            )
        }
        .sheet(isPresented: $showAddToPlaylistSheet) {
            if let track = trackToAdd {
                AddToPlaylistSheet(track: track)
            }
        }
    }

    private func playPlaylist(shuffle: Bool) {
        playlistManager.playPlaylist(playlist.id, shuffle: shuffle)
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
            .store(in: &playlistManager.cancellables)
    }

    private func addTrackToQueue(_ track: Track) {
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
            .store(in: &playlistManager.cancellables)
    }

    private func playTrackNext(_ track: Track) {
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
            .store(in: &playlistManager.cancellables)
    }

    private func deleteTrack(_ track: Track) {
        guard let playlist = currentPlaylist else { return }
        playlistManager.removeTrack(track.videoId, from: playlist.id)
    }
}

// MARK: - Scroll Offset Preference Key

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Background Glow

struct PlaylistBackgroundGlow: View {
    let playlist: Playlist
    let scrollOffset: CGFloat

    private var accentColor: Color {
        if let hex = playlist.smartCriteria?.type.color {
            return Color(hex: hex) ?? Theme.cyberCyan
        }
        return Theme.cyberCyan
    }

    private var opacity: Double {
        max(0, min(1, 1 - (scrollOffset / 300)))
    }

    var body: some View {
        ZStack {
            // Top glow
            Circle()
                .fill(accentColor.opacity(0.2 * opacity))
                .frame(width: 400, height: 400)
                .blur(radius: 80)
                .offset(y: -100)

            Theme.cyberBackground
        }
    }
}

// MARK: - Hero Header Cyberpunk

struct HeroPlaylistHeaderCyberpunk: View {
    let playlist: Playlist
    let trackCount: Int
    let scrollOffset: CGFloat
    let onPlay: () -> Void
    let onShuffle: () -> Void

    private var scale: CGFloat {
        let scaleFactor = 1 - (scrollOffset / 1000)
        return max(0.85, min(1, scaleFactor))
    }

    private var opacity: Double {
        max(0, min(1, 1 - (scrollOffset / 200)))
    }

    private var accentColor: Color {
        if let hex = playlist.smartCriteria?.type.color {
            return Color(hex: hex) ?? Theme.cyberCyan
        }
        return Theme.cyberCyan
    }

    var body: some View {
        VStack(spacing: 24) {
            // Large Artwork
            HeroPlaylistArtworkCyberpunk(
                playlist: playlist,
                accentColor: accentColor
            )
            .frame(width: 220, height: 220)
            .scaleEffect(scale)
            .shadow(color: accentColor.opacity(0.4), radius: 30, x: 0, y: 15)

            // Playlist Info
            VStack(spacing: 8) {
                Text(playlist.name.uppercased())
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)

                if let description = playlist.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(Theme.cyberDim)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }

                HStack(spacing: 4) {
                    if playlist.isSmart {
                        Image(systemName: "wand.and.stars")
                            .font(.caption)
                            .foregroundColor(Theme.cyberMagenta)
                        Text("NEURAL")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.cyberMagenta)
                    }

                    if playlist.isSmart && trackCount > 0 {
                        Text("·")
                            .font(.caption)
                            .foregroundColor(Theme.cyberDim)
                    }

                    if trackCount > 0 {
                        Text("\(trackCount) TRACKS")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(Theme.cyberDim)
                    }
                }
            }
            .padding(.horizontal, 32)

            // Action Buttons
            HStack(spacing: 16) {
                // Play Button
                Button(action: onPlay) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("PLAY")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(Theme.cyberBackground)
                    .frame(width: 140, height: 48)
                    .background(accentColor)
                    .cornerRadius(8)
                    .shadow(color: accentColor.opacity(0.5), radius: 12, x: 0, y: 0)
                }

                // Shuffle Button
                Button(action: onShuffle) {
                    HStack(spacing: 6) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 16, weight: .semibold))
                        Text("SHUFFLE")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(accentColor)
                    .frame(width: 140, height: 48)
                    .background(Theme.cyberSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(accentColor.opacity(0.5), lineWidth: 1)
                    )
                    .cornerRadius(8)
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .opacity(opacity)
    }
}

// MARK: - Hero Artwork Cyberpunk

struct HeroPlaylistArtworkCyberpunk: View {
    let playlist: Playlist
    let accentColor: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.cyberSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(accentColor.opacity(0.3), lineWidth: 1)
                )

            if let thumbnailURL = playlist.thumbnailURL,
               let url = URL(string: thumbnailURL) {
                CachedAsyncImage(url: url) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Theme.cyberSurface)
                }
                .aspectRatio(contentMode: .fill)
                .cornerRadius(16)
            } else {
                artworkContent
            }
        }
        .cornerRadius(16)
    }

    @ViewBuilder
    private var artworkContent: some View {
        let trackIds = Array(playlist.trackIds.prefix(4))

        if trackIds.isEmpty {
            // Empty state
            LinearGradient(
                colors: [accentColor.opacity(0.2), accentColor.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "music.note")
                .font(.system(size: 80, weight: .light))
                .foregroundColor(accentColor)
                .shadow(color: accentColor.opacity(0.5), radius: 10, x: 0, y: 0)
        } else if trackIds.count < 4 {
            // 1-3 tracks - gradient with icon
            LinearGradient(
                colors: [accentColor.opacity(0.2), accentColor.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: trackIds.count == 1 ? "music.note" : "music.note.list")
                .font(.system(size: 80, weight: .light))
                .foregroundColor(accentColor)
                .shadow(color: accentColor.opacity(0.5), radius: 10, x: 0, y: 0)
        } else {
            // 4+ tracks - cyberpunk mosaic
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Rectangle().fill(Theme.cyberMagenta.opacity(0.8))
                    Rectangle().fill(Theme.cyberCyan.opacity(0.8))
                }
                HStack(spacing: 4) {
                    Rectangle().fill(Theme.cyberYellow.opacity(0.8))
                    Rectangle().fill(Theme.cyberCyan.opacity(0.4))
                }
            }
            .padding(6)
        }
    }
}

// MARK: - Cyberpunk Track Row

struct CyberpunkTrackRow: View {
    let track: Track
    let index: Int
    let isPlaying: Bool
    let isEditing: Bool
    let downloadTask: DownloadTask?
    let isDownloaded: Bool
    let onPlay: () -> Void
    let onDownload: () -> Void
    let onAddToQueue: () -> Void
    let onPlayNext: () -> Void
    let onAddToPlaylist: () -> Void
    let onDelete: () -> Void

    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 12) {
            // Index or Playing Indicator
            ZStack {
                if isPlaying {
                    PlayingBars()
                        .frame(width: 20, height: 20)
                } else {
                    Text(String(format: "%02d", index))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.cyberDim)
                }
            }
            .frame(width: 28, alignment: .center)

            // Artwork
            ZStack(alignment: .bottomTrailing) {
                ArtworkThumbnail(url: track.artworkURL)
                    .frame(width: 50, height: 50)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isPlaying ? Theme.cyberCyan.opacity(0.5) : Color.clear, lineWidth: 1)
                    )

                if isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.cyberCyan)
                        .background(Circle().fill(Theme.cyberBackground))
                        .offset(x: 4, y: 4)
                }
            }

            // Track Info
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 15, weight: isPlaying ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundColor(isPlaying ? Theme.cyberCyan : .white)

                HStack(spacing: 4) {
                    Text(track.displayArtist)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.cyberDim)

                    if track.isExplicit {
                        Text("E")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.cyberBackground)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Theme.cyberMagenta)
                            .cornerRadius(2)
                    }
                }
                .lineLimit(1)
            }

            Spacer()

            // Duration / Download Progress
            HStack(spacing: 12) {
                if let task = downloadTask, task.status.isActive {
                    CircularProgressView(progress: task.progress)
                        .frame(width: 20, height: 20)
                } else {
                    Text(track.durationText)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.cyberDim)
                }

                // Play button
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(isPlaying ? Theme.cyberCyan : Theme.cyberDim)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isPlaying ? Theme.cyberCyan.opacity(0.08) : Theme.cyberSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isPlaying ? Theme.cyberCyan.opacity(0.4) : Theme.cyberCyan.opacity(0.1), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .scaleEffect(isPressed ? 0.98 : 1)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .onLongPressGesture(minimumDuration: 0.3, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
        .contextMenu {
            Button(action: onPlay) {
                Label(isPlaying ? "Now Playing" : "Play", systemImage: isPlaying ? "waveform" : "play.fill")
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
                    Label(isDownloaded ? "Downloaded" : "Download", systemImage: isDownloaded ? "checkmark" : "arrow.down")
                }
            }
            .disabled(isDownloaded)

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("Remove from Playlist", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label("Remove", systemImage: "trash")
            }

            Button(action: onDownload) {
                Label("Download", systemImage: "arrow.down")
            }
            .tint(Theme.cyberCyan)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(action: onPlayNext) {
                Label("Next", systemImage: "text.badge.plus")
            }
            .tint(Theme.cyberMagenta)
        }
    }
}

// MARK: - Empty State Cyberpunk

struct EmptyPlaylistCyberpunk: View {
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Theme.cyberCyan.opacity(0.3), lineWidth: 1)
                    .frame(width: 120, height: 120)

                Image(systemName: "music.note.list")
                    .font(.system(size: 50, weight: .light))
                    .foregroundColor(Theme.cyberCyan)
                    .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 10, x: 0, y: 0)
            }

            VStack(spacing: 8) {
                Text("NO_DATA")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                Text("Add tracks from search or neural library")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.cyberDim)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Rename Sheet

struct RenamePlaylistSheet: View {
    let currentName: String
    let onRename: (String) -> Void
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    init(currentName: String, onRename: @escaping (String) -> Void) {
        self.currentName = currentName
        self.onRename = onRename
        _name = State(initialValue: currentName)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Theme.cyberBackground
                    .ignoresSafeArea()

                Form {
                    Section {
                        TextField("NEW_NAME", text: $name)
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .listRowBackground(Theme.cyberSurface)
                }
                // Use a clear background to show the cyberBackground underneath
                .background(Color.clear)
            }
            .navigationTitle("RENAME")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("CANCEL") {
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("SAVE") {
                        onRename(name)
                        dismiss()
                    }
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.cyberCyan)
                    .disabled(name.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Preview

struct PlaylistDetailView_Previews: PreviewProvider {
    static var previews: some View {
        PlaylistDetailView(
            playlist: Playlist(
                name: "My Awesome Playlist",
                description: "Some great tunes",
                trackIds: ["1", "2", "3"]
            )
        )
    }
}
