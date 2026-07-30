//
//  QueueController.swift
//  PeacePlayer
//
//  S17-H / Tier 4: Fifth extraction from the 2999-line
//  PlayerState god object. Owns the queue navigation +
//  repeat/shuffle logic that used to live as nextTrack /
//  previousTrack / toggleShuffle / toggleRepeat +
//  autoplayNextFromRecentlyPlayed + performCrossfadeToNextItem
//  + prepareNextTrackForCrossfade on PlayerState.
//
//  ## Why this is a safe extraction
//
//  1. **The state lives in QueueStore + @Published vars on
//     PlayerState.** QueueController owns no state of its
//     own — it reads queue / currentIndex / currentItem /
//     repeatMode from PlayerState (which gets them from
//     QueueStore) and writes through QueueStore's API
//     (`setCurrentIndex`, `add`, `addNext`, `replace`).
//     This is consistent with the other Tier 4
//     extractions: stateless function-on-demand over
//     existing state holders.
//
//  2. **The "logic" is what was big, not the state.** The
//     ~380 lines that move here are all conditional flow:
//     "if gapless + AVQueuePlayer + has-next → advance;
//     else if crossfade + has-nextPlayer → crossfade;
//     else if autoplay → fall through; else → repeat-all
//     wrap; else → autoplay-from-recently-played". This
//     belongs in one place. Splitting it across
//     PlayerState meant the gapless-vs-crossfade
//     decision lived in nextTrack, but the crossfade
//     preparation lived in performCrossfadeToNextItem
//     (called from nextTrack), and the crossfade
//     trigger (the actual audio handoff) lived in
//     CrossfadeManager.crossfadeToNext. Three layers for
//     one user action.
//
//  3. **The crossfade path is the trickiest part.** It
//     uses `CrossfadeManager.shared` (a singleton), the
//     AVPlayerController's player reference, and
//     PlayerState's `updateExpectedDuration` +
//     `endTrackTransitionBackgroundTask` +
//     `beginTrackTransitionBackgroundTask` +
//     `playQueue(at:)`. All of these are accessible via
//     the weak playerState ref. The crossfade callback
//     (`CrossfadeManager.shared.crossfadeToNext { ... }`)
//     captures `self` (the controller) weakly so it
//     doesn't create a cycle with CrossfadeManager.
//
//  4. **Single weak ref to PlayerState.** All reads of
//     queue / currentIndex / currentItem / repeatMode /
//     isShuffled / originalQueue / queueStore / dataManager
//     go through this ref. The weak ref breaks the strong
//     reference cycle that would otherwise form
//     (PlayerState owns the controller, controller holds
//     back a ref to PlayerState).
//
//  ## Threading
//
//  **Not** `@MainActor`. All call sites run on the main
//  thread:
//  - next() / previous() / toggleShuffle() / toggleRepeat()
//    are called from SwiftUI views (button taps), which
//    are main-thread by contract
//  - The autoplay / crossfade completion callbacks are
//    dispatched to `.main` before they reach this code
//
//  PlayerState is not `@MainActor`, so making this
//  `@MainActor` would force every call site to bridge —
//  verbose and adds nothing. The internal state is just
//  references to PlayerState and CrossfadeManager.shared
//  (both thread-safe in the access patterns we use).
//
//  ## Forwarding pattern
//
//  PlayerState exposes `var repeatMode`, `var queue`,
//  etc. as computed properties forwarding to the store.
//  QueueController reads them via `playerState.repeatMode`
//  and writes through `playerState.queueStore.setCurrentIndex(_:)`
//  etc. No new forwarding patterns needed — the
//  QueueStore interface already exists.
//

import Foundation
import AVFoundation
import Combine

/// S17-H / Tier 4: Owns queue navigation (next, previous) +
/// repeat/shuffle state transitions for PlayerState.
///
/// See class header for the extraction rationale + threading
/// notes. The controller is the single owner of:
/// - `next(useCrossfade:userSkipped:)` (was `nextTrack`)
/// - `previous()` (was `previousTrack`)
/// - `toggleShuffle()`
/// - `toggleRepeat()`
/// - `autoplayNextFromRecentlyPlayed()` (private helper)
/// - `performCrossfadeToNextItem(_:at:)` (private helper)
/// - `prepareNextTrackForCrossfade()` (private helper)
final class QueueController {

    // MARK: - Dependencies

    /// Single weak ref to PlayerState. All reads of
    /// queue / currentIndex / currentItem / repeatMode /
    /// isShuffled / originalQueue / queueStore / dataManager
    /// go through this ref. The weak ref breaks the strong
    /// reference cycle (PlayerState owns the controller,
    /// controller holds back a ref to PlayerState).
    private weak var playerState: PlayerState?

    // MARK: - Init

    init(playerState: PlayerState) {
        self.playerState = playerState
    }

    // MARK: - Public API

    /// Advance to the next track. Handles every variant
    /// of "what does next mean":
    /// - repeat-one → seek to 0 (stay on current track)
    /// - gapless + AVQueuePlayer + has-next → `advanceToNextItem`
    /// - gapless + end-of-queue → autoplay-from-recently-played
    /// - crossfade + has-nextPlayer → `CrossfadeManager.crossfadeToNext`
    /// - autoplay at end of queue → most-recent non-current track
    /// - repeat-all at end of queue → wrap to index 0
    /// - everything else → `playQueue(at: nextIndex)`
    ///
    /// `userSkipped` distinguishes "user pressed next"
    /// (which the AntiAlgorithm + S17-H race-condition
    /// logic cares about) from "track finished, autoplay
    /// kicked in" (which doesn't).
    func next(useCrossfade: Bool = true, userSkipped: Bool = false) {
        guard let state = playerState else { return }
        print("⏭️ next called. Queue count: \(state.queue.count), currentIndex: \(state.currentIndex)")
        state.beginTrackTransitionBackgroundTask()

        // S10 diagnostic: distinguish "user pressed next" from "track
        // finished, autoplay kicked in". These take very different paths
        // and we want to know which fired when reading the console after
        // a background-track-transition repro.
        let fromCompletion = !userSkipped && state.isHandlingCompletion
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "S10: nextTrack ENTRY fromCompletion=\(fromCompletion) queue.count=\(state.queue.count) currentIndex=\(state.currentIndex) userSkipped=\(userSkipped)")
        #endif
        print("⏭️ S10: nextTrack ENTRY fromCompletion=\(fromCompletion) queue.count=\(state.queue.count) currentIndex=\(state.currentIndex)")

        // Anti-Algorithm: track skip/complete
        if let currentVideoId = state.currentItem?.track.videoId {
            if userSkipped {
                AntiAlgorithmEngine.shared.trackSkipped(videoId: currentVideoId)
            }
        }
        // S17-H: mark that a user-initiated skip just happened.
        // The handleTrackCompletion path that fires from
        // .AVPlayerItemDidPlayToEndTime (which is in flight on
        // completionQueue at this very moment for tracks that
        // are near the end) will see this flag and skip its own
        // auto-advance, so the user hears the track they tapped
        // for, not the one after it.
        if userSkipped {
            state.userSkippedPendingCompletion = true
        }
        guard !state.queue.isEmpty else {
            print("⏭️ Queue is empty!")
            state.endTrackTransitionBackgroundTask()
            return
        }

        if state.repeatMode == .one {
            // Repeat current
            state.seek(to: 0)
            state.endTrackTransitionBackgroundTask()
            return
        }

        // S3-5: Gapless mode path. If the player is an AVQueuePlayer, the
        // next item is already in the queue. Just call advanceToNextItem
        // and let AVFoundation do the rest. We still update currentIndex
        // / currentItem synchronously for the UI.
        if CrossfadeManager.shared.gaplessEnabled, let queuePlayer = state.avPlayerController.player as? AVQueuePlayer {
            let nextIndex = state.currentIndex + 1
            if nextIndex < state.queue.count {
                print("⏭️ Gapless: advancing AVQueuePlayer to next track")
                // S17-G: set currentIndex via the store. The mirror
                // subscription updates `currentItem`. The expected
                // duration is per-track metadata, not a queue
                // property, so it stays on PlayerState.
                state.queueStore.setCurrentIndex(nextIndex)
                let nextItem = state.queueStore.items[nextIndex]
                // S17-H: route through the helper so playbackClock
                // (the focused observable that the scrubber
                // subscribes to) also gets the new duration. A
                // direct `expectedDuration =` write here was
                // leaving the scrubber denominator stale across
                // gapless transitions, so the progress bar
                // visibly compressed when crossing into the next
                // track. Same helper is used by every other
                // play/crossfade path.
                state.updateExpectedDuration(Double(nextItem.track.durationSeconds))
                // S17-H: removed the premature
                // `addToRecentlyPlayed` and
                // `NotificationCenter.default.post(.trackPlayed)`
                // calls here. Previously the user's Next tap
                // was recording the upcoming track in
                // recently-played and notifying PlaylistManager
                // before the track actually started playing —
                // the user would see the new track in the
                // recently-played list while the previous track
                // was still playing. Now both happen in
                // `handleAutoAdvance` (in GaplessController) when the
                // AVQueuePlayer reports the new track has
                // actually started, which is the user-visible
                // "track changed" moment.
                queuePlayer.advanceToNextItem()
                // Re-enqueue to refill the queue player
                state.gaplessController.enqueueUpcomingItems()
                state.endTrackTransitionBackgroundTask()
                return
            } else if state.repeatMode == .all {
                // Loop — fall through to playQueue(at: 0) below
                print("⏭️ Gapless: looping to beginning")
            } else {
                // S11 fix (Bug 6): previously went silent at end of
                // queue when gapless was enabled. Now fall through to
                // autoplay-from-recently-played, matching the non-
                // gapless path so the user always has continuous music.
                print("⏭️ End of queue reached (gapless) — falling through to autoplay")
                autoplayNextFromRecentlyPlayed()
                state.endTrackTransitionBackgroundTask()
                state.clearCompletionFlag()
                return
            }
        }

        let nextIndex = state.currentIndex + 1
        print("⏭️ Next index: \(nextIndex), queue.count: \(state.queue.count)")

        if nextIndex < state.queue.count {
            let nextItem = state.queue[nextIndex]
            print("⏭️ Playing next: \(nextItem.track.title), streamUrl: \(nextItem.streamUrl.prefix(50))...")

            // Check if we should use crossfade
            if useCrossfade && CrossfadeManager.shared.isEnabled {
                performCrossfadeToNextItem(nextItem, at: nextIndex)
            } else {
                state.playQueue(at: nextIndex)
            }
        } else if state.repeatMode == .all {
            // Loop to beginning
            print("⏭️ Looping to beginning")
            state.playQueue(at: 0)
        } else {
            // 2026-06-29 (S9c): when the queue is exhausted (the
            // common case is a single-track play from search or
            // home), fall back to autoplay from the user's
            // recently-played list. We pick the most recent track
            // that isn't the one that just finished and start
            // playback on it. This makes the listening experience
            // continuous without requiring the user to manually
            // queue tracks.
            print("⏭️ End of queue reached — trying autoplay from recently played")
            autoplayNextFromRecentlyPlayed()
        }
    }

    /// Go back to the previous track, or restart the current
    /// track if the user is more than `previousTrackRestartGracePeriod`
    /// into it (Apple Music / Spotify UX).
    func previous() {
        guard let state = playerState, !state.queue.isEmpty else { return }

        if state.repeatMode == .one {
            state.seek(to: 0)
            return
        }

        // S17-H: Apple Music / Spotify UX. If the user is more
        // than `previousTrackRestartGracePeriod` into the
        // current track, the first prev-press restarts the
        // current track (seek to 0) instead of going back to
        // the previous one. Without this, the user has to
        // re-find the previous track from the queue, which is
        // jarring after they accidentally tapped a track and
        // want to undo.
        let currentPosition = state.avPlayerController.player?.currentTime().seconds ?? 0
        if currentPosition > state.previousTrackRestartGracePeriod {
            print("⏮️ previousTrack: more than \(Int(state.previousTrackRestartGracePeriod))s into track — restarting current")
            state.seek(to: 0)
            return
        }

        let prevIndex = state.currentIndex - 1

        if prevIndex >= 0 {
            state.playQueue(at: prevIndex)
        } else if state.repeatMode == .all {
            // Loop to end
            state.playQueue(at: state.queue.count - 1)
        }
    }

    /// Toggle shuffle on/off. When turning on, the queue is
    /// reordered via "smart shuffle" (fresh first, recently
    /// played last) so the user doesn't hear stuff they just
    /// heard. When turning off, the original queue is restored.
    func toggleShuffle() {
        guard let state = playerState else { return }
        state.isShuffled.toggle()

        if state.isShuffled {
            // Save original queue
            state.originalQueue = state.queue
            // Sprint 3 / S3-1 fix: smart shuffle — avoid tracks played in the
            // last 50 plays. Pull the recent videoIds from DataManager's
            // recentlyPlayed list (UserDefaults-backed, kept in sync with
            // CDPlayHistory for stats). Tracks that have been played recently
            // are pushed to the end of the shuffled order rather than
            // appearing early. Without this, shuffle feels like a random
            // rewind of "stuff you just heard".
            let recentVideoIds: Set<String> = Set(
                state.dataManager.recentlyPlayed.prefix(50).map { $0.videoId }
            )

            if state.currentIndex < state.queue.count - 1 {
                let current = state.queue[state.currentIndex]
                let remaining = Array(state.queue[(state.currentIndex + 1)...])
                // Partition: fresh first, recent last
                let fresh = remaining.filter { !recentVideoIds.contains($0.track.videoId) }
                let recent = remaining.filter { recentVideoIds.contains($0.track.videoId) }
                print("🔀 Smart shuffle: \(fresh.count) fresh + \(recent.count) recent (last 50 played)")
                // S17-G: replace via the store. The mirror subscription
                // updates `currentItem` from the store's new items +
                // currentIndex (which we set below).
                let newQueue = Array(state.queue[...state.currentIndex]) + fresh.shuffled() + recent.shuffled()
                state.queueStore.replace(with: newQueue)
                state.queueStore.setCurrentIndex(state.currentIndex)
            }
        } else {
            // Restore original order
            if let current = state.currentItem {
                // S17-G: replace via the store. Find the current item
                // in the original queue and set the store's index.
                state.queueStore.replace(with: state.originalQueue)
                if let newIndex = state.originalQueue.firstIndex(where: { $0.track.videoId == current.track.videoId }) {
                    state.queueStore.setCurrentIndex(newIndex)
                }
            }
        }
    }

    /// Cycle through repeat modes: none → all → one → none.
    func toggleRepeat() {
        playerState?.repeatMode.next()
    }

    // MARK: - Private helpers

    /// 2026-06-29 (S9c): fall back to the user's recently-played
    /// list when the queue is exhausted. Picks the most recent
    /// track that isn't the one that just finished and starts
    /// playback on it. If no candidates are available, leaves the
    /// player in the .paused state on the last track.
    ///
    /// S10: do NOT release the track-transition background task here.
    /// The previous code ended it the instant `play(track:)` returned,
    /// which was BEFORE the new AVPlayer had buffered any audio. In the
    /// background, iOS could then suspend the app while the stream was
    /// still being fetched by yt-dlp. The task is now released in the
    /// `isPlaybackLikelyToKeepUp` observer once the new track is
    /// audibly playing (see setupPlayerObservers).
    private func autoplayNextFromRecentlyPlayed() {
        // S15: this is called from the AVPlayer KVO observer
        // (`isPlaybackLikelyToKeepUp` on a background queue) via
        // `handleTrackCompletion` -> `nextTrack`. Everything inside
        // mutates @Published properties on `dataManager`,
        // `currentItem`, etc. SwiftUI requires those mutations to
        // happen on the main thread, otherwise the runtime emits
        // 'Publishing changes from background threads is not
        // allowed' warnings and views can render inconsistent
        // state. Hop to main before reading or writing any UI
        // state.
        DispatchQueue.main.async { [weak self] in
            self?._autoplayNextFromRecentlyPlayedOnMain()
        }
    }

    private func _autoplayNextFromRecentlyPlayedOnMain() {
        guard let state = playerState else { return }
        let justPlayedId = state.currentItem?.track.videoId
        let candidates = state.dataManager.recentlyPlayed
            .filter { $0.videoId != justPlayedId }
            .compactMap { $0.toTrack }

        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "S10: autoplayNextFromRecentlyPlayed candidates=\(candidates.count)")
        #endif
        print("⏭️ S10: autoplay candidates=\(candidates.count) justPlayed=\(justPlayedId ?? "nil")")

        guard let nextTrack = candidates.first else {
            print("⏭️ No recently-played candidates; staying on last track")
            // No next track — release the background task so we don't
            // hold it forever.
            state.endTrackTransitionBackgroundTask()
            return
        }

        print("⏭️ S10: Autoplaying next: \(nextTrack.title)")
        state.play(track: nextTrack)
        // Note: background task is released in setupPlayerObservers'
        // isPlaybackLikelyToKeepUp observer when the new track is
        // actually playing.
    }

    private func performCrossfadeToNextItem(_ item: QueueItem, at index: Int) {
        guard let state = playerState else { return }
        print("🔊 Performing crossfade to: \(item.track.title)")

        // CRITICAL FIX: Set expectedDuration BEFORE updating UI so progress calculations use correct duration
        state.updateExpectedDuration(Double(item.track.durationSeconds))
        print("🎵 Crossfade: Set expectedDuration = \(state.expectedDuration) from track.durationSeconds = \(item.track.durationSeconds)")

        // CRITICAL FIX: Check if crossfade is possible BEFORE updating UI
        // CrossfadeManager needs a prepared nextPlayer
        guard CrossfadeManager.shared.canCrossfade() else {
            print("⚠️ Cannot crossfade - nextPlayer not prepared. Falling back to regular playback.")
            state.playQueue(at: index, isCrossfadeFallback: true)
            state.endTrackTransitionBackgroundTask()
            return
        }

        // Now safe to update UI state
        // S17-G: set currentIndex via the store. The mirror
        // subscription will keep currentItem in sync (though
        // the explicit assignment below is the more direct
        // path for this code path).
        state.queueStore.setCurrentIndex(index)
        state.currentItem = item

        // Perform crossfade
        CrossfadeManager.shared.crossfadeToNext { [weak self] in
            guard let self = self, let state = self.playerState else { return }

            // Crossfade complete, update player reference
            state.player = CrossfadeManager.shared.takeNextPlayer()

            // CRITICAL FIX: Only proceed if we got a valid player
            guard state.player != nil else {
                print("❌ Crossfade completed but player is nil - forcing fallback")
                state.playQueue(at: index, isCrossfadeFallback: true)
                state.endTrackTransitionBackgroundTask()
                return
            }

            // QW-13 fix: re-install the visualizer tap on the new player
            // item. installTap is only called in play(item:), so after a
            // crossfade the visualizer + haptic symphony engine would read
            // silent buffers for the new track.
            if let newItem = state.player?.currentItem {
                AudioVisualizerEngine.shared.installTap(on: newItem)
            }
            // Setup observers on new player
            state.avPlayerController.setupObservers()

            // Update state
            state.playbackState = .playing

            // Update remote controls
            state.updateRemoteControls()

            // Prepare next track for future crossfade
            self.prepareNextTrackForCrossfade()

            print("✅ Crossfade complete, now playing: \(item.track.title)")
            state.endTrackTransitionBackgroundTask()
        }

        // Add to recently played
        state.dataManager.addToRecentlyPlayed(item.track)
        NotificationCenter.default.post(name: .trackPlayed, object: nil)
    }

    /// Prepare the next track for crossfade. Called from
    /// `PlayerState.play(item:)` (after a 0.5s delay to let
    /// the queue populate) and from `PlayerState.updateProgress`
    /// (when the current track is near its end).
    ///
    /// `internal` (not `private`) so the thin wrappers on
    /// PlayerState can forward to this from places where the
    /// controller isn't already in scope (e.g. from inside
    /// `play(item:)` itself, which is a pre-Tier-4 method
    /// that already routes to many controllers).
    func prepareNextTrackForCrossfade() {
        guard let state = playerState else { return }
        guard CrossfadeManager.shared.isEnabled else { return }

        // Prevent duplicate preparation
        guard !state.isPreparingNextTrack else {
            print("🔊 Already preparing next track, skipping")
            return
        }

        let nextIndex = state.currentIndex + 1
        guard nextIndex < state.queue.count else {
            print("🔊 No next track to prepare for crossfade")
            return
        }

        let nextItem = state.queue[nextIndex]

        // Check if already prepared (CrossfadeManager has a nextPlayer)
        guard !CrossfadeManager.shared.hasNextPlayer() else {
            print("🔊 Next track already prepared: \(nextItem.track.title)")
            return
        }

        print("🔊 Preparing next track for crossfade: \(nextItem.track.title)")
        state.isPreparingNextTrack = true
        CrossfadeManager.shared.prepareNextTrack(nextItem) { [weak self] in
            self?.playerState?.isPreparingNextTrack = false
        }
    }
}
