//
//  CrossfadeManager.swift
//  YTAudioPlayer
//
//  Manages smooth transitions between songs
//

import Foundation
import AVFoundation
import Combine

/// Manages crossfade transitions between tracks
class CrossfadeManager: ObservableObject {
    static let shared = CrossfadeManager()

    // MARK: - Configuration

    /// Whether crossfade is enabled
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "crossfadeEnabled")
        }
    }

    /// Crossfade duration in seconds (1-5 seconds)
    @Published var duration: TimeInterval {
        didSet {
            UserDefaults.standard.set(duration, forKey: "crossfadeDuration")
        }
    }

    /// Whether gapless playback is enabled for albums
    @Published var gaplessEnabled: Bool {
        didSet {
            UserDefaults.standard.set(gaplessEnabled, forKey: "gaplessEnabled")
        }
    }

    // MARK: - Private Properties

    private var currentPlayer: AVPlayer?
    private var nextPlayer: AVPlayer?
    private var isCrossfading = false
    private var cancellables = Set<AnyCancellable>()
    private var crossfadeTimer: Timer?
    private var isPreparingNextTrack = false  // Guards against duplicate preparation calls

    // Original volume to restore after crossfade
    private var originalVolume: Float = 1.0

    // MARK: - Initialization

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "crossfadeEnabled")
        self.duration = UserDefaults.standard.double(forKey: "crossfadeDuration")
        self.gaplessEnabled = UserDefaults.standard.bool(forKey: "gaplessEnabled")

        // Set defaults if not set
        if duration == 0 {
            self.duration = 3.0
        }

        print("🔊 CrossfadeManager initialized - Enabled: \(isEnabled), Duration: \(duration)s")
    }

    // MARK: - Public Methods

    /// Checks if next player is already prepared
    func hasNextPlayer() -> Bool {
        return nextPlayer != nil
    }

    /// Prepares the next track for crossfade
    func prepareNextTrack(_ item: QueueItem, completion: (() -> Void)? = nil) {
        guard isEnabled || gaplessEnabled else {
            completion?()
            return
        }

        // Don't re-prepare if already have a next player
        guard nextPlayer == nil else {
            print("🔊 Next player already exists, skipping preparation")
            completion?()
            return
        }

        print("🔊 Preparing next track for crossfade: \(item.track.title)")

        guard let url = URL(string: item.streamUrl) else {
            print("❌ Invalid stream URL")
            completion?()
            return
        }

        // Create and prepare next player
        let playerItem = AVPlayerItem(url: url)
        nextPlayer = AVPlayer(playerItem: playerItem)
        nextPlayer?.volume = 0  // Start silent
        // Ensure background playback for crossfade preparation
        nextPlayer?.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible

        // Preload the asset and start buffering by playing at rate 0
        playerItem.asset.loadValuesAsynchronously(forKeys: ["playable", "duration"]) { [weak self] in
            DispatchQueue.main.async {
                var error: NSError?
                let status = playerItem.asset.statusOfValue(forKey: "playable", error: &error)
                if status == .loaded {
                    print("✅ Next track asset loaded, starting pre-buffering")
                    // Start player paused to force actual buffering
                    self?.nextPlayer?.playImmediately(atRate: 0)
                    self?.nextPlayer?.pause()
                } else if let error = error {
                    print("❌ Failed to preload next track: \(error)")
                }
                completion?()
            }
        }
    }

    /// Checks if crossfade can be performed
    func canCrossfade() -> Bool {
        return isEnabled && currentPlayer != nil && nextPlayer != nil
    }

    /// Performs crossfade from current track to next track
    func crossfadeToNext(completion: @escaping () -> Void) {
        guard isEnabled, let current = currentPlayer, let next = nextPlayer else {
            // No crossfade possible - this shouldn't happen if canCrossfade() was checked
            print("❌ Crossfade failed: isEnabled=\(isEnabled), current=\(currentPlayer != nil), next=\(nextPlayer != nil)")
            completion()
            return
        }

        guard !isCrossfading else {
            print("⚠️ Crossfade already in progress")
            return
        }

        // Ensure the next player is ready to play
        guard let nextItem = next.currentItem, nextItem.status == .readyToPlay else {
            print("⚠️ Next player not ready to play, aborting crossfade")
            completion()
            return
        }

        isCrossfading = true
        originalVolume = current.volume

        print("🔊 Starting crossfade (duration: \(duration)s)")
        print("🔊 Current player rate: \(current.rate), time: \(current.currentTime().seconds)")
        print("🔊 Next player rate before play: \(next.rate)")

        // Start playing next track at volume 0
        next.play()
        print("🔊 Next player rate after play: \(next.rate)")

        // Calculate fade steps (10 updates per second for smooth fade)
        // Reduced from 30fps to reduce main thread load and prevent audio glitches
        let stepsPerSecond = 10.0
        let totalSteps = Int(duration * stepsPerSecond)
        let timeInterval = 1.0 / stepsPerSecond

        var currentStep = 0

        // Invalidate any existing timer
        crossfadeTimer?.invalidate()

        // Create fade timer
        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            currentStep += 1
            let progress = Double(currentStep) / Double(totalSteps)

            // Fade out current, fade in next
            current.volume = Float(1.0 - progress) * self.originalVolume
            next.volume = Float(progress) * self.originalVolume

            if currentStep >= totalSteps {
                // Crossfade complete
                timer.invalidate()
                self.completeCrossfade(completion: completion)
            }
        }
    }

    /// Sets the current player (called by PlayerState)
    func setCurrentPlayer(_ player: AVPlayer?) {
        // Cancel any ongoing crossfade
        if isCrossfading {
            cancelCrossfade()
        }

        currentPlayer = player
        originalVolume = player?.volume ?? 1.0
    }

    /// Gets the next player to become current
    func takeNextPlayer() -> AVPlayer? {
        let player = nextPlayer
        nextPlayer = nil
        isCrossfading = false
        return player
    }

    /// Cancels an ongoing crossfade
    func cancelCrossfade() {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil

        // Restore volumes
        currentPlayer?.volume = originalVolume
        nextPlayer?.pause()
        nextPlayer?.volume = 0

        isCrossfading = false

        print("🔊 Crossfade cancelled")
    }

    /// Checks if we should use gapless playback for the current context
    func shouldUseGapless(for currentTrack: Track, nextTrack: Track) -> Bool {
        guard gaplessEnabled else { return false }

        // Check if tracks are from the same album
        let sameAlbum = currentTrack.album == nextTrack.album
        let validAlbum = currentTrack.album != "Unknown Album"

        return sameAlbum && validAlbum
    }

    // MARK: - Private Methods

    private func completeCrossfade(completion: @escaping () -> Void) {
        // Pause current player
        currentPlayer?.pause()
        currentPlayer?.volume = originalVolume

        // Next player is now at full volume and playing
        // Move nextPlayer to currentPlayer, but DON'T clear nextPlayer yet
        // PlayerState needs to take it via takeNextPlayer()
        currentPlayer = nextPlayer
        // nextPlayer will be cleared by takeNextPlayer()
        isCrossfading = false

        print("✅ Crossfade complete")

        completion()
    }
}

// MARK: - Gapless Playback Support

extension CrossfadeManager {

    /// Pre-buffers the next track for gapless playback
    func prebufferNextTrack(_ item: QueueItem) {
        guard gaplessEnabled else { return }

        print("🔊 Prebuffering for gapless: \(item.track.title)")

        guard let url = URL(string: item.streamUrl) else { return }

        // Just load the asset, don't create player yet
        let asset = AVURLAsset(url: url)
        asset.loadValuesAsynchronously(forKeys: ["playable", "duration"]) {
            DispatchQueue.main.async {
                var error: NSError?
                let status = asset.statusOfValue(forKey: "playable", error: &error)
                if status == .loaded {
                    print("✅ Gapless: Next track prebuffered")
                }
            }
        }
    }
}
