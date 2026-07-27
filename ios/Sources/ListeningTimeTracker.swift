//
//  ListeningTimeTracker.swift
//  PeacePlayer
//
//  S17-H / Tier 4: First extraction from the 2959-line PlayerState god
//  object. Owns the listening-time accounting state that used to live
//  as two private vars on PlayerState (`accumulatedListeningTime` and
//  `lastProgressUpdate`) plus the inline logic in the 1Hz time
//  observer and the save-on-completion path.
//
//  Why this is a safe first extraction:
//
//  1. The state is fully internal — neither `accumulatedListeningTime`
//     nor `lastProgressUpdate` was ever read by anything outside
//     PlayerState's own updateProgress() and handleTrackCompletion().
//     Audited via grep before extraction (no external consumers).
//
//  2. The interface is narrow — three methods (`reset()`, `tick()`,
//     `flush()`) and the construction-time dependency on DataManager.
//     No callbacks, no Combine publishers, no notification posts.
//     The tracker doesn't observe PlayerState; PlayerState pushes
//     ticks to it from the time observer.
//
//  3. The "ground truth" check for audio-actually-playing lives here
//     now (was inline in updateProgress before) — `player.rate > 0`
//     is the S17-H fix from commit `88c6de9` for "listening time
//     credited during phone call / headphone unplug". The fix is
//     preserved by moving the check, not the comment.
//
//  4. The 10-second save cadence and 5-second max-tick-delta guard
//     are constants on the tracker, not magic numbers in PlayerState.
//     Easier to tune in one place.
//
//  5. Thread safety: all callers run on the main queue (the time
//     observer is registered on .main; `handleTrackCompletion` is
//     dispatched to .main; `play(item:)` is main-thread by contract).
//     So `@MainActor` is correct and the design is non-contended.
//

import Foundation
import AVFoundation

/// S17-H / Tier 4: First extraction from the 2959-line PlayerState god
/// object. Owns the listening-time accounting state that used to live
/// as two private vars on PlayerState (`accumulatedListeningTime` and
/// `lastProgressUpdate`) plus the inline logic in the 1Hz time
/// observer and the save-on-completion path.
///
/// ## Why this is a safe first extraction
///
/// 1. The state is fully internal — neither `accumulatedListeningTime`
///    nor `lastProgressUpdate` was ever read by anything outside
///    PlayerState's own updateProgress() and handleTrackCompletion().
///    Audited via grep before extraction (no external consumers).
///
/// 2. The interface is narrow — three methods (`reset()`, `tick()`,
///    `flush()`) and the construction-time dependency on DataManager.
///    No callbacks, no Combine publishers, no notification posts.
///    The tracker doesn't observe PlayerState; PlayerState pushes
///    ticks to it from the time observer.
///
/// 3. The "ground truth" check for audio-actually-playing lives here
///    now (was inline in updateProgress before) — `player.rate > 0`
///    is the S17-H fix from commit `88c6de9` for "listening time
///    credited during phone call / headphone unplug". The fix is
///    preserved by moving the check, not the comment.
///
/// 4. The 10-second save cadence and 5-second max-tick-delta guard
///    are constants on the tracker, not magic numbers in PlayerState.
///    Easier to tune in one place.
///
/// ## Threading
///
/// **Not** `@MainActor`. All three call sites run on the main thread
/// today (the AVPlayer time observer is registered on `.main`;
/// `handleTrackCompletion` is dispatched to `.main`; `play(item:)`
/// is main-thread by contract on PlayerState). But `PlayerState` is
/// not itself `@MainActor`, so making the tracker `@MainActor` would
/// require the call sites to bridge — which is verbose and adds
/// nothing. The tracker's state is two simple fields (a `TimeInterval`
/// and an optional `Date`) and the API is small; callers are
/// documented to call from main and the class is non-contended.
///
/// If a future caller needs the tracker from a background thread,
/// add a serial dispatch queue internally rather than reach for
/// `@MainActor` (which would force every call site to bridge).
final class ListeningTimeTracker {

    // MARK: - Configuration

    /// Persist `accumulated` when it reaches this many seconds.
    /// Mirrors the 10s save cadence in the original PlayerState code.
    private let flushThreshold: TimeInterval = 10

    /// Reject ticks more than this many seconds apart — they're
    /// spurious (e.g. the app was backgrounded for a minute and
    /// the time observer fires on resume with a huge gap). Mirrors
    /// the 5s guard in the original code.
    private let maxTickDelta: TimeInterval = 5

    // MARK: - State

    /// Seconds of audio actually produced (player.rate > 0) since
    /// the last flush. Reset to 0 by `reset()` (on new track) or
    /// `flush()` (on threshold reached or external save).
    private var accumulated: TimeInterval = 0

    /// Time of the previous tick. Used to compute the delta.
    /// `nil` means "not actively tracking" (e.g. between tracks
    /// before the first tick). The first tick after a `reset()` is
    /// handled correctly: reset() sets it to `now`, so the first
    /// delta is ~0 and the tick is a no-op.
    private var lastTick: Date?

    // MARK: - Dependencies

    private weak var dataManager: DataManager?

    // MARK: - Init

    init(dataManager: DataManager? = .shared) {
        self.dataManager = dataManager
    }

    // MARK: - Public API

    /// Call when a new track starts (e.g. `play(item:)` after the
    /// previous item is stopped). Resets the accumulator and the
    /// last-tick timestamp so the next tick doesn't get a huge
    /// delta from the previous track.
    func reset() {
        accumulated = 0
        lastTick = Date()
    }

    /// Call from the 1Hz time observer. Reads `player.rate` to
    /// decide whether to count the tick — this is the "ground
    /// truth" check that prevents phone calls and headphone
    /// unplugs from being counted (the AVPlayer auto-pauses but
    /// `playbackState` doesn't flip until `pause()` is explicitly
    /// called; `player.rate` flips immediately).
    ///
    /// - Parameter player: the current AVPlayer. Pass the one
    ///   whose time observer is firing — typically
    ///   `PlayerState.player` (which may be AVPlayer or
    ///   AVQueuePlayer depending on gapless mode).
    func tick(player: AVPlayer) {
        let now = Date()
        let last = lastTick ?? now
        let delta = now.timeIntervalSince(last)
        lastTick = now

        // Reject spurious ticks: backward time (clock change), or
        // > 5s gap (background → foreground with the time observer
        // catching up). Without this guard, a 60s background would
        // credit the user 60s of listening time they didn't actually
        // hear (the AVPlayer would have auto-paused on route change,
        // but `rate > 0` is checked below anyway).
        guard delta > 0, delta < maxTickDelta else { return }

        // Ground truth: only count time when audio is actually being
        // produced. `player.rate > 0` is the AVPlayer's own
        // "currently producing audio" flag — it flips to 0 on
        // interruption, route change, and app backgrounding.
        guard player.rate > 0 else { return }

        accumulated += delta
        if accumulated >= flushThreshold {
            flush()
        }
    }

    /// Persist any accumulated time to DataManager and reset the
    /// accumulator. Called automatically by `tick()` when the
    /// accumulator reaches `flushThreshold`. Called externally by
    /// PlayerState on track completion
    /// (`handleTrackCompletion`) so the last partial batch isn't
    /// lost when a track ends.
    ///
    /// Idempotent: calling with `accumulated == 0` is a no-op.
    func flush() {
        guard accumulated > 0 else { return }
        dataManager?.addListeningTime(accumulated)
        accumulated = 0
    }
}
