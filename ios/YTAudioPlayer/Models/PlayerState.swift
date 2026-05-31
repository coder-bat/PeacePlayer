//
//  PlayerState.swift
//  YTAudioPlayer
//
//  Central player state management
//

import Foundation
import Combine
import AVFoundation
import UIKit
import MediaPlayer
import SwiftUI

/// Represents the current playback state
enum PlaybackState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case error(String)
    
    var isPlaying: Bool {
        self == .playing
    }
    
    var isLoading: Bool {
        self == .loading || self == .buffering
    }
}

enum PlaybackContentType {
    case track
    case liveRadio
    case podcastEpisode
    case audiobook
}

/// Represents the repeat mode
enum RepeatMode: String, CaseIterable {
    case none = "repeat"
    case all = "repeat.all"
    case one = "repeat.1"
    
    var iconName: String {
        switch self {
        case .none: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
    
    mutating func next() {
        switch self {
        case .none: self = .all
        case .all: self = .one
        case .one: self = .none
        }
    }
}

/// Represents the content source origin
enum ContentSource: Equatable {
    case youtube
    case local

    var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .local: return "Downloaded"
        }
    }

    var iconName: String {
        switch self {
        case .youtube: return "play.rectangle.fill"
        case .local: return "arrow.down.circle.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .youtube: return .red
        case .local: return .green
        }
    }
}

/// Represents an item in the playback queue
struct QueueItem: Identifiable, Equatable {
    let id = UUID()
    let track: Track
    let streamUrl: String
    let source: TrackSource
    let contentSource: ContentSource
    let createdAt: Date

    enum TrackSource: Equatable {
        case stream
        case local(path: String)
    }

    init(track: Track, streamUrl: String, source: TrackSource, contentSource: ContentSource = .youtube, createdAt: Date = Date()) {
        self.track = track
        self.streamUrl = streamUrl
        self.source = source
        self.contentSource = contentSource
        self.createdAt = createdAt
    }
    
    static func == (lhs: QueueItem, rhs: QueueItem) -> Bool {
        lhs.id == rhs.id && lhs.track.videoId == rhs.track.videoId
    }
    
    /// Returns true if the stream URL is likely expired (older than 4 hours)
    var isStreamUrlExpired: Bool {
        Date().timeIntervalSince(createdAt) > 4 * 60 * 60 // 4 hours
    }
}

/// Central player state manager
class PlayerState: ObservableObject {
    static let shared = PlayerState()
    
    // MARK: - Published Properties
    
    /// Current playback state
    @Published var playbackState: PlaybackState = .idle
    
    /// Currently playing track
    @Published var currentItem: QueueItem?
    
    /// Current progress (0.0 to 1.0)
    @Published var progress: Double = 0.0
    
    /// Current time in seconds
    @Published var currentTime: Double = 0.0
    
    /// Total duration in seconds (from AVPlayer, may be inaccurate for some streams)
    @Published var duration: Double = 0.0

    /// Expected duration from track metadata (more reliable)
    private var expectedDuration: Double = 0.0

    /// Flag to prevent multiple completion triggers
    private var isHandlingCompletion = false
    
    /// Playback queue
    @Published var queue: [QueueItem] = []
    
    /// Current track index in queue
    @Published var currentIndex: Int = 0
    
    /// Shuffle enabled
    @Published var isShuffled: Bool = false
    
    /// Repeat mode
    @Published var repeatMode: RepeatMode = .none
    
    /// Volume (0.0 to 1.0)
    @Published var volume: Double = 1.0

    /// Playback rate (0.5 to 2.0)
    @Published var playbackRate: Float = 1.0

    /// Show full player
    @Published var showFullPlayer: Bool = false
    
    /// Show queue
    @Published var showQueue: Bool = false

    /// Content type for current playback
    @Published var contentType: PlaybackContentType = .track

    /// Audiobook chapter tracking
    @Published var currentChapters: [AudiobookChapter] = []
    @Published var currentChapterIndex: Int = 0
    @Published var currentBookId: String = ""
    
    // MARK: - Private Properties
    
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var retryCount = 0
    private let maxRetries = 2
    private var originalQueue: [QueueItem] = []
    private var dataManager = DataManager.shared
    private var accumulatedListeningTime: TimeInterval = 0
    private var lastProgressUpdate: Date = Date()

    // Adaptive quality switching
    private var qualityUpgradeTimer: Timer?
    private var isAdaptiveQualityEnabled = true
    private var hasUpgradedQuality = false

    // Memory management
    private let maxQueueSize = 100
    private let trimQueueToSize = 50
    private let maxItemAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private var cleanupTimer: Timer?  // Store reference for proper cleanup

    // Serial queue for completion handling to prevent race conditions
    private let completionQueue = DispatchQueue(label: "com.ytaudio.completion", qos: .userInitiated)

    // Background task for track transitions when app is backgrounded
    private var trackTransitionBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    // Stall recovery
    private var isPlaybackStalled = false

    // MARK: - Computed Properties
    
    var hasNextTrack: Bool {
        guard !queue.isEmpty else { return false }
        if repeatMode == .one { return true }
        return currentIndex < queue.count - 1 || repeatMode == .all
    }
    
    var hasPreviousTrack: Bool {
        guard !queue.isEmpty else { return false }
        return currentIndex > 0 || repeatMode == .all
    }
    
    var isNowPlaying: Bool {
        currentItem != nil
    }
    
    var currentTimeFormatted: String {
        formatTime(currentTime)
    }
    
    var durationFormatted: String {
        // Use expected duration from track metadata if AVPlayer reports wrong duration
        let displayDuration = expectedDuration > 0 ? expectedDuration : duration
        print("🎵 durationFormatted: expectedDuration=\(expectedDuration), duration=\(duration), using=\(displayDuration)")
        return formatTime(displayDuration)
    }

    /// Returns the duration to use for display and Now Playing info
    var effectiveDuration: Double {
        if contentType == .liveRadio { return 0 }
        // Use expected duration from track metadata if available
        if expectedDuration > 0 {
            return expectedDuration
        }
        // Audiobook chapters and podcasts can be long — skip the 20-min sanity check
        if contentType == .audiobook || contentType == .podcastEpisode {
            return duration
        }
        // If AVPlayer reports unreasonably long duration (>20 min), assume it's wrong
        // and use a default of 3 minutes for display purposes
        if duration > 1200 { // 20 minutes
            print("🎵 WARNING: AVPlayer duration \(duration)s seems wrong, using fallback")
            return 180 // 3 minutes default
        }
        return duration
    }
    
    var remainingTimeFormatted: String {
        let displayDuration = effectiveDuration > 0 ? effectiveDuration : duration
        return formatTime(displayDuration - currentTime)
    }
    
    // MARK: - Initialization
    
    private init() {
        setupAudioSession()
        setupAudioSessionObservers()
        restoreQueue()

        // Register for memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        // Periodic cleanup every 5 minutes
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.cleanupOldItems()
        }
    }
    
    @objc private func handleMemoryWarning() {
        print("⚠️ PlayerState received memory warning")
        
        // Clear non-essential data
        cleanupOldItems()
        
        // Trim queue if large
        if queue.count > 50 {
            trimQueue()
        }
        
        // Clear image cache
        ImageCache.shared.clearCache()
    }
    
    // MARK: - Queue Restoration

    private func restoreQueue() {
        // Use PlaybackQueueManager to restore queue with fresh stream URLs
        PlaybackQueueManager.shared.restoreQueue { [weak self] items in
            guard let self = self, !items.isEmpty else { return }

            DispatchQueue.main.async {
                self.queue = items
                self.currentIndex = PlaybackQueueManager.shared.getSavedCurrentIndex()

                // Clamp index to valid range
                if self.currentIndex >= items.count {
                    self.currentIndex = 0
                }

                print("📱 Restored queue with \(items.count) items, current index: \(self.currentIndex)")

                // Restore the current item without auto-playing
                if self.currentIndex >= 0 && self.currentIndex < items.count {
                    let currentItem = items[self.currentIndex]
                    self.currentItem = currentItem
                    self.expectedDuration = Double(currentItem.track.durationSeconds)
                }
            }
        }
    }
    
    /// Restores playback state from saved data
    func restorePlaybackState() {
        let (trackId, progress) = dataManager.loadLastPlaybackState()
        guard let trackId = trackId else { return }
        
        // Find the track in recently played
        if let recentTrack = dataManager.recentlyPlayed.first(where: { $0.videoId == trackId }) {
            // We could auto-resume here, but let's just remember the state
            // The user can tap "Continue Listening" on Home
            print("📱 Can resume track: \(recentTrack.title) at \(Int(progress * 100))%")
        }
    }
    
    // MARK: - Audio Session
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("❌ Audio session setup failed: \(error)")
        }
    }

    private func setupAudioSessionObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            print("🔇 Audio interruption began")
            DispatchQueue.main.async { [weak self] in
                self?.player?.pause()
            }
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

            if options.contains(.shouldResume) {
                print("🔊 Audio interruption ended, resuming playback")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                    } catch {
                        print("❌ Failed to reactivate audio session: \(error)")
                    }
                    self?.player?.play()
                    self?.player?.rate = self?.playbackRate ?? 1.0
                }
            }
        @unknown default:
            break
        }
    }

    @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            print("🎧 Audio route changed, ensuring session is active")
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("❌ Failed to activate audio session after route change: \(error)")
            }
        default:
            break
        }
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        print("🔄 Media services were reset, rebuilding audio session and player")
        setupAudioSession()
        if let current = currentItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.play(item: current, addToQueue: false)
            }
        }
    }

    // MARK: - Background Task Helpers

    private func beginTrackTransitionBackgroundTask() {
        endTrackTransitionBackgroundTask()
        trackTransitionBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "com.peaceplayer.trackTransition") { [weak self] in
            self?.endTrackTransitionBackgroundTask()
        }
        if trackTransitionBackgroundTask != .invalid {
            print("🔒 Background task started for track transition")
        }
    }

    private func endTrackTransitionBackgroundTask() {
        guard trackTransitionBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(trackTransitionBackgroundTask)
        trackTransitionBackgroundTask = .invalid
        print("🔓 Background task ended for track transition")
    }

    // MARK: - Playback Control

    /// Play a track with local file check (plays local file if available, otherwise streams)
    func play(track: Track) {
        // Check if we have a local file for this track
        let localURL = AudioFileManager.shared.localFileURL(for: track.videoId)

        if FileManager.default.fileExists(atPath: localURL.path) {
            // Play from local file
            let item = QueueItem(
                track: track,
                streamUrl: localURL.absoluteString,
                source: .local(path: localURL.path)
            )
            play(item: item)
        } else {
            // Stream from backend - fetch stream URL first
            APIService.shared.getStreamUrl(videoId: track.videoId, quality: "low")
                .sink(
                    receiveCompletion: { result in
                        if case .failure(let error) = result {
                            print("❌ Failed to get stream URL: \(error)")
                        }
                    },
                    receiveValue: { [weak self] streamInfo in
                        let item = QueueItem(
                            track: track,
                            streamUrl: streamInfo.streamUrl,
                            source: .stream
                        )
                        self?.play(item: item)
                    }
                )
                .store(in: &cancellables)
        }
    }

    func play(item: QueueItem, addToQueue: Bool = true) {
        // Stop current playback and save progress
        if let current = currentItem {
            dataManager.updatePlaybackProgress(for: current.track.videoId, progress: progress)
        }
        
        stop()
        contentType = .track

        currentItem = item
        // Store expected duration from track metadata
        expectedDuration = Double(item.track.durationSeconds)
        print("🎵 CRITICAL: Set expectedDuration = \(expectedDuration) from track.durationSeconds = \(item.track.durationSeconds)")
        playbackState = .loading
        
        if addToQueue {
            // Add to queue if not already there
            if !queue.contains(where: { $0.track.videoId == item.track.videoId }) {
                queue.append(item)
                currentIndex = queue.count - 1
            }
        }
        
        // Add to recently played
        dataManager.addToRecentlyPlayed(item.track)
        NotificationCenter.default.post(name: .trackPlayed, object: nil)

        // Note: PlaybackQueueManager auto-saves queue changes, no need to manually save

        // Create player item
        print("🔊 Creating URL from streamUrl...")
        guard let url = URL(string: item.streamUrl) else {
            print("❌ Failed to create URL from: \(item.streamUrl.prefix(50))...")
            playbackState = .error("Invalid URL")
            return
        }
        print("✅ URL created: \(url.absoluteString.prefix(80))...")
        
        print("🔊 Creating AVPlayerItem...")
        
        // Use standard initialization - let AVPlayer auto-detect the format
        let playerItem = AVPlayerItem(url: url)

        print("🔊 Configuring player item for fast streaming...")
        // Configure for FAST streaming playback - 5 seconds buffer for long songs
        playerItem.preferredForwardBufferDuration = 5
        
        // Disable automatic waiting - start playing immediately
        // We'll handle buffering state manually for better UX
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
        print("🔊 Creating AVPlayer...")
        player = AVPlayer(playerItem: playerItem)
        player?.volume = Float(volume)
        // Ensure background playback continues on iOS 16+
        player?.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        // Don't wait to minimize stalling - start immediately and let it buffer as it plays
        player?.automaticallyWaitsToMinimizeStalling = false
        print("✅ AVPlayer created with fast-start config")
        
        // Set current player in crossfade manager
        CrossfadeManager.shared.setCurrentPlayer(player)

        // Attach audio visualizer tap to this player item
        AudioVisualizerEngine.shared.installTap(on: playerItem)
        
        // Setup observers
        print("🔊 Setting up observers...")
        setupPlayerObservers()
        print("✅ Observers set up")
        
        // Start playback immediately for fast start - don't wait for readyToPlay
        // AVPlayer will handle buffering as it plays
        print("🔊 Starting playback immediately (fast-start mode)...")
        player?.play()
        player?.rate = playbackRate
        playbackState = .playing

        print("🔊 Auto-populating queue...")
        QueuePrefetcher.shared.autoPopulateQueue(startingFrom: item.track)
        
        // Setup remote controls
        print("🔊 Setting up remote controls...")
        setupRemoteControls()
        print("✅ Remote controls set up")
        
        // Prepare next track for crossfade (with delay to allow queue to populate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.prepareNextTrackForCrossfade()
        }
        
        // Reset listening time tracking
        lastProgressUpdate = Date()

        // Start adaptive quality timer if enabled
        if isAdaptiveQualityEnabled && item.source == .stream {
            startQualityUpgradeTimer(for: item)
        }

        print("✅ play() completed successfully for: \(item.track.title)")
    }

    // MARK: - Adaptive Quality Switching

    private func startQualityUpgradeTimer(for item: QueueItem) {
        // Cancel any existing timer
        qualityUpgradeTimer?.invalidate()
        hasUpgradedQuality = false

        // Start a 5-second timer to upgrade quality after playback begins
        qualityUpgradeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self = self, self.playbackState.isPlaying else { return }
            self.upgradeToHighQuality(for: item)
        }
    }

    private func upgradeToHighQuality(for item: QueueItem) {
        guard !hasUpgradedQuality else { return }
        hasUpgradedQuality = true

        print("🔊 Upgrading to high quality stream for: \(item.track.title)")

        APIService.shared.getStreamUrl(videoId: item.track.videoId, quality: "high")
            .sink(
                receiveCompletion: { [weak self] result in
                    if case .failure(let error) = result {
                        print("⚠️ Failed to get high quality stream: \(error)")
                        // Keep playing low quality - not a critical error
                    }
                },
                receiveValue: { [weak self] streamInfo in
                    guard let self = self,
                          self.playbackState.isPlaying,  // Only switch if still playing
                          let currentItem = self.currentItem,
                          currentItem.track.videoId == item.track.videoId,
                          currentItem.source == .stream,  // Only switch streaming items (not local files)
                          currentItem.streamUrl != streamInfo.streamUrl else {
                        return
                    }

                    // Perform seamless quality switch
                    self.performSeamlessQualitySwitch(to: streamInfo.streamUrl, for: item)
                }
            )
            .store(in: &cancellables)
    }

    private func performSeamlessQualitySwitch(to newUrl: String, for originalItem: QueueItem) {
        guard let player = player,
              let currentItem = player.currentItem else { return }

        // Get current playback position
        let currentTime = player.currentTime()
        let wasPlaying = playbackState.isPlaying

        print("🔊 Seamless quality switch at \(currentTime.seconds)s")

        // Create new player item with high quality URL
        guard let url = URL(string: newUrl) else { return }
        let newPlayerItem = AVPlayerItem(url: url)

        // Configure with same settings
        newPlayerItem.preferredForwardBufferDuration = 5
        newPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        // Replace item without stopping playback (if possible)
        player.replaceCurrentItem(with: newPlayerItem)

        // Seek to previous position
        player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self = self else { return }

            // Restore playback state
            if wasPlaying {
                player.play()
                player.rate = 1.0
            }

            // Update current item with new URL
            let upgradedItem = QueueItem(
                track: originalItem.track,
                streamUrl: newUrl,
                source: .stream
            )
            self.currentItem = upgradedItem

            // Update queue
            if self.currentIndex < self.queue.count {
                self.queue[self.currentIndex] = upgradedItem
            }

            print("✅ Quality upgraded to high - seamless switch complete")
        }
    }

    func cancelQualityUpgrade() {
        qualityUpgradeTimer?.invalidate()
        qualityUpgradeTimer = nil
    }
    
    func playQueue(at index: Int, isCrossfadeFallback: Bool = false) {
        print("▶️ playQueue called with index: \(index), queue.count: \(queue.count)")

        // Reset completion flag when starting a new track
        // But don't reset if this is a crossfade fallback (crossfade will handle it)
        if !isCrossfadeFallback {
            isHandlingCompletion = false
        }

        guard index >= 0 && index < queue.count else {
            print("▶️ Invalid index!")
            return
        }
        
        let item = queue[index]
        print("▶️ Playing: \(item.track.title), URL expired: \(item.isStreamUrlExpired)")
        
        // If URL is expired and it's a stream (not local), refresh it
        if item.isStreamUrlExpired && item.source == .stream {
            print("▶️ Stream URL expired, refreshing...")
            refreshAndPlay(item: item, at: index)
        } else {
            // CRITICAL FIX: Set expectedDuration from track metadata before playing
            expectedDuration = Double(item.track.durationSeconds)
            print("🎵 playQueue: Set expectedDuration = \(expectedDuration)")
            currentIndex = index
            play(item: item, addToQueue: false)
        }
        endTrackTransitionBackgroundTask()
    }
    
    private func refreshAndPlay(item: QueueItem, at index: Int) {
        APIService.shared.getStreamUrl(videoId: item.track.videoId)
            .sink(
                receiveCompletion: { [weak self] result in
                    if case .failure(let error) = result {
                        print("❌ Failed to refresh stream URL: \(error)")
                        self?.playbackState = .error("Failed to load audio")
                        self?.endTrackTransitionBackgroundTask()
                    }
                },
                receiveValue: { [weak self] streamInfo in
                    guard let self = self else { return }

                    // Create new item with fresh URL
                    let refreshedItem = QueueItem(
                        track: item.track,
                        streamUrl: streamInfo.streamUrl,
                        source: .stream
                    )

                    // Update queue with refreshed item
                    self.queue[index] = refreshedItem

                    print("▶️ URL refreshed, playing...")
                    self.currentIndex = index
                    self.play(item: refreshedItem, addToQueue: false)
                    self.endTrackTransitionBackgroundTask()
                }
            )
            .store(in: &cancellables)
    }
    
    private func refreshAndPlayCurrentItem() {
        guard let item = currentItem else { return }
        print("🔄 Refreshing current item: \(item.track.title)")
        
        APIService.shared.getStreamUrl(videoId: item.track.videoId)
            .sink(
                receiveCompletion: { [weak self] result in
                    if case .failure(let error) = result {
                        print("❌ Failed to refresh stream URL: \(error)")
                        self?.playbackState = .error("Failed to load audio")
                    }
                },
                receiveValue: { [weak self] streamInfo in
                    guard let self = self else { return }
                    
                    // Create new item with fresh URL
                    let refreshedItem = QueueItem(
                        track: item.track,
                        streamUrl: streamInfo.streamUrl,
                        source: .stream
                    )
                    
                    // Update current item and queue
                    self.currentItem = refreshedItem
                    if self.currentIndex < self.queue.count {
                        self.queue[self.currentIndex] = refreshedItem
                    }
                    
                    print("🔄 URL refreshed, retrying playback...")
                    self.play(item: refreshedItem, addToQueue: false)
                }
            )
            .store(in: &cancellables)
    }
    
    func togglePlayPause() {
        guard let player = player else { return }
        
        if playbackState.isPlaying {
            player.pause()
            playbackState = .paused
        } else {
            player.play()
            playbackState = .playing
        }
        
        updateRemoteControls()
    }
    
    func pause() {
        player?.pause()
        playbackState = .paused
        updateRemoteControls()
    }
    
    func resume() {
        player?.play()
        playbackState = .playing
        updateRemoteControls()
    }

    /// Set playback rate (0.5 to 3.0)
    func setPlaybackRate(_ rate: Float) {
        guard rate >= 0.5 && rate <= 3.0 else { return }

        playbackRate = rate
        player?.rate = rate

        // Update Now Playing info with new rate
        if let item = currentItem {
            NowPlayingService.shared.updateNowPlaying(
                track: item.track,
                duration: duration,
                currentTime: currentTime,
                isPlaying: playbackState.isPlaying,
                playbackRate: rate
            )
        }
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        removeTimeObserver()

        // Cancel quality upgrade timer
        cancelQualityUpgrade()

        // Remove audio visualizer tap
        AudioVisualizerEngine.shared.removeTap()

        // CRITICAL FIX: Cancel all Combine subscriptions to prevent duplicate observers
        cancellables.removeAll()

        player = nil
        playbackState = .idle
        progress = 0.0
        currentTime = 0.0
        duration = 0.0
        expectedDuration = 0.0
        contentType = .track

        // Re-register audio session observers after cleanup for next playback
        setupAudioSessionObservers()

        print("✅ Player stopped and observers cleaned up")
    }
    
    func seek(to progress: Double) {
        // Use effective duration for seeking (track metadata if available)
        let seekDuration = effectiveDuration > 0 ? effectiveDuration : duration
        guard let player = player, seekDuration > 0 else { return }

        let targetTime = progress * seekDuration
        let time = CMTime(seconds: targetTime, preferredTimescale: 1000)

        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.updateRemoteControls()
        }
    }
    
    func seek(by seconds: Double) {
        guard let player = player else { return }

        let current = player.currentTime().seconds
        // Use effective duration for seeking bounds
        let seekDuration = effectiveDuration > 0 ? effectiveDuration : duration
        let target = max(0, min(current + seconds, seekDuration))
        let time = CMTime(seconds: target, preferredTimescale: 1000)

        player.seek(to: time)
    }

    // MARK: - Radio & Podcast Playback

    func playRadioStation(_ station: RadioStation) {
        guard let url = URL(string: station.urlResolved) else { return }

        // Clean up previous playback state
        removeTimeObserver()
        cancelQualityUpgrade()
        cancellables.removeAll()
        NotificationCenter.default.removeObserver(self)

        player?.pause()
        contentType = .liveRadio

        let radioTrack = Track(
            videoId: station.stationuuid,
            title: station.name,
            artists: [station.country.isEmpty ? "Internet Radio" : station.country],
            album: station.tagList.first ?? "Radio",
            durationSeconds: 0,
            thumbnails: station.faviconURL.map { [Thumbnail(url: $0, width: 600, height: 600)] } ?? [],
            isExplicit: false,
            videoType: "RADIO_STATION"
        )

        let item = QueueItem(track: radioTrack, streamUrl: station.urlResolved, source: .stream)
        currentItem = item
        expectedDuration = 0

        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player?.volume = Float(volume)
        player?.play()
        playbackState = .playing
        setupPlayerObservers()
    }

    func playPodcastEpisode(_ episode: PodcastEpisode) {
        guard let url = episode.audioURL else { return }

        savePodcastPosition()  // Save current position before cleanup
        // Clean up previous playback state
        removeTimeObserver()
        cancelQualityUpgrade()
        cancellables.removeAll()
        NotificationCenter.default.removeObserver(self)

        player?.pause()
        contentType = .podcastEpisode

        let podcastTrack = Track(
            videoId: episode.guid,
            title: episode.title,
            artists: ["Podcast"],
            album: "",
            durationSeconds: episode.durationSeconds,
            thumbnails: episode.artworkURL.map { [Thumbnail(url: $0, width: 600, height: 600)] } ?? [],
            isExplicit: false,
            videoType: "PODCAST_EPISODE"
        )

        let item = QueueItem(track: podcastTrack, streamUrl: episode.audioUrl, source: .stream)
        currentItem = item
        expectedDuration = Double(episode.durationSeconds)

        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player?.volume = Float(volume)
        player?.play()
        playbackState = .playing
        setupPlayerObservers()

        // Resume from saved position
        let key = "podcast_position_\(episode.guid)"
        let savedPosition = UserDefaults.standard.double(forKey: key)
        if savedPosition > 0 {
            let time = CMTime(seconds: savedPosition, preferredTimescale: 600)
            player?.seek(to: time)
        }
    }

    func savePodcastPosition() {
        guard contentType == .podcastEpisode,
              let guid = currentItem?.track.videoId else { return }
        let key = "podcast_position_\(guid)"
        UserDefaults.standard.set(currentTime, forKey: key)
    }

    // MARK: - Audiobook Playback

    func playAudiobookChapter(_ chapter: AudiobookChapter, chapters: [AudiobookChapter], bookTitle: String, bookId: String) {
        guard let url = chapter.audioURL else { return }

        savePodcastPosition()
        saveAudiobookPosition()

        removeTimeObserver()
        cancelQualityUpgrade()
        cancellables.removeAll()
        NotificationCenter.default.removeObserver(self)

        player?.pause()
        contentType = .audiobook

        currentChapters = chapters
        currentChapterIndex = chapters.firstIndex(where: { $0.guid == chapter.guid }) ?? 0
        currentBookId = bookId

        let audiobookTrack = Track(
            videoId: chapter.guid,
            title: chapter.displayTitle,
            artists: [bookTitle],
            album: "Chapter \(chapter.chapterNumber) of \(chapters.count)",
            durationSeconds: chapter.durationSeconds,
            thumbnails: [],
            isExplicit: false,
            videoType: "AUDIOBOOK_CHAPTER"
        )

        let item = QueueItem(track: audiobookTrack, streamUrl: chapter.audioUrl, source: .stream)
        currentItem = item
        expectedDuration = Double(chapter.durationSeconds)

        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        player?.volume = Float(volume)
        player?.play()
        playbackState = .playing
        setupPlayerObservers()

        // Resume from saved position
        let key = "audiobook_position_\(chapter.guid)"
        let savedPosition = UserDefaults.standard.double(forKey: key)
        if savedPosition > 0 {
            let time = CMTime(seconds: savedPosition, preferredTimescale: 600)
            player?.seek(to: time)
        }

        UserDefaults.standard.set(currentChapterIndex, forKey: "audiobook_chapter_\(bookId)")
    }

    func saveAudiobookPosition() {
        guard contentType == .audiobook,
              let guid = currentItem?.track.videoId else { return }
        let key = "audiobook_position_\(guid)"
        UserDefaults.standard.set(currentTime, forKey: key)
        if !currentBookId.isEmpty {
            UserDefaults.standard.set(currentChapterIndex, forKey: "audiobook_chapter_\(currentBookId)")
        }
    }

    func skipToNextChapter() {
        guard contentType == .audiobook else { return }
        saveAudiobookPosition()
        let nextIndex = currentChapterIndex + 1
        guard nextIndex < currentChapters.count else { return }
        playAudiobookChapter(currentChapters[nextIndex], chapters: currentChapters, bookTitle: currentItem?.track.artists.first ?? "", bookId: currentBookId)
    }

    func skipToPreviousChapter() {
        guard contentType == .audiobook else { return }
        saveAudiobookPosition()
        if currentTime > 5 {
            seek(to: 0)
            return
        }
        let prevIndex = currentChapterIndex - 1
        guard prevIndex >= 0 else {
            seek(to: 0)
            return
        }
        playAudiobookChapter(currentChapters[prevIndex], chapters: currentChapters, bookTitle: currentItem?.track.artists.first ?? "", bookId: currentBookId)
    }

    func skipForward(_ seconds: Double = 15) {
        let newTime = min(currentTime + seconds, effectiveDuration)
        seek(to: newTime / max(effectiveDuration, 1))
    }

    func skipBackward(_ seconds: Double = 15) {
        let newTime = max(currentTime - seconds, 0)
        seek(to: newTime / max(effectiveDuration, 1))
    }
    
    // MARK: - Queue Management

    func addToQueue(_ item: QueueItem) {
        queue.append(item)

        // Trim queue if it gets too large
        if queue.count > maxQueueSize {
            trimQueue()
        }

        dataManager.saveQueue(queue)
    }

    func addToQueueNext(_ item: QueueItem) {
        let insertIndex = min(currentIndex + 1, queue.count)
        queue.insert(item, at: insertIndex)
        
        // Trim queue if it gets too large
        if queue.count > maxQueueSize {
            trimQueue()
        }
        
        dataManager.saveQueue(queue)
    }
    
    /// Trims queue to keep memory usage in check
    private func trimQueue() {
        // Keep current track and next 50 items
        let keepStart = currentIndex
        let keepEnd = min(currentIndex + trimQueueToSize, queue.count)
        
        // Create new queue with kept items
        var newQueue: [QueueItem] = []
        
        // Add items before current if they exist (up to 10 previous)
        let prevStart = max(0, currentIndex - 10)
        if prevStart < currentIndex {
            newQueue.append(contentsOf: queue[prevStart..<currentIndex])
        }
        
        // Add current and future items
        newQueue.append(contentsOf: queue[currentIndex..<keepEnd])
        
        // Update queue and adjust index
        queue = newQueue
        currentIndex = min(currentIndex - prevStart, queue.count - 1)
        
        print("✂️ Trimmed queue to \(queue.count) items")
    }
    
    /// Clears old items from queue (call periodically)
    func cleanupOldItems() {
        let cutoff = Date().addingTimeInterval(-maxItemAge)
        
        // Remove items older than cutoff, except current
        queue.removeAll { item in
            item.createdAt < cutoff && item.track.videoId != currentItem?.track.videoId
        }
        
        // Recalculate current index
        if let current = currentItem {
            currentIndex = queue.firstIndex(where: { $0.track.videoId == current.track.videoId }) ?? 0
        }
    }
    
    func removeFromQueue(at index: Int) {
        guard index >= 0 && index < queue.count else { return }

        let removedItem = queue.remove(at: index)

        // Adjust current index if needed
        if index < currentIndex {
            currentIndex -= 1
        } else if index == currentIndex {
            // Removed current item, play next
            if currentIndex < queue.count {
                playQueue(at: currentIndex)
            } else if !queue.isEmpty {
                currentIndex = queue.count - 1
                playQueue(at: currentIndex)
            } else {
                stop()
                currentItem = nil
            }
        }
    }
    
    func moveQueueItem(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)

        // Recalculate current index
        if let current = currentItem {
            currentIndex = queue.firstIndex(where: { $0.track.videoId == current.track.videoId }) ?? 0
        }
    }

    func clearQueue() {
        queue.removeAll()
        currentIndex = 0
    }
    
    // MARK: - Skip Control
    
    func nextTrack(useCrossfade: Bool = true, userSkipped: Bool = false) {
        print("⏭️ nextTrack called. Queue count: \(queue.count), currentIndex: \(currentIndex)")
        beginTrackTransitionBackgroundTask()

        // Anti-Algorithm: track skip/complete
        if let currentVideoId = currentItem?.track.videoId {
            if userSkipped {
                AntiAlgorithmEngine.shared.trackSkipped(videoId: currentVideoId)
            }
        }
        guard !queue.isEmpty else {
            print("⏭️ Queue is empty!")
            endTrackTransitionBackgroundTask()
            return
        }

        if repeatMode == .one {
            // Repeat current
            seek(to: 0)
            endTrackTransitionBackgroundTask()
            return
        }

        let nextIndex = currentIndex + 1
        print("⏭️ Next index: \(nextIndex), queue.count: \(queue.count)")

        if nextIndex < queue.count {
            let nextItem = queue[nextIndex]
            print("⏭️ Playing next: \(nextItem.track.title), streamUrl: \(nextItem.streamUrl.prefix(50))...")

            // Check if we should use crossfade
            if useCrossfade && CrossfadeManager.shared.isEnabled {
                performCrossfadeToNextItem(nextItem, at: nextIndex)
            } else {
                playQueue(at: nextIndex)
            }
        } else if repeatMode == .all {
            // Loop to beginning
            print("⏭️ Looping to beginning")
            playQueue(at: 0)
        } else {
            print("⏭️ End of queue reached")
            endTrackTransitionBackgroundTask()
        }
    }
    
    private func performCrossfadeToNextItem(_ item: QueueItem, at index: Int) {
        print("🔊 Performing crossfade to: \(item.track.title)")

        // CRITICAL FIX: Set expectedDuration BEFORE updating UI so progress calculations use correct duration
        expectedDuration = Double(item.track.durationSeconds)
        print("🎵 Crossfade: Set expectedDuration = \(expectedDuration) from track.durationSeconds = \(item.track.durationSeconds)")
        
        // CRITICAL FIX: Check if crossfade is possible BEFORE updating UI
        // CrossfadeManager needs a prepared nextPlayer
        guard CrossfadeManager.shared.canCrossfade() else {
            print("⚠️ Cannot crossfade - nextPlayer not prepared. Falling back to regular playback.")
            playQueue(at: index, isCrossfadeFallback: true)
            endTrackTransitionBackgroundTask()
            return
        }
        
        // Now safe to update UI state
        currentIndex = index
        currentItem = item
        
        // Perform crossfade
        CrossfadeManager.shared.crossfadeToNext { [weak self] in
            guard let self = self else { return }
            
            // Crossfade complete, update player reference
            self.player = CrossfadeManager.shared.takeNextPlayer()
            
            // CRITICAL FIX: Only proceed if we got a valid player
            guard self.player != nil else {
                print("❌ Crossfade completed but player is nil - forcing fallback")
                self.playQueue(at: index, isCrossfadeFallback: true)
                self.endTrackTransitionBackgroundTask()
                return
            }
            
            // Setup observers on new player
            self.setupPlayerObservers()

            // Update state
            self.playbackState = .playing

            // Update remote controls
            self.updateRemoteControls()

            // Prepare next track for future crossfade
            self.prepareNextTrackForCrossfade()

            print("✅ Crossfade complete, now playing: \(item.track.title)")
            self.endTrackTransitionBackgroundTask()
        }
        
        // Add to recently played
        dataManager.addToRecentlyPlayed(item.track)
        NotificationCenter.default.post(name: .trackPlayed, object: nil)
    }
    
    private var isPreparingNextTrack = false

    private func prepareNextTrackForCrossfade() {
        guard CrossfadeManager.shared.isEnabled else { return }

        // Prevent duplicate preparation
        guard !isPreparingNextTrack else {
            print("🔊 Already preparing next track, skipping")
            return
        }

        let nextIndex = currentIndex + 1
        guard nextIndex < queue.count else {
            print("🔊 No next track to prepare for crossfade")
            return
        }

        let nextItem = queue[nextIndex]

        // Check if already prepared (CrossfadeManager has a nextPlayer)
        guard !CrossfadeManager.shared.hasNextPlayer() else {
            print("🔊 Next track already prepared: \(nextItem.track.title)")
            return
        }

        print("🔊 Preparing next track for crossfade: \(nextItem.track.title)")
        isPreparingNextTrack = true
        CrossfadeManager.shared.prepareNextTrack(nextItem) { [weak self] in
            self?.isPreparingNextTrack = false
        }
    }
    
    func previousTrack() {
        guard !queue.isEmpty else { return }
        
        if repeatMode == .one {
            seek(to: 0)
            return
        }
        
        let prevIndex = currentIndex - 1
        
        if prevIndex >= 0 {
            playQueue(at: prevIndex)
        } else if repeatMode == .all {
            // Loop to end
            playQueue(at: queue.count - 1)
        }
    }
    
    // MARK: - Shuffle & Repeat
    
    func toggleShuffle() {
        isShuffled.toggle()

        if isShuffled {
            // Save original queue
            originalQueue = queue
            // Shuffle remaining items after current (if any)
            if currentIndex < queue.count - 1 {
                let current = queue[currentIndex]
                var remaining = Array(queue[(currentIndex + 1)...])
                remaining.shuffle()
                queue = Array(queue[...currentIndex]) + remaining
            }
        } else {
            // Restore original order
            if let current = currentItem {
                queue = originalQueue
                currentIndex = queue.firstIndex(where: { $0.track.videoId == current.track.videoId }) ?? 0
            }
        }
    }
    
    func toggleRepeat() {
        repeatMode.next()
    }
    
    // MARK: - Volume
    
    func setVolume(_ newVolume: Double) {
        volume = max(0.0, min(1.0, newVolume))
        player?.volume = Float(volume)
    }
    
    // MARK: - Private Methods
    
    private func setupPlayerObservers() {
        guard let player = player else { return }
        
        print("🔊 setupPlayerObservers: player exists")
        
        // Observe player item status and errors
        player.currentItem?.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                print("🔊 Player item status changed: \(status)")
                switch status {
                case .readyToPlay:
                    print("✅ Player item ready to play")
                    self?.retryCount = 0  // Reset retry count on success
                case .failed:
                    if let error = self?.player?.currentItem?.error as NSError? {
                        print("❌ Player item failed: \(error)")
                        print("❌ Error domain: \(error.domain), code: \(error.code)")
                        print("❌ Error userInfo: \(error.userInfo)")

                        // Retry with fresh URL if possible
                        if let self = self, self.retryCount < self.maxRetries,
                           let item = self.currentItem {
                            self.retryCount += 1
                            print("🔄 Retrying playback (attempt \(self.retryCount)/\(self.maxRetries))...")
                            self.refreshAndPlayCurrentItem()
                        } else {
                            // CRITICAL FIX: After max retries, skip to next track instead of staying in error
                            print("❌ Max retries reached, skipping to next track")
                            self?.playbackState = .error("Playback failed, skipping...")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
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
            .store(in: &cancellables)
        
        // Note: Asset loading observation removed - using standard URL initialization
        
        // Time observer for progress updates
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updateProgress()
        }
        
        // Observe item duration
        player.currentItem?.publisher(for: \.duration)
            .compactMap { $0.seconds > 0 ? $0.seconds : nil }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                print("🔊 Duration updated: \(duration)")
                self?.duration = duration
                // Update Now Playing info with the new duration
                self?.updateRemoteControls()
            }
            .store(in: &cancellables)
        
        // Observe playback end
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )

        // Observe playback failure mid-track
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerFailedToPlayToEndTime),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: player.currentItem
        )

        // Observe playback stall
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerPlaybackStalled),
            name: .AVPlayerItemPlaybackStalled,
            object: player.currentItem
        )

        // Observe buffering / stall recovery
        player.currentItem?.publisher(for: \.isPlaybackLikelyToKeepUp)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLikelyToKeepUp in
                guard let self = self else { return }
                print("🔊 isPlaybackLikelyToKeepUp: \(isLikelyToKeepUp)")
                if isLikelyToKeepUp {
                    if self.isPlaybackStalled {
                        self.isPlaybackStalled = false
                        print("🔄 Recovery from stall: resuming playback")
                        self.player?.play()
                        self.player?.rate = self.playbackRate
                        self.playbackState = .playing
                    } else if self.playbackState == .buffering {
                        self.playbackState = .playing
                    }
                }
            }
            .store(in: &cancellables)

        print("✅ setupPlayerObservers completed")
    }
    
    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        NotificationCenter.default.removeObserver(self)
    }
    
    private var progressLogCounter = 0
    
    private func updateProgress() {
        guard let player = player else { return }
        
        let current = player.currentTime().seconds
        let total = player.currentItem?.duration.seconds ?? 0
        
        // Log every 10th call (every 5 seconds) to avoid spam
        progressLogCounter += 1
        if progressLogCounter >= 10 {
            progressLogCounter = 0
            print("⏱️ Progress: \(String(format: "%.1f", current))s / \(String(format: "%.1f", total))s, state: \(playbackState)")
        }
        
        currentTime = current
        // Debug: Log duration changes
        if abs(duration - total) > 0.1 {
            print("🎵 Duration changing from \(duration) to \(total)")
        }
        duration = total

        // Update Now Playing info periodically (every ~1 second)
        if progressLogCounter % 2 == 0 {
            NowPlayingService.shared.updatePlaybackTime(
                currentTime: currentTime,
                isPlaying: playbackState.isPlaying,
                playbackRate: playbackRate
            )
        }

        // Use effective duration (from track metadata) for progress calculation
        let effectiveTotal = effectiveDuration > 0 ? effectiveDuration : total
        if progressLogCounter == 0 {  // Log every 5 seconds
            print("🎵 updateProgress: current=\(current), total=\(total), expectedDuration=\(expectedDuration), effectiveTotal=\(effectiveTotal)")
        }
        if effectiveTotal > 0 {
            let newProgress = current / effectiveTotal
            progress = min(newProgress, 1.0)  // Cap at 1.0 to prevent overflow
            
            // Prepare next track for crossfade when near the end (use effective duration)
            let timeRemaining = effectiveTotal - current
            if timeRemaining <= CrossfadeManager.shared.duration && timeRemaining > CrossfadeManager.shared.duration - 1 {
                prepareNextTrackForCrossfade()
            }
            
            // Track listening time (only count when playing and progress is moving forward)
            let now = Date()
            let timeDelta = now.timeIntervalSince(lastProgressUpdate)
            if timeDelta > 0 && timeDelta < 5 && playbackState == .playing {
                accumulatedListeningTime += timeDelta
                // Save to DataManager every 10 seconds
                if accumulatedListeningTime >= 10 {
                    dataManager.addListeningTime(accumulatedListeningTime)
                    accumulatedListeningTime = 0
                }
            }
            lastProgressUpdate = now
            
            // Save progress periodically (every 5% progress)
            if Int(newProgress * 100) % 5 == 0 {
                if let item = currentItem {
                    dataManager.updatePlaybackProgress(for: item.track.videoId, progress: newProgress)
                }
            }

            // Check if track has reached the end - trigger on either actual AVPlayer duration
            // OR effective duration (metadata), whichever is reached first
            let actualDuration = player.currentItem?.duration.seconds ?? 0
            let isNearActualEnd = actualDuration.isFinite && actualDuration > 0 && current >= actualDuration - 0.5
            let isNearEffectiveEnd = effectiveTotal > 0 && current >= effectiveTotal - 0.5
            let shouldTriggerCompletion = isNearActualEnd || isNearEffectiveEnd

            if shouldTriggerCompletion && !playbackState.isLoading {
                print("🏁 Track reached end (current: \(current), actual: \(actualDuration), effective: \(effectiveTotal))")
                completionQueue.async { [weak self] in
                    self?.handleTrackCompletion()
                }
                return
            }
        }

        // Auto-save podcast position every ~10 seconds
        if contentType == .podcastEpisode {
            let intTime = Int(currentTime)
            if intTime > 0 && intTime % 10 == 0 {
                savePodcastPosition()
            }
        }

        // Auto-save audiobook position every ~10 seconds
        if contentType == .audiobook {
            let intTime = Int(currentTime)
            if intTime > 0 && intTime % 10 == 0 {
                saveAudiobookPosition()
            }
        }
    }
    
    @objc private func playerDidFinishPlaying() {
        print("🏁 AVPlayer reported song finished playing")
        // Live radio: reconnect instead of advancing
        if contentType == .liveRadio {
            if let urlString = currentItem?.streamUrl, let url = URL(string: urlString) {
                let newItem = AVPlayerItem(url: url)
                player?.replaceCurrentItem(with: newItem)
                player?.play()
            }
            return
        }
        // Audiobook: auto-advance to next chapter
        if contentType == .audiobook {
            saveAudiobookPosition()
            // Check "End of Chapter" sleep timer
            let sleepTimer = SleepTimer.shared
            if sleepTimer.isActive && sleepTimer.selectedMinutes == 0 {
                print("🌙 End of chapter sleep timer triggered")
                DispatchQueue.main.async {
                    sleepTimer.cancel()
                }
                return
            }
            let nextIndex = currentChapterIndex + 1
            if nextIndex < currentChapters.count {
                print("📖 Auto-advancing to chapter \(nextIndex + 1)")
                // Update library progress when chapter completes
                AudiobookLibrary.shared.updateProgress(
                    bookId: currentBookId,
                    chapterIndex: nextIndex,
                    chaptersCompleted: nextIndex
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.playAudiobookChapter(self.currentChapters[nextIndex], chapters: self.currentChapters, bookTitle: self.currentItem?.track.artists.first ?? "", bookId: self.currentBookId)
                }
            } else {
                print("📖 Audiobook completed")
                AudiobookLibrary.shared.updateProgress(
                    bookId: currentBookId,
                    chapterIndex: currentChapters.count - 1,
                    chaptersCompleted: currentChapters.count
                )
                DispatchQueue.main.async { [weak self] in
                    self?.playbackState = .idle
                }
            }
            return
        }
        // Dispatch to serial queue to prevent race with updateProgress
        beginTrackTransitionBackgroundTask()
        completionQueue.async { [weak self] in
            self?.handleTrackCompletion()
        }
    }

    @objc private func playerFailedToPlayToEndTime(_ notification: Notification) {
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        print("❌ Player failed to play to end time: \(error?.localizedDescription ?? "Unknown error")")

        if let error = error as NSError? {
            print("❌ Failure domain: \(error.domain), code: \(error.code)")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.retryCount < self.maxRetries, let item = self.currentItem {
                self.retryCount += 1
                print("🔄 Retrying after mid-track failure (attempt \(self.retryCount)/\(self.maxRetries))...")
                self.refreshAndPlayCurrentItem()
            } else {
                print("❌ Max retries reached after failure, skipping to next track")
                self.nextTrack()
            }
        }
    }

    @objc private func playerPlaybackStalled(_ notification: Notification) {
        print("⚠️ Playback stalled (buffer underrun)")
        DispatchQueue.main.async { [weak self] in
            self?.isPlaybackStalled = true
            self?.playbackState = .buffering
        }
    }

    private func handleTrackCompletion() {
        // Prevent multiple completion triggers - now thread-safe via completionQueue
        guard !isHandlingCompletion else {
            print("🏁 Completion already being handled, skipping")
            return
        }
        isHandlingCompletion = true

        // Ensure flag is reset even if something goes wrong
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isHandlingCompletion = false
                print("🏁 Completion flag reset")
            }
        }

        // Stop the player to prevent progress from continuing to increment
        DispatchQueue.main.async { [weak self] in
            self?.player?.pause()
        }

        // Save final listening time
        if accumulatedListeningTime > 0 {
            dataManager.addListeningTime(accumulatedListeningTime)
            accumulatedListeningTime = 0
        }
        // Mark as completed
        if let item = currentItem {
            dataManager.updatePlaybackProgress(for: item.track.videoId, progress: 1.0)
        }
        // Check if "End of Track" sleep timer is active
        let sleepTimer = SleepTimer.shared
        if sleepTimer.isActive && sleepTimer.selectedMinutes == 0 {
            print("🌙 End of Track sleep timer triggered: stopping playback")
            DispatchQueue.main.async {
                sleepTimer.cancel()
            }
            return
        }

        print("🏁 Advancing to next track after completion")

        // Anti-Algorithm: track completed
        if let currentVideoId = currentItem?.track.videoId {
            AntiAlgorithmEngine.shared.trackCompleted(videoId: currentVideoId)
        }

        // Move to next track on main thread
        DispatchQueue.main.async { [weak self] in
            self?.nextTrack()
            self?.endTrackTransitionBackgroundTask()
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "0:00" }
        
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

// MARK: - Remote Controls
extension PlayerState {
    private func setupRemoteControls() {
        // Remote commands are now handled by NowPlayingService
        // This method is called to ensure backward compatibility
        // All remote command setup is centralized in NowPlayingService
    }

    private func updateRemoteControls() {
        guard let item = currentItem else {
            NowPlayingService.shared.clearNowPlaying()
            return
        }

        // Use effective duration (from track metadata if available)
        let displayDuration = effectiveDuration
        print("🎵 updateRemoteControls - effectiveDuration: \(displayDuration), currentTime: \(currentTime)")

        NowPlayingService.shared.updateNowPlaying(
            track: item.track,
            duration: displayDuration,
            currentTime: currentTime,
            isPlaying: playbackState.isPlaying,
            playbackRate: playbackRate
        )
    }
}
