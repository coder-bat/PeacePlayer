//
//  GaplessController.swift
//  PeacePlayer
//
//  S17-H / Tier 4: Second extraction from the 3269-line PlayerState
//  god object. Owns the AVQueuePlayer pre-queueing logic and the
//  auto-advance state sync that used to live as `enqueueUpcomingItemsForGapless`
//  and `advanceGaplessState` plus the `trackIdentifier(for:)` helper
//  on PlayerState.
//
//  ## Why this is a safe extraction
//
//  1. **No state, only behavior.** The class has no @Published
//     properties. All state lives on the AVQueuePlayer (which
//     PlayerState owns), the QueueStore (which the rest of the
//     app reads), and the dataManager (history persistence).
//     GaplessController is a stateless function-on-demand over
//     these existing state holders.
//
//  2. **Narrow surface area.** Three methods:
//     - `enqueueUpcomingItems()` — clear AVQueuePlayer's pre-queue
//       and refill it with the next 3 tracks
//     - `handleAutoAdvance()` — called from the
//       `.AVPlayerItemDidPlayToEndTime` notification handler
//       in gapless mode; mirrors the new currentItem into
//       PlayerState's @Published properties
//     - `trackIdentifier(for: AVPlayerItem)` — reverse lookup
//       from an AVQueuePlayer item back to a videoId, used by
//       `handleAutoAdvance`
//
//  3. **Single weak dependency.** All PlayerState state we need
//     to read or mutate flows through one `weak var` PlayerState
//     reference. This avoids a protocol/closure explosion for a
//     110-line extraction that already has tight coupling to
//     PlayerState's structure (the @Published `currentItem`,
//     the `updateExpectedDuration(_:)` helper, etc).
//
//  4. **Preserves all S17-H fixes.** The "drop already-queued
//     items" bug from commit `dd7b110` (P3 polish) is preserved
//     by the iteration-and-remove in `enqueueUpcomingItems()`.
//     The S11 lock-screen-refresh fix in `advanceGaplessState`
//     moves with the method, intact.
//
//  ## Threading
//
//  **Not** `@MainActor`. All call sites run on the main thread:
//  - `enqueueUpcomingItems()` is called from `setCurrentPlayer`
//    and the auto-advance path in PlayerState (both main)
//  - `handleAutoAdvance()` is called from the
//    `.AVPlayerItemDidPlayToEndTime` notification observer
//    registered on `.main` in PlayerState
//
//  PlayerState itself is not `@MainActor`, so making this
//  `@MainActor` would force every call site to bridge. The
//  internal state is the AVQueuePlayer's `items()` (atomic)
//  and local consts — no contention possible.
//

import Foundation
import AVFoundation
import Combine

/// S17-H / Tier 4: Owns gapless mode (AVQueuePlayer pre-queue +
/// auto-advance state sync) for PlayerState.
///
/// See class header for the extraction rationale + threading notes.
final class GaplessController {

    // MARK: - Configuration

    /// How many tracks to pre-queue ahead of the current track.
    /// Mirrors the 3-track limit in the original PlayerState code.
    /// Tuned to balance memory (each AVPlayerItem is ~5MB for
    /// prefetched AAC) vs perceived gaplessness (next 3 transitions
    /// are instant).
    private let lookAhead: Int = 3

    /// Pre-buffer duration for each pre-queued item. Mirrors the
    /// 5s setting in the original code. AVPlayer will start
    /// downloading this much ahead of the playhead.
    private let preBufferSeconds: Double = 5

    // MARK: - Dependencies

    /// Single weak ref to PlayerState. All reads of player/queue/
    /// repeatMode and writes to currentItem/updateExpectedDuration
    /// go through this. The weak ref breaks the strong reference
    /// cycle that would otherwise form (PlayerState owns the
    /// controller, controller holds back a strong ref to state).
    private weak var playerState: PlayerState?

    // MARK: - Init

    init(playerState: PlayerState) {
        self.playerState = playerState
    }

    // MARK: - Public API

    /// Re-fill the AVQueuePlayer with the next `lookAhead` tracks
    /// (wrapping on repeat-all). Clears any already-pre-queued
    /// items first to prevent the S17-H "track 4 played three
    /// times" bug (commit `dd7b110`).
    ///
    /// Call sites in PlayerState:
    /// - After `setCurrentPlayer` (initial pre-queue)
    /// - From `handleAutoAdvance` (re-fill after auto-advance)
    /// - After manual `playNext` / `playPrevious` (queue rebuild)
    func enqueueUpcomingItems() {
        guard let playerState = playerState,
              let queuePlayer = playerState.player as? AVQueuePlayer else { return }
        guard playerState.repeatMode != .one else {
            print("🔊 Gapless: repeat-one, not enqueueing more items")
            return
        }

        // Walk forward from the next index, taking into account repeat-all
        // (which wraps the queue back to the start).
        let queueCount = playerState.queue.count
        guard queueCount > 1 else { return }

        // S17-H: drop already-queued-but-not-current AVPlayerItems
        // before re-enqueueing. The previous code blindly called
        // `queuePlayer.insert(item, after: queuePlayer.items().last)`
        // on every auto-advance / next-tap, leaving the items the
        // AVQueuePlayer had already pre-queued for upcoming tracks
        // in place. After 3 auto-advances in a row, the
        // AVQueuePlayer's items[] would contain [3, 4, 5, 6, 4, 5,
        // 6, 4, 5, 6] — same tracks appended multiple times. The
        // user would hear track 4 played three times in a row.
        // Strategy: remove every item except the current one. This
        // is safe because AVQueuePlayer's `canInsert(_:after:)` is
        // for inserting new items; what we need is the inverse
        // operation on already-queued items. The simplest correct
        // path: iterate `items()` after the current, remove each.
        for queuedItem in queuePlayer.items().dropFirst() {
            queuePlayer.remove(queuedItem)
        }

        let lookAhead = min(self.lookAhead, queueCount - 1)
        for offset in 1...lookAhead {
            let nextIdx: Int
            if playerState.repeatMode == .all {
                nextIdx = (playerState.currentIndex + offset) % queueCount
            } else {
                nextIdx = playerState.currentIndex + offset
                if nextIdx >= queueCount { break }
            }

            let nextItem = playerState.queue[nextIdx]
            guard let url = URL(string: nextItem.streamUrl) else { continue }

            let nextPlayerItem = AVPlayerItem(url: url)
            nextPlayerItem.preferredForwardBufferDuration = preBufferSeconds
            nextPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            queuePlayer.insert(nextPlayerItem, after: queuePlayer.items().last)
            print("🔊 Gapless: pre-queued [\(nextIdx)] \(nextItem.track.title)")
        }
    }

    /// Sync PlayerState's `currentIndex`/`currentItem` to the new
    /// `currentItem` of the AVQueuePlayer after an auto-advance.
    ///
    /// Called from the `.AVPlayerItemDidPlayToEndTime` notification
    /// observer in PlayerState when gapless mode is on. The
    /// observer finds this method on `gaplessController` and
    /// delegates here.
    ///
    /// Side effects (kept in lockstep with the pre-extraction code):
    /// - `queueStore.setCurrentIndex(matchIdx)` — drive the
    ///   currentIndex via the store so the @Published mirror
    ///   in PlayerState updates
    /// - `currentItem = item` — direct write (PlayerState's
    ///   setter triggers UI observers)
    /// - `updateExpectedDuration(_:)` — keep the scrubber /
    ///   playbackClock in sync with the new track's duration
    ///   (S17-H fix: was 1-3s lag on auto-advance)
    /// - `dataManager.addToRecentlyPlayed` + `.trackPlayed`
    ///   notification — same path as a manual next-tap
    /// - `NowPlayingService.shared.updateNowPlaying` — S11 fix
    ///   for "lock screen shows previous track for 1-3s"
    /// - Re-enqueue so the queue is never empty
    func handleAutoAdvance() {
        guard let playerState = playerState,
              let queuePlayer = playerState.player as? AVQueuePlayer else { return }
        guard let nowPlaying = queuePlayer.currentItem,
              let matchIdx = playerState.queueStore.items.firstIndex(where: { $0.track.videoId == trackIdentifier(for: nowPlaying) }) else {
            return
        }
        // S17-G: set currentIndex via the store. The mirror
        // subscription will keep currentItem in sync.
        playerState.queueStore.setCurrentIndex(matchIdx)
        if matchIdx < playerState.queueStore.items.count {
            let item = playerState.queueStore.items[matchIdx]
            playerState.currentItem = item
            // S17-H: push expectedDuration through the helper so
            // playbackClock (and the scrubber) follow the
            // auto-advance. Without this the lock-screen / control-
            // center duration stayed on the previous track for
            // 1-3s after the auto-advance fired (NowPlayingService
            // gets the new duration, but the in-app scrubber uses
            // playbackClock).
            playerState.updateExpectedDuration(Double(item.track.durationSeconds))
            playerState.dataManager.addToRecentlyPlayed(item.track)
            NotificationCenter.default.post(name: .trackPlayed, object: nil)
            // S11 fix (Bug 2): refresh Lock Screen / Control Center
            // immediately on gapless auto-advance. Without this the
            // system Now Playing kept showing the previous track
            // until the next duration-publisher tick (1-3s for HTTP
            // streams).
            NowPlayingService.shared.updateNowPlaying(
                track: item.track,
                duration: Double(item.track.durationSeconds),
                currentTime: 0,
                isPlaying: playerState.playbackState.isPlaying,
                playbackRate: playerState.playbackRate
            )
        }
        // Re-enqueue so we always have a few items in the queue player.
        enqueueUpcomingItems()
    }

    /// Best-effort: match an AVPlayerItem back to a videoId by
    /// inspecting the URL path. Used by `handleAutoAdvance` to
    /// figure out which queue item the AVQueuePlayer just
    /// auto-advanced to.
    func trackIdentifier(for playerItem: AVPlayerItem) -> String? {
        guard let asset = playerItem.asset as? AVURLAsset else { return nil }
        // S11 fix (Bug 7): previously only stripped .m4a; the proxy
        // endpoint also serves .webm when preferM4A=false. Use the
        // delegate's preferred bit depth via pathExtension rather than
        // hardcoding the suffix.
        let lastPath = asset.url.lastPathComponent
        for ext in ["m4a", "webm", "mp4", "mp3"] {
            if lastPath.hasSuffix(".\(ext)") {
                return String(lastPath.dropLast(ext.count + 1))
            }
        }
        return lastPath
    }
}
