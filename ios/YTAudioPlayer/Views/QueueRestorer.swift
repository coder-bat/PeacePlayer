//
//  QueueRestorer.swift
//  YTAudioPlayer
//
//  Restores the last session's queue + current track on cold launch.
//
//  2026-11-20 (rewrite). The previous version of this file asked the
//  user "Resume Playback?" for multi-track queues and silently
//  auto-resumed single-track queues — but the flag that gated it
//  (`@AppStorage("queueRestorePromptShown")` in ContentView) was
//  UserDefaults-backed, so it latched `true` on the very first launch
//  that had a saved queue and every later launch skipped the restore
//  entirely. The user-visible symptom was "close the app, come back,
//  everything has reset".
//
//  The only path that survived was `PlayerState.init` → `restoreQueue()`,
//  which refetched a stream URL for EVERY queue item in parallel. When
//  the backend was cold or unreachable, every fetch failed, the restore
//  produced an EMPTY queue, and the app came back with nothing at all.
//
//  The new path restores METADATA ONLY: the queue is rebuilt from the
//  CoreData rows `PlaybackQueueManager` already persists, with a
//  placeholder stream URL on streamed tracks. The URL for the track the
//  user plays is resolved lazily, on demand. That makes the restore
//  instant and independent of the backend being up.
//
//  Behaviour on launch: the queue comes back, the current track comes
//  back, the scrubber sits at the saved position, and the player is
//  PAUSED — the user taps play and it continues from where it stopped.
//

import Foundation
import SwiftUI
import Combine

/// Restores the previous session's queue + current track.
final class QueueRestorer: ObservableObject {
    static let shared = QueueRestorer()

    /// True once a restore has been attempted in this process. Guards
    /// against restoring twice (e.g. `ContentView` re-appearing after a
    /// sheet dismissal would re-run `onAppear`).
    @Published private(set) var didRestore = false

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    /// Restores the previous session's queue + current track, paused.
    ///
    /// Returns `true` when a queue was restored.
    @discardableResult
    func restoreLastSession() -> Bool {
        guard !didRestore else { return false }
        didRestore = true

        // Metadata only — no stream URLs are fetched here.
        let saved = PlaybackQueueManager.shared.loadQueue()
        guard !saved.isEmpty else {
            print("📭 No saved queue to restore")
            return false
        }

        let items: [QueueItem] = saved.map { entry in
            // A local file keeps its path — nothing to resolve.
            if entry.wasLocal,
               let streamUrl = entry.streamUrl,
               let path = URL(string: streamUrl)?.path,
               FileManager.default.fileExists(atPath: path) {
                return QueueItem(
                    track: entry.track,
                    streamUrl: streamUrl,
                    source: .local(path: path),
                    contentSource: .local,
                    createdAt: Date()
                )
            }
            // Streamed track: placeholder URL. `PlayerState.play(item:)`
            // resolves a fresh one the moment the user presses play.
            return QueueItem(
                track: entry.track,
                streamUrl: "",
                source: .stream,
                createdAt: Date()
            )
        }

        guard !items.isEmpty else { return false }

        // Which track were we on? The snapshot knows (it records the
        // track the user actually had loaded); the CoreData `isCurrent`
        // flag is the fallback for a snapshot that predates this build.
        let snapshot = DataManager.shared.loadPlaybackSnapshot()
        var index = PlaybackQueueManager.shared.getSavedCurrentIndex()
        if let snapshot,
           let snapshotIndex = items.firstIndex(where: { $0.track.videoId == snapshot.trackId }) {
            index = snapshotIndex
        }
        index = max(0, min(index, items.count - 1))

        let state = PlayerState.shared
        state.queueStore.replace(with: items)
        state.queueStore.setCurrentIndex(index)
        state.applyRestoredState(item: items[index], snapshot: snapshot)
        // Persist the restored state, so the next launch restores the
        // same track and position even if the user never presses play.
        state.persistPlaybackSnapshot()

        // Upgrade the queue with fresh stream URLs in the background.
        // The restore above already succeeded — this only makes the
        // next tracks gapless-ready, and a failure here is harmless.
        resolveMissingStreamURLs()

        #if DEBUG
        // 2026-11-20: test hook — auto-play the restored track so the
        // whole chain (restore → lazy stream-URL resolution → resume
        // position) can be verified from the command line:
        //   xcrun devicectl device process launch --device <udid> \
        //       com.ytaudioplayer.app -ui_test_autoplay_restored
        if ProcessInfo.processInfo.arguments.contains("-ui_test_autoplay_restored") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PlayerState.shared.play(item: items[index], addToQueue: false)
            }
        }
        #endif

        print("📂 Restored \(items.count) queue items (index \(index)) — paused, no stream URLs fetched")
        return true
    }

    // MARK: - Background URL upgrade

    /// Background pass that upgrades the restored queue with fresh
    /// stream URLs, so gapless playback and crossfade work again.
    ///
    /// 2026-11-20: deliberately NOT part of the restore. The restore
    /// must succeed with the backend down — this pass only *upgrades*
    /// the restored queue. Failures are ignored: a track whose URL
    /// could not be resolved is still playable through the lazy path
    /// in `PlayerState.play(item:)`.
    ///
    /// Sequential on purpose. The old eager restore fired one request
    /// per queue item at once — that burst is exactly what made the
    /// backend give up and the restore come back empty.
    private func resolveMissingStreamURLs() {
        let state = PlayerState.shared
        let pending = state.queueStore.items.filter { $0.source == .stream && $0.streamUrl.isEmpty }
        guard !pending.isEmpty else { return }

        print("🔗 Resolving \(pending.count) stream URLs in the background...")

        func resolveNext(_ remaining: [QueueItem]) {
            guard let item = remaining.first else {
                print("🔗 Background stream URL resolution finished")
                return
            }
            let rest = Array(remaining.dropFirst())
            StreamURLCache.shared.getStreamUrl(videoId: item.track.videoId)
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { _ in
                        // Fires for both success and failure — advance
                        // the chain here so it never runs twice.
                        resolveNext(rest)
                    },
                    receiveValue: { [weak self] streamInfo in
                        self?.applyResolvedURL(streamInfo.streamUrl, for: item.track.videoId)
                    }
                )
                .store(in: &cancellables)
        }

        resolveNext(pending)
    }

    /// Swaps a resolved stream URL into the queue slot for `videoId`.
    private func applyResolvedURL(_ streamUrl: String, for videoId: String) {
        let state = PlayerState.shared
        var items = state.queueStore.items
        guard let idx = items.firstIndex(where: { $0.track.videoId == videoId }),
              items[idx].streamUrl.isEmpty else { return }

        items[idx] = QueueItem(
            track: items[idx].track,
            streamUrl: streamUrl,
            source: .stream,
            contentSource: items[idx].contentSource,
            createdAt: items[idx].createdAt,
            replayGain: items[idx].replayGain
        )
        state.queueStore.replace(with: items)
    }
}
