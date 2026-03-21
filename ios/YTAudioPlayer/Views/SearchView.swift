//
//  SearchView.swift
//  YTAudioPlayer
//
//  Unified search interface for songs and playlists
//

import SwiftUI
import Combine

enum SearchFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case songs = "Songs"
    case playlists = "Playlists"
    
    var id: String { rawValue }
}

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var searchText = ""
    @State private var selectedTrackForPlaylist: Track?
    @State private var selectedYouTubePlaylist: YouTubePlaylist?
    @State private var activeFilter: SearchFilter = .all
    @State private var cancellables = Set<AnyCancellable>()
    
    var body: some View {
        NavigationView {
            ZStack {
                Theme.cyberBackground.ignoresSafeArea()

                if viewModel.isLoading {
                    skeletonLoadingView
                } else if viewModel.results.isEmpty && viewModel.playlistResults.isEmpty {
                    emptyStateView
                } else {
                    resultsListView
                }
            }
            .navigationTitle("Search Music")
            .preferredColorScheme(.dark)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search songs & playlists..."
            )
            .onSubmit(of: .search) {
                HapticManager.medium()
                viewModel.search(query: searchText)
            }
            .onAppear {
                viewModel.refreshDownloadedIds()
                UITableView.appearance().backgroundColor = .clear
            }
            .onDisappear {
                UITableView.appearance().backgroundColor = .systemGroupedBackground
            }
            .onChange(of: downloadManager.completedDownloads.count) { _ in
                viewModel.refreshDownloadedIds()
            }
            .onChange(of: searchText) { newValue in
                if newValue.isEmpty && viewModel.hasSearched {
                    viewModel.clearSearch()
                    activeFilter = .all
                }
            }
            .errorAlert()
            .sheet(item: $selectedTrackForPlaylist) { track in
                AddToPlaylistSheet(track: track)
            }
            .sheet(item: $selectedYouTubePlaylist) { playlist in
                PlaylistPreviewView(playlist: playlist)
            }
        }
    }
    
    // MARK: - Results List
    private var resultsListView: some View {
        List {
            // Filter Chips
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(SearchFilter.allCases) { filter in
                            FilterChip(
                                title: filter.rawValue,
                                count: resultCount(for: filter),
                                isSelected: activeFilter == filter
                            ) {
                                withAnimation(.spring()) {
                                    activeFilter = filter
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            // Songs Section
            if shouldShowSongs {
                if !viewModel.results.isEmpty {
                    Section(header:
                        HStack {
                            Text("SONGS")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyberDim)
                            Spacer()
                            Text("\(viewModel.results.count)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyberDim)
                        }
                    ) {
                        ForEach(viewModel.results) { track in
                            let downloadTask = downloadManager.taskForTrack(track)

                            SearchResultRow(
                                track: track,
                                isDownloaded: viewModel.isDownloaded(track),
                                isPlaying: viewModel.isCurrentlyPlaying(track),
                                downloadTask: downloadTask,
                                onPlay: {
                                    HapticManager.medium()
                                    viewModel.playTrack(track)
                                },
                                onDownload: {
                                    HapticManager.light()
                                    viewModel.downloadTrack(track)
                                },
                                onAddToQueue: {
                                    HapticManager.light()
                                    viewModel.addToQueue(track)
                                },
                                onPlayNext: {
                                    HapticManager.light()
                                    viewModel.playNext(track)
                                },
                                onAddToPlaylist: {
                                    HapticManager.light()
                                    selectedTrackForPlaylist = track
                                }
                            )
                            .listRowBackground(Color.cyberSurface)
                        }
                    }
                }
            }

            // Playlists Section
            if shouldShowPlaylists {
                if !viewModel.playlistResults.isEmpty {
                    Section(header:
                        HStack {
                            Text("PLAYLISTS")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyberDim)
                            Spacer()
                            Text("\(viewModel.playlistResults.count)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyberDim)
                        }
                    ) {
                        ForEach(viewModel.playlistResults) { playlist in
                            PlaylistSearchRow(
                                playlist: playlist,
                                onTap: {
                                    selectedYouTubePlaylist = playlist
                                },
                                onClone: {
                                    cloneYouTubePlaylist(playlist)
                                },
                                onPlayAll: {
                                    playYouTubePlaylist(playlist)
                                },
                                onAddToQueue: {
                                    queueYouTubePlaylist(playlist)
                                }
                            )
                            .listRowBackground(Color.cyberSurface)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var shouldShowSongs: Bool {
        activeFilter == .all || activeFilter == .songs
    }
    
    private var shouldShowPlaylists: Bool {
        activeFilter == .all || activeFilter == .playlists
    }
    
    private func resultCount(for filter: SearchFilter) -> Int {
        switch filter {
        case .all:
            return viewModel.results.count + viewModel.playlistResults.count
        case .songs:
            return viewModel.results.count
        case .playlists:
            return viewModel.playlistResults.count
        }
    }
    
    // MARK: - Playlist Actions
    
    private func cloneYouTubePlaylist(_ playlist: YouTubePlaylist) {
        // Fetch playlist details then clone
        APIService.shared.getPlaylistDetails(playlistId: playlist.playlistId, limit: 100)
            .handleErrors(with: .shared)
            .sink(receiveValue: { details in
                // Save track metadata
                TrackStore.shared.saveTracks(details.tracks)
                
                // Get thumbnail URL
                let thumbnailURL = details.thumbnails.last?.url.absoluteString
                
                // Create playlist
                let newPlaylist = PlaylistManager.shared.createPlaylist(
                    name: details.title,
                    description: "Cloned from YouTube • by \(details.author)",
                    thumbnailURL: thumbnailURL
                )
                
                // Add tracks
                PlaylistManager.shared.addTracks(details.tracks, to: newPlaylist.id)
                
                HapticManager.success()
            })
            .store(in: &cancellables)
    }
    
    private func playYouTubePlaylist(_ playlist: YouTubePlaylist) {
        APIService.shared.getPlaylistDetails(playlistId: playlist.playlistId, limit: 20)
            .handleErrors(with: .shared)
            .sink(receiveValue: { details in
                PlaylistManager.shared.playYouTubePlaylist(details)
            })
            .store(in: &cancellables)
    }
    
    private func queueYouTubePlaylist(_ playlist: YouTubePlaylist) {
        APIService.shared.getPlaylistDetails(playlistId: playlist.playlistId, limit: 20)
            .handleErrors(with: .shared)
            .sink(receiveValue: { details in
                PlaylistManager.shared.queueYouTubePlaylist(details)
                HapticManager.light()
            })
            .store(in: &cancellables)
    }
    
    // MARK: - Skeleton Loading
    private var skeletonLoadingView: some View {
        List {
            ForEach(0..<8, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.cyberDim.opacity(0.2))
                        .frame(width: 60, height: 60)
                        .shimmer()

                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.cyberDim.opacity(0.2))
                            .frame(width: 180, height: 16)
                            .shimmer()

                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.cyberDim.opacity(0.2))
                            .frame(width: 120, height: 14)
                            .shimmer()
                    }

                    Spacer()
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.cyberSurface)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Empty State
    @ViewBuilder
    private var emptyStateView: some View {
        if viewModel.hasSearched {
            // No results
            VStack(spacing: 20) {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 70))
                    .foregroundColor(.cyberDim)

                Text("No results for \"\(searchText)\"")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                Text("Try a different search term")
                    .foregroundColor(.cyberDim)

                Button("Clear Search") {
                    searchText = ""
                    viewModel.clearSearch()
                    activeFilter = .all
                }
                .foregroundColor(.cyberCyan)
                .padding(.top, 8)
            }
        } else {
            // Initial state with genres
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 60))
                        .foregroundColor(.cyberCyan.opacity(0.5))

                    Text("Search Music")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    Text("Find songs and playlists from YouTube Music")
                        .foregroundColor(.cyberDim)

                    // Genre quick picks
                    VStack(alignment: .leading, spacing: 12) {
                        Text("BROWSE BY GENRE")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyberDim)
                            .padding(.horizontal)

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            GenreButton(title: "Pop", icon: "sparkles", color: .pink) {
                                searchText = "Pop"
                                viewModel.search(query: "Pop music")
                            }
                            GenreButton(title: "Trending", icon: "flame.fill", color: .orange) {
                                searchText = "Trending"
                                viewModel.search(query: "Trending music 2024")
                            }
                            GenreButton(title: "Rock", icon: "guitars.fill", color: .red) {
                                searchText = "Rock"
                                viewModel.search(query: "Rock and roll")
                            }
                            GenreButton(title: "Hip-Hop", icon: "mic.fill", color: .purple) {
                                searchText = "Hip Hop"
                                viewModel.search(query: "Hip hop rap")
                            }
                            GenreButton(title: "Electronic", icon: "waveform", color: .cyan) {
                                searchText = "Electronic"
                                viewModel.search(query: "Electronic dance music")
                            }
                            GenreButton(title: "Jazz", icon: "music.note", color: .indigo) {
                                searchText = "Jazz"
                                viewModel.search(query: "Jazz classics")
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.top, 10)

                    // Recent searches
                    if !viewModel.recentSearches.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("RECENT SEARCHES")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyberDim)
                                .padding(.horizontal)

                            ForEach(viewModel.recentSearches, id: \.self) { query in
                                Button(action: {
                                    searchText = query
                                    viewModel.search(query: query)
                                }) {
                                    HStack {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundColor(.cyberCyan)
                                        Text(query)
                                            .foregroundColor(.white)
                                        Spacer()
                                    }
                                    .padding(.vertical, 8)
                                }
                            }
                        }
                        .padding(.horizontal, 32)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.bold())

                if count > 0 {
                    Text("\(count)")
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.cyberCyan.opacity(0.3) : Color.cyberDim.opacity(0.2))
                        .cornerRadius(10)
                }
            }
            .foregroundColor(isSelected ? .cyberBackground : .white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? Color.cyberCyan : Color.cyberSurface)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? Color.clear : Color.cyberDim.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Playlist Search Row

struct PlaylistSearchRow: View {
    let playlist: YouTubePlaylist
    let onTap: () -> Void
    let onClone: () -> Void
    let onPlayAll: () -> Void
    let onAddToQueue: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Artwork with video count
            ZStack(alignment: .bottomTrailing) {
                ArtworkThumbnail(url: playlist.artworkURL)
                    .frame(width: 60, height: 60)
                
                Text("\(playlist.videoCount)")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(4)
                    .padding(4)
            }
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .foregroundColor(.white)

                Text("by \(playlist.author)")
                    .font(.system(size: 14))
                    .foregroundColor(.cyberDim)
                    .lineLimit(1)

                if !playlist.description.isEmpty {
                    Text(playlist.description)
                        .font(.system(size: 12))
                        .foregroundColor(.cyberDim)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.cyberDim)
                .font(.caption)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .contextMenu {
            Button(action: onTap) {
                Label("Preview", systemImage: "eye")
            }
            
            Button(action: onPlayAll) {
                Label("Play All", systemImage: "play.fill")
            }
            
            Button(action: onAddToQueue) {
                Label("Add to Queue", systemImage: "plus")
            }
            
            Divider()
            
            Button(action: onClone) {
                Label("Clone to Library", systemImage: "doc.on.doc")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: onClone) {
                Label("Clone", systemImage: "doc.on.doc")
            }
            .tint(.cyberCyan)

            Button(action: onAddToQueue) {
                Label("Queue", systemImage: "plus")
            }
            .tint(.cyberMagenta)
        }
    }
}

// MARK: - Artwork Thumbnail

struct ArtworkThumbnail: View {
    let url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.cyberSurface)
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundColor(.cyberDim)
                )

            if let url = url {
                CachedAsyncImage(url: url) {
                    EmptyView()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Genre Button

struct GenreButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                Spacer()
            }
            .foregroundColor(color)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(color.opacity(0.4), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search Result Row

struct SearchResultRow: View {
    let track: Track
    let isDownloaded: Bool
    let isPlaying: Bool
    let downloadTask: DownloadTask?
    let onPlay: () -> Void
    let onDownload: () -> Void
    let onAddToQueue: () -> Void
    let onPlayNext: () -> Void
    let onAddToPlaylist: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Artwork with indicators
            ZStack(alignment: .bottomTrailing) {
                ArtworkThumbnail(url: track.artworkURL)
                    .frame(width: 60, height: 60)
                
                // Download status badge
                if let task = downloadTask, task.status.isActive {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.7))
                            .frame(width: 20, height: 20)
                        
                        CircularProgressView(progress: task.progress)
                            .frame(width: 16, height: 16)
                    }
                    .offset(x: 4, y: 4)
                } else if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.cyberCyan)
                        .background(Circle().fill(Color.black))
                        .offset(x: 4, y: 4)
                }
                
                // Now playing indicator
                if isPlaying {
                    CyberPlayingBars()
                        .frame(width: 16, height: 16)
                        .padding(4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(4)
                        .offset(x: -4, y: -4)
                }
            }
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 16, weight: isPlaying ? .bold : .semibold))
                    .lineLimit(1)
                    .foregroundColor(isPlaying ? .cyberCyan : .white)

                Text(track.displayArtist)
                    .font(.system(size: 14))
                    .foregroundColor(.cyberDim)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if !track.album.isEmpty && track.album != "Unknown Album" {
                        Text(track.album)
                            .font(.system(size: 12))
                            .foregroundColor(.cyberDim)
                            .lineLimit(1)
                    }

                    Text("• \(track.durationText)")
                        .font(.system(size: 12))
                        .foregroundColor(.cyberDim)

                    if track.isExplicit {
                        Text("• E")
                            .font(.system(size: 12))
                            .foregroundColor(.cyberDim)
                    }
                }
            }
            
            Spacer()
            
            // Actions - Play button + download indicator
            HStack(spacing: 12) {
                // Download status indicator (not clickable)
                if let task = downloadTask {
                    if task.status.isActive {
                        ZStack {
                            Circle()
                                .stroke(Color.cyberDim.opacity(0.3), lineWidth: 2)
                                .frame(width: 24, height: 24)
                            Circle()
                                .trim(from: 0, to: task.progress)
                                .stroke(Color.cyberCyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .frame(width: 24, height: 24)
                                .rotationEffect(.degrees(-90))
                        }
                    } else if task.status == .completed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.cyberCyan)
                    }
                } else if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.cyberCyan)
                }

                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "waveform" : "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.cyberCyan)
                }
            }
        }
        .padding(.vertical, 8)
        .background(isPlaying ? Color.cyberCyan.opacity(0.08) : Color.clear)
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
            .tint(.cyberCyan)

            Button(action: onAddToQueue) {
                Label("Queue", systemImage: "plus")
            }
            .tint(.cyberMagenta)
        }
    }
}

// MARK: - Circular Progress View

struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.cyberDim.opacity(0.3), lineWidth: 2)

            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(Color.cyberCyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: progress)
        }
    }
}

// MARK: - View Model

class SearchViewModel: ObservableObject {
    @Published var results: [Track] = []
    @Published var playlistResults: [YouTubePlaylist] = []
    @Published var isLoading = false
    @Published var hasSearched = false
    @Published var downloadedVideoIds: Set<String> = []
    @Published var recentSearches: [String] = []
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        loadRecentSearches()
    }
    
    private func loadRecentSearches() {
        recentSearches = UserDefaults.standard.stringArray(forKey: "recentSearches") ?? []
    }
    
    private func saveRecentSearch(_ query: String) {
        var searches = recentSearches
        searches.removeAll { $0 == query }
        searches.insert(query, at: 0)
        searches = Array(searches.prefix(10))
        recentSearches = searches
        UserDefaults.standard.set(searches, forKey: "recentSearches")
    }
    
    func refreshDownloadedIds() {
        APIService.shared.fetchLibrary()
            .sink(receiveCompletion: { _ in },
                  receiveValue: { [weak self] tracks in
                self?.downloadedVideoIds = Set(tracks.compactMap { track -> String? in
                    let title = track.parsedTitle.lowercased().trimmingCharacters(in: .whitespaces)
                    return self?.results.first { $0.title.lowercased().trimmingCharacters(in: .whitespaces) == title }?.videoId
                })
            })
            .store(in: &cancellables)
    }
    
    func isDownloaded(_ track: Track) -> Bool {
        DownloadManager.shared.isAlreadyDownloaded(track) ||
        downloadedVideoIds.contains(track.videoId)
    }
    
    func isCurrentlyPlaying(_ track: Track) -> Bool {
        PlayerState.shared.currentItem?.track.videoId == track.videoId
    }
    
    func search(query: String) {
        guard !query.isEmpty else { return }
        
        isLoading = true
        hasSearched = true
        saveRecentSearch(query)
        
        results = []
        playlistResults = []
        
        // Search for songs
        APIService.shared.search(query: query, limit: 20)
            .handleErrors(with: .shared, retry: { [weak self] in
                self?.search(query: query)
            })
            .sink(receiveCompletion: { _ in },
                  receiveValue: { [weak self] tracks in
                self?.results = tracks
                self?.refreshDownloadedIds()
            })
            .store(in: &cancellables)
        
        // Search for playlists
        print("🔍 Searching playlists for: \(query)")
        APIService.shared.searchPlaylists(query: query, limit: 10)
            .handleErrors(with: .shared)
            .sink(receiveCompletion: { [weak self] completion in
                print("🔍 Playlist search completed")
                self?.isLoading = false
            }, receiveValue: { [weak self] playlists in
                print("🔍 Found \(playlists.count) playlists")
                self?.playlistResults = playlists
            })
            .store(in: &cancellables)
    }
    
    func clearSearch() {
        results = []
        playlistResults = []
        hasSearched = false
        cancellables.removeAll()
    }
    
    func playTrack(_ track: Track) {
        performPlayTrack(track)
    }
    
    private func performPlayTrack(_ track: Track) {
        APIService.shared.getStreamUrl(videoId: track.videoId)
            .handleErrors(with: .shared, retry: { [weak self] in
                self?.performPlayTrack(track)
            })
            .sink(receiveCompletion: { _ in },
                  receiveValue: { streamInfo in
                let item = QueueItem(
                    track: track,
                    streamUrl: streamInfo.streamUrl,
                    source: .stream
                )
                PlayerState.shared.play(item: item)
            })
            .store(in: &cancellables)
    }
    
    func downloadTrack(_ track: Track) {
        if DownloadManager.shared.isDownloading(track) {
            DownloadManager.shared.cancelDownload(for: track)
            return
        }
        
        guard !isDownloaded(track) else {
            ErrorHandler.shared.show(.downloadFailed("This track is already in your library"))
            return
        }
        
        DownloadManager.shared.download(track)
    }
    
    func addToQueue(_ track: Track) {
        APIService.shared.getStreamUrl(videoId: track.videoId)
            .handleErrors(with: .shared)
            .sink(receiveValue: { streamInfo in
                let item = QueueItem(
                    track: track,
                    streamUrl: streamInfo.streamUrl,
                    source: .stream
                )
                PlayerState.shared.addToQueue(item)
                HapticManager.success()
            })
            .store(in: &cancellables)
    }
    
    func playNext(_ track: Track) {
        APIService.shared.getStreamUrl(videoId: track.videoId)
            .handleErrors(with: .shared)
            .sink(receiveValue: { streamInfo in
                let item = QueueItem(
                    track: track,
                    streamUrl: streamInfo.streamUrl,
                    source: .stream
                )
                PlayerState.shared.addToQueueNext(item)
                HapticManager.success()
            })
            .store(in: &cancellables)
    }
}

// MARK: - Preview

struct SearchView_Previews: PreviewProvider {
    static var previews: some View {
        SearchView()
    }
}
