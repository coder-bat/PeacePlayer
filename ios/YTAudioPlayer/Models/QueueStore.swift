//
//  QueueStore.swift
//  PeacePlayer
//
//  S17-G (perf 10 P0-F1): extracted from PlayerState so queue
//  mutations don't trigger `PlayerState.objectWillChange`.
//
//  The previous design had `@Published var queue: [QueueItem] = []`
//  on PlayerState. Every add/remove/move/replace fired
//  `objectWillChange`, which re-evaluated every view that observes
//  PlayerState — including MiniPlayer (1 view), FullPlayer
//  (1 view, 1853-line body with 1288-line ArtworkBackground
//  blur), OrbitalMenu, LyricsView, and ProgressSection. With a
//  200-item queue, drag-to-reorder of 200 items × 200 observers
//  × full-body re-evaluation = multi-second jank.
//
//  Fix: the queue lives in a separate ObservableObject. Views
//  that display the queue (QueueView) observe the store directly.
//  Views that don't display the queue (MiniPlayer, FullPlayer,
//  etc.) continue to observe PlayerState — but PlayerState's
//  objectWillChange no longer fires on queue mutations. It only
//  fires when the *current item* changes (via the mirror in
//  PlayerState.init).
//
//  Design notes:
//  - Both `items` and `currentIndex` are private(set) so the
//    store's invariants (dedup on add, trim on overflow) are
//    maintained in one place.
//  - `currentItem` is a computed property (not @Published) —
//    views that need it observe the store and re-derive.
//  - The store is a `let` on PlayerState so the lifetime is
//    tied to PlayerState (singleton). PlayerState forwards
//    `addToQueue` / `addToQueueNext` / `removeFromQueue` / etc.
//    to the store. PlayerState's `nextTrack` (gapless path)
//    also goes through the store.
//

import Foundation
import Combine

final class QueueStore: ObservableObject {
    /// The full queue. Includes the current track at `currentIndex`
    /// and upcoming tracks after it. `private(set)` because
    /// mutations go through the `add*` / `remove*` / `move*` /
    /// `clear` / `replace` methods, which maintain the dedup
    /// + trim invariants.
    @Published private(set) var items: [QueueItem] = []

    /// The current playback index. -1 when nothing is queued.
    @Published private(set) var currentIndex: Int = -1

    /// The current item, if any. Computed, not @Published, so
    /// accessing it doesn't register a separate observation.
    /// Views that display it should observe `items` and
    /// `currentIndex` directly.
    var currentItem: QueueItem? {
        guard currentIndex >= 0, currentIndex < items.count else { return nil }
        return items[currentIndex]
    }

    // MARK: - Mutations

    /// Append `item` to the end of the queue. Dedups by
    /// `videoId` — duplicates are silently dropped. Trims to
    /// `maxQueueSize` (drops from the front) if the queue
    /// grows beyond that.
    func add(_ item: QueueItem, maxQueueSize: Int) {
        if items.contains(where: { $0.track.videoId == item.track.videoId }) {
            print("⚠️ QueueStore.add: skipping duplicate videoId=\(item.track.videoId)")
            return
        }
        items.append(item)
        if items.count > maxQueueSize {
            trimFront(maxQueueSize: maxQueueSize)
        }
    }

    /// Insert `item` immediately after the current track. If
    /// the queue is empty, this behaves like `add`. Dedups by
    /// `videoId`. Trims to `maxQueueSize` on overflow.
    func addNext(_ item: QueueItem, maxQueueSize: Int) {
        if items.contains(where: { $0.track.videoId == item.track.videoId }) {
            print("⚠️ QueueStore.addNext: skipping duplicate videoId=\(item.track.videoId)")
            return
        }
        let insertIndex: Int
        if currentIndex < 0 {
            insertIndex = items.count
        } else {
            insertIndex = min(currentIndex + 1, items.count)
        }
        items.insert(item, at: insertIndex)
        if items.count > maxQueueSize {
            trimFront(maxQueueSize: maxQueueSize)
        }
    }

    /// Remove the item at `index`. Adjusts `currentIndex` if
    /// the removal would leave it pointing past the end.
    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        let removed = items.remove(at: index)
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex, currentIndex >= items.count {
            // The current track was removed and there are no
            // tracks after it. Clamp the index.
            currentIndex = items.count - 1
        }
        _ = removed // suppress unused warning; we may log later
    }

    /// Move items from `source` to `destination`. Standard
    /// SwiftUI `List.onMove` semantics — `destination` is
    /// the index *before* the move in the new ordering.
    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    /// Remove all items and reset the index. Use sparingly —
    /// clearing the queue doesn't stop playback (the
    /// `nextTrack` path handles the "no more tracks" case).
    func clear() {
        items.removeAll()
        currentIndex = -1
    }

    /// Replace the entire queue. Used by `QueueRestorer` on
    /// app launch when a saved queue is found. The caller is
    /// responsible for setting `currentIndex` afterwards.
    func replace(with newItems: [QueueItem]) {
        items = newItems
    }

    /// Update the current index. Called by `playQueue(at:)`,
    /// gapless `nextTrack`, and `QueueRestorer` after
    /// `replace(with:)`. Out-of-range values are clamped.
    func setCurrentIndex(_ index: Int) {
        if items.isEmpty {
            currentIndex = -1
        } else {
            currentIndex = max(0, min(index, items.count - 1))
        }
    }

    // MARK: - Private

    /// Drop the oldest items from the front, keeping the
    /// current track and the next ~50 upcoming tracks.
    private func trimFront(maxQueueSize: Int) {
        let keepFromCurrent = 50
        let keepEnd = min(currentIndex + keepFromCurrent, items.count)
        if keepEnd < items.count {
            // Drop everything after `keepEnd` (these are tracks
            // we'll never get to).
            items.removeSubrange(keepEnd..<items.count)
        }
        // If still over maxQueueSize, drop from the front.
        if items.count > maxQueueSize {
            let dropCount = items.count - maxQueueSize
            items.removeFirst(dropCount)
            currentIndex = max(-1, currentIndex - dropCount)
        }
    }
}
