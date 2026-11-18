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
//    crate sleeves     -> HomeViewModel.playTrack(_:)
//    queue discs       -> PlayerState.playQueue(at:)
//    level meter       -> AudioVisualizerEngine.bands
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
    /// Flatten the per-artist suggestion dictionary into a single
    /// ordered list of sleeves, de-duplicated by track.
    static func sleeves(from suggestions: [String: [Track]], limit: Int) -> [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        for artist in suggestions.keys.sorted() {
            for track in suggestions[artist] ?? [] {
                guard !seen.contains(track.videoId) else { continue }
                seen.insert(track.videoId)
                result.append(track)
                if result.count >= limit { return result }
            }
        }
        return result
    }

    /// The crate's contents.
    ///
    /// The suggestions are the crate's spine, but they are not always
    /// enough to fill three rows — a user with two favourite artists
    /// sees five records and the deck looks half empty. The queue and
    /// the recently-played shelf top the crate up so the deck always
    /// shows three full rows of records.
    static func crateContents(
        suggestions: [String: [Track]],
        queue: [QueueItem],
        recent: [RecentTrack],
        limit: Int
    ) -> [Track] {
        var seen = Set<String>()
        var result: [Track] = []

        func append(_ track: Track) {
            guard !seen.contains(track.videoId) else { return }
            seen.insert(track.videoId)
            result.append(track)
        }

        for track in sleeves(from: suggestions, limit: limit) {
            append(track)
        }
        for item in queue {
            append(item.track)
            if result.count >= limit { return result }
        }
        for entry in recent {
            append(entry.toTrack)
            if result.count >= limit { return result }
        }
        return Array(result.prefix(limit))
    }
}

// MARK: - View

struct TurntableHomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject var favoriteArtists: FavoriteArtistsManager
    @ObservedObject var playerState: PlayerState
    @ObservedObject var visualizer: AudioVisualizerEngine

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0
    @State private var showSmartLibrary = false
    @State private var showCleanup = false

    /// The progress the deck shows. While the user drags the tonearm
    /// the arm wins; otherwise playback drives it.
    ///
    /// Source is `playbackClock.progress`, NOT `PlayerState.progress`:
    /// the latter is a legacy @Published mirror that the hot path no
    /// longer writes (PlayerState.swift, "Sprint 2 / C-4 fix"), so it
    /// stays frozen at 0 and the record would never turn.
    private var displayedProgress: Double {
        isScrubbing ? scrubProgress : playerState.playbackClock.progress
    }

    private var sleeves: [Track] {
        TurntableHomeModel.crateContents(
            suggestions: viewModel.artistSuggestions,
            queue: playerState.queue,
            recent: DataManager.shared.recentlyPlayed,
            limit: CrateGrid.columnCount * CrateGrid.visibleRows
        )
    }

    /// The progress the deck animates from, sampled at display rate.
    ///
    /// The player's clock ticks once a second, which makes a record
    /// that turns once per track move in visible one-degree jumps.
    /// Projecting the clock's value forward by the wall-clock time
    /// since its last tick makes the motion continuous while still
    /// deriving from the player's own position in the track.
    private func smoothProgress(at date: Date) -> Double {
        if isScrubbing { return scrubProgress }
        let clock = playerState.playbackClock
        guard playerState.isTransportRunning else { return clock.progress }
        return clock.projectedProgress(at: date)
    }

    var body: some View {
        VStack(spacing: 0) {
            DeckFasciaView(
                hasSmartLibraryCandidates: SmartLibraryManager.shared.pendingCandidates != nil,
                hasPendingCleanup: SmartLibraryManager.shared.pendingCleanup != nil,
                onSmartLibrary: { showSmartLibrary = true },
                onCleanup: { showCleanup = true }
            ) {
                navChips
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            // The deck: platter with the tonearm swinging over it, and
            // the cue lever at the side.
            ZStack {
                PlatterView(
                    artworkURL: playerState.currentItem?.track.artworkURL,
                    trackIdentity: playerState.currentItem?.track.videoId ?? "",
                    isPlaying: playerState.isTransportRunning,
                    progress: displayedProgress,
                    reduceMotion: reduceMotion,
                    progressAt: { date in smoothProgress(at: date) },
                    onTapPlatter: {
                        playerState.showFullPlayer = true
                    },
                    onLongPress: {
                        playerState.showQueue = true
                    }
                )
                .frame(width: PlatterView.diameter, height: PlatterView.diameter)

                TonearmView(
                    progress: displayedProgress,
                    isScrubbing: isScrubbing,
                    progressAt: { date in smoothProgress(at: date) },
                    onScrub: { value in
                        isScrubbing = true
                        scrubProgress = value
                    },
                    onScrubEnded: { value in
                        isScrubbing = false
                        scrubProgress = value
                        playerState.seek(to: value)
                    }
                )
                .frame(width: PlatterView.diameter, height: PlatterView.diameter)

                CueLeverView(
                    isPlaying: playerState.isTransportRunning,
                    onToggle: {
                        HapticManager.medium()
                        playerState.togglePlayPause()
                    }
                )
                // The start/stop lever sits on the LEFT of the platter,
                // the way it does on a Technics — the arm owns the
                // right-hand side.
                .offset(x: -132, y: -76)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            // The deck's output meter — a slim peak meter strip on the
            // plinth, the way a turntable's aux VU meter sits beside
            // the controls.
            LevelMeterRow(
                levels: visualizer.bands,
                accent: Theme.cyberCyan
            )
            .frame(width: 150, height: 12)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.black.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(TurntableTokens.aluminium.opacity(0.22), lineWidth: 1)
                    )
            )
            .padding(.bottom, 2)

            // The shelf of queued records, under the deck.
            QueueStackView(
                queue: playerState.queue,
                currentIndex: playerState.currentIndex,
                onSelect: { index in
                    playerState.playQueue(at: index)
                }
            )
            .padding(.horizontal, 18)

            // The crate.
            SleeveCrateView(
                sleeves: sleeves,
                onPlay: { track in
                    HapticManager.medium()
                    viewModel.playTrack(track)
                },
                onQueue: { track in
                    viewModel.addToQueue(track)
                }
            )
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Spacer(minLength: 8)
        }
        .background(deckBackground)
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

    // MARK: - Nav chips

    /// The five existing Home destinations. They are passed into the
    /// fascia rather than owned by it, so Home keeps ownership of its
    /// NavigationStack routes.
    ///
    /// Each chip is a 30pt graphic inside a 44x44 touch target, so
    /// the five of them fit the top-right corner.
    @ViewBuilder
    private var navChips: some View {
        HStack(spacing: 2) {
            NavigationLink(value: HomeDestination.timeCapsule) {
                deckChip(icon: "hourglass", accent: Theme.cyberYellow)
            }
            .buttonStyle(.plain)

            NavigationLink(value: HomeDestination.antiAlgorithm) {
                deckChip(icon: "dice.fill", accent: Theme.cyberMagenta)
            }
            .buttonStyle(.plain)

            NavigationLink(value: HomeDestination.radio) {
                deckChip(icon: "antenna.radiowaves.left.and.right", accent: Theme.cyberCyan)
            }
            .buttonStyle(.plain)

            NavigationLink(value: HomeDestination.playlists) {
                deckChip(icon: "music.note.list", accent: TurntableTokens.aluminium)
            }
            .buttonStyle(.plain)

            NavigationLink(value: HomeDestination.settings) {
                deckChip(icon: "gearshape.fill", accent: TurntableTokens.aluminium)
            }
            .buttonStyle(.plain)
        }
    }

    private func deckChip(icon: String, accent: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(accent)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(accent.opacity(0.35), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
            // HIG minimum for an icon-only control.
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    // MARK: - Background

    /// The deck's plinth: walnut with a dark vignette so the deck
    /// sits in a room rather than on a flat colour.
    ///
    /// The walnut texture sits inside an overlay on purpose. A
    /// resizable image with `.aspectRatio(contentMode: .fill)` reports
    /// its natural size as its ideal size, and in a ZStack that ideal
    /// size wins: the container grows to the texture's 1024pt width
    /// and everything laid out inside the deck is pushed off screen.
    /// An overlay pins the texture to the plinth's own bounds.
    private var deckBackground: some View {
        ZStack {
            Color.clear
                .overlay(
                    Image(TurntableTexture.walnut)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(0.22)
                )

            LinearGradient(
                colors: [
                    Color.black.opacity(0.72),
                    Color.black.opacity(0.45),
                    Color.black.opacity(0.88)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Warm key light from the upper left, matching the
            // generated textures' studio lighting.
            RadialGradient(
                colors: [TurntableTokens.keyLight.opacity(0.10), .clear],
                center: UnitPoint(x: 0.18, y: 0.05),
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}
