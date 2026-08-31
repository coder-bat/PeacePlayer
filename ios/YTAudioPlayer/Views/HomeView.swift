//
//  HomeView.swift
//  YTAudioPlayer
//
//  Cyberpunk minimal home - instant play focused
//

import SwiftUI
import Combine

// S14: Navigation destinations accessible from the Home page header
// chip cluster. The Home tab owns its own NavigationStack; tapping
// Settings / Playlists / Radio chips pushes the destination into that
// stack so swipe-from-edge back gesture works (instead of a modal
// sheet that lacked nav chrome and looked like a "black bar").
enum HomeDestination: Hashable {
    case settings
    case playlists
    case radio
    // S18 / P1-1: the two most distinctive features get
    // dedicated home-header chips. Without these the user has to
    // know the long-press / OrbitalMenu gesture in FullPlayer to
    // find them, which most users don't.
    case timeCapsule
    case antiAlgorithm
    // 2026-08-12: "View all" links from the Your Library
    // section on Home. Pushed onto Home's NavigationStack so the
    // swipe-from-edge back gesture works (vs. a tab switch,
    // which loses context).
    case likedSongs
    case library
}

struct HomeView: View {
    @StateObject private var playerState = PlayerState.shared
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var favoriteArtists = FavoriteArtistsManager.shared
    @StateObject private var profile = UserProfile.shared
    // 2026-08-12: observed here so the Your Library section on
    // Home updates the moment the user likes / unlikes a track
    // from FullPlayer, MiniPlayer, or any context menu. Same
    // pattern as LibraryView (which observes PlaylistManager to
    // keep its Liked segment in sync).
    @StateObject private var playlistManager = PlaylistManager.shared
    // 2026-08-12: separate LibraryViewModel instance so the Home
    // "Downloaded" sub-section reads CoreData + DownloadManager
    // changes. Both this and LibraryView's instance hit the same
    // CoreData store (PersistenceController.shared is a
    // singleton) so the data is consistent, but each view
    // owns its own @Published state to avoid cross-view
    // coupling.
    @StateObject private var libraryVM = LibraryViewModel()
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

                        // S18 / P1-3: "On this day in your music" —
                        // tracks the user played on this calendar day
                        // in prior years. Gives a daily re-entry reason.
                        // Gated by ff_on_this_day flag (default OFF
                        // for v1.5; can flip in Settings → Labs later).
                        if UserDefaults.standard.object(forKey: "ff_on_this_day") as? Bool ?? false {
                            OnThisDaySection()
                                .padding(.top, 24)
                        }

                        // 2026-08-30: v1.9.0 Smart Library
                        // card. Appears only when
                        // SmartLibraryManager.pendingCandidates
                        // is non-nil (the manager is the source
                        // of truth — the card self-hides when
                        // there's nothing to show). Placed
                        // above the "Your Library" section so
                        // the user sees the actionable surface
                        // first.
                        SmartLibraryCard()
                            .padding(.top, Spacing.lg)

                        // 2026-08-12: replaced the broken nested-List
                        // recently played section (which couldn't
                        // scroll past the bottom) with a "Your
                        // Library" section containing Liked Songs
                        // (horizontal) + Downloaded (vertical
                        // LazyVStack). See issue #1 + #2.
                        yourLibrarySection
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
                    // S18 / v1.6.4: RadioView now owns its viewModel
                    // internally via @StateObject. Passing a fresh
                    // RadioViewModel() here caused the viewModel to
                    // be recreated every time HomeView re-rendered
                    // (which happens on every PlayerState change —
                    // play, pause, track-end), wiping the loaded
                    // data and showing the skeleton again.
                    RadioView()
                case .timeCapsule:
                    // The vault is presented as a sheet from the
                    // root (per P0-5 in W1), so push a thin wrapper
                    // that just dismisses on appear. Or — for a
                    // proper nav-bar experience — use the existing
                    // .openTimeCapsuleVault notification.
                    Color.clear
                        .onAppear {
                            NotificationCenter.default.post(
                                name: .openTimeCapsuleVault,
                                object: nil,
                                userInfo: [:]
                            )
                            // Pop back to Home so the sheet sits over
                            // the tab bar (not over the nav stack).
                            if !path.isEmpty { path.removeLast() }
                        }
                case .antiAlgorithm:
                    // S18 / v1.6.1: Anti-Algorithm is now a real
                    // destination on Home's NavigationStack. The
                    // previous "Color.clear + pop back" hack
                    // was a no-op for the user — the dice icon
                    // opened a white screen and bounced back to
                    // Home. AntiAlgorithmScreen embeds the shared
                    // AntiAlgorithmContent (no nested
                    // NavigationStack — that crashes iOS) with
                    // a custom back button matching the rest of
                    // the S18 design language.
                    AntiAlgorithmScreen()
                case .likedSongs:
                    // 2026-08-12: push the content (no inner
                    // NavigationStack) — nested NavigationStacks
                    // crash iOS, per the S18 anti-algorithm
                    // comment above. LikedSongsContent carries
                    // the custom header + PlaylistDetailView
                    // (with showsDismissButton: false since we
                    // now have a back button in the nav stack).
                    LikedSongsContent()
                case .library:
                    // 2026-08-14: was `LibraryView()`, which has
                    // its own `NavigationStack` — nested
                    // NavigationStacks crash iOS, per the
                    // `.likedSongs` case comment above (the
                    // 2026-08-12 note that "LibraryView has its
                    // own NavigationStack, accept the nested
                    // stack" was wrong; the user hit the crash
                    // on the Downloaded "View All" tap). The
                    // `LikedSongsContent` pattern is the
                    // correct one: extract the LibraryView's
                    // content body (chrome + search + chips +
                    // list) into a stack-less view, push that
                    // from Home's NavigationStack. The full
                    // `LibraryView` (with its own stack) is
                    // still used for the Library tab — same
                    // pattern as `LikedSongsView` being a thin
                    // wrapper around `LikedSongsContent`.
                    //
                    // 2026-08-14: pass `showsBackButton: true`
                    // so `LibraryContent`'s custom header
                    // renders a back chevron at the leading
                    // edge (replacing the system nav bar's
                    // back button, which is hidden by the
                    // matching `.toolbar(.hidden, ...)` on
                    // the `LibraryContent` body when it's
                    // pushed from a parent stack).
                    LibraryContent(showsBackButton: true)
                }
            }
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            viewModel.loadData()
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

            // Top-right nav icons.
            // v1.6.8 (CV-14): the Search chip is removed.
            // Search is now the rightmost icon in the bottom
            // navbar pill (CyberpunkTabBar tag 1) — having it
            // in two places was redundant. The remaining
            // chips (Time Capsule, Anti-Algorithm, Radio,
            // Playlists, Settings) all push into Home's
            // NavigationStack via NavigationLink(value:).
            // S14: each chip is wrapped in either a Button
            // (Search, for a side-effect) or a NavigationLink
            // (Radio / Playlists / Settings, to push into
            // Home's stack). CyberIconChip is a pure visual
            // so the outer wrapper's gesture handler fires
            // reliably — previously the inner Button wrapper
            // ate the tap and the NavigationLink never fired.
            HStack(spacing: 8) {
                // S18 / P1-1: distinctive features get their own
                // chips with a subtle accent. Time Capsule was only
                // reachable via a long-press in FullPlayer;
                // Anti-Algorithm only via 0.6s long-press. Both
                // are flagship features that 80%+ of new users
                // would never find.
                NavigationLink(value: HomeDestination.timeCapsule) {
                    CyberIconChip(icon: "hourglass", accent: Theme.cyberYellow)
                }
                .buttonStyle(.plain)

                NavigationLink(value: HomeDestination.antiAlgorithm) {
                    CyberIconChip(icon: "dice.fill", accent: Theme.cyberMagenta)
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
                EmptyHero()
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

    // MARK: - Your Library (replaces Recently Played, 2026-08-12)
    //
    // Two sub-sections:
    //   1. Liked Songs    — horizontal scroll, up to 15 cards
    //   2. Downloaded     — vertical LazyVStack, up to 15 compact rows
    //
    // Both use the same context menu + swipe actions as the old
    // recently played list (Play / Play Next / Add to Queue / Start
    // Radio / Add to Playlist / Like-Unlike / Download-Downloaded).
    // Dedup: a track that's both liked AND downloaded shows only in
    // the Liked section (Liked is the more "intentional" signal).
    //
    // Why a LazyVStack (and not a nested List) for Downloaded:
    // the previous recently played list was a List inside the parent
    // ScrollView with scrollDisabled(true) and a hardcoded 64pt per
    // row. The List's intrinsic size didn't propagate to the parent
    // scroll region reliably, and the hardcoded row height
    // undercounted the actual rendered row (~68-72pt), so the bottom
    // rows got clipped and the parent ScrollView couldn't scroll
    // past them. LazyVStack sizes to its content correctly.
    private var yourLibrarySection: some View {
        // Compute the two arrays here — they're cheap (O(n) where n
        // is the number of liked/downloaded tracks, typically <100)
        // and computing in the view body keeps the @StateObject
        // graph simple. The view re-renders on any change to
        // playlistManager or libraryVM, which is the reactivity we
        // want (like from anywhere → updates immediately).
        let likedIds = Set(playlistManager.likedTracks)
        let likedOrderedIds: [String] = {
            if let likedPlaylist = playlistManager.playlists.first(where: { $0.isLikedSongsPlaylist }) {
                return likedPlaylist.trackIds
            }
            return Array(playlistManager.likedTracks)
        }()
        // Liked: ordered by most-recently-liked-first (reverse the
        // playlist's trackIds since the Liked playlist appends new
        // likes at the end). Matches the LibraryView's Liked mode
        // ordering (see LibraryView.swift:576-620 likedTracksAsItems).
        let likedTracks = TrackStore.shared.getTracks(
            videoIds: Array(likedOrderedIds.reversed())
        )
        // Downloaded: from LibraryViewModel (CoreData + file checks),
        // excluding anything that's also in Liked Songs.
        let downloadedTracks = libraryVM.tracks
            .filter { !likedIds.contains($0.videoId) }
            .map { $0.track }

        return VStack(alignment: .leading, spacing: 24) {
            // Section header
            HStack {
                Text("YOUR LIBRARY")
                    .font(Typography.sectionHeader)
                    .foregroundColor(.cyberDim)

                Spacer()
            }
            .padding(.horizontal, 20)

            // 1. Liked Songs — horizontal cards
            likedSongsSubsection(likedTracks: likedTracks)

            // 2. Downloaded — vertical compact rows
            downloadedSubsection(downloadedTracks: downloadedTracks)
        }
        .task(id: likedOrderedIds) {
            // Prefetch the first 5 liked so tapping is snappy.
            // Same pattern as the old recently played list, but
            // gated to the visible items (cap of 5 keeps it cheap).
            StreamURLCache.shared.prefetchBatch(
                videoIds: likedTracks.prefix(5).map(\.videoId)
            )
            StreamURLCache.shared.prefetchBatch(
                videoIds: downloadedTracks.prefix(5).map(\.videoId)
            )
        }
    }

    // MARK: Liked Songs sub-section
    @ViewBuilder
    private func likedSongsSubsection(likedTracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Liked Songs")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                if !likedTracks.isEmpty {
                    NavigationLink(value: HomeDestination.likedSongs) {
                        Text("View All")
                            .font(Typography.eyebrow)
                            .foregroundColor(.cyberCyan)
                    }
                }
            }
            .padding(.horizontal, 20)

            if likedTracks.isEmpty {
                // Inline empty state — only the "Liked Songs" header
                // is hidden visually if the rest of the section is
                // also empty, but a one-liner nudge stays.
                HStack(spacing: 10) {
                    Image(systemName: "heart.slash")
                        .foregroundColor(.cyberDim)
                    Text("Tap the heart on any track to add it here")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.cyberTextSecondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.cyberSurface.opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.cyberDim.opacity(0.2), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 20)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(likedTracks.prefix(15)) { track in
                            LikedSongCard(
                                track: track,
                                isPlaying: playerState.currentItem?.track.videoId == track.videoId
                                    && playerState.playbackState == .playing,
                                onPlay: { viewModel.playTrack(track) },
                                onPlayNext: {
                                    HapticManager.light()
                                    viewModel.addToQueue(track)
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
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    // MARK: Downloaded sub-section
    @ViewBuilder
    private func downloadedSubsection(downloadedTracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Downloaded")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                if !downloadedTracks.isEmpty {
                    // 2026-08-13: Play All / Shuffle chips for the
                    // Downloaded sub-section. Replaces the current
                    // queue with the full downloaded library
                    // (local files only, no /stream) and loops
                    // forever. Compact chip styling matches the
                    // existing header row density — these are
                    // utilities, not primary CTAs (Library's full
                    // Play All row is the primary CTA in the
                    // Library surface).
                    Button {
                        HapticManager.medium()
                        viewModel.playDownloaded(downloadedTracks, shuffled: false)
                    } label: {
                        downloadedChipLabel(
                            icon: "play.fill",
                            text: "PLAY ALL"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play all downloaded tracks")

                    Button {
                        HapticManager.medium()
                        viewModel.playDownloaded(downloadedTracks, shuffled: true)
                    } label: {
                        downloadedChipLabel(
                            icon: "shuffle",
                            text: "SHUFFLE"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Shuffle all downloaded tracks")

                    NavigationLink(value: HomeDestination.library) {
                        Text("View All")
                            .font(Typography.eyebrow)
                            .foregroundColor(.cyberCyan)
                    }
                }
            }
            .padding(.horizontal, 20)

            if downloadedTracks.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.cyberDim)
                    Text("Download tracks from Search to listen offline")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.cyberTextSecondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.cyberSurface.opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.cyberDim.opacity(0.2), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 20)
            } else {
                // LazyVStack (NOT a nested List) — the inner List
                // inside the parent ScrollView was the root cause
                // of the "cut at the bottom, can't scroll"
                // bug. LazyVStack sizes to its content correctly
                // and the parent ScrollView handles all scrolling.
                LazyVStack(spacing: 0) {
                    ForEach(downloadedTracks.prefix(15)) { track in
                        let isCurrentTrack = playerState.currentItem?.track.videoId == track.videoId
                        let isPlaying = isCurrentTrack && playerState.playbackState == .playing
                        let isLoading = isCurrentTrack && (playerState.playbackState == .loading || playerState.playbackState == .buffering)

                        HomeRecentTrackRow(
                            track: track,
                            isDownloaded: true,  // by construction
                            isPlaying: isPlaying,
                            isLoading: isLoading,
                            onPlay: { viewModel.playTrack(track) },
                            onPlayNext: {
                                HapticManager.light()
                                viewModel.addToQueue(track)
                            },
                            onDownload: {
                                // For downloaded tracks, "Download" in
                                // the context menu becomes "Remove
                                // from Library" — but the swipe action
                                // still calls this. The row UI shows
                                // the right label based on
                                // isDownloaded, and the destructive
                                // action is gated by the LibraryView's
                                // own delete flow. For now, calling
                                // downloadTrack on a downloaded track
                                // is a no-op (DownloadManager
                                // short-circuits isAlreadyDownloaded).
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
                        .padding(.vertical, 4)

                        if track.videoId != downloadedTracks.prefix(15).last?.videoId {
                            Divider()
                                .background(Color.cyberDim.opacity(0.15))
                                .padding(.horizontal, 20)
                        }
                    }
                }
            }
        }
    }

    // 2026-08-13: Chip-style label for the Downloaded
    // sub-section's Play All / Shuffle buttons. Compact,
    // tappable, mono-cased to match the rest of the header
    // typography. Cyan foreground on a slightly raised
    // surface so the chips read as a group against the
    // dark scrollview background.
    private func downloadedChipLabel(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundColor(.cyberCyan)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.cyberCyan.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.cyberCyan.opacity(0.45), lineWidth: 1)
                )
        )
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
// S18 / P1-8: was a single Search button. Now offers 3 entry
// points so a brand-new user with no history has multiple
// paths forward. Each button posts a notification that
// ContentView / Library / Radio listens for.
struct EmptyHero: View {
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 40))
                    .foregroundColor(.cyberCyan)
                Text("Start Listening")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text("Pick where to begin")
                    .font(.system(size: 12))
                    .foregroundColor(.cyberDim)
            }

            HStack(spacing: 12) {
                EmptyHeroButton(
                    icon: "magnifyingglass",
                    title: "Search",
                    accent: Theme.cyberCyan
                ) {
                    HapticManager.light()
                    NotificationCenter.default.post(name: .openSearch, object: nil)
                }
                EmptyHeroButton(
                    icon: "dice.fill",
                    title: "Anti-Algorithm",
                    accent: Theme.cyberMagenta
                ) {
                    HapticManager.light()
                    // Push the Anti-Algorithm view via a notification.
                    // AntiAlgorithmView is presented from FullPlayer
                    // today; we'll surface a Home entry in P1-1.
                    NotificationCenter.default.post(name: .switchTab, object: 0)
                }
                EmptyHeroButton(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Live Radio",
                    accent: Theme.cyberYellow
                ) {
                    HapticManager.light()
                    // RadioView is pushed from Home's NavigationStack
                    // (P1-1 wiring) — for now, route through the
                    // openRadioView notification that Home listens for.
                    NotificationCenter.default.post(name: .openRadioView, object: nil)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.cyberSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.cyberCyan.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [8, 8]))
                )
        )
    }
}

// S18 / P1-8: small 3-icon button used by EmptyHero and any
// future "give the user a path" empty state.
private struct EmptyHeroButton: View {
    let icon: String
    let title: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(accent)
                    .frame(height: 22)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(accent.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(accent.opacity(0.4), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
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

// MARK: - Liked Song Card (2026-08-12)
//
// Horizontal card for the Liked Songs sub-section on Home. Styled
// after ArtistSuggestionCard (130x130 artwork + title + artist
// underneath) but with a magenta heart badge top-right to make
// the "this is a Liked track" signal visible at a glance. Tap plays;
// long-press opens the same context menu as the vertical row.
struct LikedSongCard: View {
    let track: Track
    let isPlaying: Bool
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onAddToPlaylist: () -> Void
    let onStartRadio: () -> Void

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
                            colors: [Theme.cyberMagenta.opacity(0.7), Theme.cyberCyan.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            .shadow(color: Theme.cyberMagenta.opacity(0.25), radius: 8, x: 0, y: 0)
            .overlay(alignment: .topTrailing) {
                // Liked indicator — small magenta heart in the
                // top-right corner. Mirrors the "this is liked"
                // signal from the heart-filled Liked button, so the
                // user can see at a glance which section they're
                // looking at without tapping.
                Image(systemName: isLiked ? "heart.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isLiked ? Theme.cyberMagenta : .white)
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(Color.black.opacity(0.55))
                    )
                    .padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                // Playing indicator — equalizer bars when the
                // track is currently playing in the player.
                if isPlaying {
                    CyberPlayingBars()
                        .frame(width: 22, height: 16)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.55))
                        )
                        .padding(6)
                }
            }

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
        .onTapGesture {
            HapticManager.medium()
            onPlay()
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
            Button(action: onStartRadio) {
                Label("Start Radio", systemImage: "antenna.radiowaves.left.and.right")
            }
            Divider()
            Button(action: onAddToPlaylist) {
                Label("Add to Playlist", systemImage: "music.note.list")
            }
            // By construction this card is in the Liked Songs
            // sub-section, so the heart is always filled — show
            // "Unlike" only. (Defensive: if a user taps from
            // another surface and the heart is somehow not filled
            // by the time the menu opens, show "Like" instead.)
            Button {
                playlistManager.toggleLike(trackId: track.videoId)
                HapticManager.medium()
            } label: {
                Label(isLiked ? "Unlike" : "Like",
                      systemImage: isLiked ? "heart.fill" : "heart")
            }
            Button {
                // Toggle the local download state — the
                // DownloadManager's `download(...)` method is a
                // no-op if the track is already downloaded
                // (matched by videoId in its existing check).
                if !isDownloaded {
                    DownloadManager.shared.download(track)
                }
            } label: {
                Label(isDownloaded ? "Downloaded" : "Download",
                      systemImage: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
            }
        }
    }
}

// MARK: - Cyber Icon Chip (compact header icon)
struct CyberIconChip: View {
    let icon: String
    // S18 / P1-1: optional accent color. Default cyberCyan.
    // Distinctive feature chips (Time Capsule, Anti-Algorithm)
    // use a different accent to stand out from the utility
    // navigation chips.
    var accent: Color = .cyberCyan

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
            .foregroundColor(accent)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.cyberSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(accent.opacity(0.25), lineWidth: 1)
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
        case "hourglass": return "Time Capsule"
        case "dice.fill": return "Anti-Algorithm"
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
    @Published var downloadCount = 0
    @Published var totalListeningTime: TimeInterval = 0
    @Published var isLoading = true
    @Published var artistSuggestions: [String: [Track]] = [:]

    // 2026-08-12: removed `recentlyPlayed: [Track]` and the
    // dataManager.$recentlyPlayed subscription. The old
    // recently played section is gone (replaced by Your
    // Library's Liked + Downloaded sub-sections, which read
    // directly from playlistManager + libraryVM as @StateObject
    // on HomeView). The viewModel now only owns the hero /
    // greeting / favorite-artist data, which doesn't need a
    // reactive subscription to recently played (greeting is
    // computed on load, lastPlayedTrack is read once on load,
    // totalListeningTime is a count).

    private let dataManager = DataManager.shared
    private let favoriteArtists = FavoriteArtistsManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var vibeCancellables = Set<AnyCancellable>()
    private var suggestionCancellables = Set<AnyCancellable>()

    init() {
        favoriteArtists.$artists
            .receive(on: DispatchQueue.main)
            .sink { [weak self] artists in
                self?.fetchSuggestionsForFavoriteArtists(artists)
            }
            .store(in: &cancellables)
    }

    func loadData() {
        updateGreeting()
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
        // 2026-08-12: delegate to PlayerState.shared.play(track:),
        // which has the local-first logic (C-5 fix in PlayerState
        // .play(track:) at line 1098 — checks AudioFileManager.isPlayable
        // and plays the local M4A if it exists, falls back to a
        // /stream roundtrip otherwise). The previous inline implementation
        // here always went through StreamURLCache.getStreamUrl, which
        // meant tapping a downloaded track from Home's Downloaded /
        // Liked sub-sections silently streamed the track from the
        // backend instead of playing the local file. User-visible bug:
        // downloaded tracks wouldn't play in airplane mode + the
        // /stream roundtrip was wasted on every tap.
        //
        // LibraryViewModel.playTrack already used the correct delegate
        // (LibraryViewModel.swift:373) — this brings HomeViewModel in
        // line. The optional seek-to-progress is the only piece of
        // the old body we still need (used by the Resume block on
        // Home to resume the last-played track at its saved position).
        print("▶️ [S9d] playTrack ENTRY track=\(track.title) videoId=\(track.videoId) seekToProgress=\(progress ?? -1)")

        PlayerState.shared.play(track: track)

        // S11 fix (Bug 8): seek to saved progress if the caller
        // passed one. Same asyncAfter pattern as before — the seek
        // happens after the player has had a moment to start decoding
        // the audio (works for both local and stream sources).
        if let p = progress, p > 0.02, p < 0.98 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                print("▶️ [S11] playTrack: seeking to progress \(p)")
                PlayerState.shared.seek(to: p)
            }
        }
    }

    // 2026-08-13: Play All / Shuffle for the Home "Downloaded"
    // sub-section. Takes every track in the downloaded library
    // (not just the 15 visible in the section) and replaces the
    // current queue with local-file QueueItems so the playback
    // never hits /stream. When `shuffled` is true the tracks are
    // randomized before being queued; in both cases repeatMode
    // is set to .all so the queue loops forever after the last
    // track (per Vergil's spec — Downloaded Play All is a "set
    // and forget" offline mode).
    //
    // Why filter via `isPlayable`:
    //   LibraryViewModel.tracks reads from CoreData. If a user
    //   deleted the .m4a via Files.app, the CoreData row is
    //   stale and the file is missing on disk. Skipping
    //   unplayable rows up front avoids a "playback failed"
    //   toast on the first track. LibraryViewModel.refreshLibrary
    //   will prune the stale row on the next refresh; this is
    //   just a belt-and-suspenders gate.
    //
    // Why `queueStore.replace` (not `addToQueue` x N):
    //   Going through `add` would dedup against the existing
    //   queue and could leave stale items in place. `replace`
    //   gives a clean swap so the user's prior queue (or any
    //   in-flight restore) can't leak into the new playback.
    //   Combined with `markUserTouchedPlayback()` this also
    //   wins the race against QueueRestorer's pending restore.
    //
    // Why set isShuffled = shuffled after queueing:
    //   The store's `originalQueue` is what `toggleShuffle` uses
    //   to restore the unshuffled order on toggle-off. We build
    //   the queue in the final order (shuffled or not), so the
    //   flag just needs to reflect reality — the queue itself
    //   is the source of truth, not a runtime shuffle.
    @MainActor
    func playDownloaded(_ tracks: [Track], shuffled: Bool) {
        let context = PersistenceController.shared.viewContext
        // Defensive: skip stale CoreData rows whose file is gone.
        let playable = tracks.filter {
            AudioFileManager.shared.isPlayable(videoId: $0.videoId, context: context)
        }
        guard !playable.isEmpty else {
            ErrorHandler.shared.show(
                .playbackFailed("None of your downloaded tracks are playable right now")
            )
            return
        }

        let ordered: [Track] = shuffled ? Self.shuffled(playable) : playable

        let items: [QueueItem] = ordered.compactMap { track in
            let localURL = AudioFileManager.shared.localFileURL(for: track.videoId)
            return QueueItem(
                track: track,
                streamUrl: localURL.absoluteString,
                source: .local(path: localURL.path),
                contentSource: .local
            )
        }
        guard !items.isEmpty else { return }

        // Defeat any in-flight QueueRestorer swap.
        PlayerState.shared.markUserTouchedPlayback()
        // Replace the entire queue with the downloaded set.
        PlayerState.shared.queueStore.replace(with: items)
        PlayerState.shared.queueStore.setCurrentIndex(0)
        // Loop forever (per spec). User can still toggle off
        // from the player chrome.
        PlayerState.shared.repeatMode = .all
        // Reflect the chosen mode in the player's shuffle state.
        // The queue itself is already in the final order, so the
        // flag is just a UI signal + a hint for toggle-off.
        PlayerState.shared.isShuffled = shuffled
        // Clear any leftover "original queue" so a later
        // toggleShuffle-off from the chrome doesn't try to
        // restore a stale order.
        PlayerState.shared.originalQueue = []

        HapticManager.medium()
        PlayerState.shared.playQueue(at: 0)
    }

    // Fisher–Yates shuffle. Pulled out so the random order is
    // determined once on the main thread, before the queue
    // replace, instead of being deferred into the queue store.
    private static func shuffled<T>(_ array: [T]) -> [T] {
        var copy = array
        for i in stride(from: copy.count - 1, through: 1, by: -1) {
            let j = Int.random(in: 0...i)
            copy.swapAt(i, j)
        }
        return copy
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

// MARK: - Playing Bars Indicator moved to DesignSystem/CyberPlayingBars.swift
// (S18 / P1-15). The two parallel components (CyberPlayingBars in
// MiniPlayer.swift, PlayingBarsIndicator here) produced slightly
// different bar-height ranges (4-16 vs 6-16). The 4-16 range is
// the canonical one; all call sites now resolve to the single
// DesignSystem component.

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
        // S18 / v1.6.7 (CV-8): the artwork + title + artist
        // block is now the unified TrackRow. The right-side
        // cluster (downloaded icon + play/loading/playing
        // indicator) is still custom because it's a 3-state
        // compound indicator; folding it into the TrackRow
        // accessory system would add a third bespoke case for
        // one call site. The custom cluster is passed in via
        // .custom(AnyView) so the rest of the row matches the
        // global TrackRow design (font size, color, line
        // limits, tap target).
        TrackRow(
            title: track.title,
            subtitle: track.displayArtist,
            artworkURL: track.artworkURL,
            isPlaying: isPlaying,
            titleSize: 16,
            subtitleSize: 14,
            accessory: .custom(AnyView(
                HStack(spacing: 8) {
                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.cyberCyan)
                    }
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(Theme.cyberCyan)
                    } else if isPlaying {
                        CyberPlayingBars()
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.cyberCyan)
                    }
                }
                .frame(width: 36)
            )),
            onTap: onPlay
        )
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

// MARK: - On This Day Section
// S18 / P1-3: tracks the user played on this calendar day in
// prior years. Hidden when no entries (e.g. brand-new user).
private struct OnThisDaySection: View {
    @StateObject private var viewModel = MemoryTimelineViewModel()
    @StateObject private var playerState = PlayerState.shared

    var body: some View {
        Group {
            if !viewModel.entries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "calendar")
                            .foregroundColor(Theme.cyberMagenta)
                        Text("On This Day")
                            .font(Typography.sectionHeader)
                            .foregroundColor(.cyberDim)
                        Spacer()
                    }
                    .padding(.horizontal, 20)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(viewModel.entries) { entry in
                                OnThisDayCard(entry: entry) {
                                    HapticManager.light()
                                    // Build a Track directly from the
                                    // CDTrack's fields. Track has no
                                    // `from(cdTrack:)` initializer.
                                    let track = Track(
                                        videoId: entry.track.videoId ?? "",
                                        title: entry.track.title ?? "Unknown",
                                        artists: entry.track.artists,
                                        album: entry.track.album,
                                        durationSeconds: Int(entry.track.durationSeconds),
                                        thumbnails: entry.track.thumbnailURLs.compactMap { URL(string: $0) }.map { Thumbnail(url: $0, width: 0, height: 0) },
                                        isExplicit: entry.track.isExplicit,
                                        videoType: entry.track.videoType
                                    )
                                    playerState.play(track: track)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .onAppear { viewModel.loadIfNeeded() }
            }
        }
    }
}

private struct OnThisDayCard: View {
    let entry: MemoryTimelineViewModel.MemoryEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(entry.year))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.cyberMagenta)

                Text(entry.track.title ?? "Unknown")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(entry.track.displayArtist)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.cyberTextSecondary)
                    .lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.cyberSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.cyberMagenta.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview
struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
            .preferredColorScheme(.dark)
    }
}
