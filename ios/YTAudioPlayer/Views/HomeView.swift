//
//  HomeView.swift
//  YTAudioPlayer
//
//  Cyberpunk minimal home - instant play focused
//

import SwiftUI
import Combine

// MARK: - All Recently Played View
struct AllRecentlyPlayedView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cyberBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Play / Shuffle action buttons
                    if !viewModel.recentlyPlayed.isEmpty {
                        HStack(spacing: Spacing.md) {
                            Button(action: {
                                HapticManager.medium()
                                viewModel.playTrack(viewModel.recentlyPlayed[0])
                            }) {
                                HStack(spacing: Spacing.xxs) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: IconSize.sm, weight: .semibold))
                                    Text("PLAY")
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                }
                                .foregroundColor(Theme.cyberBackground)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Theme.cyberCyan)
                                .cornerRadius(CornerRadius.sm)
                                .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 12, x: 0, y: 0)
                            }

                            Button(action: {
                                HapticManager.medium()
                                let shuffled = viewModel.recentlyPlayed.shuffled()
                                viewModel.playTrack(shuffled[0])
                            }) {
                                HStack(spacing: Spacing.xxs) {
                                    Image(systemName: "shuffle")
                                        .font(.system(size: IconSize.sm, weight: .semibold))
                                    Text("SHUFFLE")
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                }
                                .foregroundColor(Theme.cyberCyan)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Theme.cyberSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: CornerRadius.sm)
                                        .stroke(Theme.cyberCyan.opacity(0.5), lineWidth: 1)
                                )
                                .cornerRadius(CornerRadius.sm)
                            }
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(Theme.cyberBackground)
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

// S14: Navigation destinations accessible from the Home page header
// chip cluster. The Home tab owns its own NavigationStack; tapping
// Settings / Playlists / Radio chips pushes the destination into that
// stack so swipe-from-edge back gesture works (instead of a modal
// sheet that lacked nav chrome and looked like a "black bar").
enum HomeDestination: Hashable {
    case settings
    case playlists
    case radio
}

struct HomeView: View {
    @StateObject private var playerState = PlayerState.shared
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var favoriteArtists = FavoriteArtistsManager.shared
    @StateObject private var profile = UserProfile.shared
    @State private var showAllRecent = false
    @State private var showAddToPlaylistSheet = false
    @State private var showAvatarPicker = false
    @State private var selectedTrack: Track?
    @State private var hasLoaded = false
    // S14: path for Home's NavigationStack. Pushing onto this path
    // animates the destination view in from the right and gives it a
    // standard nav bar with a back button — replaces the previous
    // modal-sheet behavior.
    @State private var path: [HomeDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                // Animated background gradient
                CyberBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // 2026-06-28 (S6): top header — user profile chip
                        // (avatar + name) on the left, nav icons on the right.
                        headerSection
                            .padding(.horizontal, 20)
                            .padding(.top, 20)

                        // Hero: Now Playing or Resume (upgraded futuristic styling)
                        heroSection
                            .padding(.horizontal, 20)
                            .padding(.top, 28)

                        // FOR YOU - Favorite artists suggestions
                        favoriteArtistsSection
                            .padding(.top, 24)

                        // Recently played - horizontal scroll (with context menu per row)
                        recentlyPlayedSection
                            .padding(.top, 24)
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
            // S14: hide the standard nav bar on Home itself (the
            // headerSection is the custom chrome). When a destination
            // pushes onto the stack, that destination shows its own
            // nav bar with a back button.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HomeDestination.self) { destination in
                switch destination {
                case .settings:
                    SettingsView()
                case .playlists:
                    PlaylistsView()
                case .radio:
                    RadioView(viewModel: RadioViewModel())
                }
            }
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            viewModel.loadData()
        }
        .sheet(isPresented: $showAllRecent) {
            AllRecentlyPlayedView()
        }
        .sheet(isPresented: $showAvatarPicker) {
            AvatarPickerSheet()
        }
        .addToPlaylistSheet(isPresented: $showAddToPlaylistSheet, track: selectedTrack)
        // S15: when "Start Radio" fires from any track-row context
        // menu, ContentView kicks off playback and switches to the
        // Home tab. Push RadioView onto this NavigationStack so the
        // user actually sees the radio. (Previously the destination
        // was unreachable from outside — ContentView tried to switch
        // to a non-existent tab 5.)
        .onReceive(NotificationCenter.default.publisher(for: .startSongRadio)) { _ in
            if !path.contains(.radio) {
                path.append(.radio)
            }
        }
        // S15: OrbitalMenu's "Radio" item (which used to silently
        // set selectedTab = 5) now posts `.openRadioView`. Push
        // the same destination.
        .onReceive(NotificationCenter.default.publisher(for: .openRadioView)) { _ in
            if !path.contains(.radio) {
                path.append(.radio)
            }
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack(spacing: 10) {
            // 2026-06-28 (S6): profile chip replaces the static
            // "Afternoon PeacePlayer" greeting. Tapping the chip
            // opens the avatar picker. Shows the user's chosen
            // avatar + display name (or "Set up profile" if no
            // name is set yet).
            profileChip

            Spacer()

            // Top-right nav icons: Search, Radio, Playlists, Settings
            // S14: each chip is wrapped in either a Button (Search, for
            // a side-effect) or a NavigationLink (Radio / Playlists /
            // Settings, to push into Home's stack). CyberIconChip is
            // a pure visual so the outer wrapper's gesture handler
            // fires reliably — previously the inner Button wrapper
            // ate the tap and the NavigationLink never fired.
            HStack(spacing: 8) {
                Button {
                    NotificationCenter.default.post(name: .switchTab, object: 1)
                } label: {
                    CyberIconChip(icon: "magnifyingglass")
                }
                .buttonStyle(.plain)

                NavigationLink(value: HomeDestination.radio) {
                    CyberIconChip(icon: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(.plain)

                NavigationLink(value: HomeDestination.playlists) {
                    CyberIconChip(icon: "music.note.list")
                }
                .buttonStyle(.plain)

                NavigationLink(value: HomeDestination.settings) {
                    CyberIconChip(icon: "gearshape.fill")
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Profile chip
    private var profileChip: some View {
        Button {
            showAvatarPicker = true
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Theme.cyberCyan.opacity(0.18))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Circle()
                                .stroke(Theme.cyberCyan.opacity(0.4), lineWidth: 1)
                        )
                    Image(systemName: profile.avatarSymbolName)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundColor(.cyberCyan)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.greeting)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.cyberDim)
                        .textCase(.uppercase)
                    Text(profile.displayName ?? "Set up profile")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hero Section
    private var heroSection: some View {
        // 2026-06-28 (S7): single design for both playing and
        // resume states. The block itself stays the same; only the
        // state label ("NOW PLAYING" / "PAUSED" / "RESUME"), the
        // right-side icon, and the equalizer animation change.
        Group {
            if let track = playerState.currentItem?.track {
                NowPlayingHero(
                    track: track,
                    state: playerState.playbackState,
                    onTap: { viewModel.togglePlayPause() }
                )
            } else if let lastTrack = viewModel.lastPlayedTrack {
                // S11 fix (Bug 8): the local lookup has to happen
                // outside the ViewBuilder (`let` and `print` aren't
                // allowed inside `Group { }`). Read the saved progress
                // for the last-played track from DataManager.
                ResumeBlockContent(
                    viewModel: viewModel,
                    lastTrack: lastTrack
                )
            } else {
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
                .font(Typography.sectionHeader)
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

    // MARK: - Favorite Artists Section (FOR YOU)
    private var favoriteArtistsSection: some View {
        Group {
            if !favoriteArtists.isEmpty && !viewModel.artistSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("FOR YOU")
                        .font(Typography.sectionHeader)
                        .foregroundColor(.cyberCyan)
                        .padding(.horizontal, 20)

                    ForEach(favoriteArtists.getArtists(), id: \.self) { artist in
                        if let tracks = viewModel.artistSuggestions[artist], !tracks.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(artist.uppercased())
                                        .font(Typography.eyebrow)
                                        .foregroundColor(.cyberMagenta)

                                    Spacer()

                                    Button {
                                        HapticManager.light()
                                        viewModel.playVibeTracks(tracks)
                                    } label: {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.cyberCyan)
                                            .frame(width: 28, height: 28)
                                            .background(Color.cyberSurface)
                                            .cornerRadius(6)
                                    }

                                    Button {
                                        HapticManager.light()
                                        viewModel.playVibeTracks(tracks.shuffled())
                                    } label: {
                                        Image(systemName: "shuffle")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.cyberMagenta)
                                            .frame(width: 28, height: 28)
                                            .background(Color.cyberSurface)
                                            .cornerRadius(6)
                                    }
                                }
                                .padding(.horizontal, 20)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 14) {
                                        ForEach(tracks) { track in
                                            ArtistSuggestionCard(track: track) {
                                                viewModel.playTrack(track)
                                            } onPlayNext: {
                                                viewModel.playTrack(track)
                                                PlayerState.shared.addToQueue(PlayerState.shared.currentItem!)
                                            } onAddToQueue: {
                                                viewModel.addToQueue(track)
                                            } onAddToPlaylist: {
                                                selectedTrack = track
                                                showAddToPlaylistSheet = true
                                            } onDownload: {
                                                viewModel.downloadTrack(track)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recently Played
    private var recentlyPlayedSection: some View {
        // S13: Previously the entire Recently Played section silently
        // disappeared when the user had no listening history. New users
        // saw a wall of mostly-empty sections. Now we show a small
        // "Get started" empty state instead, suggesting they tap a
        // search tab to explore.
        Group {
            if viewModel.recentlyPlayed.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recently Played")
                        .font(Typography.sectionHeader)
                        .foregroundColor(.cyberDim)
                        .padding(.horizontal, 20)

                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 36, weight: .light))
                            .foregroundColor(.cyberDim.opacity(0.7))
                        Text("Nothing here yet")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Tracks you play will show up here")
                            .font(.system(size: 12))
                            .foregroundColor(.cyberDim.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .padding(.horizontal, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.cyberSurface.opacity(0.4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.cyberDim.opacity(0.2), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 20)
                }
            } else {
                let recentTracks = Array(viewModel.recentlyPlayed.prefix(20))
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Recently Played")
                            .font(Typography.sectionHeader)
                            .foregroundColor(.cyberDim)

                        Spacer()

                        if viewModel.recentlyPlayed.count > 20 {
                            Button("View All") {
                                showAllRecent = true
                            }
                            .font(Typography.eyebrow)
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
        let rowHeight: CGFloat = 64
        let contentHeight = CGFloat(tracks.count) * rowHeight

        let baseList = List {
            ForEach(tracks) { track in
                let isCurrentTrack = playerState.currentItem?.track.videoId == track.videoId
                let isPlaying = isCurrentTrack && playerState.playbackState == .playing
                let isLoading = isCurrentTrack && (playerState.playbackState == .loading || playerState.playbackState == .buffering)

                HomeRecentTrackRow(
                    track: track,
                    isDownloaded: viewModel.isDownloaded(track),
                    isPlaying: isPlaying,
                    isLoading: isLoading,
                    onPlay: {
                        viewModel.playTrack(track)
                    },
                    onPlayNext: {
                        HapticManager.light()
                        viewModel.addToQueue(track)
                    },
                    onDownload: {
                        HapticManager.light()
                        viewModel.downloadTrack(track)
                    },
                    onAddToQueue: {
                        HapticManager.light()
                        viewModel.addToQueue(track)
                    },
                    onAddToPlaylist: {
                        HapticManager.light()
                        selectedTrack = track
                        showAddToPlaylistSheet = true
                    },
                    onStartRadio: {
                        HapticManager.light()
                        NotificationCenter.default.post(
                            name: .startSongRadio,
                            object: track
                        )
                    }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .frame(height: contentHeight)

        if #available(iOS 16.0, *) {
            baseList
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .task(id: tracks.map(\.videoId)) {
                    StreamURLCache.shared.prefetchBatch(videoIds: tracks.prefix(5).map(\.videoId))
                }
        } else {
            baseList
                .task(id: tracks.map(\.videoId)) {
                    StreamURLCache.shared.prefetchBatch(videoIds: tracks.prefix(5).map(\.videoId))
                }
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

/// S11 fix (Bug 8): wraps the resume-block UI in a struct so we
/// can do non-view work (DataManager lookup, print, optionally
/// debounce) outside the parent's @ViewBuilder. SwiftUI ViewBuilder
/// only accepts View expressions; it can't run `let` declarations
/// or free-form `print` calls without a wrapper.
struct ResumeBlockContent: View {
    let viewModel: HomeViewModel
    let lastTrack: Track

    var body: some View {
        let savedProgress = DataManager.shared.recentlyPlayed
            .first(where: { $0.videoId == lastTrack.videoId })?
            .playbackProgress
        let _ = {
            print("▶️ [S11] resume block: lastTrack=\(lastTrack.title) savedProgress=\(savedProgress ?? -1)")
        }()
        return NowPlayingHero(
            track: lastTrack,
            state: .idle,
            onTap: {
                viewModel.playTrack(lastTrack, seekToProgress: savedProgress)
            }
        )
    }
}

struct NowPlayingHero: View {
    let track: Track
    /// .playing shows the equalizer animation + pause icon.
    /// .paused shows static bars + play icon.
    /// .idle (no track loaded) shows a hint that the user can tap to play.
    let state: PlaybackState
    let onTap: () -> Void
    @StateObject private var playerState = PlayerState.shared
    @State private var pulse = false

    private var statusLabel: String {
        switch state {
        case .playing: return "NOW PLAYING"
        case .paused:  return "PAUSED"
        case .loading, .buffering: return "LOADING"
        case .idle: return "RESUME"
        case .error: return "ERROR"
        @unknown default: return "RESUME"
        }
    }

    private var rightIcon: String {
        switch state {
        case .playing: return "pause.fill"
        default:        return "play.fill"
        }
    }

    private var isAnimating: Bool { state == .playing }

    var body: some View {
        // 2026-06-28 (S8): the outer button opens the full player.
        // The play/pause button inside the card handles its own
        // play/pause action. SwiftUI gives inner buttons priority
        // over outer ones in hit-testing, so the layout works.
        Button {
            // 2026-06-28 (S8): post a notification that ContentView
            // listens for and uses to set showFullPlayer = true.
            // We post rather than passing a binding down to keep
            // NowPlayingHero self-contained.
            NotificationCenter.default.post(name: .openFullPlayer, object: nil)
        } label: {
            ZStack {
                // Glass + gradient surface — same in all states.
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.cyberSurface,
                                Color.cyberSurface.opacity(0.6)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        // Animated neon border that pulses (only when
                        // actually playing, to draw the eye).
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        .cyberCyan.opacity(pulse && isAnimating ? 0.9 : 0.35),
                                        .cyberMagenta.opacity(pulse && isAnimating ? 0.55 : 0.25)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(color: .cyberCyan.opacity(pulse && isAnimating ? 0.5 : 0.18), radius: pulse && isAnimating ? 18 : 8, x: 0, y: 0)

                HStack(spacing: 14) {
                    // Compact artwork with corner glow
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.cyberCyan.opacity(0.25))
                            .blur(radius: 14)
                            .frame(width: 72, height: 72)
                            .opacity(isAnimating && pulse ? 0.9 : 0.5)

                        CachedAsyncImage(url: track.artworkURL) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.cyberDim.opacity(0.3))
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        // State label (NOW PLAYING / PAUSED / RESUME)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(state == .playing ? Color.cyberCyan : Color.cyberMagenta)
                                .frame(width: 6, height: 6)
                                .shadow(color: state == .playing ? Color.cyberCyan : Color.cyberMagenta, radius: 4)
                            Text(statusLabel)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(state == .playing ? .cyberCyan : .cyberMagenta)
                                .tracking(2)
                        }

                        Text(track.title)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Text(track.displayArtist)
                            .font(.system(size: 12))
                            .foregroundColor(.cyberDim)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        // Equalizer — animates when playing, static when paused
                        ResumeBarsIndicator(animating: isAnimating)
                            .frame(height: 14)
                            .padding(.top, 4)
                    }

                    Spacer(minLength: 8)

                    // 2026-06-28 (S8): the right-side play/pause
                    // button is its own tappable control. Tapping it
                    // toggles play/pause; tapping the rest of the
                    // card opens the full player.
                    //
                    // 2026-06-29 (S9d): SwiftUI's nested Button
                    // behavior was the cause of "tap does nothing"
                    // on the inner button — when the inner Button
                    // shares its action with the outer Button, the
                    // hit-testing sometimes routes to the outer.
                    // We use a tap gesture with a clear content
                    // shape on the inner button, which guarantees
                    // the inner tap fires (the outer Button does
                    // NOT see the tap inside the inner's content
                    // shape).
                    ZStack {
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [.cyberCyan, .cyberMagenta],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                            .frame(width: 52, height: 52)
                        Image(systemName: rightIcon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.cyberCyan)
                            .offset(x: rightIcon == "play.fill" ? 1.5 : 0)
                    }
                    .contentShape(Circle())
                    .onTapGesture {
                        HapticManager.light()
                        // 2026-06-29 (S9d): log so we can see the
                        // play flow in the console.
                        print("▶️ [S9d] NowPlayingHero play button tapped, state=\(state), track=\(track.title)")
                        onTap()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .buttonStyle(.plain)
        .frame(height: 96)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Resume Hero

// MARK: - Resume Bars Indicator
// 2026-06-28 (S7): takes an `animating` flag. When true the bars
// pulse in a wave; when false they sit at a static mid-height so
// the resume/paused state is visually distinct from playing.
struct ResumeBarsIndicator: View {
    let animating: Bool
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(LinearGradient(
                        colors: [.cyberCyan, .cyberMagenta],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .frame(width: 3, height: (animate && animating) ? 14 : 5)
                    .animation(
                        reduceMotion ? .none : Animation.easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.12),
                        value: animate && animating
                    )
            }
        }
        .onAppear { if !reduceMotion { animate = true } }
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

// MARK: - Artist Suggestion Card
struct ArtistSuggestionCard: View {
    let track: Track
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onAddToPlaylist: () -> Void
    let onDownload: () -> Void

    @StateObject private var playlistManager = PlaylistManager.shared

    private var isLiked: Bool {
        playlistManager.isLiked(trackId: track.videoId)
    }

    private var isDownloaded: Bool {
        DownloadManager.shared.isAlreadyDownloaded(track)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CachedAsyncImage(url: track.artworkURL) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cyberDim.opacity(0.2))
            }
            .frame(width: 130, height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(
                            colors: [.cyberCyan.opacity(0.6), .cyberMagenta.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: .cyberCyan.opacity(0.3), radius: 8, x: 0, y: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Text(track.displayArtist)
                    .font(.system(size: 11))
                    .foregroundColor(.cyberDim)
                    .lineLimit(1)
            }
            .frame(width: 130, alignment: .leading)
        }
        .contextMenu {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
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
            Button {
                playlistManager.toggleLike(trackId: track.videoId)
                HapticManager.medium()
            } label: {
                Label(isLiked ? "Unlike" : "Like", systemImage: isLiked ? "heart.fill" : "heart")
            }
            Button(action: onDownload) {
                Label(isDownloaded ? "Downloaded" : "Download", systemImage: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
            }
        }
        .swipeActions(edge: .trailing) {
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

// MARK: - Cyber Icon Chip (compact header icon)
struct CyberIconChip: View {
    let icon: String

    // S14: CyberIconChip is now a pure visual (no Button wrapper).
    // Previously it wrapped its content in a `Button(action: onTap)`,
    // which meant a NavigationLink with this chip as its label
    // couldn't navigate — the inner Button's gesture handler ate
    // the tap before the NavigationLink saw it. Callers now wrap
    // the chip themselves: in a `Button` for actions, or in a
    // `NavigationLink` for pushes.
    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.cyberCyan)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.cyberSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.cyberCyan.opacity(0.25), lineWidth: 1)
                    )
            )
            .accessibilityLabel(Text(accessibilityLabel))
    }

    private var accessibilityLabel: String {
        switch icon {
        case "magnifyingglass": return "Search"
        case "antenna.radiowaves.left.and.right": return "Radio"
        case "music.note.list": return "Playlists"
        case "gearshape.fill": return "Settings"
        default: return icon
        }
    }
}

// MARK: - Stat Item
struct StatItem: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Typography.playerTitle)
                .foregroundColor(Theme.cyberCyan)

            Text(label)
                .font(Typography.caption2)
                .foregroundColor(Theme.cyberDim)
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
    @Published var artistSuggestions: [String: [Track]] = [:]

    private let dataManager = DataManager.shared
    private let favoriteArtists = FavoriteArtistsManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var vibeCancellables = Set<AnyCancellable>()
    private var suggestionCancellables = Set<AnyCancellable>()

    init() {
        dataManager.$recentlyPlayed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadData()
            }
            .store(in: &cancellables)

        favoriteArtists.$artists
            .receive(on: DispatchQueue.main)
            .sink { [weak self] artists in
                self?.fetchSuggestionsForFavoriteArtists(artists)
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
        case 5..<12: greeting = "MORNING"
        case 12..<17: greeting = "AFTERNOON"
        case 17..<22: greeting = "EVENING"
        default: greeting = "NIGHT"
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

    @MainActor
    func playTrack(_ track: Track, seekToProgress progress: Double? = nil) {
        // 2026-06-29 (S9d): log so we can see the play flow in the
        // console when the user reports "tap does nothing".
        print("▶️ [S9d] playTrack ENTRY track=\(track.title) videoId=\(track.videoId) seekToProgress=\(progress ?? -1)")

        // Show loading indicator immediately before fetching stream URL
        let loadingItem = QueueItem(
            track: track,
            streamUrl: "",
            source: .stream
        )
        PlayerState.shared.currentItem = loadingItem
        PlayerState.shared.playbackState = .loading

        StreamURLCache.shared.getStreamUrl(videoId: track.videoId)
            .handleErrors(with: .shared, retry: { [weak self] in
                print("▶️ [S9e] playTrack: getStreamUrl failed, retrying")
                self?.playTrack(track, seekToProgress: progress)
            })
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    print("▶️ [S9e] playTrack: stream URL FAILED for \(track.title): \(error)")
                }
            },
                  receiveValue: { streamInfo in
                print("▶️ [S9e] playTrack: stream URL received for \(track.title), calling play()")
                let item = QueueItem(
                    track: track,
                    streamUrl: streamInfo.streamUrl,
                    source: .stream
                )
                PlayerState.shared.play(item: item)
                // S11 fix (Bug 8): seek to saved progress if the caller
                // passed one (e.g., resume block tapping the most-
                // recently-played track at its last-known position).
                if let p = progress, p > 0.02, p < 0.98 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        print("▶️ [S11] playTrack: seeking to progress \(p)")
                        PlayerState.shared.seek(to: p)
                    }
                }
            })
            .store(in: &cancellables)
    }

    func addToQueue(_ track: Track) {
        StreamURLCache.shared.getStreamUrl(videoId: track.videoId)
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

                Task { @MainActor in
                    self.playTrack(tracks[0])
                }

                self.vibeCancellables.removeAll()
                for track in tracks.dropFirst() {
                    StreamURLCache.shared.getStreamUrl(videoId: track.videoId)
                        .sink(receiveCompletion: { completion in
                            if case .failure(let error) = completion {
                                print("⚠️ [HomeView] Stream URL failed: \(error.localizedDescription)")
                            }
                        }, receiveValue: { streamInfo in
                            let item = QueueItem(
                                track: track,
                                streamUrl: streamInfo.streamUrl,
                                source: .stream
                            )
                            PlayerState.shared.addToQueue(item)
                        })
                        .store(in: &self.vibeCancellables)
                }

                // Haptic feedback
                HapticManager.medium()
            })
            .store(in: &cancellables)
    }

    func playVibeTracks(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }

        vibeCancellables.removeAll()

        Task { @MainActor in
            self.playTrack(tracks[0])
        }

        for track in tracks.dropFirst() {
            StreamURLCache.shared.getStreamUrl(videoId: track.videoId)
                .sink(receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        print("⚠️ [HomeView] Stream URL failed: \(error.localizedDescription)")
                    }
                }, receiveValue: { streamInfo in
                    let item = QueueItem(
                        track: track,
                        streamUrl: streamInfo.streamUrl,
                        source: .stream
                    )
                    PlayerState.shared.addToQueue(item)
                })
                .store(in: &vibeCancellables)
        }

        HapticManager.medium()
    }

    func fetchSuggestionsForFavoriteArtists(_ artists: [String]) {
        suggestionCancellables.removeAll()
        artistSuggestions.removeAll()

        for artist in artists {
            APIService.shared.search(query: artist, limit: 5)
                .sink(receiveCompletion: { _ in },
                      receiveValue: { [weak self] tracks in
                    guard let self = self, !tracks.isEmpty else { return }
                    DispatchQueue.main.async {
                        self.artistSuggestions[artist] = tracks
                    }
                })
                .store(in: &suggestionCancellables)
        }
    }
}

// MARK: - Playing Bars Indicator

struct PlayingBarsIndicator: View {
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.cyberCyan)
                    .frame(width: 3, height: animate ? 16 : 6)
                    .animation(
                        reduceMotion ? .none : Animation.easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .frame(width: 30, height: 30)
        .onAppear {
            if !reduceMotion {
                animate = true
            }
        }
    }
}

struct HomeRecentTrackRow: View {
    let track: Track
    let isDownloaded: Bool
    let isPlaying: Bool
    let isLoading: Bool
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onDownload: () -> Void
    // 2026-06-28: context menu actions. The row already had swipe
    // actions; long-press context menu gives parity on iPad and on
    // devices where swipe isn't discoverable.
    let onAddToQueue: () -> Void
    let onAddToPlaylist: () -> Void
    let onStartRadio: () -> Void

    @StateObject private var playlistManager = PlaylistManager.shared

    private var isLiked: Bool {
        playlistManager.isLiked(trackId: track.videoId)
    }

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

                // Play indicator cluster
                HStack(spacing: 8) {
                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.cyberCyan)
                    }

                    // Playing/Loading indicator
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(.cyberCyan)
                    } else if isPlaying {
                        PlayingBarsIndicator()
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.cyberCyan)
                    }
                }
                .frame(width: 36)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            // 2026-06-28: long-press menu for parity with the
            // recently-played list. Order matches iOS Music app
            // convention: play actions first, queue, library, like,
            // download, share at the bottom.
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
            }
            Button(action: onPlayNext) {
                Label("Play Next", systemImage: "text.badge.plus")
            }
            Button(action: onAddToQueue) {
                Label("Add to Queue", systemImage: "plus")
            }
            Button(action: onStartRadio) {
                Label("Start Radio", systemImage: "antenna.radiowaves.left.and.right")
            }
            Divider()
            Button(action: onAddToPlaylist) {
                Label("Add to Playlist", systemImage: "music.note.list")
            }
            Button {
                playlistManager.toggleLike(trackId: track.videoId)
                HapticManager.medium()
            } label: {
                Label(isLiked ? "Unlike" : "Like", systemImage: isLiked ? "heart.fill" : "heart")
            }
            Button(action: onDownload) {
                Label(isDownloaded ? "Downloaded" : "Download", systemImage: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(action: onPlayNext) {
                Label("Next", systemImage: "text.badge.plus")
            }
            .tint(Theme.cyberMagenta)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(action: onDownload) {
                Label(isDownloaded ? "Downloaded" : "Download", systemImage: isDownloaded ? "checkmark" : "arrow.down")
            }
            .tint(Theme.cyberCyan)
            .disabled(isDownloaded)
        }
    }
}

// MARK: - Preview
struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
            .preferredColorScheme(.dark)
    }
}
