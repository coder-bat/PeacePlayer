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
//    spindle tap       -> PlayerState.setPlaybackRate(_:)
//    crate sleeves     -> HomeViewModel.playTrack(_:)
//    level meter       -> AudioVisualizerEngine.bands
//
//  The view deliberately owns NO playback state of its own. It reads
//  PlayerState and calls its methods; that keeps the deck honest
//  (it cannot show a position the player does not agree with) and
//  means every existing player control keeps working unchanged.
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

    /// Playback rate for the 33 / 45 RPM switch. 45 RPM is the real
    /// turntable convention: the same record plays 45/33 = 1.36x
    /// faster. We use 1.25x so it stays musical.
    static func playbackRate(forRPM is45: Bool) -> Float {
        is45 ? 1.25 : 1.0
    }
}

// MARK: - View

struct TurntableHomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject var favoriteArtists: FavoriteArtistsManager
    @ObservedObject var playerState: PlayerState
    @ObservedObject var visualizer: AudioVisualizerEngine

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var is45RPM = false
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
        TurntableHomeModel.sleeves(from: viewModel.artistSuggestions, limit: 12)
    }

    var body: some View {
        VStack(spacing: 0) {
            DeckFasciaView(
                greeting: viewModel.greeting,
                isPlaying: playerState.playbackState == .playing,
                isConnected: true,
                rpmLabel: is45RPM ? "45" : "33⅓",
                hasSmartLibraryCandidates: SmartLibraryManager.shared.pendingCandidates != nil,
                hasPendingCleanup: SmartLibraryManager.shared.pendingCleanup != nil,
                onToggleRPM: { toggleRPM() },
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
                    isPlaying: playerState.playbackState == .playing,
                    progress: displayedProgress,
                    reduceMotion: reduceMotion,
                    onTapSpindle: { toggleRPM() },
                    onLongPress: {
                        playerState.showQueue = true
                    }
                )
                .frame(width: 320, height: 320)

                TonearmView(
                    progress: displayedProgress,
                    isScrubbing: isScrubbing,
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
                .frame(width: 320, height: 320)

                CueLeverView(
                    isPlaying: playerState.playbackState == .playing,
                    onToggle: {
                        HapticManager.medium()
                        playerState.togglePlayPause()
                    }
                )
                .offset(x: 132, y: -76)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)

            // Queue stack.
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

            // Now-playing strip — the deck's only now-playing surface.
            nowPlayingStrip
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
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

    // MARK: - RPM

    private func toggleRPM() {
        HapticManager.selectionChanged()
        is45RPM.toggle()
        playerState.setPlaybackRate(TurntableHomeModel.playbackRate(forRPM: is45RPM))
    }

    // MARK: - Nav chips

    /// The five existing Home destinations. They are passed into the
    /// fascia rather than owned by it, so Home keeps ownership of its
    /// NavigationStack routes.
    @ViewBuilder
    private var navChips: some View {
        HStack(spacing: 6) {
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
            .font(.system(size: 12, weight: .medium))
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
    }

    // MARK: - Now playing strip

    private var nowPlayingStrip: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(playerState.currentItem?.track.title ?? "Nothing playing")
                    .font(Typography.playerTitle)
                    .foregroundColor(TurntableTokens.cream)
                    .lineLimit(1)

                Text(playerState.currentItem?.track.artists.first ?? "Turn the record")
                    .font(Typography.playerArtist)
                    .foregroundColor(TurntableTokens.aluminium.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            LevelMeterRow(
                levels: visualizer.bands,
                accent: Theme.cyberCyan
            )
            .frame(width: 110, height: 22)

            // Time readout.
            Text(timeReadout)
                .font(Typography.playerTime)
                .foregroundColor(TurntableTokens.aluminium.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(TurntableTokens.aluminium.opacity(0.18), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            playerState.showFullPlayer = true
        }
        .accessibilityLabel("Now playing")
        .accessibilityValue(playerState.currentItem?.track.title ?? "Nothing playing")
        .accessibilityAddTraits(.isButton)
    }

    private var timeReadout: String {
        let elapsed = formatTime(playerState.playbackClock.currentTime)
        let total = formatTime(playerState.playbackClock.duration)
        return "\(elapsed) / \(total)"
    }

    /// Formats seconds as m:ss. Local helper so the strip does not
    /// depend on PlayerState's formatting helpers, which read the
    /// legacy (frozen) currentTime / duration mirrors.
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Background

    /// The deck's plinth: walnut with a dark vignette so the deck
    /// sits in a room rather than on a flat colour.
    private var deckBackground: some View {
        ZStack {
            Image(TurntableTexture.walnut)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .opacity(0.22)

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
