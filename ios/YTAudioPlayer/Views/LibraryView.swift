//
//  LibraryView.swift
//  YTAudioPlayer
//

import SwiftUI
import Combine

enum LibraryViewMode: String, CaseIterable {
    case grid = "Grid"
    case list = "List"
}

enum LibrarySortOption: String, CaseIterable, Identifiable {
    case recentlyAdded = "Recently Added"
    case title = "Title"
    case artist = "Artist"
    case size = "Size"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .recentlyAdded: return "clock.arrow.circlepath"
        case .title: return "textformat.abc"
        case .artist: return "person"
        case .size: return "externaldrive"
        }
    }
}

// v1.6.9 (CV-15b): Library now has two modes — Liked
// (everything the user has tapped the heart on) and
// Downloaded (everything in the local CoreData store).
// A segmented Picker at the top of the Library view
// toggles between them. Both modes use the same row
// components, the same grid/list toggle, the same
// search, the same sort — only the source data and
// the per-row "remove" action differ (Unlike for liked,
// Remove from Library for downloaded).
//
// Why segmented control over two sections in one
// scroll: the user asked for "liked and downloaded
// both in the same view, without going anywhere else".
// The segmented Picker is the same view (Library), the
// same screen, the same tab — switching is one tap on
// the segment, not a navigation. It also lets each
// mode get the full Library toolbar (sort, view mode,
// multi-select) instead of the Liked section being a
// second-class "lite" view.
enum LibraryMode: String, CaseIterable, Identifiable {
    case liked
    case downloaded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .liked:     return "Liked"
        case .downloaded: return "Downloaded"
        }
    }

    var icon: String {
        switch self {
        case .liked:     return "heart.fill"
        case .downloaded: return "arrow.down.circle.fill"
        }
    }
}

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @StateObject private var playerState = PlayerState.shared
    @StateObject private var songMemoryManager = SongMemoryManager.shared
    // v1.6.9 (CV-15b): PlaylistManager is observed so
    // the Liked mode refreshes the moment a track is
    // liked / unliked from anywhere in the app.
    @StateObject private var playlistManager = PlaylistManager.shared
    @ObservedObject var undoService = UndoService.shared
    @State private var viewMode: LibraryViewMode = .grid
    @State private var showStorageInfo = false
    @State private var showDownloadQueue = false
    @State private var selectedTracks: Set<String> = []
    @State private var isEditing = false
    @State private var searchQuery = ""
    // v1.6.9 (CV-15b): segmented Picker state. Default
    // Downloaded so the first thing the user sees is
    // the offline-available library they already know
    // — the Liked view is one tap away.
    @State private var libraryMode: LibraryMode = .downloaded
    // v1.6.9 (CV-15b): Combine cancellables for the
    // async stream-URL fetches kicked off by
    // playAllLiked / addLikedTrackToQueue /
    // playLikedTrackNext. The sinks are short-lived
    // (they fire once and complete) but we still need
    // a bag to hold the AnyCancellable so the closure
    // is deallocated cleanly.
    @State private var cancellables: Set<AnyCancellable> = []

    var body: some View {
        // S14: NavigationStack replaces the deprecated NavigationView
        // so the Library tab's chrome (DONE/DELETE toolbar in edit
        // mode + standard nav bar) is consistent with iOS 16+ patterns.
        // v1.6.8 (CV-13): Liked Songs opens as a .sheet (below) —
        // not pushed onto this stack — to avoid nested
        // NavigationStacks with PlaylistDetailView.
        NavigationStack {
            ZStack {
                // Cyberpunk background
                Theme.cyberBackground
                    .ignoresSafeArea()

                Group {
                    // v1.6.9 (CV-15b): empty check is per-mode
                    // so the user sees the Liked empty state
                    // (or the Downloaded one) based on the
                    // active segment — not a single global
                    // "library is empty" overlay that hides
                    // both modes.
                    if currentTracks.isEmpty {
                        emptyView
                    } else {
                        contentView
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isEditing {
                        HStack(spacing: 16) {
                            Button("DONE") {
                                isEditing = false
                                selectedTracks.removeAll()
                            }
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.cyberCyan)

                            if !selectedTracks.isEmpty {
                                // v1.6.9 (CV-15b): destructive
                                // action label switches with the
                                // active mode — "UNLIKE" for the
                                // Liked segment, "DELETE" for
                                // Downloaded.
                                Button(libraryMode == .liked ? "UNLIKE" : "DELETE", role: .destructive) {
                                    print("🗑️ Toolbar Delete button tapped. selectedTracks: \(selectedTracks.count)")
                                    viewModel.showDeleteConfirmation = true
                                }
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                            }
                        }
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        // v1.6.9 (CV-15b): Downloads queue bell
                        // is only relevant for the Downloaded
                        // mode. In the Liked mode it's hidden —
                        // the user is browsing favorites, not
                        // managing downloads, and a downloads
                        // bell that does nothing would just be
                        // visual noise.
                        if libraryMode == .downloaded {
                            // S18 (P0-1 rescue): Downloads queue +
                            // History were orphaned because
                            // nothing observed
                            // DownloadManager.showDownloadQueue.
                            // Surface them via a bell in the
                            // Library toolbar. The bell also
                            // shows a badge when there are active
                            // or failed downloads.
                            Button {
                                HapticManager.light()
                                showDownloadQueue = true
                            } label: {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundColor(Theme.cyberCyan)
                                    // Badge: active OR failed downloads
                                    let activeCount = DownloadManager.shared.activeDownloads.count
                                    let failedCount = DownloadManager.shared.completedDownloads.filter {
                                        if case .failed = $0.status { return true }; return false
                                    }.count
                                    if activeCount + failedCount > 0 {
                                        Text("\(activeCount + failedCount)")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(
                                                Capsule().fill(failedCount > 0 ? Theme.cyberMagenta : Theme.cyberYellow)
                                            )
                                            .offset(x: 6, y: -4)
                                    }
                                }
                            }
                            .accessibilityLabel("Downloads")
                            .accessibilityHint("Show download queue and history")
                        }

                        // 2026-06-28 (S6): show toolbar even when the
                        // library is empty so the sort menu is
                        // always accessible (it controls the
                        // empty-state as well). v1.6.9 (CV-15b):
                        // enabled state follows the current mode's
                        // track list, not just the downloaded
                        // library.
                        Button(isEditing ? "\(selectedTracks.count)" : "SELECT") {
                            isEditing.toggle()
                            if !isEditing {
                                selectedTracks.removeAll()
                            }
                        }
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.cyberCyan)
                        .disabled(currentTracks.isEmpty)
                        .opacity(currentTracks.isEmpty ? 0.4 : 1)

                        Button {
                            viewMode = viewMode == .grid ? .list : .grid
                        } label: {
                            Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(Theme.cyberCyan)
                        }

                        Menu {
                            Section("SORT BY") {
                                // v1.6.9 (CV-15b): in Liked mode
                                // we hide the "Size" sort option
                                // (file size is meaningless for
                                // liked tracks that aren't
                                // downloaded). Downloaded mode
                                // gets the full list.
                                ForEach(availableSortOptions) { option in
                                    Button {
                                        viewModel.sortOption = option
                                    } label: {
                                        Label(option.rawValue,
                                              systemImage: viewModel.sortOption == option ? "checkmark" : option.icon)
                                    }
                                }
                            }

                            // v1.6.9 (CV-15b): STORAGE INFO is
                            // only relevant for the Downloaded
                            // mode — it tracks on-disk bytes,
                            // which is meaningless for liked
                            // tracks that may not be downloaded.
                            if libraryMode == .downloaded {
                                Divider()

                                Button {
                                    showStorageInfo = true
                                } label: {
                                    Label("STORAGE INFO", systemImage: "externaldrive")
                                }
                            }
                        } label: {
                            // 2026-06-28 (S6): wrap the icon in a glass
                            // circle so it's clearly visible against
                            // the dark background. The previous plain
                            // `arrow.up.arrow.down.circle` SF Symbol
                            // was nearly invisible at the toolbar
                            // size on the simulator.
                            ZStack {
                                Circle()
                                    .fill(Theme.cyberSurface.opacity(0.85))
                                    .frame(width: 30, height: 30)
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(Theme.cyberCyan)
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showStorageInfo) {
                StorageInfoSheetCyberpunk(
                    totalSize: viewModel.totalSize,
                    trackCount: viewModel.tracks.count,
                    onClearAll: {
                        viewModel.clearLibrary()
                    }
                )
            }
            .sheet(isPresented: $showDownloadQueue) {
                DownloadQueueView()
            }
            // v1.6.9 (CV-15b): Liked Songs sheet removed.
            // Liked tracks are now a first-class Library
            // mode toggled via the segmented Picker at the
            // top of contentView — no separate sheet
            // needed. The LikedSongsView file stays around
            // for any future standalone use (e.g. a
            // ShareCard / search-result jump-to).
            .alert(deleteAlertTitle, isPresented: $viewModel.showDeleteConfirmation) {
                Button("CANCEL", role: .cancel) {
                    print("🗑️ Delete cancelled")
                }
                Button(libraryMode == .liked ? "UNLIKE" : "DELETE", role: .destructive) {
                    print("🗑️ Alert Delete button tapped. Selected tracks: \(selectedTracks.count)")
                    let ids = Array(selectedTracks)
                    print("🗑️ Track IDs to delete: \(ids)")
                    HapticManager.heavy()
                    let count = ids.count
                    // v1.6.9 (CV-15b): destructive action
                    // depends on the active mode. Downloaded
                    // mode removes the files from disk via
                    // the LibraryViewModel; Liked mode just
                    // toggles the like state in
                    // PlaylistManager. Different toast
                    // messages reflect the difference.
                    if libraryMode == .liked {
                        for id in ids {
                            playlistManager.toggleLike(trackId: id)
                        }
                        UndoService.shared.registerUndo(
                            message: "Unliked \(count) track\(count == 1 ? "" : "s")",
                            restore: nil,
                            showUndoButton: false
                        )
                    } else {
                        viewModel.deleteTracks(ids)
                        // S15: Library multi-delete is destructive
                        // (files are removed from disk). No working
                        // restore, so the toast is a confirmation
                        // only — no Undo button (previously the
                        // button was a lie).
                        UndoService.shared.registerUndo(
                            message: "Deleted \(count) track\(count == 1 ? "" : "s")",
                            restore: nil,
                            showUndoButton: false
                        )
                    }
                    selectedTracks.removeAll()
                    isEditing = false
                }
            } message: {
                Text(deleteAlertMessage)
            }
            .preferredColorScheme(.dark)
        }
        .onAppear {
            viewModel.loadLibrary()
        }
    }

    private var emptyView: some View {
        // v1.6.9 (CV-15b): the empty state changes
        // with the active segment. Downloaded =
        // "go search and download something" with
        // a CTA button. Liked = "tap the heart to
        // start collecting", no CTA (the user is
        // already in the app, no action to take
        // here — they need to go play a track and
        // heart it).
        Group {
            switch libraryMode {
            case .downloaded:
                EmptyStateView(
                    type: .library,
                    action: {
                        NotificationCenter.default.post(name: .openSearch, object: nil)
                    },
                    actionTitle: "Search Music"
                )
            case .liked:
                EmptyStateView(type: .liked)
            }
        }
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Library")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 10, x: 0, y: 0)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)

            // v1.6.9 (CV-15b): segmented Picker
            // toggles between Liked and Downloaded.
            // Same view, same screen, one tap to
            // switch — meets the "show both in the
            // same view" goal without burying one
            // mode behind a card or a sheet.
            modePicker
                .padding(.horizontal)
                .padding(.bottom, 8)

            // v1.6.9 (CV-15b): Play-all row. Only
            // shown in Liked mode (Downloaded mode
            // already has Play / Shuffle buttons
            // elsewhere via the row context menu
            // and the FullPlayer's Play All from
            // an artist).
            if libraryMode == .liked && !currentTracks.isEmpty {
                playAllRow
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            // Search bar
            searchBar
                .padding(.horizontal)
                .padding(.bottom, 8)

            // Stats bar
            HStack {
                Text("\(currentTracks.count) TRACK\(currentTracks.count == 1 ? "" : "S")")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)

                Spacer()

                if libraryMode == .downloaded {
                    Text(viewModel.totalSizeFormatted.uppercased())
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.cyberDim)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Content
            if viewMode == .grid {
                gridView
            } else {
                listView
            }
        }
    }

    // v1.6.9 (CV-15b): segmented Picker for the
    // Liked / Downloaded toggle. Segmented style
    // matches the iOS 17 default; the underlying
    // labels use the heart / download-circle icons
    // so the two modes are visually distinct even
    // when text is truncated.
    private var modePicker: some View {
        Picker("Library mode", selection: $libraryMode) {
            ForEach(LibraryMode.allCases) { mode in
                Label(mode.label, systemImage: mode.icon)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    // v1.6.9 (CV-15b): Play-all action for the
    // Liked mode. Tapping it plays the first liked
    // track and pre-fetches the rest into the queue
    // (same pattern Anti-Algorithm's "start session"
    // uses). Replaces the "Play All" button the
    // Liked Songs sheet had via PlaylistDetailView's
    // hero header.
    private var playAllRow: some View {
        Button {
            HapticManager.medium()
            playAllLiked()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                Text("PLAY ALL")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Spacer()
                Text("\(currentTracks.count) TRACK\(currentTracks.count == 1 ? "" : "S")")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .opacity(0.8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .foregroundColor(Theme.cyberBackground)
            .background(Theme.cyberCyan)
            .cornerRadius(CornerRadius.sm)
            .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 10, x: 0, y: 0)
        }
        .buttonStyle(.plain)
    }

    // v1.6.9 (CV-15b): play the first liked track
    // and pre-fetch the rest into the queue. Mirrors
    // the Anti-Algorithm playFirstAndQueueRest flow
    // — `PlayerState.shared.play(track:)` for the
    // first one, then a per-track StreamURLCache
    // fetch (Combine sink) that appends a QueueItem
    // to the player's queue as each stream URL
    // arrives.
    private func playAllLiked() {
        let items = currentTracks
        guard let first = items.first else { return }
        let firstTrack = first.track
        // Play the first via the standard path.
        // play(track:) handles the stream-URL fetch
        // internally.
        PlayerState.shared.play(track: firstTrack)

        // The remaining tracks go through a per-track
        // pre-fetch. StreamURLCache is the same cache
        // play(track:) uses, so the first play of each
        // track is the only network roundtrip.
        let remaining = Array(items.dropFirst())
        let maxQueueSize = max(50, remaining.count + 5)
        for trackItem in remaining {
            let track = trackItem.track
            StreamURLCache.shared.getStreamUrl(videoId: track.videoId, quality: "low")
                .sink(
                    receiveCompletion: { completion in
                        if case .failure = completion {
                            // Quiet fail: the next-played track
                            // would have hit this anyway. The
                            // Anti-Algorithm engine logs the
                            // os_log breadcrumb; we just skip
                            // silently here to keep the toast
                            // surface clean.
                        }
                    },
                    receiveValue: { streamInfo in
                        let item = QueueItem(
                            track: track,
                            streamUrl: streamInfo.streamUrl,
                            source: .stream
                        )
                        PlayerState.shared.queueStore.add(item, maxQueueSize: maxQueueSize)
                    }
                )
                .store(in: &cancellables)
        }
    }

    // v1.6.9 (CV-15b): tracks to display in the
    // current mode. Downloaded reads from
    // LibraryViewModel (filtered by search query);
    // Liked reads from PlaylistManager (the set of
    // liked videoIds) and converts the underlying
    // Track objects into DownloadedTrackItem shape
    // so the existing row components work
    // unchanged. The conversion fills fileSize /
    // downloadedAt / localPath with empty /
    // zero values, which the row UI handles
    // gracefully (the "Remove from Library" context
    // action is replaced with "Unlike" via the
    // `mode` parameter on the row).
    private var currentTracks: [DownloadedTrackItem] {
        switch libraryMode {
        case .downloaded:
            return viewModel.filteredTracks(searchQuery: searchQuery)
        case .liked:
            return likedTracksAsItems
        }
    }

    // v1.6.9 (CV-15b): convert the Liked playlist's
    // videoIds to DownloadedTrackItem array. The
    // order is "first liked is first" — the Liked
    // playlist preserves insertion order via its
    // underlying trackIds array, so most-recently
    // liked tracks come last. We reverse so the
    // newest liked track shows at the top of the
    // list (matches user expectation from
    // Instagram / Spotify's "Recently liked" feeds).
    private var likedTracksAsItems: [DownloadedTrackItem] {
        let videoIds = Array(playlistManager.likedTracks)
        // Sort by reverse order: items the user liked
        // most recently appear at the top. Since
        // likedTracks is a Set<String> (no order),
        // we fall back to the Liked playlist's
        // trackIds order if available — that array
        // IS ordered (it's the order in which tracks
        // were added to the playlist).
        let orderedIds: [String]
        if let likedPlaylist = playlistManager.playlists.first(where: { $0.isLikedSongsPlaylist }) {
            orderedIds = likedPlaylist.trackIds
        } else {
            orderedIds = videoIds
        }
        // Apply search filter
        let filteredIds: [String]
        if searchQuery.isEmpty {
            filteredIds = orderedIds
        } else {
            let q = searchQuery.lowercased()
            filteredIds = orderedIds.filter { id in
                // We don't have direct access to the
                // track's title/artist here without
                // looking it up, so we do that in the
                // next pass.
                return true
            }
        }
        // Build items, applying the search filter
        // against the actual track metadata.
        let tracks = TrackStore.shared.getTracks(videoIds: filteredIds)
        return tracks.compactMap { track in
            // Search filter on title/artist
            if !searchQuery.isEmpty {
                let q = searchQuery.lowercased()
                let matchesTitle = track.title.lowercased().contains(q)
                let matchesArtist = track.displayArtist.lowercased().contains(q)
                if !matchesTitle && !matchesArtist {
                    return nil
                }
            }
            return DownloadedTrackItem.likedPlaceholder(track: track)
        }
    }

    // v1.6.9 (CV-15b): per-mode sort options. The
    // "Size" sort doesn't apply to liked tracks
    // (they don't have a file size unless they
    // happen to also be downloaded — and even
    // then, we're not displaying it in the Liked
    // mode). The full list stays for Downloaded.
    private var availableSortOptions: [LibrarySortOption] {
        switch libraryMode {
        case .downloaded:
            return LibrarySortOption.allCases
        case .liked:
            return LibrarySortOption.allCases.filter { $0 != .size }
        }
    }

    // v1.6.9 (CV-15b): per-mode delete alert copy.
    private var deleteAlertTitle: String {
        let count = selectedTracks.count
        switch libraryMode {
        case .downloaded:
            return "DELETE \(count) TRACK\(count == 1 ? "" : "S")?"
        case .liked:
            return "UNLIKE \(count) TRACK\(count == 1 ? "" : "S")?"
        }
    }

    private var deleteAlertMessage: String {
        switch libraryMode {
        case .downloaded:
            return "This will permanently remove the selected tracks from your library."
        case .liked:
            return "These tracks will be removed from your Liked Songs. You can re-like them any time."
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(Theme.cyberDim)

            TextField("Search library...", text: $searchQuery)
                .font(.system(.body, design: .default))
                .foregroundColor(.white)
                .accentColor(Theme.cyberCyan)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.cyberDim)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.smd)
                .fill(Theme.cyberSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.smd)
                        .stroke(Theme.cyberCyan.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 16
            ) {
                // v1.6.9 (CV-15b): iterate over
                // currentTracks (Liked or Downloaded
                // depending on the segmented Picker)
                // instead of the downloaded library
                // directly. Each row gets the active
                // `mode` so its context menu can show
                // the right destructive action
                // (Unlike vs Remove from Library).
                ForEach(currentTracks) { track in
                    GridTrackCell(
                        track: track,
                        isSelected: selectedTracks.contains(track.videoId),
                        isEditing: isEditing,
                        isPlaying: viewModel.isCurrentlyPlaying(track),
                        memoryPreview: songMemoryManager.memory(for: track.track)?.previewText,
                        mode: libraryMode,
                        onTap: {
                            if isEditing {
                                toggleSelection(track)
                            } else {
                                viewModel.playTrack(track)
                            }
                        },
                        onPlay: {
                            viewModel.playTrack(track)
                        },
                        onPlayNext: {
                            HapticManager.light()
                            handlePlayNext(track)
                        },
                        onAddToQueue: {
                            HapticManager.light()
                            handleAddToQueue(track)
                        },
                        onDelete: {
                            handleDelete(track)
                        }
                    )
                }
            }
            .padding(16)
        }
        .refreshable {
            // v1.6.9 (CV-15b): pull-to-refresh is
            // only meaningful in the Downloaded mode
            // (it reloads the on-disk library). In
            // Liked mode, the data is already live
            // (PlaylistManager is observed).
            if libraryMode == .downloaded {
                viewModel.loadLibrary()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var listView: some View {
        List {
            ForEach(currentTracks) { track in
                    ListTrackRow(
                        track: track,
                        isSelected: selectedTracks.contains(track.videoId),
                        isEditing: isEditing,
                        isPlaying: viewModel.isCurrentlyPlaying(track),
                        memoryPreview: songMemoryManager.memory(for: track.track)?.previewText,
                        mode: libraryMode,
                        onTap: {
                            if isEditing {
                                toggleSelection(track)
                            } else {
                                viewModel.playTrack(track)
                            }
                        },
                        onPlay: {
                            viewModel.playTrack(track)
                        },
                        onPlayNext: {
                            HapticManager.light()
                            handlePlayNext(track)
                        },
                        onAddToQueue: {
                            HapticManager.light()
                            handleAddToQueue(track)
                        },
                        onDelete: {
                            handleDelete(track)
                        }
                    )
            }
        }
        .listStyle(.plain)
        .refreshable {
            // v1.6.9 (CV-15b): same as gridView —
            // pull-to-refresh only refreshes
            // Downloaded data.
            if libraryMode == .downloaded {
                viewModel.loadLibrary()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // v1.6.9 (CV-15b): mode-aware dispatch for
    // "Add to Queue" / "Play Next". Downloaded
    // tracks use the local file URL (sync, fast);
    // Liked tracks need a network roundtrip to
    // resolve the stream URL before they can be
    // queued. We keep both paths simple by
    // routing through the LibraryView's helpers
    // — the row components don't need to know
    // about the mode.
    private func handleAddToQueue(_ track: DownloadedTrackItem) {
        switch libraryMode {
        case .downloaded:
            viewModel.addToQueue(track)
            UndoService.shared.registerUndo(
                message: "Added \(track.title) to Queue",
                restore: nil,
                showUndoButton: false
            )
            NotificationCenter.default.post(
                name: .trackAddedToQueue,
                object: track.track
            )
        case .liked:
            addLikedTrackToQueue(track)
        }
    }

    private func handlePlayNext(_ track: DownloadedTrackItem) {
        switch libraryMode {
        case .downloaded:
            viewModel.playNextTrack(track)
        case .liked:
            playLikedTrackNext(track)
        }
    }

    // v1.6.9 (CV-15b): mode-aware destructive
    // action. Downloaded = remove from disk
    // (existing LibraryViewModel.deleteTracks);
    // Liked = toggle the like off in
    // PlaylistManager. Both surface a toast.
    private func handleDelete(_ track: DownloadedTrackItem) {
        HapticManager.medium()
        switch libraryMode {
        case .downloaded:
            let trackName = track.title
            viewModel.deleteTracks([track.videoId])
            UndoService.shared.registerUndo(
                message: "Deleted \"\(trackName)\"",
                restore: nil,
                showUndoButton: false
            )
        case .liked:
            let trackName = track.title
            playlistManager.toggleLike(trackId: track.videoId)
            UndoService.shared.registerUndo(
                message: "Unliked \"\(trackName)\"",
                restore: nil,
                showUndoButton: false
            )
        }
    }

    // v1.6.9 (CV-15b): fetch a stream URL for a
    // liked (non-downloaded) track and queue it.
    // The fetched URL is cached in StreamURLCache
    // so subsequent plays of the same track
    // resolve immediately.
    private func addLikedTrackToQueue(_ track: DownloadedTrackItem) {
        let trackObj = track.track
        let title = track.title
        StreamURLCache.shared.getStreamUrl(videoId: trackObj.videoId, quality: "low")
            .sink(
                receiveCompletion: { completion in
                    if case .failure = completion {
                        // Quiet fail — same reasoning as
                        // playAllLiked.
                    }
                },
                receiveValue: { streamInfo in
                    let item = QueueItem(
                        track: trackObj,
                        streamUrl: streamInfo.streamUrl,
                        source: .stream
                    )
                    PlayerState.shared.addToQueue(item)
                    UndoService.shared.registerUndo(
                        message: "Added \(title) to Queue",
                        restore: nil,
                        showUndoButton: false
                    )
                    NotificationCenter.default.post(
                        name: .trackAddedToQueue,
                        object: trackObj
                    )
                }
            )
            .store(in: &cancellables)
    }

    // v1.6.9 (CV-15b): "Play Next" for a liked
    // (non-downloaded) track — fetch the stream URL
    // and insert at the head of the queue.
    private func playLikedTrackNext(_ track: DownloadedTrackItem) {
        let trackObj = track.track
        StreamURLCache.shared.getStreamUrl(videoId: trackObj.videoId, quality: "low")
            .sink(
                receiveCompletion: { completion in
                    if case .failure = completion {
                        // Quiet fail.
                    }
                },
                receiveValue: { streamInfo in
                    let item = QueueItem(
                        track: trackObj,
                        streamUrl: streamInfo.streamUrl,
                        source: .stream
                    )
                    PlayerState.shared.addToQueueNext(item)
                }
            )
            .store(in: &cancellables)
    }

    private func toggleSelection(_ track: DownloadedTrackItem) {
        let id = track.videoId
        if selectedTracks.contains(id) {
            selectedTracks.remove(id)
            print("🗑️ Deselected: \(track.title)")
        } else {
            selectedTracks.insert(id)
            print("🗑️ Selected: \(track.title)")
        }
        print("🗑️ Total selected: \(selectedTracks.count)")
    }
}

// MARK: - Grid Track Cell
struct GridTrackCell: View {
    let track: DownloadedTrackItem
    let isSelected: Bool
    let isEditing: Bool
    let isPlaying: Bool
    let memoryPreview: String?
    // v1.6.9 (CV-15b): the active LibraryMode
    // (Liked or Downloaded). Used to swap the
    // destructive context-menu label — "Unlike"
    // for liked, "Remove from Library" for
    // downloaded — and to hide the file-size line
    // in Liked mode (the placeholder item has no
    // real size).
    let mode: LibraryMode
    let onTap: () -> Void
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(Theme.cyberSurface)

                // Artwork image
                if let url = track.thumbnailURL {
                    CachedAsyncImage(url: url) {
                        Image(systemName: "music.note")
                            .font(.system(size: 40))
                            .foregroundColor(Theme.cyberDim)
                    }
                    .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundColor(Theme.cyberDim)
                }

                // Cyberpunk border
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .stroke(isPlaying ? Theme.cyberCyan.opacity(0.5) : Theme.cyberCyan.opacity(0.1), lineWidth: 1)

                if memoryPreview != nil {
                    SongMemoryBadge(text: nil)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                // Playing indicator overlay
                if isPlaying {
                    Color.black.opacity(0.3)

                    CyberPlayingBars()
                        .frame(width: 30, height: 30)
                }

                if !isEditing && !isPlaying {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .frame(width: 50, height: 50)
                            .background(Theme.cyberCyan.opacity(0.8))
                            .clipShape(Circle())
                            .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 10, x: 0, y: 0)
                    }
                }

                if isEditing {
                    Circle()
                        .fill(isSelected ? Theme.cyberCyan : Theme.cyberDim.opacity(0.3))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: isSelected ? "checkmark" : "")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Theme.cyberBackground)
                        )
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isPlaying ? Theme.cyberCyan : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(track.artist)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.cyberDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                // v1.6.9 (CV-15b): file size is hidden
                // in Liked mode. The Liked placeholder
                // item has an empty fileSizeFormatted
                // string (the track may not be
                // downloaded), so showing "" would be
                // visual noise. Downloaded mode keeps
                // the size line as before.
                if mode == .downloaded {
                    Text(track.fileSizeFormatted.uppercased())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.cyberTextSecondary)
                }
            }
        }
        // S13: tap target. The inner play-button overlay (in the
        // ZStack above) is itself a Button — SwiftUI's hit-testing
        // routes taps on the play button to its action, and taps
        // anywhere else on the row to this .onTapGesture. The
        // `.contentShape(Rectangle())` makes the entire artwork +
        // text area tappable (otherwise only the rendered shapes
        // would receive touches).
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
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

            Button {
                ShareHelper.shareTrack(
                    title: track.title,
                    artist: track.artist,
                    videoId: track.videoId
                )
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Button {
                ShareHelper.copyTrackInfo(
                    title: track.title,
                    artist: track.artist
                )
            } label: {
                Label("Copy Info", systemImage: "doc.on.doc")
            }

            Button {
                Task {
                    if let card = await ShareCardGenerator.generateCard(for: track.track) {
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
                NotificationCenter.default.post(name: .startSongRadio, object: track.track)
                HapticManager.light()
            } label: {
                Label("Start Radio", systemImage: "antenna.radiowaves.left.and.right")
            }

            Divider()

            // v1.6.9 (CV-15b): destructive action
            // label changes with the LibraryMode.
            // Downloaded = "Remove from Library"
            // (deletes the file from disk); Liked =
            // "Unlike" (toggles off the heart).
            // Same row, two meanings — the parent
            // LibraryView passes the right
            // onDelete closure for each.
            Button(role: .destructive, action: onDelete) {
                if mode == .liked {
                    Label("Unlike", systemImage: "heart.slash")
                } else {
                    Label("Remove from Library", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - List Track Row
struct ListTrackRow: View {
    let track: DownloadedTrackItem
    let isSelected: Bool
    let isEditing: Bool
    let isPlaying: Bool
    let memoryPreview: String?
    // v1.6.9 (CV-15b): the active LibraryMode
    // (Liked or Downloaded). Mirrors GridTrackCell
    // — same pattern of hiding the file-size line
    // and swapping the destructive label.
    let mode: LibraryMode
    let onTap: () -> Void
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                Circle()
                    .fill(isSelected ? Theme.cyberCyan : Theme.cyberDim.opacity(0.3))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: isSelected ? "checkmark" : "")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Theme.cyberBackground)
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.cyberSurface)
                        .frame(width: 50, height: 50)

                    if let url = track.thumbnailURL {
                        CachedAsyncImage(url: url) {
                            Image(systemName: "music.note")
                                .foregroundColor(Theme.cyberDim)
                        }
                        .frame(width: 50, height: 50)
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "music.note")
                            .foregroundColor(Theme.cyberDim)
                    }

                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isPlaying ? Theme.cyberCyan.opacity(0.5) : Color.clear, lineWidth: 1)

                    if isPlaying {
                        CyberPlayingBars()
                            .frame(width: 20, height: 20)
                            .padding(4)
                            .background(Theme.cyberBackground.opacity(0.8))
                            .cornerRadius(CornerRadius.xs)
                    }
                }
                .frame(width: 50, height: 50)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 15, weight: isPlaying ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundColor(isPlaying ? Theme.cyberCyan : .white)

                Text(track.artist)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.cyberDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                // v1.6.9 (CV-15b): file size hidden
                // in Liked mode (placeholder item has
                // empty fileSizeFormatted).
                if mode == .downloaded {
                    Text(track.fileSizeFormatted.uppercased())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.cyberTextSecondary)
                }

                if let memoryPreview {
                    SongMemoryBadge(text: memoryPreview)
                }
            }

            Spacer()

            if !isEditing {
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "waveform" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundColor(isPlaying ? Theme.cyberCyan : Theme.cyberDim)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(isPlaying ? Theme.cyberCyan.opacity(0.05) : Theme.cyberSurface.opacity(0.5))
        .cornerRadius(CornerRadius.md)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .stroke(isPlaying ? Theme.cyberCyan.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        // S13: same tap-target pattern as GridTrackCell. The inner
        // play Button (line 628) handles its own frame; everything
        // else on the row falls through to this .onTapGesture.
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
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

            Button {
                ShareHelper.shareTrack(
                    title: track.title,
                    artist: track.artist,
                    videoId: track.videoId
                )
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Button {
                ShareHelper.copyTrackInfo(
                    title: track.title,
                    artist: track.artist
                )
            } label: {
                Label("Copy Info", systemImage: "doc.on.doc")
            }

            Button {
                Task {
                    if let card = await ShareCardGenerator.generateCard(for: track.track) {
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
                NotificationCenter.default.post(name: .startSongRadio, object: track.track)
                HapticManager.light()
            } label: {
                Label("Start Radio", systemImage: "antenna.radiowaves.left.and.right")
            }

            Divider()

            // v1.6.9 (CV-15b): destructive action
            // label changes with LibraryMode.
            // Downloaded = "Remove from Library";
            // Liked = "Unlike" (with heart.slash
            // icon to telegraph the meaning).
            Button(role: .destructive, action: onDelete) {
                if mode == .liked {
                    Label("Unlike", systemImage: "heart.slash")
                } else {
                    Label("Remove from Library", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // v1.6.9 (CV-15b): swipe-to-delete
            // label mirrors the context menu —
            // "Remove" for downloaded, "Unlike"
            // for liked. The action is the same
            // onDelete closure either way; only
            // the visible label changes.
            Button(role: .destructive, action: onDelete) {
                if mode == .liked {
                    Label("Unlike", systemImage: "heart.slash")
                } else {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(action: onPlayNext) {
                Label("Next", systemImage: "text.badge.plus")
            }
            .tint(Theme.cyberMagenta)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Storage Info Sheet Cyberpunk
struct StorageInfoSheetCyberpunk: View {
    let totalSize: Int64
    let trackCount: Int
    let onClearAll: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.cyberBackground
                    .ignoresSafeArea()

                VStack(spacing: 24) {
                    // Header
                    Text("NEURAL_STORAGE")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.top, 24)

                    // Storage ring
                    ZStack {
                        Circle()
                            .stroke(Theme.cyberDim.opacity(0.2), lineWidth: 20)
                            .frame(width: 200, height: 200)

                        Circle()
                            .trim(from: 0, to: min(CGFloat(totalSize) / (500 * 1024 * 1024), 1.0))
                            .stroke(Theme.cyberCyan, style: StrokeStyle(lineWidth: 20, lineCap: .round))
                            .frame(width: 200, height: 200)
                            .rotationEffect(.degrees(-90))
                            .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 10, x: 0, y: 0)

                        VStack {
                            Text(formattedSize(totalSize).uppercased())
                                .font(.system(size: 28, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                            Text("OF 500 MB")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Theme.cyberDim)
                        }
                    }
                    .padding(.top, 16)

                    // Stats
                    VStack(spacing: 16) {
                        StatRowCyberpunk(title: "TRACKS", value: "\(trackCount)")
                        StatRowCyberpunk(title: "AVERAGE", value: trackCount > 0 ? formattedSize(totalSize / Int64(trackCount)) : "0")
                        StatRowCyberpunk(title: "TOTAL", value: formattedSize(totalSize))
                    }
                    .padding(.horizontal)

                    Spacer()

                    VStack(spacing: 12) {
                        Button(action: {
                            onClearAll()
                            dismiss()
                        }) {
                            Text("PURGE_ALL")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.cyberMagenta)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Theme.cyberMagenta.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: CornerRadius.sm)
                                        .stroke(Theme.cyberMagenta.opacity(0.3), lineWidth: 1)
                                )
                                .cornerRadius(CornerRadius.sm)
                        }

                        Button(action: { dismiss() }) {
                            Text("CLOSE")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Theme.cyberSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: CornerRadius.sm)
                                        .stroke(Theme.cyberCyan.opacity(0.3), lineWidth: 1)
                                )
                                .cornerRadius(CornerRadius.sm)
                        }
                    }
                    .padding()
                }
            }
            .navigationBarHidden(true)
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct StatRowCyberpunk: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Theme.cyberDim)
            Spacer()
            Text(value.uppercased())
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.vertical, 12)
        Divider()
            .background(Theme.cyberCyan.opacity(0.2))
    }
}

struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryView()
    }
}
