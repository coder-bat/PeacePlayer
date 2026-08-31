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

// 2026-08-14: renamed `struct LibraryView` to
// `struct LibraryContent` and added a new thin
// `struct LibraryView` wrapper below that hosts
// the content in its own NavigationStack. The
// HomeView's `.library` destination pushes
// `LibraryContent()` directly (no inner
// NavigationStack — that crashed iOS). Same
// pattern as `LikedSongsContent` / `LikedSongsView`.
//
// The body inside `LibraryContent` is also a clean
// 2026-08-14 UI pass: removed the system
// `ToolbarItem`-based top-right buttons (they
// rendered with the iOS system toolbar look — blue
// tint, system padding), replaced the segmented
// `Picker` for Liked/Downloaded with a custom chip
// strip matching SearchView's `FilterChip`, restyled
// the search bar to match SearchView's
// "FIND MUSIC..." treatment, and rewrote the list
// row to use the unified `TrackRow` configured to
// match `SearchResultRow` (50pt artwork, title +
// artist subtitle, cyberCyan playing highlight,
// 36pt right-side accessory cluster). All previous
// functionality (SELECT mode with multi-select,
// downloads bell with active/failed badge, grid/list
// toggle, sort menu, storage info, download queue,
// delete alert) is preserved.

struct LibraryContent: View {
    // 2026-08-14: `showsBackButton` is true when the
    // content is pushed onto a parent NavigationStack
    // (e.g. from Home's "View All" link). When true, a
    // custom chevron back button is rendered at the
    // leading edge of the header instead of the system
    // nav bar's back button. When false (the Library
    // tab root), no back button is shown — there's
    // nowhere to go back to.
    var showsBackButton: Bool = false
    // 2026-08-14: SwiftUI's dismiss action — pops the
    // current destination from the parent NavigationStack
    // (no-op when there's no parent to pop, e.g. the
    // Library tab root). Always available via the
    // environment; only called from the custom back
    // button.
    @Environment(\.dismiss) private var dismiss

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
    // 2026-08-14: search bar focus state. Matches the
    // SearchView's `isSearchFocused` pattern — drives the
    // animated cyan-stroke border on the input.
    @FocusState private var isSearchFocused: Bool
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
        // 2026-08-14: removed the inner NavigationStack
        // (now provided by the `LibraryView` wrapper) and
        // the system `.toolbar { ToolbarItem ... }` chrome
        // (which rendered buttons with the iOS system
        // toolbar look — blue tint, system padding). The
        // chrome is now a custom `HStack` inside the
        // `customHeader` view, with the same affordances
        // (downloads bell, SELECT, view mode, sort) but
        // themed to match the rest of the app: cyber cyan
        // icons on glass circles, monospaced labels.
        //
        // Mode picker, search bar, and list row were also
        // restyled in this pass — see `modePicker`,
        // `searchBar`, and `listView`.
        ZStack {
            // Cyberpunk background
            Theme.cyberBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                customHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

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
        // 2026-08-14: hide the system nav bar so the
        // customHeader is the only header chrome. When
        // LibraryContent is hosted inside the
        // `LibraryView` wrapper (the Library tab
        // root), the wrapper also applies
        // `.toolbar(.hidden, for: .navigationBar)`
        // — applying it here too is redundant but
        // safe, and is the only way to hide the
        // system back button when LibraryContent is
        // pushed onto a parent NavigationStack
        // (e.g. Home's `.library` destination).
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            viewModel.loadLibrary()
        }
    }

    // 2026-08-14: replaced the system toolbar with a
    // custom HStack header. Same affordances as before
    // (downloads bell with active/failed badge, SELECT
    // toggle, grid/list view-mode toggle, sort menu) but
    // themed to match the rest of the app: cyber cyan
    // icons on a glass surface, monospaced labels, no
    // system toolbar tint.
    private var customHeader: some View {
        HStack(spacing: 10) {
            // 2026-08-14: custom back chevron at the
            // leading edge when this view was pushed
            // onto a parent NavigationStack (e.g. from
            // Home's "View All" link). Replaces the
            // system nav bar back button — same icon
            // weight, size, and tint as
            // AntiAlgorithmScreen and RadioView's
            // custom back chevron so the destinations
            // share one back-button language. Hidden
            // when this is the Library tab root (no
            // parent to pop to).
            if showsBackButton {
                Button {
                    HapticManager.light()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Theme.cyberCyan)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }

            // Title (left) — gives the header structure and
            // matches the rest of the app's screen-level
            // titles (e.g. Home's "Downloaded", Search's
            // "Search").
            Text("Library")
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .shadow(color: Theme.cyberCyan.opacity(0.4), radius: 8, x: 0, y: 0)

            Spacer()

            // Right-side action cluster. Each button is a
            // glass circle with a cyber cyan icon, matching
            // the chip cluster style we use on Home.
            // Conditional on isEditing (DONE / DELETE
            // instead of bell / select / etc).
            if isEditing {
                // DONE button (monospaced label, no icon —
                // the standard "exit edit mode" affordance).
                Button {
                    isEditing = false
                    selectedTracks.removeAll()
                } label: {
                    Text("DONE")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyberCyan)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.cyberSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Theme.cyberCyan.opacity(0.5), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)

                // DELETE / UNLIKE button — destructive,
                // magenta tint. Only shown when at least one
                // row is selected.
                if !selectedTracks.isEmpty {
                    Button {
                        HapticManager.light()
                        viewModel.showDeleteConfirmation = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .bold))
                            Text(libraryMode == .liked ? "UNLIKE" : "DELETE")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                            Text("\(selectedTracks.count)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(Theme.cyberMagenta.opacity(0.3))
                                )
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.cyberMagenta.opacity(0.18))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Theme.cyberMagenta.opacity(0.6), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            } else {
                // Normal (non-edit) action cluster: 4 glass
                // circle buttons (downloads bell, SELECT,
                // view mode, sort). Each is a ZStack with a
                // circle background and an SF Symbol, so
                // they read as a cohesive set, not a row of
                // system buttons.

                // Downloads queue bell — Downloaded mode only.
                if libraryMode == .downloaded {
                    headerIconButton(
                        systemImage: "arrow.down.circle",
                        badge: downloadBadgeText,
                        badgeColor: downloadBadgeColor,
                        accessibilityLabel: "Downloads",
                        accessibilityHint: "Show download queue and history"
                    ) {
                        HapticManager.light()
                        showDownloadQueue = true
                    }
                }

                // SELECT — also shows the selected count
                // when isEditing is somehow true (defensive
                // — this branch only renders when
                // !isEditing, but the toolbar code had the
                // same dual-state button, so we keep parity).
                headerIconButton(
                    systemImage: "checkmark.circle",
                    badge: nil,
                    badgeColor: .cyberCyan,
                    accessibilityLabel: "Select tracks",
                    accessibilityHint: "Enter multi-select mode"
                ) {
                    HapticManager.light()
                    isEditing = true
                }
                .opacity(currentTracks.isEmpty ? 0.4 : 1)
                .disabled(currentTracks.isEmpty)

                // Grid / list view-mode toggle.
                headerIconButton(
                    systemImage: viewMode == .grid ? "list.bullet" : "square.grid.2x2",
                    badge: nil,
                    badgeColor: .cyberCyan,
                    accessibilityLabel: viewMode == .grid ? "Switch to list view" : "Switch to grid view",
                    accessibilityHint: nil
                ) {
                    HapticManager.light()
                    viewMode = viewMode == .grid ? .list : .grid
                }

                // Sort menu — the only button that retains
                // a `Menu` because the dropdown contents
                // (sort options + storage info) are
                // multi-item. The trigger itself is the
                // same glass-circle style as the other
                // buttons.
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
                    // mode.
                    if libraryMode == .downloaded {
                        Divider()
                        Button {
                            showStorageInfo = true
                        } label: {
                            Label("STORAGE INFO", systemImage: "externaldrive")
                        }
                    }
                } label: {
                    headerIconCircle(systemImage: "arrow.up.arrow.down")
                }
            }
        }
    }

    // 2026-08-14: helper for the glass-circle icon
    // buttons in `customHeader`. Renders a 32pt circle
    // on a `cyberSurface` fill with a 1pt cyber cyan
    // stroke, an SF Symbol centered inside, and an
    // optional pill badge in the top-right corner (used
    // by the downloads bell to show active + failed
    // download count). The badge mirrors the old toolbar
    // behavior exactly (active + failed count, magenta
    // tint when any are failed, yellow otherwise).
    @ViewBuilder
    private func headerIconButton(
        systemImage: String,
        badge: String?,
        badgeColor: Color,
        accessibilityLabel: String,
        accessibilityHint: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            headerIconCircle(
                systemImage: systemImage,
                badge: badge,
                badgeColor: badgeColor
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint ?? "")
    }

    // 2026-08-14: the visual primitive for a header
    // icon button — glass circle + SF Symbol + optional
    // badge. Extracted so the `Menu` (sort) can reuse the
    // same look without going through the action-button
    // wrapper.
    @ViewBuilder
    private func headerIconCircle(
        systemImage: String,
        badge: String? = nil,
        badgeColor: Color = .cyberCyan
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Circle()
                    .fill(Theme.cyberSurface)
                    .frame(width: 32, height: 32)
                Circle()
                    .stroke(Theme.cyberCyan.opacity(0.45), lineWidth: 1)
                    .frame(width: 32, height: 32)
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.cyberCyan)
            }
            if let badge {
                Text(badge)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(badgeColor))
                    .offset(x: 6, y: -4)
            }
        }
    }

    // 2026-08-14: computed badge text + color for the
    // downloads bell. Mirrors the old toolbar badge
    // exactly: sum of active + failed download counts,
    // magenta if any are failed (more urgent), yellow
    // otherwise. nil when there's nothing to show, so
    // `headerIconCircle` can skip rendering the badge.
    private var downloadBadgeText: String? {
        let activeCount = DownloadManager.shared.activeDownloads.count
        let failedCount = DownloadManager.shared.completedDownloads.filter {
            if case .failed = $0.status { return true }; return false
        }.count
        let total = activeCount + failedCount
        return total > 0 ? "\(total)" : nil
    }
    private var downloadBadgeColor: Color {
        let failedCount = DownloadManager.shared.completedDownloads.filter {
            if case .failed = $0.status { return true }; return false
        }.count
        return failedCount > 0 ? Theme.cyberMagenta : Theme.cyberYellow
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
        // 2026-08-14: removed the duplicate "Library"
        // title HStack — `customHeader` at the top of
        // the body now owns the title + action cluster.
        // The mode picker, play-all row, search bar,
        // stats bar, and content all live here.
        VStack(spacing: 0) {
            // v1.6.9 (CV-15b): mode picker toggles
            // between Liked and Downloaded. Same view,
            // same screen, one tap to switch — meets
            // the "show both in the same view" goal
            // without burying one mode behind a card
            // or a sheet.
            modePicker
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            // v1.6.9 (CV-15b): Play-all row. Only
            // shown in Liked mode (Downloaded mode
            // already has Play / Shuffle buttons
            // elsewhere via the row context menu
            // and the FullPlayer's Play All from
            // an artist).
            if libraryMode == .liked && !currentTracks.isEmpty {
                playAllRow
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            // Search bar
            searchBar
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

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
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Content
            if viewMode == .grid {
                gridView
            } else {
                listView
            }
        }
    }

    // 2026-08-14: replaced the segmented `Picker` with a
    // custom chip strip matching SearchView's `FilterChip`.
    // The segmented control rendered with the iOS system
    // look (rounded gray pill, system-tinted selected
    // state) which clashed with the rest of the app's
    // custom cyber theme. Now both modes are pills with
    // a cyber-cyan filled state when selected and a
    // dim-stroke + surface fill when unselected, identical
    // to the "ALL / SONGS / PLAYLISTS" filter row at the
    // top of SearchView.
    //
    // Each chip also shows a count badge (liked count /
    // downloaded count) so the user can see at a glance
    // how many tracks are in each mode without switching
    // to find out.
    private var modePicker: some View {
        HStack(spacing: 10) {
            // Liked chip
            LibraryModeChip(
                title: "Liked",
                icon: "heart.fill",
                count: playlistManager.likedTracks.count,
                isSelected: libraryMode == .liked
            ) {
                HapticManager.medium()
                withAnimation(.spring(response: 0.3)) {
                    libraryMode = .liked
                }
            }

            // Downloaded chip
            LibraryModeChip(
                title: "Downloaded",
                icon: "arrow.down.circle.fill",
                count: viewModel.tracks.count,
                isSelected: libraryMode == .downloaded
            ) {
                HapticManager.medium()
                withAnimation(.spring(response: 0.3)) {
                    libraryMode = .downloaded
                }
            }

            Spacer()
        }
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

    // 2026-08-14: restyled to match SearchView's
    // "FIND MUSIC..." treatment. Same monospaced
    // placeholder, same animated focus border, same
    // magnifier icon color transition, same xmark
    // clear button. The placeholder is uppercased
    // ("SEARCH LIBRARY...") to match the "FIND MUSIC..."
    // pattern from SearchView.
    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(isSearchFocused || !searchQuery.isEmpty ? .cyberCyan : .cyberDim)

            TextField("", text: $searchQuery,
                      prompt: Text("SEARCH LIBRARY...")
                          .foregroundColor(Color.cyberDim)
                          .font(.system(size: 14, design: .monospaced)))
                .foregroundColor(.white)
                .font(.system(size: 14, design: .monospaced))
                .focused($isSearchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accentColor(Theme.cyberCyan)

            if !searchQuery.isEmpty {
                Button {
                    HapticManager.light()
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.cyberDim)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.cyberSurface)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .stroke(
                    isSearchFocused || !searchQuery.isEmpty
                        ? Color.cyberCyan.opacity(0.5)
                        : Color.cyberDim.opacity(0.3),
                    lineWidth: 1
                )
        )
        .cornerRadius(CornerRadius.md)
        .animation(.easeInOut(duration: 0.2), value: isSearchFocused)
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

    // 2026-08-14: rewrote the list view to use the
    // unified `TrackRow` configured to match
    // `SearchResultRow`'s style (50pt artwork, title +
    // artist subtitle, cyber-cyan playing highlight,
    // 36pt right-side accessory cluster with download
    // icon / playing bars / small play icon). The
    // previous `ListTrackRow` was its own bespoke
    // component with subtle inconsistencies vs Search
    // (different title/subtitle sizes, different
    // right-side accessory, file-size line that's
    // irrelevant for the Liked mode and unused in
    // practice).
    //
    // The edit-mode selection circle is rendered
    // OUTSIDE the TrackRow via a leading HStack, so
    // the row itself stays a clean SearchView match
    // when not editing. The `.contextMenu` +
    // `.swipeActions` on TrackRow give us Play /
    // Play Next / Add to Queue / Like / Delete
    // without needing our own custom row component.
    //
    // We use a plain `List` (still .listStyle(.plain))
    // for the swipe-to-delete affordance + section
    // separator support that `TrackRow` already
    // provides. The `.listRowBackground(Color.cyberSurface)`
    // matches SearchView's results list so the two
    // surfaces feel like one design system.
    private var listView: some View {
        List {
            ForEach(currentTracks) { track in
                let isSelected = selectedTracks.contains(track.videoId)
                let isPlaying = viewModel.isCurrentlyPlaying(track)
                let isDownloadedTrack = libraryMode == .downloaded
                // 2026-08-14: `isDownloaded` for the badge
                // cluster — true in Downloaded mode
                // (always, by construction) AND in Liked
                // mode if the track happens to also be on
                // disk (the user liked it before/after
                // downloading it). Mirrors
                // `SearchResultRow.isDownloaded` which
                // checks via `LibraryViewModel.isAlreadyDownloaded`.
                let trackIsOnDisk: Bool = {
                    if isDownloadedTrack { return true }
                    return AudioFileManager.shared.isPlayable(
                        videoId: track.videoId,
                        context: PersistenceController.shared.viewContext
                    )
                }()

                HStack(spacing: 12) {
                    if isEditing {
                        // 2026-08-14: edit-mode selection
                        // circle. Same 24pt cyber-cyan
                        // filled circle with a white
                        // checkmark as the previous
                        // `ListTrackRow`, kept on the
                        // leading edge of the row. Tapping
                        // anywhere on the row still
                        // toggles selection in edit mode
                        // (handled by the
                        // `Button { toggleSelection(track) }`
                        // below).
                        Button {
                            HapticManager.light()
                            toggleSelection(track)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(isSelected ? Theme.cyberCyan : Color.clear)
                                    .frame(width: 22, height: 22)
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                isSelected ? Theme.cyberCyan : Theme.cyberDim.opacity(0.5),
                                                lineWidth: 1.5
                                            )
                                    )
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(Theme.cyberBackground)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    // 2026-08-14: the SearchView-style
                    // track row. Same visual treatment as
                    // SearchView.SearchResultRow — 50pt
                    // artwork, title + artist subtitle,
                    // cyber-cyan playing highlight, 36pt
                    // right-side accessory cluster.
                    TrackRow(
                        title: track.title,
                        subtitle: track.artist,
                        subtitle2: nil,  // no album/duration
                        artworkURL: track.thumbnailURL,
                        isPlaying: isPlaying,
                        // 2026-08-14: dropped subtitle2
                        // (no file-size line) for visual
                        // parity with SearchView's
                        // `SearchResultRow`. The file
                        // size is still shown in the
                        // header stats bar above the
                        // list (`.padding(.horizontal)`
                        // row with "X TRACKS · Y MB")
                        // for Downloaded mode.
                        showSubtitle: true,
                        accessory: .custom(AnyView(
                            libraryAccessoryCluster(
                                isPlaying: isPlaying,
                                isDownloaded: trackIsOnDisk,
                                isEditing: isEditing
                            )
                        )),
                        onTap: {
                            if isEditing {
                                HapticManager.light()
                                toggleSelection(track)
                            } else {
                                HapticManager.medium()
                                viewModel.playTrack(track)
                            }
                        }
                    )
                }
                .listRowBackground(Color.cyberSurface)
                .listRowSeparatorTint(Theme.cyberDim.opacity(0.2))
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // 2026-08-14: trailing swipe action
                    // — destructive action labelled per
                    // mode (Unlike / Remove from
                    // Library), matches the old
                    // `ListTrackRow`'s swipe behavior.
                    Button(role: .destructive) {
                        handleDelete(track)
                    } label: {
                        Label(
                            libraryMode == .liked ? "Unlike" : "Remove",
                            systemImage: libraryMode == .liked ? "heart.slash" : "trash"
                        )
                    }
                    .tint(libraryMode == .liked ? Theme.cyberMagenta : Theme.cyberCyan)

                    // 2026-08-14: also surface Play Next
                    // + Add to Queue as swipe actions,
                    // matching the SearchView's swipe
                    // action set.
                    Button {
                        HapticManager.light()
                        handleAddToQueue(track)
                    } label: {
                        Label("Queue", systemImage: "plus")
                    }
                    .tint(Theme.cyberMagenta)
                }
                .contextMenu {
                    Button {
                        HapticManager.medium()
                        viewModel.playTrack(track)
                    } label: {
                        Label(isPlaying ? "Now Playing" : "Play", systemImage: "play.fill")
                    }

                    Button {
                        HapticManager.light()
                        handlePlayNext(track)
                    } label: {
                        Label("Play Next", systemImage: "text.badge.plus")
                    }

                    Button {
                        HapticManager.light()
                        handleAddToQueue(track)
                    } label: {
                        Label("Add to Queue", systemImage: "plus")
                    }

                    // 2026-08-14: like/unlike context
                    // menu item — only shown in
                    // Downloaded mode (Liked mode is
                    // already the "liked" view, so
                    // toggling is redundant).
                    if libraryMode == .downloaded {
                        Button {
                            HapticManager.medium()
                            playlistManager.toggleLike(trackId: track.videoId)
                        } label: {
                            let isLiked = playlistManager.isLiked(trackId: track.videoId)
                            Label(isLiked ? "Unlike" : "Like",
                                  systemImage: isLiked ? "heart.slash.fill" : "heart.fill")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        HapticManager.medium()
                        handleDelete(track)
                    } label: {
                        Label(libraryMode == .liked ? "Unlike" : "Remove from Library",
                              systemImage: libraryMode == .liked ? "heart.slash" : "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.cyberBackground)
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

    // 2026-08-14: 36pt right-side accessory cluster
    // for the SearchView-style track row. Mirrors
    // `SearchResultRow`'s right cluster: a small
    // downloaded indicator on the left (when
    // downloaded), then a play icon or playing bars on
    // the right. Wrapped in `AnyView` via the
    // `TrackRowAccessory.custom` case so we can use the
    // existing `TrackRow` primitive instead of
    // duplicating it.
    @ViewBuilder
    private func libraryAccessoryCluster(
        isPlaying: Bool,
        isDownloaded: Bool,
        isEditing: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if isDownloaded && !isEditing {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.cyberCyan)
            }

            if isPlaying {
                CyberPlayingBars()
            } else if !isEditing {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.cyberCyan)
            } else {
                // Edit mode: show nothing on the right
                // (the selection circle is on the
                // leading edge).
                EmptyView()
            }
        }
        .frame(width: 36)
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
            // v1.8.7 / S18-LIBRARY-GRID-OVERFLOW: the ZStack used
            // to host a CachedAsyncImage with no frame. The
            // CachedAsyncImage renders at the image's natural
            // pixel size (e.g. 720x720 for the largest
            // thumbnail), which is larger than the grid cell
            // (column width = ~163pt on iPhone). The ZStack's
            // .aspectRatio(1, .fit) constrained the ZStack's
            // frame to a square — but the children inside still
            // rendered at their intrinsic sizes and overflowed
            // the ZStack's bounds, despite the trailing
            // .clipShape. .scaledToFill() on a non-Image view
            // is a no-op.
            //
            // The v1.8.7 fix: drop .scaledToFill() (no-op here)
            // and give the CachedAsyncImage an explicit
            // maxWidth/maxHeight .infinity frame so it
            // stretches to the ZStack's bounds. The ZStack's
            // .aspectRatio(1, .fit) defines the square; the
            // CachedAsyncImage fills that square.
            //
            // 2026-08-14 / S18-LIBRARY-GRID-OVERFLOW-2: the
            // v1.8.7 fix was incomplete. The
            // `.frame(maxWidth: .infinity).aspectRatio(1, .fit)`
            // pattern on a ZStack is unreliable when the
            // children have variable intrinsic sizes (the
            // placeholder SF Symbol is 40x40; the loaded
            // image is its natural pixel size like 720x720;
            // the resizable+fill image has no intrinsic size
            // at all). The aspectRatio modifier picks the
            // larger of the intrinsic dimensions and the
            // proposed size, which means cells where the
            // placeholder hasn't yet been replaced by the
            // loaded image OR where the resizable image
            // "leaks" through with a different intrinsic size
            // get sized larger than the column. The trailing
            // .clipShape only hides the visual overflow; the
            // LAYOUT frame is still wrong, so neighboring
            // cells get pushed sideways.
            //
            // 2026-08-14 / S18-LIBRARY-GRID-OVERFLOW-4: the
            // previous fix (Color.clear.aspectRatio + .overlay)
            // was still leaking the ZStack's intrinsic content
            // size up through the overlay into the outer VStack.
            // The CachedAsyncImage, when loaded, has a
            // `image.resizable().aspectRatio(contentMode: .fill)`
            // child whose intrinsic size is the image's natural
            // pixel size (e.g., 720×720). Without an explicit
            // frame constraint, that intrinsic size propagates
            // up: the ZStack becomes 720×720, the overlay
            // reports 720×720 to its parent (Color.clear), and
            // the outer VStack ends up 720 wide — which is way
            // more than the 172pt column. The .clipShape
            // hides the visual overflow, but the LAYOUT
            // frame is still wrong, so the whole cell is
            // wider than its column and the next column gets
            // pushed off-screen.
            //
            // The fix: explicitly bound the ZStack to the
            // overlay's size with `.frame(maxWidth: .infinity,
            // maxHeight: .infinity)`. Now the ZStack's layout
            // frame is the overlay's size (172.5×172.5),
            // not its intrinsic content size. The
            // CachedAsyncImage (which still has no explicit
            // frame, since the overlay already bounds it) is
            // also bounded to 172.5×172.5. The visual
            // overflow is gone AND the layout is correct.
            //
            // Also added `.frame(maxWidth: .infinity,
            // alignment: .leading)` on the outer VStack
            // (forces it to take the full column width
            // instead of its intrinsic content width) and
            // on the text VStack (forces it to the column
            // width so long titles don't push the cell
            // wider). Together these four constraints make
            // the cell's layout frame exactly column-width
            // regardless of any child's intrinsic size.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay(
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
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 40))
                                .foregroundColor(Theme.cyberDim)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    // 2026-08-14 / OVERFLOW-4: bound the
                    // ZStack to the overlay's size. Without
                    // this, the CachedAsyncImage's natural
                    // 720×720 intrinsic size propagates up
                    // and the whole cell overflows the
                    // column. With this, the ZStack's
                    // layout frame is the overlay's size
                    // (column-width square) and the
                    // CachedAsyncImage is constrained
                    // inside it.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
                )

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
            // 2026-08-14 / OVERFLOW-4: bound the text
            // VStack to the column width. Without
            // this, a long track title or artist
            // name would let the text VStack's
            // intrinsic content width exceed the
            // column, pushing the whole cell wider.
            // With `.frame(maxWidth: .infinity)` the
            // text VStack takes the column width and
            // the `.lineLimit(1)` on the Text views
            // truncates cleanly at the column edge.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 2026-08-14 / OVERFLOW-4: bound the outer
        // VStack to the column width. Without this,
        // the VStack's intrinsic content width
        // (the max of its children's widths) could
        // exceed the column if any child's intrinsic
        // size was larger than the column — the
        // Color.clear with aspectRatio is column
        // width, but the text VStack's intrinsic
        // content width could be wider for a long
        // title. Forcing `.frame(maxWidth: .infinity)`
        // on the outer VStack ensures the cell's
        // layout frame is exactly the column width
        // regardless of any child's intrinsic size.
        .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Library Mode Chip
//
// 2026-08-14: custom Liked / Downloaded mode pill
// matching SearchView's `FilterChip` (same cyber-cyan
// filled state when selected, dim-stroke + surface fill
// when unselected, count badge in the trailing edge).
// Replaces the system `Picker` + `.segmented` style.
struct LibraryModeChip: View {
    let title: String
    let icon: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))

                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            isSelected
                                ? Color.cyberBackground.opacity(0.3)
                                : Color.cyberDim.opacity(0.25)
                        )
                        .clipShape(Capsule())
                }
            }
            .foregroundColor(isSelected ? .cyberBackground : .white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Color.cyberCyan : Color.cyberSurface)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(
                        isSelected ? Color.clear : Color.cyberDim.opacity(0.4),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
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
                    HStack(spacing: 6) {
                        Text(track.fileSizeFormatted.uppercased())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.cyberTextSecondary)
                        // v1.9.0: Smart Library tier badge
                        // for auto-downloaded tracks.
                        // Self-hides for .liked / .manual
                        // tracks (per the plan decision:
                        // "Auto only"). Color shifts
                        // cyan → yellow → magenta as the
                        // cleanup grace period runs down.
                        LibraryTierBadge(videoId: track.videoId)
                    }
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

// 2026-08-14: thin wrapper that hosts `LibraryContent` in
// a NavigationStack. Used by the Library tab (so the tab
// still gets a NavigationStack host, useful for any future
// push destinations from Library). The HomeView's
// `.library` destination uses `LibraryContent()` directly
// to avoid nested NavigationStacks (crash on iOS).
//
// `.toolbar(.hidden, for: .navigationBar)` is applied here
// so the Library tab doesn't get a system back button
// (the tab is the root — there's nowhere to go back to).
// When the content is pushed from another surface (e.g.
// Home's "View All" link), that surface owns the
// NavigationStack and hides its own system back button
// (the pushed `LibraryContent(showsBackButton: true)`
// renders its own custom back chevron in the header).
struct LibraryView: View {
    var body: some View {
        NavigationStack {
            LibraryContent()
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryView()
    }
}
