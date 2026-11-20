//
//  TurntableHomeView.swift
//  YTAudioPlayer
//
//  The Turntable Home — the record is the screen.
//
//  Replaces the old Home body (flag: ff_turntable_home). Every
//  interactive element maps onto an API that already exists:
//
//    platter rotation  -> PlayerState.playbackClock.progress
//    tonearm drag      -> PlayerState.seek(to:)
//    cue lever         -> PlayerState.togglePlayPause()
//    platter tap       -> PlayerState.showFullPlayer
//    platter long-press-> PlayerState.showQueue
//    shelf sleeves     -> HomeViewModel.playTrack(_:)
//    queue discs       -> PlayerState.playQueue(at:)
//    loading lamp      -> PlayerState.playbackState.isLoading
//    DIG key           -> AntiAlgorithmEngine.startExplorationSession
//    RADIO / SETUP key -> Home's NavigationStack (.radio / .settings)
//    REVIEW key        -> SmartLibraryReviewSheet / CleanupReviewSheet
//
//  The view deliberately owns NO playback state of its own. It reads
//  PlayerState and calls its methods; that keeps the deck honest
//  (it cannot show a position the player does not agree with) and
//  means every existing player control keeps working unchanged.
//
//

import SwiftUI
import Combine

// MARK: - Model

enum TurntableHomeModel {
    /// What the card on the recently-played shelf says.
    static let recentShelfTitle = "Recently played"

    /// What the deck says while the DIG key is working.
    static let diggingNotice = "Digging outside your bubble…"
    /// …when the engine found nothing to deal.
    static let digCameBackEmptyNotice = "Nothing new turned up. Try again"
    /// …when there is no listening history to steer away from.
    static let nothingToDigFromNotice = "Play a few songs first, then dig"
    /// What the deck says when the review button has nothing to open.
    static let nothingToReviewNotice = "Nothing waiting for review"
    /// …while an album is being fetched and its stream URLs resolved.
    static let loadingAlbumNotice = "Loading the album…"

    /// The mark the caption carries while the tray is browsed: the
    /// focused record's place in the queue, "7/20". Nil when nothing
    /// is being browsed.
    static func browsingMark(index: Int?, count: Int) -> String? {
        guard let index, index >= 0, index < count else { return nil }
        return "\(index + 1)/\(count)"
    }

    /// What the lamps on the deck's keys are doing.
    ///
    /// DIG pulses while the engine is looking, and stays lit for as
    /// long as the record on the platter is one it dealt — not for as
    /// long as the engine's session is open, which is until the app
    /// quits. RADIO is lit while a live station is playing. REVIEW is
    /// lit while something is waiting on the user.
    static func keyStates(
        isDigging: Bool,
        dugTrackIDs: [String],
        nowPlayingID: String?,
        isRadioPlaying: Bool,
        hasPendingReview: Bool = false
    ) -> [DeckKey: DeckKeyState] {
        var states: [DeckKey: DeckKeyState] = [:]
        if isDigging {
            states[.dig] = .working
        } else if let nowPlayingID, dugTrackIDs.contains(nowPlayingID) {
            states[.dig] = .lit
        }
        if isRadioPlaying {
            states[.radio] = .lit
        }
        if hasPendingReview {
            states[.review] = .lit
        }
        return states
    }

    /// The shelves under the deck.
    ///
    /// One shelf per favourite artist, in the order the user ranked
    /// them, holding that artist's albums; then one shelf of what
    /// was played recently. An album stands on one shelf only — the
    /// first that claims it — and a shelf with nothing left on it is
    /// not put up at all. Liked songs live in the Library tab, not
    /// here.
    ///
    /// The queue is not here: it has its own tray, directly under the
    /// deck.
    static func shelves(
        albums: [String: [Album]],
        artistOrder: [String],
        recent: [RecentTrack],
        perArtist: Int = CrateGrid.columnCount,
        recentLimit: Int = CrateGrid.columnCount * 2
    ) -> [CrateShelfModel] {
        var seen = Set<String>()
        var result: [CrateShelfModel] = []

        // The user's order first; any artist the order does not know
        // about follows alphabetically, so the shelves never reshuffle
        // between renders.
        var artists = artistOrder.filter { albums[$0] != nil }
        let ranked = Set(artists)
        artists += albums.keys.filter { !ranked.contains($0) }.sorted()

        for artist in artists {
            var list: [Album] = []
            for album in albums[artist] ?? [] where list.count < perArtist {
                guard seen.insert(album.browseId).inserted else { continue }
                list.append(album)
            }
            guard !list.isEmpty else { continue }
            result.append(CrateShelfModel(id: "artist-\(artist)", title: artist, albums: list))
        }

        var recents: [Track] = []
        for entry in recent where recents.count < recentLimit {
            guard seen.insert(entry.videoId).inserted else { continue }
            recents.append(entry.toTrack)
        }
        if !recents.isEmpty {
            result.append(CrateShelfModel(id: "recent", title: recentShelfTitle, tracks: recents))
        }

        return result
    }
}

// MARK: - View

struct TurntableHomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject var favoriteArtists: FavoriteArtistsManager
    @ObservedObject var playerState: PlayerState

    /// The queue lives in its own observable so queue mutations do not
    /// re-render every PlayerState observer.
    ///
    /// The deck HAS to follow it: it shows the record that is playing
    /// and the queue of records coming up, and both change when
    /// playback starts somewhere else (the Library tab, a shortcut,
    /// the notification). Watching only `playerState` left the deck
    /// showing the old song and an empty shelf (2026-11-18).
    @ObservedObject var queueStore: QueueStore

    /// The Anti-Algorithm engine, behind the deck's DIG key.
    @ObservedObject private var explorer = AntiAlgorithmEngine.shared

    /// Pushes a destination onto Home's NavigationStack. Home owns the
    /// stack; the deck only asks.
    var onNavigate: (HomeDestination) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The DIG key was pressed and the engine has not answered yet.
    @State private var digPending = false
    /// A line the deck is showing in place of the track's name.
    @State private var notice: String?
    /// The button the line came from: its symbol and its colour.
    @State private var noticeSymbol = DeckKey.dig.symbol
    @State private var noticeColor = DeckKey.dig.accent
    @State private var noticeToken = 0
    /// The queue record the tray has in focus while it is being
    /// browsed; nil when the focus is on the one that is playing.
    @State private var browsedIndex: Int?

    /// The record the caption names: the one being browsed, if any.
    private var captionItem: QueueItem? {
        if let browsedIndex, playerState.queue.indices.contains(browsedIndex) {
            return playerState.queue[browsedIndex]
        }
        return playerState.currentItem
    }

    /// Where the arm was last put down, held until the player gets
    /// there. A seek is not instant; without this the arm would drop
    /// back to the old position for a beat and then jump.
    @State private var pendingSeek: Double?
    @State private var showSmartLibrary = false
    @State private var showCleanup = false

    init(
        viewModel: HomeViewModel,
        favoriteArtists: FavoriteArtistsManager,
        playerState: PlayerState,
        onNavigate: @escaping (HomeDestination) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.favoriteArtists = favoriteArtists
        self.playerState = playerState
        self.queueStore = playerState.queueStore
        self.onNavigate = onNavigate
    }

    /// Room kept clear under the last shelf for the tab bar, which
    /// floats over the bottom of the deck.
    private static let tabBarClearance: CGFloat = 104

    /// The progress the deck shows.
    ///
    /// Source is `playbackClock.progress`, NOT `PlayerState.progress`:
    /// the latter is a legacy @Published mirror that the hot path no
    /// longer writes (PlayerState.swift, "Sprint 2 / C-4 fix"), so it
    /// stays frozen at 0 and the record would never turn.
    private var displayedProgress: Double {
        pendingSeek ?? playerState.playbackClock.progress
    }

    /// The progress the deck animates from, sampled at display rate.
    ///
    /// The player's clock ticks once a second. Projecting the clock's
    /// value forward by the wall-clock time since its last tick makes
    /// the motion continuous while still deriving from the player's
    /// own position in the track.
    private func smoothProgress(at date: Date) -> Double {
        if let pendingSeek { return pendingSeek }
        let clock = playerState.playbackClock
        guard playerState.isTransportRunning else { return clock.progress }
        return clock.projectedProgress(at: date)
    }

    /// The track's length, for the scrub readout and the record's speed.
    private var trackDuration: Double {
        let effective = playerState.effectiveDuration
        return effective > 0 ? effective : playerState.playbackClock.duration
    }

    /// The player is fetching or buffering and nothing is audible yet.
    private var isLoading: Bool {
        playerState.playbackState.isLoading && !playerState.isTransportRunning
    }

    private var shelves: [CrateShelfModel] {
        TurntableHomeModel.shelves(
            albums: viewModel.albumSuggestions,
            artistOrder: favoriteArtists.getArtists(),
            recent: DataManager.shared.recentlyPlayed
        )
    }

    var body: some View {
        GeometryReader { geo in
            let scale = min(1, (geo.size.width - 16) / TurntableDeckView.size.width)

            VStack(spacing: 0) {
                // Nothing floats over the deck (revisions 2026-11-20
                // and -21): every control that was an icon up here is
                // a button on the plinth, and Playlists live in the
                // Library tab.
                Color.clear.frame(height: 10)

                deck
                    .scaleEffect(scale)
                    .frame(
                        width: TurntableDeckView.size.width * scale,
                        height: TurntableDeckView.size.height * scale
                    )
                    .padding(.top, 2)

                // The deck's output meter used to sit here (revision
                // 2026-11-18: removed; the record is the instrument).

                // What is playing, in words (revision 2026-11-19: asked
                // for; it labels the deck above and the tray below).
                NowPlayingCaption(
                    title: captionItem?.track.title,
                    artist: captionItem?.track.artists.first,
                    notice: explorer.isLoading && digPending ? TurntableHomeModel.diggingNotice : notice,
                    noticeSymbol: explorer.isLoading && digPending ? DeckKey.dig.symbol : noticeSymbol,
                    noticeColor: explorer.isLoading && digPending ? DeckKey.dig.accent : noticeColor,
                    browsing: TurntableHomeModel.browsingMark(
                        index: browsedIndex, count: playerState.queue.count
                    )
                )
                .padding(.top, 12)

                // The tray of queued records, under the deck.
                QueueStackView(
                    queue: playerState.queue,
                    currentIndex: playerState.currentIndex,
                    onSelect: { index in
                        playerState.playQueue(at: index)
                    },
                    onShowAll: {
                        playerState.showQueue = true
                    },
                    isDealing: explorer.isLoading && digPending,
                    onBrowse: { index in browsedIndex = index }
                )
                .padding(.top, 8)

                // The shelves. A different thing from the tray: the
                // tray is what is coming up, the shelves are what else
                // there is to play.
                SleeveCrateView(
                    shelves: shelves,
                    nowPlayingID: playerState.currentItem?.track.videoId,
                    bottomInset: Self.tabBarClearance,
                    onPlay: { track in
                        HapticManager.medium()
                        viewModel.playTrack(track)
                    },
                    onQueue: { track in
                        viewModel.addToQueue(track)
                    },
                    onPlayAlbum: { album in
                        // The album's tracks have to be fetched and their
                        // stream URLs resolved; say so while that runs.
                        flash(TurntableHomeModel.loadingAlbumNotice)
                        viewModel.playAlbum(album)
                    },
                    onQueueAlbum: { album in
                        viewModel.queueAlbum(album)
                    }
                )
                // Clear air between the tray and the first shelf, so
                // the two read as different things.
                .padding(.top, 22)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(
            DeckRoomBackground(artworkURL: playerState.currentItem?.track.artworkURL)
                .animation(.easeInOut(duration: 0.9), value: playerState.currentItem?.track.artworkURL)
                .ignoresSafeArea()
        )
        // The arm is released from its held position once the player
        // has caught up with the seek.
        .onReceive(playerState.playbackClock.$progress) { value in
            guard let target = pendingSeek, abs(value - target) < 0.02 else { return }
            pendingSeek = nil
        }
        .onChange(of: playerState.currentItem?.track.videoId) { _, _ in
            pendingSeek = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .deckKeyPressed)) { note in
            if let raw = note.object as? String, let key = DeckKey(rawValue: raw) { press(key) }
        }
        // The engine has answered the DIG key.
        .onChange(of: explorer.isLoading) { was, now in
            guard was, !now, digPending else { return }
            digPending = false
            if explorer.isExploring {
                HapticManager.success()
            } else {
                HapticManager.error()
                flash(TurntableHomeModel.digCameBackEmptyNotice)
            }
        }
        .sheet(isPresented: $showSmartLibrary) {
            if let cycle = SmartLibraryManager.shared.pendingCandidates {
                SmartLibraryReviewSheet(originalCycle: cycle, isPresented: $showSmartLibrary)
            }
        }
        .sheet(isPresented: $showCleanup) {
            if let pending = SmartLibraryManager.shared.pendingCleanup {
                CleanupReviewSheet(pending: pending, isPresented: $showCleanup)
            }
        }
    }

    // MARK: - Deck

    private var deck: some View {
        TurntableDeckView(
            artworkURL: playerState.currentItem?.track.artworkURL,
            trackIdentity: playerState.currentItem?.track.videoId ?? "",
            isLoaded: playerState.currentItem != nil,
            isPlaying: playerState.isTransportRunning,
            isLoading: isLoading,
            progress: displayedProgress,
            duration: trackDuration,
            reduceMotion: reduceMotion,
            progressAt: { date in smoothProgress(at: date) },
            onTapPlatter: {
                playerState.showFullPlayer = true
            },
            onLongPress: {
                playerState.showQueue = true
            },
            onScrubEnded: { value in
                seek(to: value)
            },
            onToggle: {
                HapticManager.medium()
                playerState.togglePlayPause()
            },
            keyStates: TurntableHomeModel.keyStates(
                isDigging: explorer.isLoading && digPending,
                dugTrackIDs: explorer.isExploring ? explorer.explorationQueue.map(\.videoId) : [],
                nowPlayingID: playerState.currentItem?.track.videoId,
                isRadioPlaying: playerState.contentType == .liveRadio && playerState.currentItem != nil,
                hasPendingReview: SmartLibraryManager.shared.pendingCandidates != nil
                    || SmartLibraryManager.shared.pendingCleanup != nil
            ),
            onKey: { key in press(key) }
        )
    }

    /// A key on the deck was pressed — here, or on the same deck in
    /// the full player, which hands the press back to Home.
    private func press(_ key: DeckKey) {
        switch key {
        case .dig:
            dig()
        case .radio:
            HapticManager.light()
            onNavigate(.radio)
        case .review:
            review()
        case .setup:
            HapticManager.light()
            onNavigate(.settings)
        }
    }

    // MARK: - Dig

    /// The DIG key: re-deal the queue with songs from just outside
    /// what the user normally plays. The tray animates while the
    /// engine looks, and the new records are dealt into it.
    private func dig() {
        guard !explorer.isLoading else { return }
        HapticManager.medium()
        // The engine needs listening history to steer away from.
        // Without any it returns nothing, silently; say so instead.
        guard !explorer.analyzeListeningHistory().artists.isEmpty else {
            HapticManager.error()
            flash(TurntableHomeModel.nothingToDigFromNotice)
            return
        }
        notice = nil
        digPending = true
        explorer.startExplorationSession(replacingQueue: true)
        // The engine can decline without ever reporting that it is
        // loading; the key must not stay armed if it does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if digPending, !explorer.isLoading, !explorer.isExploring {
                digPending = false
                flash(TurntableHomeModel.digCameBackEmptyNotice)
            }
        }
    }

    // MARK: - Review

    /// The review button: whatever is waiting on the user. The Smart
    /// Library's auto-download review first; a scheduled cleanup if
    /// that is all there is; and a line saying so if there is nothing.
    private func review() {
        HapticManager.light()
        if SmartLibraryManager.shared.pendingCandidates != nil {
            showSmartLibrary = true
        } else if SmartLibraryManager.shared.pendingCleanup != nil {
            showCleanup = true
        } else {
            flash(TurntableHomeModel.nothingToReviewNotice, from: .review)
        }
    }

    /// Shows a line in place of the track's name for a few seconds.
    private func flash(_ text: String, from key: DeckKey = .dig) {
        noticeToken += 1
        let token = noticeToken
        noticeSymbol = key.symbol
        noticeColor = key.accent
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            if noticeToken == token { notice = nil }
        }
    }

    /// Puts the needle down at `value` and holds the arm there until
    /// the player arrives.
    private func seek(to value: Double) {
        pendingSeek = value
        playerState.seek(to: value)
        // If the seek never lands (nothing loaded, a dead stream) the
        // arm must not stay stuck where it was dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if pendingSeek == value { pendingSeek = nil }
        }
    }
}

// MARK: - Room

/// The room the deck stands in.
///
/// A warm near-black wall, a lamp up and to the left, and — behind
/// the deck only — the colours of the record that is playing, thrown
/// back off the wall. Change the record and the room changes with it.
struct DeckRoomBackground: View {
    let artworkURL: URL?

    var body: some View {
        ZStack {
            TurntableTokens.room

            artworkGlow

            // The glow belongs behind the deck. It is gone by the
            // time the shelves start.
            LinearGradient(
                stops: [
                    .init(color: TurntableTokens.room.opacity(0.35), location: 0),
                    .init(color: TurntableTokens.room.opacity(0.10), location: 0.22),
                    .init(color: TurntableTokens.room.opacity(0.80), location: 0.52),
                    .init(color: TurntableTokens.room, location: 0.66)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Warm key light from the upper left, matching the
            // generated textures' studio lighting.
            RadialGradient(
                colors: [TurntableTokens.keyLight.opacity(0.11), .clear],
                center: UnitPoint(x: 0.12, y: 0.04),
                startRadius: 0,
                endRadius: 460
            )
        }
    }

    /// The playing record's artwork, blurred until only its colours
    /// are left.
    ///
    /// Drawn tiny and scaled up: blurring a 46pt image and enlarging
    /// it costs a fraction of blurring a screen-sized one, and at this
    /// radius the two are indistinguishable.
    @ViewBuilder
    private var artworkGlow: some View {
        if let artworkURL {
            Color.clear
                .overlay(alignment: .top) {
                    CachedAsyncImage(url: artworkURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: 46, height: 60)
                    .clipped()
                    .blur(radius: 9)
                    .saturation(1.35)
                    .scaleEffect(10, anchor: .top)
                    .opacity(0.55)
                }
                .clipped()
                .id(artworkURL)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}

extension Notification.Name {
    /// A key was pressed on the deck in the full player. The object
    /// is the key's raw value; Home does what the key does.
    static let deckKeyPressed = Notification.Name("deckKeyPressed")
}
