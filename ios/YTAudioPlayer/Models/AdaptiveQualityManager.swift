//
//  AdaptiveQualityManager.swift
//  PeacePlayer
//
//  S18 / v1.6.7 (CV-11): extracted from PlayerState.
//
//  PlayerState was 2949 lines (audit at 2574, +375 over the
//  S18 sprint). One of the self-contained concerns was the
//  "adaptive quality switching" block — a 5-second timer
//  after playback starts, refetch the stream URL at a higher
//  quality, and seamlessly swap the player item without
//  dropping audio. It touched the player, the queue, and
//  APIService, but was logically independent of the rest of
//  PlayerState (queue restoration, scene-phase handling, gapless
//  crossfade, etc.).
//
//  Extracted to its own class so:
//    - The concern is testable in isolation (mock the player + URL
//      service, drive a synthetic timer fire, assert the swap).
//    - PlayerState gets ~100 lines back.
//    - The timer / cancellable lifecycle is owned by the manager,
//      not dangling on the god object.
//
//  The manager holds weak references to the player and the
//  queue store so it doesn't extend the lifetime of either. It
//  also has its own `cancellables` set for the stream URL fetch
//  subscription, so a fresh instance doesn't leak subscriptions
//  across calls.
//

import Foundation
import AVFoundation
import Combine

final class AdaptiveQualityManager {
    /// S18-H (CV-11): 5s after playback starts, attempt to
    /// upgrade to a high-quality stream. Tuned for "Wi-Fi
    /// connected and not on cellular" — if the user is on
    /// cellular, the APIService layer picks the right quality
    /// based on connectionType.
    private let upgradeDelay: TimeInterval = 5.0

    private weak var player: AVPlayer?
    private weak var queueStore: QueueStore?

    /// `currentItemProvider` is a closure so the manager
    /// always reads the live value at the moment of upgrade
    /// (not a stale snapshot from when the timer was
    /// scheduled). The PlayerState holds the source-of-truth
    /// and we don't want to introduce a retention cycle by
    /// capturing a strong reference.
    private let currentItemProvider: () -> QueueItem?
    private let isPlayingProvider: () -> Bool

    private var upgradeTimer: Timer?
    private var hasUpgradedQuality = false
    private var cancellables = Set<AnyCancellable>()

    init(
        player: AVPlayer,
        queueStore: QueueStore,
        currentItemProvider: @escaping () -> QueueItem?,
        isPlayingProvider: @escaping () -> Bool
    ) {
        self.player = player
        self.queueStore = queueStore
        self.currentItemProvider = currentItemProvider
        self.isPlayingProvider = isPlayingProvider
    }

    // MARK: - Lifecycle

    /// Schedule the 5s upgrade attempt. Cancels any prior
    /// pending upgrade for the new item. Resets the
    /// `hasUpgradedQuality` flag so a re-play of the same
    /// track still gets the upgrade.
    func scheduleUpgrade(for item: QueueItem) {
        upgradeTimer?.invalidate()
        hasUpgradedQuality = false
        upgradeTimer = Timer.scheduledTimer(
            withTimeInterval: upgradeDelay,
            repeats: false
        ) { [weak self] _ in
            guard let self = self, self.isPlayingProvider() else { return }
            self.upgradeToHighQuality(for: item)
        }
    }

    func cancelPendingUpgrade() {
        upgradeTimer?.invalidate()
        upgradeTimer = nil
    }

    // MARK: - Upgrade

    private func upgradeToHighQuality(for item: QueueItem) {
        guard !hasUpgradedQuality else { return }
        hasUpgradedQuality = true

        print("🔊 Upgrading to high quality stream for: \(item.track.title)")

        // C-2026-06-28: bypass StreamURLCache. The cache had an
        // activeFetchLock deadlock on its first synchronous
        // subscribe (the Just publisher's receiveCompletion
        // tried to re-lock activeFetchLock from the same
        // thread that held the outer lock). We now go direct
        // to APIService for the upgrade.
        APIService.shared.getStreamUrl(videoId: item.track.videoId, preferM4A: true, quality: "high")
            .sink(
                receiveCompletion: { result in
                    if case .failure(let error) = result {
                        print("⚠️ Failed to get high quality stream: \(error)")
                        // Keep playing low quality — not a critical error
                    }
                },
                receiveValue: { [weak self] streamInfo in
                    guard let self = self,
                          self.isPlayingProvider(),
                          // Only swap if we're STILL playing this
                          // exact track. The user could have
                          // skipped mid-timer.
                          let currentItem = self.currentItemProvider(),
                          currentItem.track.videoId == item.track.videoId,
                          currentItem.source == .stream,
                          currentItem.streamUrl != streamInfo.streamUrl else {
                        return
                    }
                    self.performSeamlessQualitySwitch(to: streamInfo.streamUrl, for: item)
                }
            )
            .store(in: &cancellables)
    }

    private func performSeamlessQualitySwitch(to newUrl: String, for originalItem: QueueItem) {
        guard let player = player,
              let currentItem = player.currentItem else { return }

        let currentTime = player.currentTime()
        let wasPlaying = isPlayingProvider()

        print("🔊 Seamless quality switch at \(currentTime.seconds)s")

        guard let url = URL(string: newUrl) else { return }
        let newPlayerItem = AVPlayerItem(url: url)

        newPlayerItem.preferredForwardBufferDuration = 5
        newPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        player.replaceCurrentItem(with: newPlayerItem)

        // QW-11 fix: use 0.5s tolerance instead of `.zero`. The
        // exact seek was stalling 1-5s on slow networks during
        // quality upgrade because AVPlayer has to download the
        // exact keyframe. A 0.5s tolerance is imperceptible to
        // the ear and completes near-instantly.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 1000)
        player.seek(to: currentTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            guard let self = self else { return }

            // S17-E: `player.play()` followed by `player.rate = 1.0`
            // has a 1-frame race where the player starts at
            // rate 0 and only ramps to 1.0 on the next runloop
            // tick — the user can hear the gap.
            // `playImmediately(atRate:)` is the atomic single-
            // call form that AVFoundation now recommends.
            if wasPlaying {
                player.playImmediately(atRate: 1.0)
            }

            // Update current item with new URL
            // S3-4: preserve replayGain across the quality switch
            let upgradedItem = QueueItem(
                track: originalItem.track,
                streamUrl: newUrl,
                source: .stream,
                replayGain: originalItem.replayGain
            )

            // Update the queue. The manager doesn't own the
            // queue, but holds a weak ref to the store; the
            // player-side mutation of `currentItem` is the
            // caller's responsibility (the manager fires the
            // callback via a closure on its consumer).
            if let queueStore = self.queueStore,
               let currentIndex = self.currentIndexProvider?() {
                if currentIndex < queueStore.items.count {
                    var updatedItems = queueStore.items
                    updatedItems[currentIndex] = upgradedItem
                    queueStore.replace(with: updatedItems)
                }
            }

            self.onItemUpgraded?(upgradedItem)

            // QW-13 fix: re-install the visualizer tap on the new
            // (high-quality) player item. installTap is only
            // called in play(item:), so after a seamless quality
            // switch the visualizer + haptic symphony engine
            // would read silent buffers for the remainder of
            // the track.
            if let newItem = player.currentItem {
                AudioVisualizerEngine.shared.installTap(on: newItem)
            }

            print("✅ Quality upgraded to high - seamless switch complete")
        }
    }

    // MARK: - Callbacks

    /// PlayerState subscribes to this to update its
    /// `currentItem` and re-apply volume. Fires on the
    /// quality-upgrade swap completion.
    var onItemUpgraded: ((QueueItem) -> Void)?

    /// PlayerState provides this so the manager can check
    /// "is this still the current track?" without holding a
    /// strong ref to PlayerState.
    var currentIndexProvider: (() -> Int?)?
}
