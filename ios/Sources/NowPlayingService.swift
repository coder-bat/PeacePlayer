//
//  NowPlayingService.swift
//  YTAudioPlayer
//
//  Central service for MPNowPlayingInfoCenter and remote command handling
//  Provides lock screen, Control Center, and system integration
//

import Foundation
import MediaPlayer
import Combine
import UIKit
import WidgetKit

/// Service responsible for updating system Now Playing interface
class NowPlayingService {
    static let shared = NowPlayingService()

    // MARK: - Properties
    private var artworkCache: [String: MPMediaItemArtwork] = [:]
    private var artworkAccessOrder: [String] = []  // LRU tracking for cache eviction
    private let maxArtworkCacheSize = 50  // Limit cache to prevent unbounded growth
    private var cancellables = Set<AnyCancellable>()
    private var currentNowPlayingInfo: [String: Any] = [:]
    private var currentDuration: TimeInterval = 0
    private var currentArtworkRequestId = UUID()  // Track current artwork request to prevent stale updates

    // Supported playback rates for Control Center
    let supportedPlaybackRates: [NSNumber] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    // S3-2: configurable skip interval (QW-12 from gap analysis)
    // Options: 5 / 10 / 15 / 30 / 45 / 60 seconds. Default 15s preserves
    // existing behavior. Read live on each remote command invocation so
    // settings changes apply immediately.
    static let skipIntervalKey = "nowPlaying.skipInterval"
    static let skipIntervalOptions: [Int] = [5, 10, 15, 30, 45, 60]
    static var skipInterval: Int {
        let raw = UserDefaults.standard.integer(forKey: skipIntervalKey)
        // UserDefaults.integer returns 0 if the key was never set; fall back
        // to 15 (legacy default). Validate against the allowed options so
        // an out-of-range value never reaches PlayerState.seek.
        if raw == 0 {
            return 15
        }
        return skipIntervalOptions.contains(raw) ? raw : 15
    }

    // MARK: - Initialization
    private init() {
        setupRemoteCommands()

        // QW-6 fix: clear the in-memory artwork cache on memory pressure.
        // The artwork cache is not cleared by ImageCache's memory-warning
        // handler (different cache), and MPMediaItemArtwork holds its bound
        // UIImage strongly via closure. Worst case was 50-150MB of artwork
        // pinned even after the user navigated away.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @objc private func handleMemoryWarning() {
        print("⚠️ NowPlayingService received memory warning, clearing artwork cache")
        clearArtworkCache()
    }

    /// QW-8 fix: static app-icon artwork for tracks with nil artworkURL
    /// (e.g., podcast / audiobook tracks that don't have a thumbnail).
    private var _fallbackArtwork: MPMediaItemArtwork?
    private func fallbackArtwork() -> MPMediaItemArtwork? {
        if let cached = _fallbackArtwork { return cached }
        // Try the asset catalog first
        if let image = UIImage(named: "AppIcon") ?? UIImage(named: "AppIcon-1024") {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            _fallbackArtwork = artwork
            return artwork
        }
        return nil
    }

    // MARK: - Remote Command Setup
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Play/Pause
        commandCenter.playCommand.addTarget { _ in
            PlayerState.shared.resume()
            return .success
        }

        commandCenter.pauseCommand.addTarget { _ in
            PlayerState.shared.pause()
            return .success
        }

        // Toggle play/pause (for headphones)
        commandCenter.togglePlayPauseCommand.addTarget { _ in
            PlayerState.shared.togglePlayPause()
            return .success
        }

        // Next/Previous
        commandCenter.nextTrackCommand.addTarget { _ in
            PlayerState.shared.nextTrack()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { _ in
            PlayerState.shared.previousTrack()
            return .success
        }

        // Seek
        commandCenter.changePlaybackPositionCommand.addTarget { event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                let duration = PlayerState.shared.duration
                guard duration > 0 else { return .commandFailed }
                let progress = event.positionTime / duration
                PlayerState.shared.seek(to: progress)
            }
            return .success
        }

        // Skip forward/backward (for headphones / lock screen)
        // S3-2: configurable via UserDefaults (Sprint 3 quick win QW-12)
        // Re-read the value on every invocation so settings changes take
        // effect immediately without re-registering the remote command.
        let initialInterval = NSNumber(value: NowPlayingService.skipInterval)
        commandCenter.skipForwardCommand.preferredIntervals = [initialInterval]
        commandCenter.skipForwardCommand.addTarget { _ in
            PlayerState.shared.seek(by: Double(NowPlayingService.skipInterval))
            return .success
        }

        commandCenter.skipBackwardCommand.preferredIntervals = [initialInterval]
        commandCenter.skipBackwardCommand.addTarget { _ in
            PlayerState.shared.seek(by: -Double(NowPlayingService.skipInterval))
            return .success
        }

        // Playback speed (iOS 11+)
        commandCenter.changePlaybackRateCommand.isEnabled = true
        commandCenter.changePlaybackRateCommand.supportedPlaybackRates = supportedPlaybackRates
        commandCenter.changePlaybackRateCommand.addTarget { event in
            if let rateEvent = event as? MPChangePlaybackRateCommandEvent {
                PlayerState.shared.setPlaybackRate(rateEvent.playbackRate)
            }
            return .success
        }

        // Enable all commands initially
        updateCommandAvailability()
    }

    // MARK: - Update Methods
    func updateNowPlaying(
        track: Track,
        duration: TimeInterval,
        currentTime: TimeInterval,
        isPlaying: Bool,
        playbackRate: Float = 1.0
    ) {
        #if DEBUG
        PlayCrashDiagnostics.log(.nowPlaying, "updateNowPlaying ENTRY videoId=\(track.videoId) duration=\(duration) currentTime=\(currentTime) isPlaying=\(isPlaying) artworkURL=\(track.artworkURL?.absoluteString ?? "nil")")
        #endif
        // Store duration for future time-only updates
        currentDuration = duration
        print("🎵 NowPlayingService.updateNowPlaying - Duration: \(duration), Current: \(currentTime), Playing: \(isPlaying)")

        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]

        // Store current info for time-only updates
        currentNowPlayingInfo = nowPlayingInfo

        // Add artwork
        if let artworkURL = track.artworkURL {
            let urlString = artworkURL.absoluteString
            // Check cache first
            if let cachedArtwork = artworkCache[urlString] {
                // Update LRU order
                touchArtworkCache(key: urlString)
                nowPlayingInfo[MPMediaItemPropertyArtwork] = cachedArtwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            } else {
                // Generate new request ID to track this specific artwork load
                let requestId = UUID()
                currentArtworkRequestId = requestId

                // Load artwork asynchronously and update
                loadArtwork(url: artworkURL, videoId: track.videoId) { [weak self] artwork in
                    guard let self = self else { return }
                    // Only update if this is still the current request (track hasn't changed)
                    guard self.currentArtworkRequestId == requestId else {
                        print("🎵 Skipping stale artwork update for \(track.title)")
                        return
                    }
                    if let artwork = artwork {
                        self.addArtworkToCache(artwork, forKey: urlString)
                        // Rebuild info with artwork - use stored duration
                        var updatedInfo: [String: Any] = [
                            MPMediaItemPropertyTitle: track.title,
                            MPMediaItemPropertyArtist: track.displayArtist,
                            MPMediaItemPropertyAlbumTitle: track.album,
                            MPMediaItemPropertyPlaybackDuration: self.currentDuration,
                            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
                            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0,
                            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
                            MPMediaItemPropertyArtwork: artwork
                        ]
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = updatedInfo
                    }
                }
                // Set initial info without artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            }
        } else {
            // QW-8 fix: podcast / audiobook tracks frequently have nil
            // artworkURL. Without a fallback the lock screen shows a blank
            // placeholder. Use the app icon as a static fallback.
            if let fallback = fallbackArtwork() {
                nowPlayingInfo[MPMediaItemPropertyArtwork] = fallback
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }

        // Update shared state and reload all widget timelines
        let progress = duration > 0 ? currentTime / duration : 0
        let nextIdx = PlayerState.shared.currentIndex + 1
        let nextTrack = nextIdx < PlayerState.shared.queue.count ? PlayerState.shared.queue[nextIdx].track : nil
        SharedNowPlayingState.update(snapshot: NowPlayingSnapshot(
            title: track.title,
            artist: track.displayArtist,
            artworkURLString: track.artworkURL?.absoluteString ?? "",
            isPlaying: isPlaying,
            progress: progress,
            nextTitle: nextTrack?.title ?? "",
            nextArtist: nextTrack?.displayArtist ?? "",
            currentVolume: Float(PlayerState.shared.volume)
        ))
        WidgetSyncService.reloadAll()

        updateCommandAvailability()
    }

    func updatePlaybackTime(currentTime: TimeInterval, isPlaying: Bool, playbackRate: Float = 1.0) {
        // Update stored info with new time values
        currentNowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        currentNowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0

        // Ensure duration is always present
        currentNowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = currentDuration

        print("🎵 NowPlayingService.updatePlaybackTime - Current: \(currentTime), Duration: \(currentDuration), Playing: \(isPlaying)")

        MPNowPlayingInfoCenter.default().nowPlayingInfo = currentNowPlayingInfo
    }

    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Command Availability
    private func updateCommandAvailability() {
        let commandCenter = MPRemoteCommandCenter.shared()
        let player = PlayerState.shared

        commandCenter.nextTrackCommand.isEnabled = player.hasNextTrack
        commandCenter.previousTrackCommand.isEnabled = player.hasPreviousTrack
    }

    // MARK: - Artwork Loading
    private var currentArtworkCancellable: AnyCancellable?

    private func loadArtwork(url: URL, videoId: String, completion: @escaping (MPMediaItemArtwork?) -> Void) {
        // Cancel any in-flight artwork load to prevent memory growth
        currentArtworkCancellable?.cancel()

        // Use ImageCache to load image
        currentArtworkCancellable = ImageCache.shared.image(for: url)
            .receive(on: DispatchQueue.main)
            .first()
            .sink { image in
                if let image = image {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    completion(artwork)
                } else {
                    completion(nil)
                }
            }
    }

    // MARK: - Artwork Cache Management

    /// Adds artwork to cache with LRU eviction
    private func addArtworkToCache(_ artwork: MPMediaItemArtwork, forKey key: String) {
        // Evict oldest entries if at capacity
        while artworkCache.count >= maxArtworkCacheSize && !artworkAccessOrder.isEmpty {
            let oldestKey = artworkAccessOrder.removeFirst()
            artworkCache.removeValue(forKey: oldestKey)
            print("🎵 Evicted oldest artwork from cache: \(oldestKey)")
        }

        artworkCache[key] = artwork
        touchArtworkCache(key: key)
    }

    /// Updates access order for LRU tracking
    private func touchArtworkCache(key: String) {
        artworkAccessOrder.removeAll { $0 == key }
        artworkAccessOrder.append(key)
    }

    func clearArtworkCache() {
        artworkCache.removeAll()
        artworkAccessOrder.removeAll()
    }

    func preloadArtwork(for track: Track) {
        guard let artworkURL = track.artworkURL else { return }
        let urlString = artworkURL.absoluteString

        // Skip if already cached
        guard artworkCache[urlString] == nil else { return }

        loadArtwork(url: artworkURL, videoId: track.videoId) { [weak self] artwork in
            if let artwork = artwork {
                self?.addArtworkToCache(artwork, forKey: urlString)
            }
        }
    }
}
