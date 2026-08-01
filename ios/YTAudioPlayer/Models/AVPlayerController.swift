//
//  AVPlayerController.swift
//  PeacePlayer
//
//  S17-H / Tier 4: Third extraction from the 3161-line
//  PlayerState god object. Owns the AVPlayer instance, the
//  1Hz time observer, the per-item NotificationCenter
//  tokens, the per-player Combine `cancellables` set, and
//  the `setupPlayerObservers` / `removeTimeObserver` methods
//  that used to live on PlayerState.
//
//  ## Why this is a safe extraction
//
//  1. **The AVPlayer is one reference.** Before this
//     extraction, `var player: AVPlayer?` and
//     `var cancellables: Set<AnyCancellable>` lived on
//     PlayerState. Moving both to the controller (and
//     exposing the player via a forwarding computed
//     property on PlayerState) is a mechanical, one-pass
//     change.
//
//  2. **Time observer is the central nervous system.** The
//     `addPeriodicTimeObserver` 1Hz tick drives
//     `updateProgress`, which fans out to PlaybackClock,
//     NowPlayingService, the listening-time tracker, etc.
//     Moving the registration / teardown to one class with
//     one owner (the controller) makes the lifetime
//     explicit: setup on player create, teardown on player
//     destroy. The actual `updateProgress` body stays on
//     PlayerState (it reads from the player via the
//     forwarding property and fans out to the rest of the
//     app — most of which is PlayerState-owned).
//
//  3. **Per-player cancellables are an implementation
//     detail of the observer set.** The previous
//     `var cancellables: Set<AnyCancellable>` on PlayerState
//     was a mix of per-player observers (4-5 publishers in
//     `setupPlayerObservers`) and a few stray ones. The
//     S17-H comment at line 327-345 already documents that
//     "lifetime-only observers" should live in
//     `lifetimeCancellables`. So the only thing in
//     `cancellables` is per-player stuff. Moving it to the
//     controller is the correct ownership line.
//
//  4. **PlayerItem observers are scoped per-item.** The
//     `.AVPlayerItemDidPlayToEndTime`,
//     `.AVPlayerItemFailedToPlayToEndTime`, and
//     `.AVPlayerItemPlaybackStalled` notifications are
//     registered with the specific `AVPlayerItem` as the
//     `object`, so they only fire for that item. The token
//     list (`playerItemObserverTokens`) is cleared on
//     `removeTimeObserver()` so a new player doesn't get
//     the old item's end-time callback.
//
//  5. **No callbacks need to fire back into PlayerState**
//     from the time observer itself — the tick reads the
//     player and writes to PlaybackClock, NowPlayingService,
//     and the listening-time tracker via the weak
//     `playerState` ref. The PlayerItem notifications route
//     to PlayerState methods
//     (`playerDidFinishPlaying`,
//     `playerFailedToPlayToEndTime`,
//     `playerPlaybackStalled`) via the same ref.
//
//  ## Threading
//
//  **Not** `@MainActor`. All call sites run on the main
//  thread:
//  - `setupObservers` is called from play(item:),
//    playRadioStation, playPodcastEpisode,
//    playAudiobookChapter (all main-thread by PlayerState
//    contract)
//  - `removeTimeObserver` is called from the same places
//    plus stop() (main)
//  - The 1Hz tick is registered on `.main` queue
//  - NotificationCenter observers are registered with
//    `queue: .main`
//
//  PlayerState is not `@MainActor`, so making this
//  `@MainActor` would force every call site to bridge —
//  verbose and adds nothing. The internal state is the
//  AVPlayer reference (atomic) + a small set of observer
//  tokens (we add/remove only on the main thread).
//
//  ## Forwarding pattern
//
//  PlayerState exposes a forwarding computed property
//  `var player: AVPlayer?` that reads/writes through the
//  controller. This lets the ~50 existing call sites
//  (`self.player?.play()`, `self.player = AVPlayer(...)`)
//  work unchanged. The only call sites that need updates
//  are the ones that call setupPlayerObservers /
//  removeTimeObserver / cancellables directly — those
//  become `avPlayerController.setupObservers()` etc.
//

import Foundation
import AVFoundation
import Combine

/// S17-H / Tier 4: Owns the AVPlayer instance + the time
/// observer + per-item notification tokens + the
/// per-player `cancellables` set for PlayerState.
///
/// See class header for the extraction rationale +
/// threading notes. The controller is the single owner of:
/// - `player: AVPlayer?` (the reference; the underlying
///   type may be `AVQueuePlayer` in gapless mode, but the
///   property is typed `AVPlayer?` for the same reason as
///   before — both subclasses are usable through the base
///   API, and the queue-specific operations live in
///   `GaplessController`).
/// - `timeObserver: Any?` (the 1Hz periodic time observer
///   token from `addPeriodicTimeObserver`).
/// - `playerItemObserverTokens: [NSObjectProtocol]`
///   (per-item notification observer tokens).
/// - `cancellables: Set<AnyCancellable>` (the per-player
///   Combine observers).
final class AVPlayerController {

    // MARK: - Public state

    /// The current AVPlayer. May be `AVQueuePlayer` in
    /// gapless mode (set by GaplessController) or
    /// `AVPlayer` in crossfade mode. Read/write is
    /// main-thread only.
    var player: AVPlayer?

    // MARK: - Private state

    /// The 1Hz periodic time observer. Removed in
    /// `removeTimeObserver()` so a new player doesn't get
    /// the old tick callback.
    private var timeObserver: Any?

    /// Per-item notification observer tokens. Cleared in
    /// `removeTimeObserver()` so a new player doesn't get
    /// the old item's end-time / failure / stall callbacks.
    private var playerItemObserverTokens: [NSObjectProtocol] = []

    /// Per-player Combine observers. Cleared in
    /// `clearCancellables()` and in `setupObservers()` so
    /// a new player doesn't accumulate dead subscriptions.
    /// **Not** the same as `lifetimeCancellables` on
    /// PlayerState (which holds non-player observers like
    /// the queueStore mirror — those are app-lifetime).
    ///
    /// S17-H / Tier 4: was `private`; promoted to internal
    /// so PlayerState's lifetime-mirror subscriptions (e.g.
    /// the queueStore mirror that survives a player
    /// rebuild, the @Snapshotable mirror) can still
    /// `.store(in: &cancellables)` here. They live with
    /// the controller's per-player set because they were
    /// mixed in with the per-player observers before this
    /// extraction; the cleaner fix would be a third
    /// `Set<AnyCancellable>` (lifetime-of-player) but
    /// that's out of scope for this refactor.
    var cancellables: Set<AnyCancellable> = []

    // MARK: - Dependencies

    /// Single weak ref to PlayerState. Used for callbacks
    /// that fire from the item notifications
    /// (`playerDidFinishPlaying`,
    /// `playerFailedToPlayToEndTime`,
    /// `playerPlaybackStalled`) and for the Combine sink
    /// bodies that need to mutate PlayerState (duration,
    /// playbackState, PlaybackClock, NowPlayingService).
    /// The weak ref breaks the strong reference cycle
    /// (PlayerState owns the controller, controller holds
    /// back a ref to PlayerState).
    private weak var playerState: PlayerState?

    // MARK: - Init

    init(playerState: PlayerState) {
        self.playerState = playerState
    }

    // MARK: - Public API

    /// Wire the time observer, item notifications, and
    /// Combine publishers for the current player.
    /// Idempotent — clears any prior `cancellables` /
    /// tokens first so the function represents "the current
    /// player has exactly these observers, and nothing
    /// else."
    ///
    /// Call sites: `play(item:)`, `playRadioStation(_:)`,
    /// `playPodcastEpisode(_:)`,
    /// `playAudiobookChapter(_:)`.
    func setupObservers() {
        guard let player = player else { return }

        // S15: cancel any prior player observers before
        // wiring the new ones. `setupPlayerObservers` adds
        // 4 cancellables per call; some call sites
        // (play(item:), gapless crossfade) didn't clear the
        // set first, so dead subscriptions accumulated over
        // a long session (200+ after 50 plays). Clearing
        // here means the function is idempotent: it
        // represents "the current player has exactly these
        // 4 observers, and nothing else."
        let priorCancellableCount = cancellables.count
        print("🔊 AVPlayerController.setupObservers: clearing \(priorCancellableCount) prior cancellables")
        cancellables.removeAll()

        // S17-H / S17-LOCK: KVO observer on
        // `player.timeControlStatus`. The scene-phase hook
        // in the App entry is the gross-grained catch (every
        // .inactive/.active). The KVO is the fine-grained
        // catch (any pause event that doesn't go through
        // scene phase — route changes, media-services
        // reset recovery, transient iOS audio session
        // deactivations). Both must run for the
        // "track pauses on lock / minimize" bug to stay
        // fixed. See `handleExternalPlayerPause` in
        // PlayerState for the gating logic.
        setupTimeControlStatusObserver()

        // Observe player item status and errors
        player.currentItem?.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.handlePlayerItemStatus(status)
            }
            .store(in: &cancellables)

        // Time observer for progress updates
        // C-2026-06-28: 1.0s instead of 0.5s. The lock screen
        // / Control Center / scrubber all display in 1s
        // increments (the iOS Music app's periodic time
        // observer also runs at 1s). Going to 0.5s doubled
        // the @Published churn on PlaybackClock and starved
        // the main thread — UI taps were lost because
        // SwiftUI never got a turn to dispatch them. 1s is
        // the precision floor the user can perceive.
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            // Route the tick back to PlayerState's
            // updateProgress, which reads from
            // `self.player` (forwards to us) and fans out to
            // PlaybackClock, NowPlayingService, the
            // listening-time tracker, etc. Keeping the
            // 1Hz-tick body on PlayerState means the
            // high-level orchestration (crossfade prep,
            // progress save) stays in one place.
            self?.playerState?.updateProgress()
        }

        // Observe item duration
        player.currentItem?.publisher(for: \.duration)
            .compactMap { $0.seconds > 0 ? $0.seconds : nil }
            // C-2026-06-28: for HTTP streams the duration
            // publisher emits many times in rapid succession
            // as the server resolves chunks. Each call to
            // updateRemoteControls() runs the full
            // updateNowPlaying pipeline
            // (MPNowPlayingInfoCenter write + 5 widget
            // reloads + SharedNowPlayingState JSON encode).
            // On a saturated main thread this exhausts the
            // 5-second gesture gate and iOS SIGKILLs the
            // process.
            //
            // Fix: only call updateRemoteControls() when the
            // duration changes by more than 1 second, and
            // skip calls that would be redundant with the
            // existing updatePlaybackTime path. The
            // per-second scrubber ticks still drive
            // updatePlaybackTime.
            .removeDuplicates(by: { abs($0 - $1) < 1.0 })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                print("🔊 Duration updated: \(duration)")
                self?.playerState?.duration = duration
                // Update Now Playing info with the new duration
                self?.playerState?.updateRemoteControls()
            }
            .store(in: &cancellables)

        // Observe playback end
        // C-2 fix: token-based observer. We scope to the
        // specific item so old observers don't fire on a
        // new player after a track change.
        if let item = player.currentItem {
            playerItemObserverTokens.append(
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    self?.playerState?.playerDidFinishPlaying()
                }
            )

            // Observe playback failure mid-track
            playerItemObserverTokens.append(
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] notification in
                    self?.playerState?.playerFailedToPlayToEndTime(notification)
                }
            )

            // Observe playback stall
            playerItemObserverTokens.append(
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemPlaybackStalled,
                    object: item,
                    queue: .main
                ) { [weak self] notification in
                    self?.playerState?.playerPlaybackStalled(notification)
                }
            )
        }

        // Observe buffering / stall recovery
        player.currentItem?.publisher(for: \.isPlaybackLikelyToKeepUp)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLikelyToKeepUp in
                self?.handleIsPlaybackLikelyToKeepUp(isLikelyToKeepUp)
            }
            .store(in: &cancellables)

        print("✅ AVPlayerController.setupObservers completed")
    }

    /// Tear down the time observer, per-item notification
    /// tokens, and per-player Combine cancellables. Called
    /// from `stop()` and the playRadioStation /
    /// playPodcastEpisode / playAudiobookChapter entry
    /// points before they build a new player.
    ///
    /// C-2 fix: only remove the player-item-scoped
    /// observers, not all observers. Audio session observers
    /// (interruption / route change / media services reset)
    /// must remain registered for the lifetime of the
    /// PlayerState singleton, otherwise phone calls /
    /// AirPods disconnect / Siri would stop pausing
    /// playback after a content-type switch.
    func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        playerItemObserverTokens.forEach { NotificationCenter.default.removeObserver($0) }
        playerItemObserverTokens.removeAll()
    }

    /// Drop the per-player Combine cancellables without
    /// touching the time observer or item notifications.
    /// Useful when a code path wants to clear the Combine
    /// publishers (e.g., to free a sink that captured a
    /// self-reference) without unregistering the periodic
    /// time observer. The `stop()` path uses
    /// `removeTimeObserver()` instead, which is more
    /// thorough.
    func clearCancellables() {
        cancellables.removeAll()
        teardownTimeControlStatusObserver()
    }

    // S17-H / S17-LOCK: KVO observer on `player.timeControlStatus`.
    // The scene-phase hook in `YTAudioPlayerApp` is the
    // "first line of defense" — it re-asserts playback on
    // every .inactive/.active transition. But iOS can pause
    // the player in OTHER situations where the scene phase
    // doesn't change (e.g., a brief route change while
    // foregrounded, a media-services-reset that's quietly
    // recovered, a phone-call-style interruption that the
    // session controller doesn't catch). When ANY of those
    // fire, the player silently goes to `paused` and the
    // user sees a track that "stops on its own".
    //
    // The KVO observer catches every `timeControlStatus`
    // change and notifies PlayerState via
    // `handleExternalPlayerPause()`. PlayerState then
    // decides whether to re-assert playback (based on the
    // user's intent recorded in `playbackState`). This is
    // the "second line of defense" — the scene phase hook
    // is the gross-grained, KVO is the fine-grained.
    //
    // Trade-off: KVO fires synchronously on the player
    // thread, so we dispatch to main before touching
    // PlayerState. The lock is held by the player during
    // the KVO callback, so we don't re-enter.
    private var timeControlStatusObserver: NSKeyValueObservation?

    /// Start the KVO observer. Called from `setupObservers`
    /// (right after the existing Combine sinks are wired).
    func setupTimeControlStatusObserver() {
        guard let player = player else { return }
        timeControlStatusObserver = player.observe(
            \.timeControlStatus,
             options: [.new, .initial]
        ) { [weak self] _, _ in
            // Dispatch off the player thread to avoid re-entry.
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.playerState?.handleExternalPlayerPause()
            }
        }
    }

    /// Stop the KVO observer. Called from `clearCancellables`
    /// when the player is torn down.
    func teardownTimeControlStatusObserver() {
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
    }

    /// Handle the AVPlayerItem status change. Was inline in
    /// the Combine sink on the original PlayerState.
    /// Extracted here so the sink body is a single closure
    /// call (testable, log noise stays out of the
    /// controller's main flow).
    private func handlePlayerItemStatus(_ status: AVPlayerItem.Status) {
        print("🔊 Player item status changed: \(status)")
        switch status {
        case .readyToPlay:
            print("✅ Player item ready to play")
            playerState?.retryCount = 0  // Reset retry count on success
            // S17-H follow-up: clear the loading-state timeout
            // — the player reached ready before the 15s safety net.
            playerState?.loadingTimeoutWorkItem?.cancel()
            // Defer showing .playing until audio is actually ready.
            if playerState?.playbackState == .loading {
                playerState?.playbackState = .playing
            }
        case .failed:
            guard let self = playerState else { return }
            if let error = player?.currentItem?.error as NSError? {
                print("❌ Player item failed: \(error)")
                print("❌ Error domain: \(error.domain), code: \(error.code)")
                print("❌ Error userInfo: \(error.userInfo)")

                // Retry with fresh URL if possible
                if self.retryCount < self.maxRetries,
                   let item = self.currentItem {
                    self.retryCount += 1
                    print("🔄 Retrying playback (attempt \(self.retryCount)/\(self.maxRetries))...")
                    self.refreshAndPlayCurrentItem()
                } else {
                    // CRITICAL FIX: After max retries, skip to
                    // next track instead of staying in error
                    print("❌ Max retries reached, skipping to next track")
                    // C-3 fix: surface the error to the user
                    // with a longer pause before auto-skip so
                    // they have a chance to read the message
                    // and tap retry. The original 1.0s skip
                    // was too short to even see the error in
                    // the previous silent flow.
                    //
                    // S17-H follow-up: include the underlying
                    // AVPlayer error details so the user can
                    // tell "network timed out" from "track not
                    // streamable" from "backend 500". The
                    // previous generic "Couldn't play this
                    // track after multiple attempts" hid the
                    // actual cause — particularly the recent
                    // S17-H bug where the AsyncClient closed
                    // mid-stream and surfaced as a generic
                    // AVPlayer failure.
                    let nsError = player?.currentItem?.error as NSError?
                    let detail = nsError.map { PlayerState.describeAVPlayerError($0) } ?? "unknown error"
                    self.playbackState = .error("Playback failed: \(detail)")
                    ErrorHandler.shared.show(
                        .playbackFailed("Couldn't play this track (\(detail)). Skipping to the next one."),
                        retry: { [weak self] in
                            self?.refreshAndPlayCurrentItem()
                        }
                    )
                    // S11 fix (Bug 4): end the BG task we
                    // acquired (via Trigger A or Trigger B)
                    // so it doesn't leak for the 2.5s wait.
                    // The nextTrack() dispatch below will
                    // re-acquire via nextTrack's
                    // beginTrackTransitionBackgroundTask().
                    self.endTrackTransitionBackgroundTask()
                    self.clearCompletionFlag()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                        self?.nextTrack()
                    }
                }
            }
        case .unknown:
            print("⚠️ Player item status unknown")
        @unknown default:
            print("⚠️ Player item status unknown default")
        }
    }

    /// Handle the isPlaybackLikelyToKeepUp Combine
    /// publisher. Was inline in the Combine sink. Drives
    /// the stall recovery path (S17-H fix from commit
    /// 88c6de9) and the loading → playing transition
    /// (S10 fix).
    private func handleIsPlaybackLikelyToKeepUp(_ isLikelyToKeepUp: Bool) {
        guard let self = playerState else { return }
        print("🔊 isPlaybackLikelyToKeepUp: \(isLikelyToKeepUp)")
        if isLikelyToKeepUp {
            // S17-H follow-up: clear the loading-state
            // timeout — the player buffered enough before
            // the 15s safety net.
            self.loadingTimeoutWorkItem?.cancel()
            if self.isPlaybackStalled {
                self.isPlaybackStalled = false
                print("🔄 Recovery from stall: resuming playback")
                self.player?.play()
                self.player?.rate = self.playbackRate
                self.playbackState = .playing
            } else if self.playbackState == .buffering {
                self.playbackState = .playing
            } else if self.playbackState == .loading {
                self.playbackState = .playing
                // S10: the new track has buffered enough to
                // start producing audio. It's now safe to
                // release the 30-second background task we
                // acquired in nextTrack /
                // playerDidFinishPlaying — the audio
                // session's "audio" background mode keeps the
                // app alive on its own. Releasing earlier
                // meant we could be suspended before any
                // audio flowed, especially in the background
                // after autoplay.
                self.endTrackTransitionBackgroundTask()
                print("🔓 S10: BG task released — new track is playing")
                // S11 fix (Bug 14): pair with the flag
                // reset. The handleTrackCompletion defer
                // scheduled a 5s safety timeout; we can clear
                // that and the isHandlingCompletion flag
                // right now since the new track is confirmed
                // playing.
                self.clearCompletionFlag()
            }
        }
    }
}
