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

        // S15: like / favorite from the lock screen and Control
        // Center. MPFeedbackCommand is the standard iOS mechanism;
        // we enable it only when the device actually supports it
        // (iOS 9.1+ and the system is happy) and wire it through
        // PlaylistManager.toggleLike(trackId:) — the same path the
        // FullPlayer LikeButton and the context-menu Like already
        // use, so the liked state is consistent across every
        // surface.
        if #available(iOS 9.1, *) {
            // S15: like from the lock screen and Control
            // Center. MPFeedbackCommand is the standard iOS
            // mechanism; we wire it through
            // PlaylistManager.toggleLike(trackId:) — the same
            // path the FullPlayer LikeButton and the
            // context-menu Like already use, so the liked
            // state is consistent across every surface.
            commandCenter.likeCommand.isEnabled = true
            commandCenter.likeCommand.localizedTitle = "Like"
            commandCenter.likeCommand.addTarget { _ in
                guard let videoId = PlayerState.shared.currentItem?.track.videoId else {
                    return .commandFailed
                }
                PlaylistManager.shared.toggleLike(trackId: videoId)
                return .success
            }
            commandCenter.dislikeCommand.isEnabled = true
            commandCenter.dislikeCommand.localizedTitle = "Dislike"
            commandCenter.dislikeCommand.addTarget { _ in
                // No-op for now — the app doesn't have a
                // dislike concept. We register the command so
                // iOS doesn't show a generic "Disliked" action;
                // the target returns .success without changing
                // state.
                return .success
            }
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

    // C-2026-06-28: coalesce rapid updateNowPlaying calls. AVPlayer emits
    // the item-duration publisher multiple times for HTTP streams as
    // chunks resolve, and each emission ran the full pipeline below
    // (5 widget reloads + MPNowPlayingInfoCenter write + JSON encode).
    // On a saturated main thread this exhausted the 5-second gesture
    // gate and iOS SIGKILLed the process.
    //
    // Track the most-recent pending parameters and run them on a
    // debounce — last-write-wins is the right semantics for Now Playing
    // info (we only care about the latest state at paint time).
    private var pendingNowPlaying: (track: Track, duration: TimeInterval, currentTime: TimeInterval, isPlaying: Bool, playbackRate: Float)?
    private var nowPlayingWorkItem: DispatchWorkItem?
    private let nowPlayingDebounceInterval: TimeInterval = 0.15

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

        // 2026-06-29 (S9e): the debounce was collapsing the
        // "new track starts" update with subsequent "current time"
        // updates, leaving the iOS Now Playing (Lock Screen /
        // Control Center) showing the previous track info for a
        // moment when the app was in the background. We now
        // bypass the debounce for track changes (a different
        // videoId) and write immediately.
        if let pending = pendingNowPlaying, pending.track.videoId != track.videoId {
            // Track changed — flush any pending write first so the
            // new track takes precedence, then write the new info
            // synchronously.
            nowPlayingWorkItem?.cancel()
            nowPlayingWorkItem = nil
            pendingNowPlaying = nil
            performNowPlayingWrite(
                track: track,
                duration: duration,
                currentTime: currentTime,
                isPlaying: isPlaying,
                playbackRate: playbackRate
            )
            return
        }

        // C-2026-06-28: coalesce. Cancel any pending run, stash the
        // latest parameters, schedule a debounced run on the main
        // queue. This collapses bursts of updateNowPlaying calls
        // (e.g., AVPlayer's rapid duration-emit storm on streams)
        // into one write.
        pendingNowPlaying = (track, duration, currentTime, isPlaying, playbackRate)
        nowPlayingWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.flushPendingNowPlaying()
        }
        nowPlayingWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + nowPlayingDebounceInterval, execute: item)
    }

    private func flushPendingNowPlaying() {
        guard let p = pendingNowPlaying else { return }
        pendingNowPlaying = nil
        nowPlayingWorkItem = nil
        performNowPlayingWrite(
            track: p.track,
            duration: p.duration,
            currentTime: p.currentTime,
            isPlaying: p.isPlaying,
            playbackRate: p.playbackRate
        )
    }

    private func performNowPlayingWrite(
        track: Track,
        duration: TimeInterval,
        currentTime: TimeInterval,
        isPlaying: Bool,
        playbackRate: Float
    ) {
        #if DEBUG
        PlayCrashDiagnostics.log(.nowPlaying, "performNowPlayingWrite ENTRY videoId=\(track.videoId) duration=\(duration) currentTime=\(currentTime) isPlaying=\(isPlaying)")
        #endif
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
                        // S11 fix (Bug 2): also update currentNowPlayingInfo
                        // so the next updatePlaybackTime tick doesn't
                        // overwrite our just-loaded artwork with the stale
                        // (pre-artwork) cached dictionary.
                        self.currentNowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
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
            currentVolume: Float(PlayerState.shared.volume),
            // S18 / P1-6: surface unread-capsule count to the widget.
            // The widget renders a 💌 pill when this is true.
            hasUnlockedCapsule: TimeCapsuleManager.shared.readyToOpen.count > 0
        ))
        // C-2026-06-28: widget timeline reloads are documented as
        // asynchronous (they schedule work in the widget extension's
        // process), but the *call site* still touches internal Core
        // Animation / SpringBoard bookkeeping on the main thread. Off
        // the main queue this overhead is invisible; on the main
        // queue it can stall Now Playing writes during the burst that
        // happens at track change.
        let trackTitle = track.title
        let videoId = track.videoId
        DispatchQueue.global(qos: .utility).async {
            WidgetSyncService.reloadAll()
            #if DEBUG
            PlayCrashDiagnostics.log(.nowPlaying, "widgetReload dispatched videoId=\(videoId) title=\(trackTitle)")
            #endif
        }

        updateCommandAvailability()
        #if DEBUG
        PlayCrashDiagnostics.log(.nowPlaying, "performNowPlayingWrite EXIT videoId=\(track.videoId)")
        #endif
    }

    func updatePlaybackTime(currentTime: TimeInterval, isPlaying: Bool, playbackRate: Float = 1.0) {
        // Update stored info with new time values
        currentNowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        currentNowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0

        // Ensure duration is always present
        currentNowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = currentDuration

        print("🎵 NowPlayingService.updatePlaybackTime - Current: \(currentTime), Duration: \(currentDuration), Playing: \(isPlaying)")

        MPNowPlayingInfoCenter.default().nowPlayingInfo = currentNowPlayingInfo
        #if DEBUG
        PlayCrashDiagnostics.log(.nowPlaying, "updatePlaybackTime EXIT currentTime=\(currentTime) isPlaying=\(isPlaying)")
        #endif
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
                    // S16: write to the App Group artwork cache so the
                    // widget extension doesn't re-download this image
                    // on every 15-min refresh. Cheap (JPEG 0.85,
                    // ~50KB for typical 600x600 album art).
                    SharedArtworkCache.store(image, for: url)
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
