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
    /// S3-4: Replay Gain in dB, captured from the backend's StreamInfo at
    /// queue-construction time. Persists across seamless quality switches
    /// so the gain doesn't have to be re-fetched.
    let replayGain: Double?

    enum TrackSource: Equatable {
        case stream
        case local(path: String)
    }

    init(track: Track, streamUrl: String, source: TrackSource, contentSource: ContentSource = .youtube, createdAt: Date = Date(), replayGain: Double? = nil) {
        self.track = track
        self.streamUrl = streamUrl
        self.source = source
        self.contentSource = contentSource
        self.createdAt = createdAt
        self.replayGain = replayGain
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

    /// Sprint 2 / C-4 helper: every place that sets expectedDuration
    /// should also call this so PlaybackClock's published value stays
    /// in sync with PlayerState's private mirror.
    private func updateExpectedDuration(_ value: Double) {
        expectedDuration = value
        playbackClock.setExpectedDuration(value)
    }

    /// Sprint 2 / C-4 fix: focused observable for the 0.5s time/progress
    /// updates. PlayerState retains @Published currentTime/duration for
    /// backwards compat (consumers like NowPlayingService, QueueView,
    /// MiniPlayer still read these), but views that update 2x/sec (the
    /// scrubber and time labels in FullPlayer) should observe only
    /// `playbackClock` to scope re-renders to that subtree.
    let playbackClock = PlaybackClock()

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

    // MARK: - Phase 2 / ios-qa: @Snapshotable marked properties
    // The ios-qa StateServer reads these via reflection. Marking a property
    // tells the codegen tool to emit a register/read/write accessor for
    // it, which the simulator-side test agent uses to assert on playback
    // state (e.g., "did the user see a 'playback error' toast?" or
    // "is the currentItem.source == .stream after tapping a YouTube
    // track?"). We only mark the properties the test plan needs to
    // assert on — everything else stays private to keep the StateServer
    // schema tight. The mirror properties (`snapshotX`) avoid name
    // collision with the @Published originals while letting the
    // StateServer's accessor point at the same logical state.
    #if DEBUG
    @Snapshotable var snapshotPlaybackState: PlaybackState = .idle
    @Snapshotable var snapshotContentType: PlaybackContentType = .track
    @Snapshotable var snapshotIsShuffled: Bool = false
    @Snapshotable var snapshotRepeatMode: RepeatMode = .none
    @Snapshotable var snapshotVolume: Double = 1.0
    @Snapshotable var snapshotPlaybackRate: Float = 1.0
    @Snapshotable var snapshotCurrentIndex: Int = 0
    #endif

    // MARK: - S3-4: Replay Gain
    /// User-facing setting. When true (default), track gain from the
    /// backend's ReplayGain metadata is applied as a pre-gain multiplier
    /// on `player.volume`. When false, player.volume is the user volume
    /// unchanged. Picked up live by `applyVolume()` so toggling the
    /// setting takes effect immediately.
    static let replayGainEnabledKey = "playback.replayGainEnabled"
    static var replayGainEnabled: Bool {
        get {
            // Default to true; users can disable in settings.
            UserDefaults.standard.object(forKey: replayGainEnabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: replayGainEnabledKey)
        }
    }

    /// Effective gain to apply for the current item, in linear amplitude
    /// (not dB). Returns 1.0 when:
    ///  - Replay Gain is disabled in settings
    ///  - the current item has no `replayGain` (backend didn't provide one)
    ///  - the value is exactly 0 dB (no change needed)
    private var currentReplayGainLinear: Float {
        guard PlayerState.replayGainEnabled,
              let db = currentItem?.replayGain,
              db.isFinite else { return 1.0 }
        // 10^(dB/20) — standard amplitude-from-dB conversion
        return Float(pow(10.0, db / 20.0))
    }
    
    // MARK: - Private Properties

    // S3-5: When gapless playback is on, this is an AVQueuePlayer that
    // pre-queues upcoming items. AVQueuePlayer auto-advances on item end
    // for a truly seamless transition (no gap, no overlap). When off,
    // it's a regular AVPlayer and we use the two-player crossfade path.
    // The type stays as `AVPlayer?` because AVQueuePlayer IS-A AVPlayer;
    // only construction and item-management differ.
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var retryCount = 0
    private let maxRetries = 2
    private var originalQueue: [QueueItem] = []
    private var dataManager = DataManager.shared
    private var accumulatedListeningTime: TimeInterval = 0
    private var lastProgressUpdate: Date = Date()

    // C-2 fix: token-based observer tracking. The previous code used
    // `NotificationCenter.default.removeObserver(self)` in the
    // playRadioStation / playPodcastEpisode / playAudiobookChapter entry
    // points and in removeTimeObserver, which stripped ALL observers
    // (including the audio session interruption / route change / media
    // services reset observers) for the rest of the app's lifetime. After
    // playing a podcast and receiving a phone call, playback would no
    // longer pause. We now track observers by token and only remove the
    // ones scoped to the current AVPlayerItem.
    //
    // We use arrays (not Sets) because NSObjectProtocol is not Hashable.
    // Cardinality is small (3 + 3 + 1) so linear scans are fine.
    private var audioSessionObserverTokens: [NSObjectProtocol] = []
    private var playerItemObserverTokens: [NSObjectProtocol] = []
    private var memoryWarningToken: NSObjectProtocol?

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

        // C-2 fix: register memory warning via token (so we can clean up
        // consistently if needed; previously this used the selector-based
        // overload that can be stripped by `removeObserver(self)`)
        memoryWarningToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }

        // Periodic cleanup every 5 minutes
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.cleanupOldItems()
        }

        // Phase 2 / ios-qa: keep the @Snapshotable mirror properties in
        // sync with their @Published counterparts. The StateServer reads
        // the mirror values; the rest of the app reads the @Published
        // originals. We do this in one place rather than at every
        // assignment site to avoid scattering DEBUG-gated code through
        // the file. We subscribe to the projected `$` publishers (not
        // `objectWillChange`) so we get the new value, not the old one.
        //
        // Publishers.MergeMany requires homogeneous types so we map each
        // to `AnyPublisher<Void, Never>` first; the handler reads the
        // up-to-date values directly from `self`.
        #if DEBUG
        let triggers: [AnyPublisher<Void, Never>] = [
            self.$playbackState.map { _ in () }.eraseToAnyPublisher(),
            self.$contentType.map { _ in () }.eraseToAnyPublisher(),
            self.$isShuffled.map { _ in () }.eraseToAnyPublisher(),
            self.$repeatMode.map { _ in () }.eraseToAnyPublisher(),
            self.$volume.map { _ in () }.eraseToAnyPublisher(),
            self.$playbackRate.map { _ in () }.eraseToAnyPublisher(),
            self.$currentIndex.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.snapshotPlaybackState = self.playbackState
                self.snapshotContentType = self.contentType
                self.snapshotIsShuffled = self.isShuffled
                self.snapshotRepeatMode = self.repeatMode
                self.snapshotVolume = self.volume
                self.snapshotPlaybackRate = self.playbackRate
                self.snapshotCurrentIndex = self.currentIndex
            }
            .store(in: &cancellables)

        // Phase 2 / ios-qa: register the @Snapshotable mirrors with the
        // embedded StateServer. This must happen AFTER `self` is fully
        // initialized (all stored properties have their defaults) so the
        // read closures return real values from the first snapshot. The
        // registration is idempotent — re-calling replaces — so it's safe
        // to call on every init.
        PlayerStateAccessor.register(self)
        #endif
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
                    self.updateExpectedDuration(Double(currentItem.track.durationSeconds))
                }
            }
        }
    }

    // S11 fix (Bug 16): removed dead `restorePlaybackState()` method.
    // It was never invoked anywhere. The lastPlaybackProgress resume
    // functionality is now handled by `HomeViewModel.playTrack(_:seekToProgress:)`
    // reading `dataManager.recentlyPlayed.first?.playbackProgress`
    // directly when the user taps the resume hero on Home.

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
        // C-2 fix: token-based observer registration. These observers must
        // remain active for the lifetime of the PlayerState singleton — the
        // previous selector-based overloads were being stripped by the
        // `removeObserver(self)` call in playRadioStation / playPodcastEpisode
        // / playAudiobookChapter / removeTimeObserver.
        audioSessionObserverTokens.append(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                self?.handleAudioSessionInterruption(notification)
            }
        )
        audioSessionObserverTokens.append(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                self?.handleAudioSessionRouteChange(notification)
            }
        )
        audioSessionObserverTokens.append(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleMediaServicesReset(notification)
            }
        )
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
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

    private func handleAudioSessionRouteChange(_ notification: Notification) {
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

    private func handleMediaServicesReset(_ notification: Notification) {
        print("🔄 Media services were reset, rebuilding audio session and player")
        setupAudioSession()
        if let current = currentItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.play(item: current, addToQueue: false)
            }
        }
    }

    // MARK: - Background Task Helpers

    // S11 fix (Bug 14): safety-timeout handle for the
    // isHandlingCompletion flag reset. The observer in
    // setupPlayerObservers will reset the flag when the new track
    // transitions from .loading to .playing. This timer is the
    // safety net in case the new player never reports ready (e.g.,
    // failed to load, queue exhausted, no autoplay candidate).
    private var completionFlagResetWorkItem: DispatchWorkItem?

    private func scheduleCompletionFlagReset(after seconds: TimeInterval) {
        completionFlagResetWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.isHandlingCompletion {
                self.isHandlingCompletion = false
                print("🏁 [S11] Completion flag reset (safety timeout \(seconds)s)")
            }
        }
        completionFlagResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Clears isHandlingCompletion immediately. Called by the new
    /// player's status observer when playbackState transitions out
    /// of .loading — the equivalent of "new track is now playing".
    private func clearCompletionFlag() {
        completionFlagResetWorkItem?.cancel()
        completionFlagResetWorkItem = nil
        if isHandlingCompletion {
            isHandlingCompletion = false
            print("🏁 [S11] Completion flag reset (new track playing)")
        }
    }

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
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(track:) ENTRY videoId=\(track.videoId) title=\(track.title) currentItem.videoId=\(currentItem?.track.videoId ?? "nil") playbackState=\(playbackState)")
        #endif
        // C-5 fix: use the reconciliation helper instead of raw FileManager.fileExists.
        // This handles the case where CDDownloadedTrack has a stale row but the
        // file is missing on disk (user deleted via Files.app, etc.).
        let isPlayable = AudioFileManager.shared.isPlayable(
            videoId: track.videoId,
            context: PersistenceController.shared.viewContext
        )
        let localURL = AudioFileManager.shared.localFileURL(for: track.videoId)

        if isPlayable {
            // Play from local file
            // C-5 fix: pass `contentSource: .local` explicitly. The default is
            // `.youtube` which caused the red YouTube chip to render on
            // downloaded tracks in FullPlayer.
            let item = QueueItem(
                track: track,
                streamUrl: localURL.absoluteString,
                source: .local(path: localURL.path),
                contentSource: .local
            )
            play(item: item)
        } else {
            // Stream from backend - fetch stream URL first
            #if DEBUG
            PlayCrashDiagnostics.log(.playback, "play(track:) PRE-getStreamUrl videoId=\(track.videoId)")
            #endif
            // C-2026-06-28: bypass StreamURLCache. The cache added
            // locking + NSCache + share() + Just wrapping that hung
            // indefinitely on a fresh install. APIService.getStreamUrl
            // is itself a synchronous Just and we hit the backend
            // directly here. The cache can be re-added later with
            // better instrumentation once we know what's blocking.
            APIService.shared.getStreamUrl(videoId: track.videoId, preferM4A: true, quality: "low")
                .sink(
                    receiveCompletion: { [weak self] result in
                        if case .failure(let error) = result {
                            // S11 fix (Bug 12): previously silent —
                            // just printed and left the player in
                            // .loading forever. Surface to user with
                            // retry so they can recover without
                            // killing/reopening the app.
                            print("❌ [S11] Failed to get stream URL for \(track.title): \(error)")
                            #if DEBUG
                            PlayCrashDiagnostics.log(.playback, "S11: play(track:) stream URL FAILED videoId=\(track.videoId) error=\(error)")
                            #endif
                            DispatchQueue.main.async {
                                self?.playbackState = .error("Could not load track")
                                ErrorHandler.shared.show(
                                    .playbackFailed("Couldn't load \"\(track.title)\". Try again or pick another track."),
                                    retry: { [weak self] in
                                        self?.play(track: track)
                                    }
                                )
                                self?.endTrackTransitionBackgroundTask()
                                self?.clearCompletionFlag()
                            }
                        }
                    },
                    receiveValue: { [weak self] streamInfo in
                        // S3-4: pass replayGain through to the queue item
                        // so the gain is preserved across quality switches
                        // and re-applied on every play.
                        let item = QueueItem(
                            track: track,
                            streamUrl: streamInfo.streamUrl,
                            source: .stream,
                            replayGain: streamInfo.replayGain
                        )
                        self?.play(item: item)
                    }
                )
                .store(in: &cancellables)
        }
    }

    func play(item: QueueItem, addToQueue: Bool = true) {
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) ENTRY videoId=\(item.track.videoId) title=\(item.track.title) source=\(item.source) currentItem.videoId=\(currentItem?.track.videoId ?? "nil") playbackState=\(playbackState)")
        #endif
        // Stop current playback and save progress
        if let current = currentItem {
            dataManager.updatePlaybackProgress(for: current.track.videoId, progress: progress)
        }

        stop()
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) POST-stop")
        #endif
        contentType = .track

        // S10: Reactivate the audio session before creating the new player.
        // stop() nil'd the previous AVPlayer; iOS can deactivate the session
        // when there's no active player. In the background, an inactive
        // session causes iOS to suspend the app before the new player has
        // buffered enough to start producing audio.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            #if DEBUG
            PlayCrashDiagnostics.log(.playback, "play(item:) POST-audioSession.setActive")
            #endif
        } catch {
            print("❌ S10: failed to reactivate audio session: \(error)")
        }

        currentItem = item
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) POST-currentItem-set")
        #endif
        // Store expected duration from track metadata
        updateExpectedDuration(Double(item.track.durationSeconds))
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
            // C-3 fix: surface the error to the user. Previously this
            // returned silently and the play button just sat in loading
            // state with no feedback.
            playbackState = .error("Invalid URL")
            ErrorHandler.shared.show(.playbackFailed("Invalid URL"))
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
        // S3-5: Use AVQueuePlayer when gapless is enabled so AVFoundation
        // can chain upcoming items seamlessly (no gap, no overlap). When
        // gapless is off, fall back to a regular AVPlayer + the two-player
        // crossfade path in CrossfadeManager.
        if CrossfadeManager.shared.gaplessEnabled {
            player = AVQueuePlayer(playerItem: playerItem)
            print("🔊 AVQueuePlayer created (gapless mode)")
        } else {
            player = AVPlayer(playerItem: playerItem)
            print("🔊 AVPlayer created (crossfade mode)")
        }
        applyVolume()
        // Ensure background playback continues on iOS 16+
        player?.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        // Don't wait to minimize stalling - start immediately and let it buffer as it plays
        player?.automaticallyWaitsToMinimizeStalling = false

        // Set current player in crossfade manager
        // For gapless mode, we still call setCurrentPlayer so observers fire
        // uniformly; CrossfadeManager just won't pre-prepare a next player.
        CrossfadeManager.shared.setCurrentPlayer(player)

        // S3-5: Pre-queue upcoming items in the AVQueuePlayer so the
        // auto-advance to next track is gapless.
        if CrossfadeManager.shared.gaplessEnabled {
            enqueueUpcomingItemsForGapless()
        }

        // Attach audio visualizer tap to this player item
        AudioVisualizerEngine.shared.installTap(on: playerItem)
        
        // Setup observers
        print("🔊 Setting up observers...")
        setupPlayerObservers()
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) POST-setupPlayerObservers")
        #endif
        print("✅ Observers set up")

        // Start playback immediately for fast start - don't wait for readyToPlay
        // AVPlayer will handle buffering as it plays. Keep playbackState as .loading
        // until the item reports .readyToPlay so the UI shows accurate feedback.
        print("🔊 Starting playback immediately (fast-start mode)...")
        player?.play()
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) POST-player.play")
        #endif
        player?.rate = playbackRate
        // playbackState stays .loading; observer will flip to .playing when ready.

        print("🔊 Auto-populating queue...")
        QueuePrefetcher.shared.autoPopulateQueue(startingFrom: item.track)
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) POST-QueuePrefetcher")
        #endif

        // Setup remote controls
        print("🔊 Setting up remote controls...")
        setupRemoteControls()
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) POST-setupRemoteControls")
        #endif
        print("✅ Remote controls set up")

        // S10: Refresh system Now Playing immediately when a new track
        // starts, so the Lock Screen / Control Center update right away
        // rather than waiting for the duration publisher (which can be
        // 1-3s late for HTTP streams served by yt-dlp's proxy-stream).
        // isPlaying: false because state is .loading until readyToPlay;
        // NowPlayingService treats rate=0 as paused, which matches what
        // the Lock Screen should show during the brief buffer.
        NowPlayingService.shared.updateNowPlaying(
            track: item.track,
            duration: Double(item.track.durationSeconds),
            currentTime: 0,
            isPlaying: playbackState.isPlaying,
            playbackRate: playbackRate
        )
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) POST-updateNowPlaying videoId=\(item.track.videoId)")
        #endif
        
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
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) EXIT videoId=\(item.track.videoId)")
        #endif
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

        // C-2026-06-28: bypass StreamURLCache. The cache had an
        // activeFetchLock deadlock on its first synchronous subscribe
        // (the Just publisher's receiveCompletion tried to re-lock
        // activeFetchLock from the same thread that held the outer
        // lock). We now go direct to APIService for the upgrade.
        APIService.shared.getStreamUrl(videoId: item.track.videoId, preferM4A: true, quality: "high")
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
        // QW-11 fix: use 0.5s tolerance instead of `.zero`. The exact seek
        // was stalling 1-5s on slow networks during quality upgrade because
        // AVPlayer has to download the exact keyframe. A 0.5s tolerance is
        // imperceptible to the ear and completes near-instantly.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 1000)
        player.seek(to: currentTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            guard let self = self else { return }

            // Restore playback state
            if wasPlaying {
                player.play()
                player.rate = 1.0
            }

            // Update current item with new URL
            // S3-4: preserve replayGain across the quality switch
            let upgradedItem = QueueItem(
                track: originalItem.track,
                streamUrl: newUrl,
                source: .stream,
                replayGain: originalItem.replayGain
            )
            self.currentItem = upgradedItem

            // Update queue
            if self.currentIndex < self.queue.count {
                self.queue[self.currentIndex] = upgradedItem
            }

            // S3-4: re-apply the gain on the (possibly new) player
            applyVolume()

            // QW-13 fix: re-install the visualizer tap on the new
            // (high-quality) player item. installTap is only called in
            // play(item:), so after a seamless quality switch the
            // visualizer + haptic symphony engine would read silent buffers
            // for the remainder of the track.
            if let newItem = player.currentItem {
                AudioVisualizerEngine.shared.installTap(on: newItem)
            }

            print("✅ Quality upgraded to high - seamless switch complete")
        }
    }

    func cancelQualityUpgrade() {
        qualityUpgradeTimer?.invalidate()
        qualityUpgradeTimer = nil
    }
    
    func playQueue(at index: Int, isCrossfadeFallback: Bool = false) {
        // S11: log every entry so we can verify the play-from-queue path
        // was reached (especially after autoplay-from-recently-played).
        print("▶️ [S11] playQueue ENTRY index=\(index) queue.count=\(queue.count) currentIndex=\(currentIndex) isCrossfadeFallback=\(isCrossfadeFallback)")
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "S11: playQueue ENTRY index=\(index) queue.count=\(queue.count) isCrossfadeFallback=\(isCrossfadeFallback)")
        #endif

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
            updateExpectedDuration(Double(item.track.durationSeconds))
            print("🎵 playQueue: Set expectedDuration = \(expectedDuration)")
            currentIndex = index
            play(item: item, addToQueue: false)
        }
        // S11 fix (Bug 11): removed `endTrackTransitionBackgroundTask()`.
        // Releasing here would end the BG task BEFORE the new player has
        // buffered enough audio. The task is now released by the
        // isPlaybackLikelyToKeepUp observer in setupPlayerObservers, which
        // is the original S10 release point.
    }
    
    private func refreshAndPlay(item: QueueItem, at index: Int) {
        StreamURLCache.shared.getStreamUrl(videoId: item.track.videoId)
            .sink(
                receiveCompletion: { [weak self] result in
                    if case .failure(let error) = result {
                        print("❌ Failed to refresh stream URL: \(error)")
                        // C-3 fix: surface to user. Previously this
                        // surfaced only in console; user saw a silent
                        // loading state.
                        self?.playbackState = .error("Failed to load audio")
                        ErrorHandler.shared.show(.playbackFailed("Could not load this track. Check your connection and try again."))
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
                    // S11 fix (Bug 11): removed `endTrackTransitionBackgroundTask()`.
                    // The task is now released by the isPlaybackLikelyToKeepUp
                    // observer when the new track is actually playing.
                }
            )
            .store(in: &cancellables)
    }
    
    private func refreshAndPlayCurrentItem() {
        guard let item = currentItem else {
            print("⚠️ [S11] refreshAndPlayCurrentItem: no currentItem — no-op")
            return
        }
        print("🔄 [S11] refreshAndPlayCurrentItem ENTRY videoId=\(item.track.videoId) title=\(item.track.title)")

        StreamURLCache.shared.getStreamUrl(videoId: item.track.videoId)
            .sink(
                receiveCompletion: { [weak self] result in
                    if case .failure(let error) = result {
                        print("❌ Failed to refresh stream URL: \(error)")
                        // C-3 fix: surface to user with retry. The retry
                        // closure re-invokes refreshAndPlayCurrentItem so
                        // they can attempt again without leaving the player.
                        self?.playbackState = .error("Failed to load audio")
                        ErrorHandler.shared.show(
                            .playbackFailed("Could not load this track. Try again."),
                            retry: { [weak self] in
                                self?.refreshAndPlayCurrentItem()
                            }
                        )
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
        // S11: log every entry so silent-no-op reports are diagnosable.
        print("▶️ [S11] togglePlayPause ENTRY currentItem=\(currentItem?.track.videoId ?? "nil") playerNil=\(player == nil) playbackState=\(playbackState) isHandlingCompletion=\(isHandlingCompletion)")
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "S11: togglePlayPause ENTRY currentItem=\(currentItem?.track.videoId ?? "nil") playerNil=\(player == nil) playbackState=\(playbackState)")
        #endif

        // S11 fix (Bug 1): when there's a current item but no AVPlayer
        // (e.g., after restoreQueue set currentItem on cold launch),
        // the previous guard returned silently. Fall through to play the
        // current item so the resume button actually does something.
        guard let player = player else {
            if let item = currentItem {
                print("▶️ [S11] togglePlayPause: player nil but currentItem set — falling through to play(item:)")
                #if DEBUG
                PlayCrashDiagnostics.log(.playback, "S11: togglePlayPause: player nil, resuming currentItem=\(item.track.videoId)")
                #endif
                play(item: item, addToQueue: false)
            } else {
                print("⚠️ [S11] togglePlayPause: no current item either — true no-op")
            }
            return
        }

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
        print("⏸ [S11] pause ENTRY playerNil=\(player == nil) playbackState=\(playbackState)")
        player?.pause()
        playbackState = .paused
        updateRemoteControls()
    }

    func resume() {
        print("▶️ [S11] resume ENTRY playerNil=\(player == nil) playbackState=\(playbackState) currentItem=\(currentItem?.track.videoId ?? "nil")")
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "S11: resume ENTRY playerNil=\(player == nil) currentItem=\(currentItem?.track.videoId ?? "nil")")
        #endif
        // S11: same fall-through as togglePlayPause — if no player but
        // there's a current item (cold launch after restoreQueue),
        // resume should kick off playback.
        guard let player = player else {
            if let item = currentItem {
                print("▶️ [S11] resume: player nil but currentItem set — falling through to play(item:)")
                play(item: item, addToQueue: false)
            }
            return
        }
        player.play()
        playbackState = .playing
        updateRemoteControls()
    }

    /// Set playback rate (0.5 to 3.0)
    func setPlaybackRate(_ rate: Float) {
        guard rate >= 0.5 && rate <= 3.0 else { return }

        playbackRate = rate
        // Sprint 2 / C-4 fix: also push to the focused clock so the
        // scrubber's @ObservedObject view picks up the new rate.
        playbackClock.setRate(rate)
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
        // S11 fix (Bug 9): clear currentItem so the UI doesn't keep
        // showing "now playing" chrome after the player is gone.
        // restoreQueue() will repopulate this on cold launch for a
        // saved queue, but only via the PlaybackQueueManager path —
        // not as a stale leftover from a previous playback session.
        // isNowPlaying is computed from currentItem != nil, so this
        // also makes hero/mini-player chrome correctly hide.
        currentItem = nil
        playbackState = .idle
        progress = 0.0
        currentTime = 0.0
        duration = 0.0
        updateExpectedDuration(0.0)
        // Sprint 2 / C-4 fix: reset the focused clock so the scrubber
        // stops re-rendering on its tick.
        playbackClock.reset()
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
        // C-2 fix: removed `NotificationCenter.default.removeObserver(self)` —
        // it was stripping audio session observers (interruption / route
        // change / media services reset) for the rest of the app's lifetime.

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
        updateExpectedDuration(0)

        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        applyVolume()
        player?.play()
        playbackState = .playing
        // QW-13 fix: install the visualizer tap on the new player item
        // (was previously only called in play(item:), missing radio/podcast/audiobook)
        AudioVisualizerEngine.shared.installTap(on: playerItem)
        setupPlayerObservers()
        // S11 fix (Bug 2): refresh Lock Screen / Control Center with
        // the radio station's metadata. Previously Lock Screen kept
        // showing the previous track.
        NowPlayingService.shared.updateNowPlaying(
            track: radioTrack,
            duration: 0,  // live = no duration
            currentTime: 0,
            isPlaying: true,
            playbackRate: 1.0
        )
    }

    func playPodcastEpisode(_ episode: PodcastEpisode) {
        guard let url = episode.audioURL else { return }

        savePodcastPosition()  // Save current position before cleanup
        // Clean up previous playback state
        removeTimeObserver()
        cancelQualityUpgrade()
        cancellables.removeAll()
        // C-2 fix: removed `NotificationCenter.default.removeObserver(self)` —
        // it was stripping audio session observers for the rest of the app's
        // lifetime. See C-2 in project-playback-gap-analysis-2026-06-16.md.

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
        updateExpectedDuration(Double(episode.durationSeconds))

        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        applyVolume()
        player?.play()
        playbackState = .playing
        // QW-13 fix: install the visualizer tap on the new player item
        AudioVisualizerEngine.shared.installTap(on: playerItem)
        setupPlayerObservers()
        // S11 fix (Bug 2): refresh Lock Screen / Control Center with
        // the podcast metadata. Without this, the Lock Screen kept
        // showing whatever track was playing before.
        NowPlayingService.shared.updateNowPlaying(
            track: podcastTrack,
            duration: Double(episode.durationSeconds),
            currentTime: 0,
            isPlaying: true,
            playbackRate: 1.0
        )

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
        // C-2 fix: removed `NotificationCenter.default.removeObserver(self)` —
        // see project-playback-gap-analysis-2026-06-16.md.

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
        updateExpectedDuration(Double(chapter.durationSeconds))

        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        applyVolume()
        player?.play()
        playbackState = .playing
        // QW-13 fix: install the visualizer tap on the new player item
        AudioVisualizerEngine.shared.installTap(on: playerItem)
        setupPlayerObservers()
        // S11 fix (Bug 2): refresh Lock Screen / Control Center with
        // audiobook chapter metadata.
        NowPlayingService.shared.updateNowPlaying(
            track: audiobookTrack,
            duration: Double(chapter.durationSeconds),
            currentTime: 0,
            isPlaying: true,
            playbackRate: 1.0
        )

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
        // S11 fix (Bug 10): dedup before appending so callers don't
        // need to worry about double-add (e.g., search-result tap
        // followed by swipe-to-add-to-queue).
        if queue.contains(where: { $0.track.videoId == item.track.videoId }) {
            print("⚠️ [S11] addToQueue: skipping duplicate videoId=\(item.track.videoId)")
            return
        }
        queue.append(item)

        // Trim queue if it gets too large
        if queue.count > maxQueueSize {
            trimQueue()
        }

        dataManager.saveQueue(queue)
    }

    func addToQueueNext(_ item: QueueItem) {
        // S11 fix (Bug 10): dedup before inserting.
        if queue.contains(where: { $0.track.videoId == item.track.videoId }) {
            print("⚠️ [S11] addToQueueNext: skipping duplicate videoId=\(item.track.videoId)")
            return
        }
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

        // S10 diagnostic: distinguish "user pressed next" from "track
        // finished, autoplay kicked in". These take very different paths
        // and we want to know which fired when reading the console after
        // a background-track-transition repro.
        let fromCompletion = !userSkipped && isHandlingCompletion
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "S10: nextTrack ENTRY fromCompletion=\(fromCompletion) queue.count=\(queue.count) currentIndex=\(currentIndex) userSkipped=\(userSkipped)")
        #endif
        print("⏭️ S10: nextTrack ENTRY fromCompletion=\(fromCompletion) queue.count=\(queue.count) currentIndex=\(currentIndex)")

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

        // S3-5: Gapless mode path. If the player is an AVQueuePlayer, the
        // next item is already in the queue. Just call advanceToNextItem
        // and let AVFoundation do the rest. We still update currentIndex
        // / currentItem synchronously for the UI.
        if CrossfadeManager.shared.gaplessEnabled, let queuePlayer = player as? AVQueuePlayer {
            let nextIndex = currentIndex + 1
            if nextIndex < queue.count {
                print("⏭️ Gapless: advancing AVQueuePlayer to next track")
                currentIndex = nextIndex
                currentItem = queue[nextIndex]
                expectedDuration = Double(queue[nextIndex].track.durationSeconds)
                dataManager.addToRecentlyPlayed(queue[nextIndex].track)
                NotificationCenter.default.post(name: .trackPlayed, object: nil)
                queuePlayer.advanceToNextItem()
                // Re-enqueue to refill the queue player
                enqueueUpcomingItemsForGapless()
                endTrackTransitionBackgroundTask()
                return
            } else if repeatMode == .all {
                // Loop — fall through to playQueue(at: 0) below
                print("⏭️ Gapless: looping to beginning")
            } else {
                // S11 fix (Bug 6): previously went silent at end of
                // queue when gapless was enabled. Now fall through to
                // autoplay-from-recently-played, matching the non-
                // gapless path so the user always has continuous music.
                print("⏭️ End of queue reached (gapless) — falling through to autoplay")
                autoplayNextFromRecentlyPlayed()
                endTrackTransitionBackgroundTask()
                clearCompletionFlag()
                return
            }
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
            // 2026-06-29 (S9c): when the queue is exhausted (the
            // common case is a single-track play from search or
            // home), fall back to autoplay from the user's
            // recently-played list. We pick the most recent track
            // that isn't the one that just finished and start
            // playback on it. This makes the listening experience
            // continuous without requiring the user to manually
            // queue tracks.
            print("⏭️ End of queue reached — trying autoplay from recently played")
            autoplayNextFromRecentlyPlayed()
        }
    }

    /// 2026-06-29 (S9c): fall back to the user's recently-played
    /// list when the queue is exhausted. Picks the most recent
    /// track that isn't the one that just finished and starts
    /// playback on it. If no candidates are available, leaves the
    /// player in the .paused state on the last track.
    ///
    /// S10: do NOT release the track-transition background task here.
    /// The previous code ended it the instant `play(track:)` returned,
    /// which was BEFORE the new AVPlayer had buffered any audio. In the
    /// background, iOS could then suspend the app while the stream was
    /// still being fetched by yt-dlp. The task is now released in the
    /// `isPlaybackLikelyToKeepUp` observer once the new track is
    /// audibly playing (see setupPlayerObservers).
    private func autoplayNextFromRecentlyPlayed() {
        // S15: this is called from the AVPlayer KVO observer
        // (`isPlaybackLikelyToKeepUp` on a background queue) via
        // `handleTrackCompletion` -> `nextTrack`. Everything inside
        // mutates @Published properties on `dataManager`,
        // `currentItem`, etc. SwiftUI requires those mutations to
        // happen on the main thread, otherwise the runtime emits
        // 'Publishing changes from background threads is not
        // allowed' warnings and views can render inconsistent
        // state. Hop to main before reading or writing any UI
        // state.
        DispatchQueue.main.async { [weak self] in
            self?._autoplayNextFromRecentlyPlayedOnMain()
        }
    }

    private func _autoplayNextFromRecentlyPlayedOnMain() {
        let justPlayedId = currentItem?.track.videoId
        let candidates = dataManager.recentlyPlayed
            .filter { $0.videoId != justPlayedId }
            .compactMap { $0.toTrack }

        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "S10: autoplayNextFromRecentlyPlayed candidates=\(candidates.count)")
        #endif
        print("⏭️ S10: autoplay candidates=\(candidates.count) justPlayed=\(justPlayedId ?? "nil")")

        guard let nextTrack = candidates.first else {
            print("⏭️ No recently-played candidates; staying on last track")
            // No next track — release the background task so we don't
            // hold it forever.
            endTrackTransitionBackgroundTask()
            return
        }

        print("⏭️ S10: Autoplaying next: \(nextTrack.title)")
        play(track: nextTrack)
        // Note: background task is released in setupPlayerObservers'
        // isPlaybackLikelyToKeepUp observer when the new track is
        // actually playing.
    }
    
    private func performCrossfadeToNextItem(_ item: QueueItem, at index: Int) {
        print("🔊 Performing crossfade to: \(item.track.title)")

        // CRITICAL FIX: Set expectedDuration BEFORE updating UI so progress calculations use correct duration
        updateExpectedDuration(Double(item.track.durationSeconds))
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

            // QW-13 fix: re-install the visualizer tap on the new player
            // item. installTap is only called in play(item:), so after a
            // crossfade the visualizer + haptic symphony engine would read
            // silent buffers for the new track.
            if let newItem = self.player?.currentItem {
                AudioVisualizerEngine.shared.installTap(on: newItem)
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

    /// S3-5: Append upcoming tracks to the AVQueuePlayer so it can chain
    /// them seamlessly. We append from currentIndex+1 forward, but stop
    /// early if the user has `repeatMode == .one` (in which case the same
    /// item would loop — no need to queue anything).
    private func enqueueUpcomingItemsForGapless() {
        guard let queuePlayer = player as? AVQueuePlayer else { return }
        guard repeatMode != .one else {
            print("🔊 Gapless: repeat-one, not enqueueing more items")
            return
        }

        // Walk forward from the next index, taking into account repeat-all
        // (which wraps the queue back to the start).
        let queueCount = queue.count
        guard queueCount > 1 else { return }

        let lookAhead = min(3, queueCount - 1)  // Pre-queue up to 3 tracks to limit memory
        for offset in 1...lookAhead {
            let nextIdx: Int
            if repeatMode == .all {
                nextIdx = (currentIndex + offset) % queueCount
            } else {
                nextIdx = currentIndex + offset
                if nextIdx >= queueCount { break }
            }

            let nextItem = queue[nextIdx]
            guard let url = URL(string: nextItem.streamUrl) else { continue }

            let nextPlayerItem = AVPlayerItem(url: url)
            nextPlayerItem.preferredForwardBufferDuration = 5
            nextPlayerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            queuePlayer.insert(nextPlayerItem, after: queuePlayer.items().last)
            print("🔊 Gapless: pre-queued [\(nextIdx)] \(nextItem.track.title)")
        }
    }

    /// S3-5: After AVQueuePlayer auto-advances to the next item, sync
    /// PlayerState's currentIndex/currentItem with the new current item.
    /// Called from the .AVPlayerItemDidPlayToEndTime notification handler
    /// when gapless mode is on.
    private func advanceGaplessState() {
        guard let queuePlayer = player as? AVQueuePlayer else { return }
        guard let nowPlaying = queuePlayer.currentItem,
              let matchIdx = queue.firstIndex(where: { $0.track.videoId == trackIdentifier(for: nowPlaying) }) else {
            return
        }
        currentIndex = matchIdx
        if matchIdx < queue.count {
            currentItem = queue[matchIdx]
            dataManager.addToRecentlyPlayed(currentItem!.track)
            NotificationCenter.default.post(name: .trackPlayed, object: nil)
            // S11 fix (Bug 2): refresh Lock Screen / Control Center
            // immediately on gapless auto-advance. Without this the
            // system Now Playing kept showing the previous track
            // until the next duration-publisher tick (1-3s for HTTP
            // streams).
            let item = queue[matchIdx]
            NowPlayingService.shared.updateNowPlaying(
                track: item.track,
                duration: Double(item.track.durationSeconds),
                currentTime: 0,
                isPlaying: playbackState.isPlaying,
                playbackRate: playbackRate
            )
        }
        // Re-enqueue so we always have a few items in the queue player.
        enqueueUpcomingItemsForGapless()
    }

    /// Best-effort: match an AVPlayerItem back to a videoId by inspecting
    /// the URL path (we used AVPlayerItem(url:) so the videoId is encoded
    /// in the URL — for streams, it's the path component after /proxy-stream/).
    private func trackIdentifier(for playerItem: AVPlayerItem) -> String? {
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
            // Sprint 3 / S3-1 fix: smart shuffle — avoid tracks played in the
            // last 50 plays. Pull the recent videoIds from DataManager's
            // recentlyPlayed list (UserDefaults-backed, kept in sync with
            // CDPlayHistory for stats). Tracks that have been played recently
            // are pushed to the end of the shuffled order rather than
            // appearing early. Without this, shuffle feels like a random
            // rewind of "stuff you just heard".
            let recentVideoIds: Set<String> = Set(
                dataManager.recentlyPlayed.prefix(50).map { $0.videoId }
            )

            if currentIndex < queue.count - 1 {
                let current = queue[currentIndex]
                var remaining = Array(queue[(currentIndex + 1)...])
                // Partition: fresh first, recent last
                let fresh = remaining.filter { !recentVideoIds.contains($0.track.videoId) }
                let recent = remaining.filter { recentVideoIds.contains($0.track.videoId) }
                print("🔀 Smart shuffle: \(fresh.count) fresh + \(recent.count) recent (last 50 played)")
                queue = Array(queue[...currentIndex]) + fresh.shuffled() + recent.shuffled()
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
        // S3-4: apply Replay Gain multiplier on top of user volume
        applyVolume()
    }

    /// S3-4: Apply user volume × Replay Gain linear multiplier to the player.
    /// Centralized so every place that touches player.volume uses the
    /// same gain model and Replay Gain can be toggled at runtime without
    /// a code change at each call site.
    private func applyVolume() {
        player?.volume = Float(volume) * currentReplayGainLinear
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
                    // Defer showing .playing until audio is actually ready.
                    if self?.playbackState == .loading {
                        self?.playbackState = .playing
                    }
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
                            // C-3 fix: surface the error to the user with a
                            // longer pause before auto-skip so they have a
                            // chance to read the message and tap retry. The
                            // original 1.0s skip was too short to even see
                            // the error in the previous silent flow.
                            self?.playbackState = .error("Playback failed, skipping...")
                            ErrorHandler.shared.show(
                                .playbackFailed("Couldn't play this track after multiple attempts. Skipping to the next one."),
                                retry: { [weak self] in
                                    self?.refreshAndPlayCurrentItem()
                                }
                            )
                            // S11 fix (Bug 4): end the BG task we acquired
                            // (via Trigger A or Trigger B) so it doesn't
                            // leak for the 2.5s wait. The nextTrack()
                            // dispatch below will re-acquire via
                            // nextTrack's beginTrackTransitionBackgroundTask().
                            self?.endTrackTransitionBackgroundTask()
                            self?.clearCompletionFlag()
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
            .store(in: &cancellables)
        
        // Note: Asset loading observation removed - using standard URL initialization
        
        // Time observer for progress updates
        // C-2026-06-28: 1.0s instead of 0.5s. The lock screen / Control
        // Center / scrubber all display in 1s increments (the iOS Music
        // app's periodic time observer also runs at 1s). Going to 0.5s
        // doubled the @Published churn on PlaybackClock and starved
        // the main thread — UI taps were lost because SwiftUI never
        // got a turn to dispatch them. 1s is the precision floor the
        // user can perceive.
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updateProgress()
        }
        
        // Observe item duration
        player.currentItem?.publisher(for: \.duration)
            .compactMap { $0.seconds > 0 ? $0.seconds : nil }
            // C-2026-06-28: for HTTP streams the duration publisher emits
            // many times in rapid succession as the server resolves
            // chunks. Each call to updateRemoteControls() runs the full
            // updateNowPlaying pipeline (MPNowPlayingInfoCenter write +
            // 5 widget reloads + SharedNowPlayingState JSON encode).
            // On a saturated main thread this exhausts the 5-second
            // gesture gate and iOS SIGKILLs the process.
            //
            // Fix: only call updateRemoteControls() when the duration
            // changes by more than 1 second, and skip calls that would
            // be redundant with the existing updatePlaybackTime path.
            // The per-second scrubber ticks still drive updatePlaybackTime.
            .removeDuplicates(by: { abs($0 - $1) < 1.0 })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                print("🔊 Duration updated: \(duration)")
                self?.duration = duration
                // Update Now Playing info with the new duration
                self?.updateRemoteControls()
            }
            .store(in: &cancellables)
        
        // Observe playback end
        // C-2 fix: token-based observer. We scope to the specific item so
        // old observers don't fire on a new player after a track change.
        if let item = player.currentItem {
            playerItemObserverTokens.append(
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    self?.playerDidFinishPlaying()
                }
            )

            // Observe playback failure mid-track
            playerItemObserverTokens.append(
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] notification in
                    self?.playerFailedToPlayToEndTime(notification)
                }
            )

            // Observe playback stall
            playerItemObserverTokens.append(
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemPlaybackStalled,
                    object: item,
                    queue: .main
                ) { [weak self] notification in
                    self?.playerPlaybackStalled(notification)
                }
            )
        }

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
                    } else if self.playbackState == .loading {
                        self.playbackState = .playing
                        // S10: the new track has buffered enough to start
                        // producing audio. It's now safe to release the
                        // 30-second background task we acquired in
                        // nextTrack / playerDidFinishPlaying — the audio
                        // session's "audio" background mode keeps the app
                        // alive on its own. Releasing earlier meant we
                        // could be suspended before any audio flowed,
                        // especially in the background after autoplay.
                        self.endTrackTransitionBackgroundTask()
                        print("🔓 S10: BG task released — new track is playing")
                        // S11 fix (Bug 14): pair with the flag reset.
                        // The handleTrackCompletion defer scheduled a
                        // 5s safety timeout; we can clear that and the
                        // isHandlingCompletion flag right now since the
                        // new track is confirmed playing.
                        self.clearCompletionFlag()
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
        // C-2 fix: only remove the player-item-scoped observers, not all
        // observers. Audio session observers (interruption / route change /
        // media services reset) must remain registered for the lifetime of
        // the PlayerState singleton, otherwise phone calls / AirPods
        // disconnect / Siri would stop pausing playback after a content-type
        // switch.
        playerItemObserverTokens.forEach { NotificationCenter.default.removeObserver($0) }
        playerItemObserverTokens.removeAll()
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

        // Sprint 2 / C-4 fix: write to PlaybackClock only. The legacy
        // `currentTime` / `duration` / `progress` @Published properties
        // were mirrored here, but that forced every view observing
        // PlayerState (MiniPlayer, LyricsView, etc.) to re-render every
        // tick. MiniPlayer now reads from `playbackClock` directly.
        // LyricsView polls via its own timer. The legacy @Published
        // mirrors remain as a debug affordance but are no longer
        // updated on the hot path.
        let effectiveTotal = effectiveDuration > 0 ? effectiveDuration : total
        _ = playbackClock.tick(currentSeconds: current, totalSeconds: total, effectiveDuration: effectiveTotal)

        // Update Now Playing info periodically (every ~1 second)
        if progressLogCounter % 2 == 0 {
            NowPlayingService.shared.updatePlaybackTime(
                currentTime: current,
                isPlaying: playbackState.isPlaying,
                playbackRate: playbackRate
            )
        }

        // Use effective duration (from track metadata) for progress calculation
        if progressLogCounter == 0 {  // Log every 5 seconds
            print("🎵 updateProgress: current=\(current), total=\(total), expectedDuration=\(expectedDuration), effectiveTotal=\(effectiveTotal)")
        }
        if effectiveTotal > 0 {
            // C-2026-06-28: progress is computed from PlaybackClock now;
            // this function does not write to `progress` on PlayerState
            // (it would force every view observing PlayerState to
            // re-render every tick — including the rest of the Home
            // tab). Views that need it should read `playbackClock.progress`.
            let newProgress = current / effectiveTotal

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
                // S11 fix (Bug 3): Trigger B (1s polling) was not
                // beginning the BG task like Trigger A did. In an
                // edge case where the polling fires first, completion
                // proceeded without any background-task protection.
                beginTrackTransitionBackgroundTask()
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
        // S11 fix (Bug 5): podcasts don't auto-advance to unrelated
        // recently-played music. Stop playback and surface end of
        // episode so the user can pick the next episode manually.
        if contentType == .podcastEpisode {
            print("🎙 [S11] Podcast episode ended — stopping (no auto-advance to music)")
            NowPlayingService.shared.clearNowPlaying()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.player?.pause()
                self.playbackState = .paused
                ErrorHandler.shared.show(
                    .playbackFailed("Episode ended. Pick another episode to keep listening.")
                )
                self.endTrackTransitionBackgroundTask()
                self.clearCompletionFlag()
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
                // C-3 fix: surface mid-track playback failure to the user.
                ErrorHandler.shared.show(
                    .playbackFailed("This track stopped playing. Skipping to the next one."),
                    retry: { [weak self] in
                        self?.refreshAndPlayCurrentItem()
                    }
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.nextTrack()
                }
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

        // S11 fix (Bug 14): extend the auto-reset from 0.5s to a more
        // generous window tied to the new player's state. The old 0.5s
        // was too short — a slow-buffering autoplay track combined
        // with the S10 "BG task waits for isPlaybackLikelyToKeepUp"
        // release could re-fire completion before the new track had
        // settled. Now: reset when the new player's playbackState
        // transitions out of .loading OR after a 5s safety timeout.
        defer {
            DispatchQueue.main.async { [weak self] in
                // Reset will happen either via the observer in
                // play(item:) setup (when .loading -> .playing flips)
                // OR via this 5s safety timeout, whichever comes first.
                self?.scheduleCompletionFlagReset(after: 5.0)
            }
        }

        // S10 diagnostic: log entry so we can confirm the autoplay path
        // fires from the background-track-transition flow.
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "S10: handleTrackCompletion ENTRY contentType=\(contentType) queue.count=\(queue.count) currentIndex=\(currentIndex) gapless=\(CrossfadeManager.shared.gaplessEnabled) videoId=\(currentItem?.track.videoId ?? "nil")")
        #endif
        print("🏁 S10: handleTrackCompletion ENTRY contentType=\(contentType) queue.count=\(queue.count) currentIndex=\(currentIndex) gapless=\(CrossfadeManager.shared.gaplessEnabled)")

        // S10: do NOT dispatch a separate pause() here. The
        // .AVPlayerItemDidPlayToEndTime notification only fires when
        // AVPlayer has already auto-paused on the finished item, and
        // `stop()` inside play(item:) replaces the item with nil as
        // part of swapping in the new player. A separate pause dispatch
        // creates an audio gap between the old and new players; in the
        // background this gap is exactly when iOS suspends the app
        // before the new player can take over.

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

        // S3-5: Gapless mode short-circuit. When the player is an
        // AVQueuePlayer, AVFoundation has ALREADY auto-advanced to the
        // next item by the time we get here. We just need to sync
        // PlayerState's currentIndex / currentItem and re-enqueue
        // upcoming items. Going through nextTrack() would re-create a
        // player, which is the opposite of what we want.
        if CrossfadeManager.shared.gaplessEnabled, player is AVQueuePlayer {
            print("🔊 Gapless: AVQueuePlayer auto-advanced; syncing state")
            DispatchQueue.main.async { [weak self] in
                self?.advanceGaplessState()
                self?.endTrackTransitionBackgroundTask()
            }
            return
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
