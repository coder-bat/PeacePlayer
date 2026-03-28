//
//  HomeView.swift
//  YTAudioPlayer
//
//  Cyberpunk minimal home - instant play focused
//

import SwiftUI
import Combine

struct HomeView: View {
    @StateObject private var playerState = PlayerState.shared
    @StateObject private var viewModel = HomeViewModel()
    @State private var showAllRecent = false
    @State private var showAddToPlaylistSheet = false
    @State private var selectedTrack: Track?
    @State private var hasLoaded = false

    var body: some View {
        NavigationView {
            ZStack {
                // Animated background gradient
                CyberBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Minimal header
                        headerSection
                            .padding(.horizontal, 20)
                            .padding(.top, 20)

                        // Hero: Now Playing or Resume
                        heroSection
                            .padding(.horizontal, 20)
                            .padding(.top, 32)

                        // Quick vibes - instant play chips
                        vibesSection
                            .padding(.top, 24)

                        // Recently played - horizontal scroll
                        recentlyPlayedSection
                            .padding(.top, 24)

                        // Minimal stats footer
                        statsFooter
                            .padding(.horizontal, 20)
                            .padding(.top, 32)
                            .padding(.bottom, 100)
                    }
                }
                .refreshable {
                    viewModel.loadData()
                    for _ in 0..<100 {
                        if !viewModel.isLoading { break }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }

                if viewModel.isLoading {
                    ProgressView()
                        .tint(.cyberCyan)
                        .scaleEffect(1.2)
                        .transition(.opacity)
                }
            }
            .navigationBarHidden(true)
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            viewModel.loadData()
        }
        .sheet(isPresented: $showAllRecent) {
            AllRecentlyPlayedView()
        }
        .addToPlaylistSheet(isPresented: $showAddToPlaylistSheet, track: selectedTrack)
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.greeting)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyberDim)
                    .textCase(.uppercase)

                Text("PeacePlayer")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyberCyan)
                    .glow(color: .cyberCyan, radius: 8)
            }

            Spacer()

            // Search button
            CyberButton(icon: "magnifyingglass") {
                NotificationCenter.default.post(name: .switchTab, object: 1)
            }
        }
    }

    // MARK: - Hero Section
    private var heroSection: some View {
        Group {
            if playerState.playbackState.isPlaying, let track = playerState.currentItem?.track {
                // Currently playing - show live player
                NowPlayingHero(track: track, isPlaying: playerState.playbackState.isPlaying) {
                    viewModel.togglePlayPause()
                }
            } else if let lastTrack = viewModel.lastPlayedTrack {
                // Resume last track
                ResumeHero(track: lastTrack) {
                    viewModel.playTrack(lastTrack)
                }
            } else {
                // Empty state - get started
                EmptyHero {
                    NotificationCenter.default.post(name: .switchTab, object: 1)
                }
            }
        }
    }

    // MARK: - Vibes Section
    private var vibesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Quick Vibes")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.cyberDim)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(VibeChip.allCases) { vibe in
                        QuickVibeChip(vibe: vibe) {
                            viewModel.playVibe(vibe)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Recently Played
    private var recentlyPlayedSection: some View {
        Group {
            if !viewModel.recentlyPlayed.isEmpty {
                let recentTracks = Array(viewModel.recentlyPlayed.prefix(20))
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Recently Played")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyberDim)

                        Spacer()

                        if viewModel.recentlyPlayed.count > 20 {
                            Button("View All") {
                                showAllRecent = true
                            }
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.cyberCyan)
                        }
                    }
                    .padding(.horizontal, 20)

                    recentlyPlayedList(tracks: recentTracks)
                }
            }
        }
    }

    @ViewBuilder
    private func recentlyPlayedList(tracks: [Track]) -> some View {
        let baseList = List {
            ForEach(tracks) { track in
                HomeRecentTrackRow(
                    track: track,
                    isDownloaded: viewModel.isDownloaded(track),
                    onPlay: {
                        viewModel.playTrack(track)
                    },
                    onAddToQueue: {
                        viewModel.addToQueue(track)
                    },
                    onAddToPlaylist: {
                        selectedTrack = track
                        showAddToPlaylistSheet = true
                    },
                    onDownload: {
                        viewModel.downloadTrack(track)
                    }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .frame(height: CGFloat(tracks.count) * 76)

        if #available(iOS 16.0, *) {
            baseList
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
        } else {
            baseList
        }
    }

    // MARK: - Stats Footer
    private var statsFooter: some View {
        HStack(spacing: 24) {
            StatItem(value: viewModel.formattedListeningTime, label: "listened")

            Divider()
                .background(Color.cyberDim.opacity(0.3))
                .frame(height: 24)

            StatItem(value: "\(viewModel.downloadCount)", label: "offline")

            Spacer()

            // Library shortcut
            CyberButton(icon: "square.stack") {
                NotificationCenter.default.post(name: .switchTab, object: 3)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.cyberSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.cyberCyan.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

// MARK: - Cyber Background
struct CyberBackground: View {
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        ZStack {
            Color.cyberBackground.ignoresSafeArea()

            // Animated gradient orbs
            GeometryReader { geo in
                ZStack {
                    Circle()
                        .fill(Color.cyberCyan.opacity(0.08))
                        .frame(width: 300, height: 300)
                        .blur(radius: 80)
                        .offset(
                            x: animate ? 50 : -50,
                            y: animate ? -100 : 100
                        )

                    Circle()
                        .fill(Color.cyberMagenta.opacity(0.06))
                        .frame(width: 250, height: 250)
                        .blur(radius: 60)
                        .offset(
                            x: animate ? -80 : 80,
                            y: animate ? 150 : -150
                        )
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                animate.toggle()
            }
        }
    }
}

// MARK: - Now Playing Hero
struct NowPlayingHero: View {
    let track: Track
    let isPlaying: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Glass container
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.cyberSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(
                                LinearGradient(
                                    colors: [.cyberCyan.opacity(0.3), .cyberMagenta.opacity(0.2)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )

                HStack(spacing: 20) {
                    // Artwork with glow
                    ZStack {
                        // Glow effect
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.cyberCyan.opacity(0.3))
                            .blur(radius: 20)
                            .frame(width: 100, height: 100)

                        CachedAsyncImage(url: track.artworkURL) {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.cyberDim.opacity(0.3))
                        }
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Now Playing")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyberCyan)
                            .glow(color: .cyberCyan, radius: 4)

                        Text(track.title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Text(track.displayArtist)
                            .font(.system(size: 14))
                            .foregroundColor(.cyberDim)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        // Visualizer bars
                        CyberPlayingBars()
                            .frame(height: 20)
                            .padding(.top, 8)
                    }

                    Spacer()

                    // Play/Pause
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.cyberCyan)
                        .glow(color: .cyberCyan, radius: 8)
                }
                .padding(20)
            }
        }
        .buttonStyle(.plain)
        .frame(height: 140)
    }
}

// MARK: - Resume Hero
struct ResumeHero: View {
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Gradient background
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyberSurface,
                                Color.cyberSurface.opacity(0.8)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )

                HStack(spacing: 20) {
                    CachedAsyncImage(url: track.artworkURL) {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.cyberDim.opacity(0.3))
                    }
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Resume")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyberDim)

                        Text(track.title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Text(track.displayArtist)
                            .font(.system(size: 14))
                            .foregroundColor(.cyberDim)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    Spacer()

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white)
                }
                .padding(20)
            }
        }
        .buttonStyle(.plain)
        .frame(height: 140)
    }
}

// MARK: - Empty Hero
struct EmptyHero: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.cyberSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.cyberCyan.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [8, 8]))
                    )

                VStack(spacing: 16) {
                    Image(systemName: "waveform")
                        .font(.system(size: 48))
                        .foregroundColor(.cyberCyan)
                        .glow(color: .cyberCyan, radius: 12)

                    Text("Start Listening")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)

                    Text("Search to begin")
                        .font(.system(size: 14))
                        .foregroundColor(.cyberDim)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(height: 180)
    }
}

// MARK: - Vibe Chips
enum VibeChip: String, CaseIterable, Identifiable {
    case focus = "FOCUS"
    case energy = "ENERGY"
    case chill = "CHILL"
    case workout = "WORKOUT"
    case sleep = "DREAM"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .focus: return "brain.head.profile"
        case .energy: return "bolt.fill"
        case .chill: return "leaf.fill"
        case .workout: return "figure.run"
        case .sleep: return "moon.fill"
        }
    }

    var color: Color {
        switch self {
        case .focus: return .cyberCyan
        case .energy: return .cyberYellow
        case .chill: return .cyberMagenta
        case .workout: return .red
        case .sleep: return .purple
        }
    }

    var query: String {
        switch self {
        case .focus: return "lofi focus study beats"
        case .energy: return "electronic dance edm energy"
        case .chill: return "chill relax ambient"
        case .workout: return "workout gym motivation"
        case .sleep: return "sleep ambient calm"
        }
    }
}

struct QuickVibeChip: View {
    let vibe: VibeChip
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: vibe.icon)
                    .font(.system(size: 14, weight: .semibold))

                Text(vibe.rawValue)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .foregroundColor(vibe.color)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(Color.cyberSurface)
                    .overlay(
                        Capsule()
                            .stroke(vibe.color.opacity(0.4), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Minimal Track Card
struct MinimalTrackCard: View {
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                CachedAsyncImage(url: track.artworkURL) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.cyberDim.opacity(0.2))
                }
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(track.displayArtist)
                        .font(.system(size: 12))
                        .foregroundColor(.cyberDim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: 140, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cyber Button
struct CyberButton: View {
    let icon: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.cyberCyan)
                .frame(width: 44, height: 44)
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
}

// MARK: - Stat Item
struct StatItem: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.cyberCyan)

            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.cyberDim)
                .textCase(.uppercase)
        }
    }
}


// MARK: - Glow Modifier
struct GlowModifier: ViewModifier {
    let color: Color
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.5), radius: radius / 2, x: 0, y: 0)
            .shadow(color: color.opacity(0.3), radius: radius, x: 0, y: 0)
    }
}

extension View {
    func glow(color: Color, radius: CGFloat) -> some View {
        modifier(GlowModifier(color: color, radius: radius))
    }
}

// MARK: - View Model
class HomeViewModel: ObservableObject {
    @Published var greeting = " SYNC "
    @Published var lastPlayedTrack: Track?
    @Published var recentlyPlayed: [Track] = []
    @Published var downloadCount = 0
    @Published var totalListeningTime: TimeInterval = 0
    @Published var isLoading = true

    private let dataManager = DataManager.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        dataManager.$recentlyPlayed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadData()
            }
            .store(in: &cancellables)
    }

    func loadData() {
        updateGreeting()
        recentlyPlayed = dataManager.recentlyPlayed.map { $0.toTrack }
        lastPlayedTrack = dataManager.recentlyPlayed.first?.toTrack
        totalListeningTime = dataManager.totalListeningSeconds

        APIService.shared.fetchLibrary()
            .sink(receiveCompletion: { [weak self] _ in
                self?.isLoading = false
            },
                  receiveValue: { [weak self] tracks in
                self?.downloadCount = tracks.count
            })
            .store(in: &cancellables)
    }

    private func updateGreeting() {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: greeting = " MORNING "
        case 12..<17: greeting = " AFTERNOON "
        case 17..<22: greeting = " EVENING "
        default: greeting = " NIGHT "
        }
    }

    var formattedListeningTime: String {
        let hours = Int(totalListeningTime) / 3600
        if hours > 0 {
            return "\(hours)h"
        } else {
            let minutes = Int(totalListeningTime) / 60
            return "\(minutes)m"
        }
    }

    func playTrack(_ track: Track) {
        APIService.shared.getStreamUrl(videoId: track.videoId)
            .handleErrors(with: .shared, retry: { [weak self] in
                self?.playTrack(track)
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

    func isDownloaded(_ track: Track) -> Bool {
        DownloadManager.shared.isAlreadyDownloaded(track)
    }

    func togglePlayPause() {
        PlayerState.shared.togglePlayPause()
    }

    func playVibe(_ vibe: VibeChip) {
        APIService.shared.search(query: vibe.query, limit: 10)
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    ErrorHandler.shared.handleAPIError(error)
                }
            }, receiveValue: { [weak self] tracks in
                guard let self = self, !tracks.isEmpty else { return }

                self.playTrack(tracks[0])

                for track in tracks.dropFirst() {
                    APIService.shared.getStreamUrl(videoId: track.videoId)
                        .sink(receiveCompletion: { _ in },
                              receiveValue: { streamInfo in
                            let item = QueueItem(
                                track: track,
                                streamUrl: streamInfo.streamUrl,
                                source: .stream
                            )
                            PlayerState.shared.addToQueue(item)
                        })
                        .store(in: &self.cancellables)
                }

                // Haptic feedback
                HapticManager.medium()
            })
            .store(in: &cancellables)
    }
}

struct HomeRecentTrackRow: View {
    let track: Track
    let isDownloaded: Bool
    let onPlay: () -> Void
    let onAddToQueue: () -> Void
    let onAddToPlaylist: () -> Void
    let onDownload: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: track.artworkURL) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.cyberDim.opacity(0.3))
                }
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(track.displayArtist)
                        .font(.system(size: 14))
                        .foregroundColor(.cyberDim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer()

                if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.cyberCyan)
                }

                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.cyberCyan)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle()
                            .fill(Color.cyberSurface)
                            .overlay(
                                Circle()
                                    .stroke(Color.cyberCyan.opacity(0.3), lineWidth: 1)
                            )
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.cyberSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.cyberCyan.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(action: onAddToQueue) {
                Label("Queue", systemImage: "text.badge.plus")
            }
            .tint(.orange)

            Button(action: onAddToPlaylist) {
                Label("Playlist", systemImage: "music.note.list")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: onDownload) {
                Label(isDownloaded ? "Downloaded" : "Download", systemImage: isDownloaded ? "checkmark" : "arrow.down")
            }
            .tint(.cyberCyan)
            .disabled(isDownloaded)
        }
    }
}

// MARK: - All Recently Played View
struct AllRecentlyPlayedView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        NavigationView {
            ZStack {
                Color.cyberBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Play / Shuffle action buttons
                    if !viewModel.recentlyPlayed.isEmpty {
                        HStack(spacing: 16) {
                            Button(action: {
                                HapticManager.medium()
                                viewModel.playTrack(viewModel.recentlyPlayed[0])
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("PLAY")
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                }
                                .foregroundColor(.cyberBackground)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color.cyberCyan)
                                .cornerRadius(8)
                                .shadow(color: Color.cyberCyan.opacity(0.5), radius: 12, x: 0, y: 0)
                            }

                            Button(action: {
                                HapticManager.medium()
                                let shuffled = viewModel.recentlyPlayed.shuffled()
                                viewModel.playTrack(shuffled[0])
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "shuffle")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("SHUFFLE")
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                }
                                .foregroundColor(.cyberCyan)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color.cyberSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.cyberCyan.opacity(0.5), lineWidth: 1)
                                )
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .background(Color.cyberBackground)
                    }

                    List {
                        ForEach(viewModel.recentlyPlayed) { track in
                            Button {
                                viewModel.playTrack(track)
                            } label: {
                                HStack(spacing: 12) {
                                    CachedAsyncImage(url: track.artworkURL) {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.cyberDim.opacity(0.3))
                                    }
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(track.title)
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)

                                        Text(track.displayArtist)
                                            .font(.system(size: 14))
                                            .foregroundColor(.cyberDim)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.8)
                                    }

                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.cyberSurface)
                        }
                    }
                    .listStyle(.plain)
                    .background(Color.cyberBackground)
                }
            }
            .navigationTitle("Recently Played")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.cyberCyan)
                }
            }
            .onAppear {
                viewModel.loadData()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Preview
struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
            .preferredColorScheme(.dark)
    }
}
