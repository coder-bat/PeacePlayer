//
//  DiscoverView.swift
//  YTAudioPlayer
//
//  Cyberpunk discovery - explore and search
//

import SwiftUI
import Combine

struct DiscoverView: View {
    @StateObject private var viewModel = DiscoverViewModel()
    @StateObject private var playerState = PlayerState.shared
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var showSearchResults = false
    @State private var selectedTrackForPlaylist: Track?
    @State private var activeFilter: SearchFilter = .all
    @State private var cancellables = Set<AnyCancellable>()

    var body: some View {
        NavigationView {
            ZStack {
                CyberBackground()

                if showSearchResults || viewModel.isLoading {
                    searchResultsView
                } else {
                    discoveryContentView
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                viewModel.loadTrending()
                viewModel.loadNewReleases()
            }
        }
        .sheet(item: $selectedTrackForPlaylist) { track in
            AddToPlaylistSheet(track: track)
        }
    }

    // MARK: - Discovery Content
    private var discoveryContentView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                // Header with search
                headerSection
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                // Search bar
                searchBarSection
                    .padding(.horizontal, 20)
                    .padding(.top, 24)

                // Quick categories
                categorySection
                    .padding(.top, 20)

                // Trending
                trendingSection
                    .padding(.top, 24)

                // New Releases
                newReleasesSection
                    .padding(.top, 24)
                    .padding(.bottom, 100)
            }
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("DISCOVER")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyberDim)
                    .textCase(.uppercase)

                Text("EXPLORE_AUDIO")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyberMagenta)
                    .glow(color: .cyberMagenta, radius: 8)
            }

            Spacer()
        }
    }

    // MARK: - Search Bar
    private var searchBarSection: some View {
        Button {
            showSearchResults = true
            isSearching = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.cyberDim)

                Text("Search songs, artists...")
                    .font(.system(size: 15))
                    .foregroundColor(.cyberDim)

                Spacer()

                Image(systemName: "waveform")
                    .font(.system(size: 16))
                    .foregroundColor(.cyberCyan)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cyberSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.cyberCyan.opacity(0.2), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Category Section
    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BROWSE")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.cyberDim)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(CyberCategory.allCases) { category in
                        CategoryChip(category: category) {
                            searchText = category.query
                            performSearch()
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Trending Section
    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("TRENDING")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyberDim)

                Spacer()

                if !viewModel.trendingTracks.isEmpty {
                    Button("play.all") {
                        playAll(viewModel.trendingTracks)
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyberCyan)
                }
            }
            .padding(.horizontal, 20)

            if viewModel.isLoadingTrending {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(0..<5) { _ in
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.cyberDim.opacity(0.2))
                                .frame(width: 140, height: 140)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(viewModel.trendingTracks.prefix(10)) { track in
                            MinimalTrackCard(track: track) {
                                playTrack(track)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    // MARK: - New Releases Section
    private var newReleasesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("NEW_RELEASES")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyberDim)

                Spacer()

                if !viewModel.newReleases.isEmpty {
                    Button("play.all") {
                        playAll(viewModel.newReleases)
                    }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyberCyan)
                }
            }
            .padding(.horizontal, 20)

            if viewModel.isLoadingNewReleases {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(0..<5) { _ in
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.cyberDim.opacity(0.2))
                                .frame(width: 140, height: 140)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(viewModel.newReleases.prefix(10)) { track in
                            MinimalTrackCard(track: track) {
                                playTrack(track)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    // MARK: - Search Results
    private var searchResultsView: some View {
        VStack(spacing: 0) {
            // Search header
            HStack(spacing: 12) {
                Button {
                    showSearchResults = false
                    isSearching = false
                    searchText = ""
                    viewModel.clearSearch()
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.cyberCyan)
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundColor(.cyberDim)

                    TextField("Search...", text: $searchText)
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .submitLabel(.search)
                        .onSubmit {
                            performSearch()
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.cyberDim)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.cyberSurface)
                )

                Button {
                    performSearch()
                } label: {
                    Text("SEARCH")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyberCyan)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.cyberBackground)

            // Filter chips
            if !viewModel.results.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SearchFilter.allCases) { filter in
                            CyberFilterChip(
                                title: filter.rawValue.uppercased(),
                                count: resultCount(for: filter),
                                isSelected: activeFilter == filter
                            ) {
                                withAnimation(.spring()) {
                                    activeFilter = filter
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            // Results
            List {
                if viewModel.isLoading {
                    Section {
                        ForEach(0..<5) { _ in
                            SearchResultSkeleton()
                                .listRowBackground(Color.cyberBackground)
                        }
                    }
                } else if viewModel.results.isEmpty && !searchText.isEmpty && !viewModel.isLoading {
                    Section {
                        VStack(spacing: 16) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(.cyberDim)
                            Text("NO_SIGNAL")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyberDim)
                            Text("No results found")
                                .font(.system(size: 14))
                                .foregroundColor(.cyberDim.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                        .listRowBackground(Color.cyberBackground)
                    }
                } else {
                    // Songs Section
                    if shouldShowSongs {
                        Section {
                            ForEach(viewModel.results) { track in
                                CyberSearchResultRow(
                                    track: track,
                                    isDownloaded: viewModel.downloadedTrackIds.contains(track.videoId),
                                    onPlay: { playTrack(track) },
                                    onDownload: { downloadTrack(track) },
                                    onAddToQueue: { addToQueue(track) },
                                    onAddToPlaylist: { selectedTrackForPlaylist = track }
                                )
                                .listRowBackground(Color.cyberBackground)
                            }
                        }
                    }

                    // Playlists Section
                    if shouldShowPlaylists {
                        Section(header:
                            Text("PLAYLISTS")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyberDim)
                        ) {
                            ForEach(viewModel.playlistResults) { playlist in
                                CyberPlaylistRow(playlist: playlist)
                                    .listRowBackground(Color.cyberBackground)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .background(Color.cyberBackground)
        }
    }

    // MARK: - Helper Properties
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

    // MARK: - Actions
    private func performSearch() {
        guard !searchText.isEmpty else { return }
        showSearchResults = true
        HapticManager.medium()
        viewModel.search(query: searchText)
    }

    private func playTrack(_ track: Track) {
        APIService.shared.getStreamUrl(videoId: track.videoId)
            .sink(receiveCompletion: { _ in }, receiveValue: { streamInfo in
                let item = QueueItem(
                    track: track,
                    streamUrl: streamInfo.streamUrl,
                    source: .stream
                )
                PlayerState.shared.play(item: item)
            })
            .store(in: &cancellables)
    }

    private func playAll(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }

        // Play first track
        playTrack(tracks[0])

        // Add rest to queue
        for track in tracks.dropFirst() {
            APIService.shared.getStreamUrl(videoId: track.videoId)
                .sink(receiveCompletion: { _ in }, receiveValue: { streamInfo in
                    let item = QueueItem(
                        track: track,
                        streamUrl: streamInfo.streamUrl,
                        source: .stream
                    )
                    PlayerState.shared.addToQueue(item)
                })
                .store(in: &cancellables)
        }

        HapticManager.medium()
    }

    private func downloadTrack(_ track: Track) {
        DownloadManager.shared.download(track)
    }

    private func addToQueue(_ track: Track) {
        APIService.shared.getStreamUrl(videoId: track.videoId)
            .sink(receiveCompletion: { _ in }, receiveValue: { streamInfo in
                let item = QueueItem(
                    track: track,
                    streamUrl: streamInfo.streamUrl,
                    source: .stream
                )
                PlayerState.shared.addToQueue(item)
                HapticManager.light()
            })
            .store(in: &cancellables)
    }
}

// MARK: - Category Chip
enum CyberCategory: String, CaseIterable, Identifiable {
    case pop = "POP"
    case electronic = "ELECTRONIC"
    case rock = "ROCK"
    case hipHop = "HIP_HOP"
    case jazz = "JAZZ"
    case classical = "CLASSICAL"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pop: return "music.mic"
        case .electronic: return "bolt.fill"
        case .rock: return "guitars"
        case .hipHop: return "speaker.wave.2"
        case .jazz: return "saxophone"
        case .classical: return "pianokeys"
        }
    }

    var color: Color {
        switch self {
        case .pop: return .cyberCyan
        case .electronic: return .cyberMagenta
        case .rock: return .red
        case .hipHop: return .cyberYellow
        case .jazz: return .orange
        case .classical: return .purple
        }
    }

    var query: String {
        switch self {
        case .pop: return "pop hits"
        case .electronic: return "electronic edm"
        case .rock: return "rock music"
        case .hipHop: return "hip hop rap"
        case .jazz: return "jazz"
        case .classical: return "classical music"
        }
    }
}

struct CategoryChip: View {
    let category: CyberCategory
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(category.color)

                Text(category.rawValue.replacingOccurrences(of: "_", with: " "))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            .frame(width: 80, height: 80)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.cyberSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(category.color.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter Chip
struct CyberFilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))

                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .foregroundColor(isSelected ? .black : .cyberCyan)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.cyberCyan : Color.cyberSurface)
                    .overlay(
                        Capsule()
                            .stroke(Color.cyberCyan.opacity(isSelected ? 0 : 0.4), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cyber Search Result Row
struct CyberSearchResultRow: View {
    let track: Track
    let isDownloaded: Bool
    let onPlay: () -> Void
    let onDownload: () -> Void
    let onAddToQueue: () -> Void
    let onAddToPlaylist: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Artwork
            CachedAsyncImage(url: track.artworkURL) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.cyberDim.opacity(0.3))
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(track.displayArtist)
                    .font(.system(size: 14))
                    .foregroundColor(.cyberDim)
                    .lineLimit(1)
            }

            Spacer()

            // Downloaded indicator
            if isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.cyberCyan)
            }

            // Play button
            Button {
                onPlay()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.cyberCyan)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(Color.cyberSurface)
                            .overlay(
                                Circle()
                                    .stroke(Color.cyberCyan.opacity(0.3), lineWidth: 1)
                            )
                    )
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .leading) {
            Button {
                onAddToQueue()
            } label: {
                Label("Queue", systemImage: "text.badge.plus")
            }
            .tint(.orange)

            Button {
                onAddToPlaylist()
            } label: {
                Label("Playlist", systemImage: "music.note.list")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button {
                onDownload()
            } label: {
                Label("Download", systemImage: "arrow.down")
            }
            .tint(.cyberCyan)
        }
    }
}

// MARK: - Cyber Playlist Row
struct CyberPlaylistRow: View {
    let playlist: YouTubePlaylist
    @State private var isShowingPreview = false

    var body: some View {
        Button(action: {
            isShowingPreview = true
        }) {
            HStack(spacing: 12) {
                // Artwork
                CachedAsyncImage(url: playlist.artworkURL) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.cyberDim.opacity(0.3))
                }
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(playlist.author)
                        .font(.system(size: 14))
                        .foregroundColor(.cyberDim)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.cyberDim)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isShowingPreview) {
            PlaylistPreviewView(playlist: playlist)
        }
    }
}

// MARK: - Skeleton
struct SearchResultSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.cyberDim.opacity(0.2))
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.cyberDim.opacity(0.2))
                    .frame(width: 150, height: 14)

                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.cyberDim.opacity(0.2))
                    .frame(width: 100, height: 12)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - View Model
class DiscoverViewModel: ObservableObject {
    @Published var results: [Track] = []
    @Published var playlistResults: [YouTubePlaylist] = []
    @Published var isLoading = false
    @Published var hasSearched = false
    @Published var downloadedTrackIds: Set<String> = []

    @Published var trendingTracks: [Track] = []
    @Published var newReleases: [Track] = []
    @Published var isLoadingTrending = false
    @Published var isLoadingNewReleases = false

    private var cancellables = Set<AnyCancellable>()

    func search(query: String) {
        isLoading = true
        hasSearched = true

        // Search both songs and playlists
        let songsPublisher = APIService.shared.search(query: query, limit: 20)
        let playlistsPublisher = APIService.shared.searchPlaylists(query: query, limit: 10)

        Publishers.Zip(songsPublisher, playlistsPublisher)
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] _ in
                self?.isLoading = false
            }, receiveValue: { [weak self] songs, playlists in
                self?.results = songs
                self?.playlistResults = playlists
            })
            .store(in: &cancellables)
    }

    func loadTrending() {
        isLoadingTrending = true
        APIService.shared.fetchTrending()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] _ in
                self?.isLoadingTrending = false
            }, receiveValue: { [weak self] tracks in
                self?.trendingTracks = tracks
            })
            .store(in: &cancellables)
    }

    func loadNewReleases() {
        isLoadingNewReleases = true
        APIService.shared.fetchNewReleases()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { [weak self] _ in
                self?.isLoadingNewReleases = false
            }, receiveValue: { [weak self] tracks in
                self?.newReleases = tracks
            })
            .store(in: &cancellables)
    }

    func clearSearch() {
        results = []
        playlistResults = []
        hasSearched = false
    }

    func refreshDownloadedIds() {
        let completed = DownloadManager.shared.completedDownloads
        downloadedTrackIds = Set(completed.map { $0.track.videoId })
    }
}

// MARK: - Preview
struct DiscoverView_Previews: PreviewProvider {
    static var previews: some View {
        DiscoverView()
            .preferredColorScheme(.dark)
    }
}
