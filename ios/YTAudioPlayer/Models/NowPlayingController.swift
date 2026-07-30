//
//  NowPlayingController.swift
//  PeacePlayer
//
//  S17-H / Tier 4: Fourth extraction from the 2999-line
//  PlayerState god object. Owns the fan-out to
//  `NowPlayingService.shared` (which writes to
//  `MPNowPlayingInfoCenter` — the Lock Screen / Control
//  Center / CarPlay / AirPods / Apple Watch metadata).
//
//  ## Why this is a safe extraction
//
//  1. **Pure fan-out, no state.** The controller has no
//     `@Published` properties. All inputs come from
//     PlayerState (track, duration, currentTime,
//     isPlaying, playbackRate); all outputs go to
//     NowPlayingService.shared. The class is a stateless
//     function-on-demand over these two endpoints.
//
//  2. **Consolidates 7 NowPlayingService callsites.** Before
//     the extraction, `NowPlayingService.shared.update*` was
//     called from 7 different methods in PlayerState
//     (play(item:), stop(), playRadioStation, playPodcastEpisode,
//     playAudiobookChapter, handleMediaServicesResetRestart,
//     handleTrackCompletion, the 1Hz tick in
//     updateProgress). Each callsite repeated the same long
//     parameter list. Moving them to a single
//     `nowPlayingController.updateNowPlaying()` reduces
//     callsite noise and makes the "what gets pushed" surface
//     obvious in one place.
//
//  3. **Single weak ref to PlayerState.** All reads of
//     `currentItem` / `playbackState` / `playbackRate` /
//     `player.currentTime` go through this ref. The weak
//     ref breaks the strong reference cycle that would
//     otherwise form (PlayerState owns the controller,
//     controller holds back a ref to PlayerState).
//
//  4. **No threading changes.** Every callsite today
//     runs on the main thread (the 1Hz tick fires on
//     `.main` queue, all the play/pause/etc methods are
//     PlayerState-contract main-thread). NowPlayingService
//     is also main-thread. So the controller's methods
//     are main-thread by transitivity.
//
//  ## Threading
//
//  **Not** `@MainActor`. All call sites run on the main
//  thread; PlayerState itself is not `@MainActor`, so
//  making this `@MainActor` would force every call site
//  to bridge. The internal state is just the
//  NowPlayingService singleton reference (thread-safe).
//
//  ## Forwarding pattern
//
//  NowPlayingController is called from PlayerState (not
//  the other way around). The pattern is: PlayerState
//  detects a state change and calls
//  `nowPlayingController.updateNowPlaying()`; the
//  controller reads what it needs and pushes to
//  NowPlayingService. This keeps the controller stateless
//  and avoids a Combine subscription that would re-fire
//  on every state change.
//

import Foundation
import AVFoundation

/// S17-H / Tier 4: Owns the fan-out to `NowPlayingService.shared`
/// (Lock Screen / Control Center metadata) for PlayerState.
///
/// See class header for the extraction rationale + threading
/// notes. The controller is the single owner of:
/// - the 7 `NowPlayingService.shared.update*` callsites
///   that used to be sprinkled through PlayerState
final class NowPlayingController {

    // MARK: - Dependencies

    /// Single weak ref to PlayerState. The controller reads
    /// `currentItem`, `playbackState`, `playbackRate`, and
    /// the AVPlayer's `currentTime()` to build the
    /// NowPlaying payload. The weak ref breaks the strong
    /// reference cycle (PlayerState owns the controller,
    /// controller holds back a ref to PlayerState).
    private weak var playerState: PlayerState?

    // MARK: - Init

    init(playerState: PlayerState) {
        self.playerState = playerState
    }

    // MARK: - Public API

    /// Push the current track + playback state to
    /// `MPNowPlayingInfoCenter` (Lock Screen, Control
    /// Center, CarPlay, AirPods, Apple Watch). Reads the
    /// track from `playerState.currentItem` and the
    /// isPlaying/rate from `playerState.playbackState` /
    /// `playbackRate`.
    ///
    /// Call sites in PlayerState (any time the
    /// track-or-playback-state changes that should be
    /// reflected on the Lock Screen):
    /// - `play(item:)` after a new AVPlayer is built
    /// - `setPlaybackRate(_:)` after the rate changes
    /// - `updateRemoteControls()` (manual refresh)
    func updateNowPlaying() {
        guard let state = playerState, let item = state.currentItem else { return }
        NowPlayingService.shared.updateNowPlaying(
            track: item.track,
            duration: Double(item.track.durationSeconds),
            currentTime: 0,
            isPlaying: state.playbackState.isPlaying,
            playbackRate: state.playbackRate
        )
    }

    /// Push an explicit track + playback state to
    /// `MPNowPlayingInfoCenter`. Use for content-type
    /// switches where the track being shown is *not*
    /// `playerState.currentItem` (e.g. live radio, where
    /// the duration is 0 and isPlaying is true even
    /// before the player state settles).
    ///
    /// Call sites:
    /// - `playRadioStation(_:)` after building the radio
    ///   player (duration=0, isPlaying=true)
    /// - `playPodcastEpisode(_:)` after building the
    ///   podcast player (specific duration, isPlaying=true)
    /// - `playAudiobookChapter(_:)` after building the
    ///   audiobook player (specific duration, isPlaying=true)
    func updateNowPlaying(
        track: Track,
        duration: Double,
        currentTime: Double,
        isPlaying: Bool,
        playbackRate: Float
    ) {
        NowPlayingService.shared.updateNowPlaying(
            track: track,
            duration: duration,
            currentTime: currentTime,
            isPlaying: isPlaying,
            playbackRate: playbackRate
        )
    }

    /// Update just the current time on the Now Playing
    /// card. Called from the 1Hz tick in `updateProgress`.
    /// `currentTime` is read from the AVPlayer itself
    /// (not from `state.currentTime` which is the legacy
    /// `@Published` mirror that the MiniPlayer no longer
    /// watches — see commit `88c6de9` for the C-4 fix).
    func updatePlaybackTime() {
        guard let state = playerState,
              let player = state.player else { return }
        NowPlayingService.shared.updatePlaybackTime(
            currentTime: player.currentTime().seconds,
            isPlaying: state.playbackState.isPlaying,
            playbackRate: state.playbackRate
        )
    }
}
