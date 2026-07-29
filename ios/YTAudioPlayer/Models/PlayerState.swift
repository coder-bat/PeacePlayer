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
        // S15: the backend's stream_cache uses a 3.5h TTL
        // (YouTube URLs typically last 4-6h, the backend takes the
        // conservative middle). The iOS check used to be 4h, so
        // an iOS-considered-fresh URL could actually be expired on
        // the backend, and `play(item:)` (which used to skip the
        // check entirely) would leave the player in `.loading`
        // forever. Align to 3h — comfortably under the backend TTL
        // — and call the check from both `playQueue(at:)` and
        // `play(item:)`.
        Date().timeIntervalSince(createdAt) > 3 * 60 * 60 // 3 hours
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
    /// S17-H: set by `nextTrack(userSkipped: true)` (and other
    /// user-initiated skip paths) so the in-flight
    /// `.AVPlayerItemDidPlayToEndTime` auto-advance can be
    /// recognized and skipped. Without this, a user tapping Next
    /// in the last 0.5s of a track races with the auto-advance:
    /// the user's tap advances to N+1 on the main thread, then
    /// the queued completion handler dispatches and advances to
    /// N+2, skipping a track the user wanted to hear. The flag
    /// is cleared in `play(item:)` once the new track is
    /// committed.
    private var userSkippedPendingCompletion = false
    
    /// Playback queue. S17-G (perf 10 P0-F1): backed by `queueStore`
    /// so that queue mutations don't fire `PlayerState.objectWillChange`
    /// and re-render every observer (MiniPlayer, FullPlayer, etc.).
    /// Views that display the queue observe the store directly; the
    /// `queue` getter is a thin pass-through for read-side compat.
    var queue: [QueueItem] { queueStore.items }

    /// Current track index in queue. Backed by the store.
    var currentIndex: Int { queueStore.currentIndex }

    /// S17-G: the queue lives in a separate observable so mutations
    /// don't fan out to every PlayerState observer. The store is
    /// `let` because the lifetime is tied to PlayerState (singleton).
    /// PlayerState mirrors `currentItem` from the store via a
    /// Combine subscription in `init`, so observers that care about
    /// the current item (MiniPlayer) still re-render when it changes.
    let queueStore = QueueStore()
    
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

    /// S17-H (P1-FF6 follow-up): lifetime subscriptions that must
    /// survive `stop()` and `setupPlayerObservers()`. The mirror
    /// from `queueStore` into `currentItem` is the prime example:
    /// `stop()` does `cancellables.removeAll()` to drop the old
    /// player observers, and `setupPlayerObservers()` repeats the
    /// clear as a defensive idempotency guard. The mirror was set
    /// up in `init` and previously lived in the same set, so it
    /// was killed on the first `stop()` and never came back. The
    /// `currentItem` value was still set explicitly in
    /// `play(item:)` so the UI looked correct for the immediate
    /// tap, but a later `restoreQueue` / QueuePrefetcher change
    /// would no longer propagate to `currentItem` (the store
    /// would mutate, PlayerState wouldn't react). Storing the
    /// mirror here means it lives for the lifetime of the
    /// singleton — exactly what we want.
    private var lifetimeCancellables = Set<AnyCancellable>()
    private var retryCount = 0
    private let maxRetries = 2
    private var originalQueue: [QueueItem] = []
    private var dataManager = DataManager.shared
    // S17-H / Tier 4: listening-time accounting is now owned by
    // `ListeningTimeTracker`. The tracker encapsulates the
    // accumulator, the last-tick timestamp, the 5s max-tick-delta
    // guard, the 10s save cadence, and the `player.rate > 0`
    // ground-truth check. PlayerState just pushes ticks to it from
    // the time observer and calls `reset()` / `flush()` on track
    // boundaries.
    private let listeningTimeTracker = ListeningTimeTracker()

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
    // S16: audio-session observer tokens moved to AudioSessionController.
    // The 3 session notifications (interruption / route change / media
    // services reset) now live in the controller. The player-item
    // observers below are unrelated to the audio session.
    private var playerItemObserverTokens: [NSObjectProtocol] = []
    private var memoryWarningToken: NSObjectProtocol?

    /// S16: extracted audio-session lifecycle (master plan §8.1 focused
    /// split). Owns AVAudioSession config + the 3 session notification
    /// observers; routes 2 callback points back to PlayerState.
    private let audioSessionController = AudioSessionController()

    // Adaptive quality switching
    private var qualityUpgradeTimer: Timer?
    private var isAdaptiveQualityEnabled = true
    private var hasUpgradedQuality = false

    // Memory management
    private let maxQueueSize = 100
    private let trimQueueToSize = 50
    private let maxItemAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    /// S17-H: prev-press within this window of the current
    /// track's start restarts the current track (seek to 0)
    /// instead of going to the previous index. Matches Apple
    /// Music / Spotify UX.
    private let previousTrackRestartGracePeriod: TimeInterval = 3
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
        // S16: audio-session setup is delegated to the controller.
        // The controller configures the category, registers the
        // 3 notification observers, and exposes an `activate()`
        // method that's called from the first `play(track:)`.
        // S15 already moved `setActive(true)` off init; the
        // controller preserves that fix.
        audioSessionController.onInterruptionShouldResume = { [weak self] in
            self?.resumeFromInterruption()
        }
        audioSessionController.onMediaServicesReset = { [weak self] in
            self?.handleMediaServicesResetRestart()
        }
        // S17-H: pause on headphone unplug. AudioSessionController
        // fires this from the routeChange handler when the
        // previous output device went away. Without this, audio
        // would keep playing through the device speaker after
        // headphones are disconnected.
        audioSessionController.onRouteChangeShouldPause = { [weak self] in
            self?.pause()
        }
        // S17-H: flip playbackState to .paused when a phone call /
        // Siri / alarm starts. The AVPlayer auto-pauses, but the
        // derived playbackState doesn't update until something
        // calls pause() explicitly. Without this, the UI shows
        // "playing" with no audio during the call.
        audioSessionController.onInterruptionBegan = { [weak self] in
            self?.playbackState = .paused
        }
        audioSessionController.setup()

        // S17-G: mirror `currentItem` from the store. The store is
        // the source of truth; PlayerState keeps a stored
        // @Published `currentItem` so observers (MiniPlayer, the
        // FullPlayer chrome) re-render when the current track
        // changes. We update it only when the resolved value
        // actually changes (removeDuplicates on the combined
        // publisher) so unrelated queue mutations (add/remove
        // a non-current track) don't fire PlayerState.objectWillChange.
        //
        // S17-H (P1-FF6 follow-up): store the mirror in
        // `lifetimeCancellables` instead of `cancellables`. The
        // `cancellables` set is cleared by `stop()` and by
        // `setupPlayerObservers()`; if the mirror lived there it
        // would die on the first `stop()` and never come back. The
        // explicit `currentItem = item` in `play(item:)` masked the
        // symptom for the immediate tap, but a subsequent
        // `restoreQueue` / QueuePrefetcher add would not
        // propagate to `currentItem` (the store would mutate,
        // PlayerState wouldn't react). Storing the mirror here
        // gives it the same lifetime as the PlayerState singleton.
        queueStore.$items
            .combineLatest(queueStore.$currentIndex)
            .map { items, index -> QueueItem? in
                guard index >= 0, index < items.count else { return nil }
                return items[index]
            }
            .removeDuplicates { $0?.track.videoId == $1?.track.videoId }
            .sink { [weak self] newItem in
                self?.currentItem = newItem
            }
            .store(in: &lifetimeCancellables)

        // S17-H: re-enqueue upcoming items for the gapless
        // AVQueuePlayer whenever the queue changes. The first-track-
        // after-launch case is the obvious one — `play(item:)`
        // creates the AVQueuePlayer with only the current track
        // (queue count = 1) so the initial `enqueueUpcomingItemsForGapless`
        // bails on its `guard queueCount > 1`. Then
        // `QueuePrefetcher.autoPopulateQueue` populates the queue
        // a few hundred ms later via async `addToQueue` calls, but
        // by then `play(item:)` has already moved on. Without this
        // subscription, the first track ends, the AVQueuePlayer
        // has no next item, and the auto-advance path is the
        // clunky one (rebuild via `advanceGaplessState`).
        //
        // The debounce coalesces bursts from the prefetcher (which
        // may add 5+ tracks within a few hundred ms). The
        // `lifetimeCancellables` set survives `stop()` /
        // `setupPlayerObservers` so this subscription persists
        // across the player-observation churn.
        queueStore.$items
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                guard CrossfadeManager.shared.gaplessEnabled,
                      self.player is AVQueuePlayer else { return }
                self.enqueueUpcomingItemsForGapless()
            }
            .store(in: &lifetimeCancellables)

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
            // S17-G: currentIndex moved to QueueStore. Subscribe
            // to the store's $currentIndex so the snapshot still
            // updates on index changes.
            self.queueStore.$currentIndex.map { _ in () }.eraseToAnyPublisher(),
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

    /// S17-H (perf 10 P1-F5): tracks whether the user has touched
    /// playback before `restoreQueue` completed. The restore fires
    /// N HTTP calls in parallel (PlaybackQueueManager.restoreQueue),
    /// which on a large saved queue can take several seconds. The
    /// previous code unconditionally overwrote whatever the user
    /// did in that window — so tapping a track first and then
    /// having the saved queue clobber it was a real bug, not just
    /// a perf issue.
    private var hasUserTouchedPlayback = false

    private func restoreQueue() {
        // Use PlaybackQueueManager to restore queue with fresh stream URLs
        PlaybackQueueManager.shared.restoreQueue { [weak self] items in
            guard let self = self, !items.isEmpty else { return }

            DispatchQueue.main.async {
                // S17-H (P1-F5): if the user has already started
                // playing, the restore would clobber their choice.
                // Skip the restore in that case — the saved queue
                // is "stale" by definition once the user has made
                // a decision.
                if self.hasUserTouchedPlayback {
                    print("📱 Skipping queue restore — user has already started playing")
                    return
                }

                // S17-G: forward to the store. The store handles
                // the index clamping via setCurrentIndex.
                self.queueStore.replace(with: items)
                let savedIndex = PlaybackQueueManager.shared.getSavedCurrentIndex()
                self.queueStore.setCurrentIndex(savedIndex)

                let currentIndex = self.queueStore.currentIndex
                print("📱 Restored queue with \(items.count) items, current index: \(currentIndex)")

                // Restore the current item without auto-playing.
                // The mirror subscription will also set currentItem,
                // but we do it here to call updateExpectedDuration
                // synchronously (the mirror fires on the next runloop).
                if currentIndex >= 0, currentIndex < items.count {
                    let item = items[currentIndex]
                    self.updateExpectedDuration(Double(item.track.durationSeconds))
                }
            }
        }
    }

    /// S17-H (P1-F5): called by any user-initiated playback entry
    /// point (play track, play queue at index, add to queue, add
    /// to queue next, restore-and-resume). Marks the queue as
    /// "user has decided" so a still-in-flight restoreQueue won't
    /// clobber it.
    private func markUserTouchedPlayback() {
        hasUserTouchedPlayback = true
    }

    // S11 fix (Bug 16): removed dead `restorePlaybackState()` method.
    // It was never invoked anywhere. The lastPlaybackProgress resume
    // functionality is now handled by `HomeViewModel.playTrack(_:seekToProgress:)`
    // reading `dataManager.recentlyPlayed.first?.playbackProgress`
    // directly when the user taps the resume hero on Home.

    // MARK: - Audio Session Callbacks
    //
    // S16: the audio-session lifecycle (category, activation, 3
    // notification observers) moved to `AudioSessionController`.
    // These two methods are the only callbacks that route back
    // into PlayerState. Both are called on the main queue.

    /// Called by AudioSessionController after an interruption ends
    /// with `.shouldResume`. The controller has already re-activated
    /// the session; we just need to resume the AVPlayer.
    private func resumeFromInterruption() {
        // S17-H: use playImmediately(atRate:) instead of
        // play() + rate=playbackRate. The two-call sequence has a
        // 1-frame window where the player runs at 1.0x (from
        // play()) before snapping to playbackRate, audible as a
        // pop/glitch on resume if the user had set 1.5x. The S17-E
        // fix for this race was already applied in
        // performSeamlessQualitySwitch but never propagated here.
        // playImmediately(atRate:) sets rate and starts in the
        // same call.
        if let player = player {
            player.playImmediately(atRate: Float(playbackRate))
        }
    }

    /// Called by AudioSessionController 0.5s after a media-services
    /// reset. The controller has already re-applied the category
    /// and re-activated the session. We need to rebuild the
    /// current AVPlayerItem by re-entering `play(item:)`.
    private func handleMediaServicesResetRestart() {
        if let current = currentItem {
            play(item: current, addToQueue: false)
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

    /// S17-H follow-up: shared helper for the AVFoundation case
    /// arms. Pulls the userInfo bits that AVPlayer actually
    /// populates (NSLocalizedDescription, NSUnderlyingError) and
    /// returns a short joined string for the toast. Kept separate
    /// from `describeAVPlayerError` so every AVFoundation case
    /// (known and unknown) can surface the same diagnostic detail.
    private static func describeAVPlayerUserInfo(_ error: NSError) -> String {
        let desc = error.userInfo[NSLocalizedDescriptionKey] as? String
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain) \($0.code)" }
        var parts: [String] = []
        if let d = desc, !d.isEmpty, d != "The operation couldn't be completed." {
            parts.append(d)
        }
        if let u = underlying {
            parts.append("underlying: \(u)")
        }
        return parts.isEmpty ? "no detail" : parts.joined(separator: " · ")
    }

    /// S17-H: turn an AVPlayer / NSURLError into a one-line
    /// human-readable description for the playback-failed toast.
    /// Without this the toast said "Couldn't play this track after
    /// multiple attempts" for every kind of failure, and the user
    /// couldn't tell a transient timeout from a 500 from a 401
    /// from "track not streamable". The most common domains /
    /// codes are mapped to plain English; everything else falls
    /// through to the localized description. For the catch-all
    /// AVError.unknown (-11829) we also surface a few of the
    /// userInfo keys AVPlayer does populate, since that's the
    /// case users see most often.
    private static func describeAVPlayerError(_ error: NSError) -> String {
        let domain = error.domain
        let code = error.code

        // NSURLErrorDomain: iOS networking layer
        if domain == NSURLErrorDomain {
            switch code {
            case NSURLErrorTimedOut:           return "network timed out"
            case NSURLErrorCannotFindHost:     return "can't find backend"
            case NSURLErrorCannotConnectToHost:return "can't reach backend"
            case NSURLErrorNetworkConnectionLost: return "network connection lost"
            case NSURLErrorNotConnectedToInternet: return "no internet"
            case NSURLErrorBadServerResponse:  return "backend returned bad response"
            case NSURLErrorCannotDecodeRawData:return "can't decode audio data"
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return "backend requires HTTPS"
            default:
                return "network error \(code)"
            }
        }

        // AVFoundationErrorDomain: AVPlayer / AVPlayerItem layer
        if domain == AVFoundationErrorDomain {
            switch code {
            case AVError.unknown.rawValue:
                // -11829 is the catch-all "AVPlayer failed for some
                // unspecified reason" — pull the userInfo keys that
                // AVPlayer does populate (NSLocalizedDescription,
                // NSUnderlyingError, AVFoundationErrorPresentationErrorDataKey,
                // sometimes a track-time / status dump). Without
                // this the toast just says "AVPlayer unknown error"
                // and we can't tell whether it was a 416, a corrupt
                // response, a missing range, etc.
                let desc = error.userInfo[NSLocalizedDescriptionKey] as? String
                let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain) \($0.code)" }
                var parts: [String] = []
                if let d = desc, !d.isEmpty, d != "The operation couldn't be completed." {
                    parts.append(d)
                }
                if let u = underlying {
                    parts.append("underlying: \(u)")
                }
                if parts.isEmpty {
                    return "AVPlayer unknown error -11829"
                }
                return "AVPlayer: " + parts.joined(separator: " · ")
            case AVError.fileFormatNotRecognized.rawValue:
                // -11828: AVPlayer can't decode the audio file
                // format. With YouTube this typically means the
                // m4a URL we handed back is actually a DASH
                // manifest (ftyp dash) rather than regular audio
                // MP4. The backend's /stream now prefers webm/Opus
                // to avoid this; if it still happens, fall through
                // to userInfo for the actual NSLocalizedDescription.
                return "format not supported by iOS: " + Self.describeAVPlayerUserInfo(error)
            case AVError.serverIncorrectlyConfigured.rawValue:
                return "AVPlayer server misconfigured"
            case AVError.formatUnsupported.rawValue:
                return "audio format not supported"
            case AVError.contentKeyRequestCancelled.rawValue:
                return "track key request cancelled"
            case AVError.operationNotSupportedForAsset.rawValue:
                return "operation not supported for this track"
            default:
                // Any other AVFoundation error — include userInfo
                // so the user (and us) can see what AVPlayer
                // actually said instead of just the code.
                return "AVPlayer \(code): " + Self.describeAVPlayerUserInfo(error)
            }
        }

        // NSOSStatusErrorDomain: low-level CoreAudio / HTTP errors
        if domain == NSOSStatusErrorDomain {
            return "system audio error \(code)"
        }

        // Fall back to the localized description (AVPlayer often
        // provides a useful one like "The operation couldn't be
        // completed" with extra in userInfo).
        let localized = error.localizedDescription
        if !localized.isEmpty && localized != "The operation couldn't be completed." {
            return "\(domain) \(code): \(localized)"
        }
        return "\(domain) \(code)"
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
        // S17-H (P1-F5): mark the queue as user-touched so an
        // in-flight restoreQueue won't clobber the user's choice.
        markUserTouchedPlayback()
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(track:) ENTRY videoId=\(track.videoId) title=\(track.title) currentItem.videoId=\(currentItem?.track.videoId ?? "nil") playbackState=\(playbackState)")
        #endif
        // S15: activate the audio session on the first play call.
        // Idempotent; the session stays active for subsequent plays
        // and through pause/resume cycles. Doing this here instead
        // of in init means a cold launch with no playback intent
        // doesn't reserve the audio hardware.
        // S16: delegated to the controller.
        audioSessionController.activate()
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
            // S17-H / S17-PLAY (Fix 3A): prefetch the next 3 likely
            // plays so the cold-path transcode rarely runs. Local-file
            // plays don't need a transcode, but the *next* track is
            // almost always a stream — still benefits from prefetch.
            StreamURLCache.shared.prefetchUpNext(
                queue: self.queue,
                currentIndex: self.currentIndex
            )
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
                        // S17-H / S17-PLAY (Fix 3A): prefetch the next 3
                        // likely plays. Wi-Fi gate is inside.
                        // This catches HistoryView.playTrack (which
                        // delegates to play(track:)) in addition to the
                        // direct call sites in HomeView/SearchView/etc.
                        if let self = self {
                            StreamURLCache.shared.prefetchUpNext(
                                queue: self.queue,
                                currentIndex: self.currentIndex
                            )
                        }
                    }
                )
                .store(in: &cancellables)
        }
    }

    func play(item: QueueItem, addToQueue: Bool = true) {
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) ENTRY videoId=\(item.track.videoId) title=\(item.track.title) source=\(item.source) currentItem.videoId=\(currentItem?.track.videoId ?? "nil") playbackState=\(playbackState)")
        #endif

        // S15: check the stream URL for expiry here too. The check
        // used to live only in `playQueue(at:)`, so a queue that
        // was restored from a session hours old (e.g. a track
        // queued the previous evening, played the next morning)
        // would skip the refresh and leave the player in
        // `.loading` forever once the URL had actually expired on
        // the backend. The QueueItem's expiry field is
        // intentionally conservative (3h, under the backend's
        // 3.5h TTL) so we always refresh in time.

        // S17-H: clear the user-skip flag. The new track is
        // about to be committed, so any future auto-advance
        // from `.AVPlayerItemDidPlayToEndTime` belongs to this
        // new track and should run normally.
        userSkippedPendingCompletion = false

        if item.isStreamUrlExpired && item.source == .stream {
            print("▶️ play(item:) URL expired, refreshing before play")
            // Find this item in the queue (if present) and refresh
            // it in place. If it's not in the queue (caller passed a
            // fresh item), fall through to the normal play path —
            // the queue will be appended to via `addToQueue`.
            if let idx = queue.firstIndex(where: { $0.track.videoId == item.track.videoId }) {
                refreshAndPlay(item: item, at: idx)
                return
            }
            // Not in queue: refresh the URL via the cache before
            // playing. The original `play(item:)` will continue
            // and use the refreshed URL via the new `streamUrl`.
        }
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
        //
        // S17-H: route through the controller instead of
        // calling `AVAudioSession.sharedInstance().setActive(true)`
        // directly. The previous code bypassed the controller
        // — both `play(track:)` and `play(item:)` were activating
        // the session via two different paths. Now the
        // controller is the single owner of session activation.
        // `play(track:)` calls `audioSessionController.activate()`
        // upstream, and `play(item:)` does the same. Idempotent
        // — AVAudioSession ignores repeat activations.
        audioSessionController.activate()

        currentItem = item
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) POST-currentItem-set")
        #endif
        // Store expected duration from track metadata
        updateExpectedDuration(Double(item.track.durationSeconds))
        print("🎵 CRITICAL: Set expectedDuration = \(expectedDuration) from track.durationSeconds = \(item.track.durationSeconds)")
        playbackState = .loading

        if addToQueue {
            // S17-G: add to the store (dedup + set currentIndex to
            // the new last item via the store's add + setCurrentIndex).
            queueStore.add(item, maxQueueSize: maxQueueSize)
            if queueStore.items.contains(where: { $0.track.videoId == item.track.videoId }) {
                queueStore.setCurrentIndex(queueStore.items.count - 1)
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
        //
        // S17-H (P1-FF6 follow-up): use `playImmediately(atRate:)` instead of
        // `play() + rate = X`. The two-call pattern has a 1-frame race where
        // the player starts at rate 0 and only ramps to the requested rate
        // on the next runloop tick. The race was already known — S17-E
        // (commit 02c622f) fixed it for `performSeamlessQualitySwitch` —
        // but the fix was never propagated to the main play path. The user
        // reports the mini-player showing the loading icon forever after
        // tapping a recently-played track; the most likely cause is the
        // 1-frame rate-0 race putting the new player in a state where the
        // `isPlaybackLikelyToKeepUp` publisher never fires, so the
        // `playbackState` observer at line 2332 never transitions
        // `.loading` → `.playing`. `playImmediately(atRate:)` is the
        // atomic single-call form AVFoundation now recommends; using it
        // here means the player starts at the correct rate from frame 0.
        print("🔊 Starting playback immediately (fast-start mode)...")
        player?.playImmediately(atRate: playbackRate)
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) POST-playImmediately")
        #endif
        // playbackState stays .loading; observer will flip to .playing when ready.

        // S17-H (P1-FF6 follow-up 2026-07-26): safety timeout.
        // The status + isPlaybackLikelyToKeepUp observers in
        // `setupPlayerObservers` should flip `playbackState` to
        // `.playing` once the AVPlayerItem reports ready / buffered.
        // If neither fires within 15s, the player is stuck
        // (typically: stream URL is unreachable, the audio session
        // failed to reactivate, or the rate-0 race put the player in
        // a weird state). The previous behavior was to spin the
        // loading icon forever with no error — exactly the user
        // report. Now we surface a real error with a retry so the
        // user can recover without killing the app.
        scheduleLoadingStateTimeout(after: 15.0, for: item)

        print("🔊 Auto-populating queue...")
        QueuePrefetcher.shared.autoPopulateQueue(startingFrom: item.track)
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) POST-QueuePrefetcher")
        #endif

        // S17-H: removed the call to the empty
        // `setupRemoteControls()` stub. Remote-command setup is
        // handled by NowPlayingService on every currentItem
        // change (see `updateRemoteControls`). The print and
        // PlayCrashDiagnostics log are also removed since
        // nothing was happening between them.
        updateRemoteControls()
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) POST-updateRemoteControls")
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
        
        // S17-H: reset the listening-time tracker for the new track.
        // The tracker's `reset()` clears the accumulator and sets
        // `lastTick` to now, so the first tick after this point has
        // a ~0s delta (a no-op) instead of the multi-second gap from
        // the previous track.
        listeningTimeTracker.reset()

        // Start adaptive quality timer if enabled
        if isAdaptiveQualityEnabled && item.source == .stream {
            startQualityUpgradeTimer(for: item)
        }

        print("✅ play() completed successfully for: \(item.track.title)")
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) EXIT videoId=\(item.track.videoId)")
        #endif
    }

    // MARK: - Loading state timeout (S17-H follow-up 2026-07-26)

    /// Safety net for the "tapped a track and the loading icon
    /// spins forever" symptom. The status / isPlaybackLikelyToKeepUp
    /// observers in `setupPlayerObservers` should transition
    /// `playbackState` to `.playing` once the AVPlayerItem reports
    /// ready / buffered. If they don't fire within `seconds`, the
    /// player is stuck — typically because:
    ///   - the stream URL is unreachable (Mac asleep, Tailscale
    ///     changed, baseURL override stale)
    ///   - the audio session failed to reactivate and was caught
    ///     silently
    ///   - some other AVPlayerItem init failure that the KVO
    ///     observers didn't surface
    /// We surface a real error with retry so the user can recover
    /// without killing the app.
    private var loadingTimeoutWorkItem: DispatchWorkItem?

    private func scheduleLoadingStateTimeout(after seconds: TimeInterval, for item: QueueItem) {
        loadingTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Only fire if we're still in a loading state for the
            // same track. If the player already started playing
            // (or the user already moved on), the timeout is a
            // no-op.
            guard self.playbackState.isLoading,
                  self.currentItem?.track.videoId == item.track.videoId else {
                return
            }
            print("⏰ [S17-H] Loading-state timeout reached for \(item.track.title) — surfacing error")
            self.playbackState = .error("Playback didn't start")
            ErrorHandler.shared.show(
                .playbackFailed("\"\(item.track.title)\" didn't start playing. The stream may be unreachable — check that your Mac is awake and on the same network, then try again."),
                retry: { [weak self] in
                    self?.play(item: item, addToQueue: false)
                }
            )
        }
        loadingTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
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
            // S17-E: `player.play()` followed by `player.rate = 1.0`
            // has a 1-frame race where the player starts at rate 0
            // and only ramps to 1.0 on the next runloop tick — the
            // user can hear the gap. `playImmediately(atRate:)` is
            // the atomic single-call form that AVFoundation now
            // recommends. (CrossfadeManager already uses it.)
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
            self.currentItem = upgradedItem

            // Update queue
            // S17-G: `queue` is now a computed property backed by
            // the store. To replace one element, rebuild the
            // array and use the store's `replace(with:)`.
            if self.currentIndex < self.queueStore.items.count {
                var updatedItems = self.queueStore.items
                updatedItems[self.currentIndex] = upgradedItem
                self.queueStore.replace(with: updatedItems)
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
        // S17-H (P1-F5): see play(track:).
        markUserTouchedPlayback()
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
            // S17-G: set currentIndex via the store. The mirror
            // subscription will update `currentItem` from the new
            // index.
            queueStore.setCurrentIndex(index)
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
                    // S17-G: rebuild the queue with the refreshed item
                    // and replace via the store. `queue[index] = X` is
                    // a no-op on the computed property.
                    var updatedItems = self.queueStore.items
                    if updatedItems.indices.contains(index) {
                        updatedItems[index] = refreshedItem
                        self.queueStore.replace(with: updatedItems)
                    }

                    print("▶️ URL refreshed, playing...")
                    self.queueStore.setCurrentIndex(index)
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
                    // S17-G: rebuild via the store. `queue[...]` is
                    // a no-op on the computed property.
                    self.currentItem = refreshedItem
                    if self.currentIndex < self.queueStore.items.count {
                        var updatedItems = self.queueStore.items
                        updatedItems[self.currentIndex] = refreshedItem
                        self.queueStore.replace(with: updatedItems)
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
        // S17-H follow-up: cancel the loading-state timeout (if any)
        // before tearing down. Otherwise a 15s timer could fire after
        // the player is already gone and surface a spurious error.
        loadingTimeoutWorkItem?.cancel()
        loadingTimeoutWorkItem = nil

        // S17-H: end the track-transition BG task if one is held.
        // Otherwise a BG task acquired by an in-flight nextTrack /
        // autoplay (held until isPlaybackLikelyToKeepUp fires on the
        // new track) would be orphaned when the user navigates away
        // or switches content type mid-transition. The 30s OS
        // timeout would eventually release it, but in the meantime
        // iOS could background-suspend the app before the new track
        // had a chance to start.
        endTrackTransitionBackgroundTask()

        player?.pause()
        // S17-H: remove the time observer and the .AVPlayerItem*
        // notification tokens BEFORE replacing the current item
        // with nil. The previous order (replace first, then
        // removeTimeObserver) left the .AVPlayerItemDidPlayToEndTime
        // observer registered while the item was being dealloc'd,
        // and a KVO update on the old item could fire one last
        // time into the soon-to-be-removed observer. The fix
        // matches C-2 (observer token teardown before item
        // teardown) and means no spurious callbacks can fire
        // after the player is gone.
        removeTimeObserver()
        player?.replaceCurrentItem(with: nil)

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

        // S16: audio-session observers live in AudioSessionController
        // for the lifetime of the app. No need to re-register here
        // — the controller's setup() already ran in init.

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
        // S17-H: release the BG task if a track-transition is
        // mid-flight. Without this, a queued nextTrack/autoplay
        // BG task would be orphaned when the user switches from a
        // track to a radio station.
        endTrackTransitionBackgroundTask()
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
        // S17-H: see playRadioStation — release BG task on
        // content-type switch.
        endTrackTransitionBackgroundTask()
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
        // S17-H: see playRadioStation — release BG task on
        // content-type switch.
        endTrackTransitionBackgroundTask()
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
        // S17-H (P1-F5): see play(track:).
        markUserTouchedPlayback()
        // S17-G: forward to the store. Dedup + trim happen inside
        // the store. The store fires its own objectWillChange; only
        // views observing the store re-render.
        // S17-H: removed `dataManager.saveQueue(queue)` — the
        // JSON path was never read by the restore flow
        // (PlaybackQueueManager/CoreData is the source of truth)
        // and was duplicating writes. The CoreData subscription
        // in PlaybackQueueManager.startObservingPlayerStateIfNeeded
        // handles persistence.
        queueStore.add(item, maxQueueSize: maxQueueSize)
    }

    func addToQueueNext(_ item: QueueItem) {
        // S17-H (P1-F5): see play(track:).
        markUserTouchedPlayback()
        // S17-G: forward to the store. The store handles dedup
        // and trims to maxQueueSize.
        // S17-H: see addToQueue — JSON path removed.
        queueStore.addNext(item, maxQueueSize: maxQueueSize)
    }
    
    /// Trims queue to keep memory usage in check
    private func trimQueue() {
        // S17-G: the trim logic moved into QueueStore.trimFront.
        // This method is kept as a hook for any future policy
        // changes that need to live on PlayerState (e.g., logging).
        // Currently it just delegates.
        let beforeCount = queue.count
        if beforeCount > maxQueueSize {
            // Compute a new items list using the same policy the
            // store uses internally. The store would do this on its
            // own when we call add*; this path is for memory-warning
            // and direct calls. We rebuild via replace.
            let keepFromCurrent = trimQueueToSize
            let currentItemVideoId = queueStore.currentItem?.track.videoId

            var newItems: [QueueItem] = []
            if let currentVideoId = currentItemVideoId,
               let currentIdx = queue.firstIndex(where: { $0.track.videoId == currentVideoId }) {
                let prevStart = max(0, currentIdx - 10)
                if prevStart < currentIdx {
                    newItems.append(contentsOf: queue[prevStart..<currentIdx])
                }
                let keepEnd = min(currentIdx + keepFromCurrent, queue.count)
                newItems.append(contentsOf: queue[currentIdx..<keepEnd])
            } else {
                newItems = Array(queue.prefix(keepFromCurrent))
            }

            let newCurrentIndex = currentItemVideoId.flatMap { videoId in
                newItems.firstIndex(where: { $0.track.videoId == videoId })
            } ?? -1

            queueStore.replace(with: newItems)
            queueStore.setCurrentIndex(newCurrentIndex)
            print("✂️ Trimmed queue to \(newItems.count) items")
        }
    }

    /// Clears old items from queue (call periodically)
    func cleanupOldItems() {
        let cutoff = Date().addingTimeInterval(-maxItemAge)

        // S17-G: build a filtered list and replace via the store.
        // This keeps `currentItem` (set later by the mirror) and
        // the store's invariants in sync.
        let currentVideoId = currentItem?.track.videoId
        let filtered = queue.filter { item in
            item.createdAt >= cutoff || item.track.videoId == currentVideoId
        }
        queueStore.replace(with: filtered)

        // Recalculate current index via the store.
        if let videoId = currentVideoId,
           let newIdx = filtered.firstIndex(where: { $0.track.videoId == videoId }) {
            queueStore.setCurrentIndex(newIdx)
        }
    }

    func removeFromQueue(at index: Int) {
        guard index >= 0 && index < queue.count else { return }

        // S17-G: forward to the store. The store handles the
        // index adjustment when removing before/after the
        // current index.
        let wasCurrent = (index == currentIndex)
        let removedItem = queue[index]
        queueStore.remove(at: index)

        // S17-H: if the removed track was already pre-queued
        // in the AVQueuePlayer (gapless mode), remove the
        // matching AVPlayerItem too. Otherwise the AVQueuePlayer
        // would play the removed track as if nothing happened,
        // and `advanceGaplessState`'s lookup in `queueStore.items`
        // would return nil, leaving `currentIndex` stale and
        // breaking the next user-tap of Next.
        if !wasCurrent, let queuePlayer = player as? AVQueuePlayer {
            let removedUrl = URL(string: removedItem.streamUrl)
            for queued in queuePlayer.items() {
                guard let queuedAsset = queued.asset as? AVURLAsset else { continue }
                if queuedAsset.url == removedUrl {
                    queuePlayer.remove(queued)
                    print("✂️ Removed pre-queued gapless item: \(removedItem.track.title)")
                    break
                }
            }
        }

        if wasCurrent {
            // Removed current item, play next (or last, or stop)
            if queueStore.currentIndex >= 0 && queueStore.currentIndex < queueStore.items.count {
                playQueue(at: queueStore.currentIndex)
            } else if !queueStore.items.isEmpty {
                let last = queueStore.items.count - 1
                queueStore.setCurrentIndex(last)
                playQueue(at: last)
            } else {
                stop()
                currentItem = nil
            }
        }
    }

    func moveQueueItem(from source: IndexSet, to destination: Int) {
        // S17-G: forward to the store. The current item is
        // re-derived by the mirror subscription in init, so
        // currentIndex automatically tracks.
        queueStore.move(from: source, to: destination)
    }

    func clearQueue() {
        // S17-G: forward to the store. The store also resets
        // currentIndex to -1.
        queueStore.clear()
        // S17-H: also stop the player. Without this, an in-flight
        // AVPlayerItem kept playing the cleared current track, and
        // when it ended the next-track path saw an empty queue and
        // left the AVPlayer paused-but-still-on-the-now-missing
        // item, with playbackState stuck at .playing. UI shows
        // "playing" with no audio. Now clearQueue is a complete
        // teardown.
        stop()
        currentItem = nil
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
        // S17-H: mark that a user-initiated skip just happened.
        // The handleTrackCompletion path that fires from
        // .AVPlayerItemDidPlayToEndTime (which is in flight on
        // completionQueue at this very moment for tracks that
        // are near the end) will see this flag and skip its own
        // auto-advance, so the user hears the track they tapped
        // for, not the one after it.
        if userSkipped {
            userSkippedPendingCompletion = true
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
                // S17-G: set currentIndex via the store. The mirror
                // subscription updates `currentItem`. The expected
                // duration is per-track metadata, not a queue
                // property, so it stays on PlayerState.
                queueStore.setCurrentIndex(nextIndex)
                let nextItem = queueStore.items[nextIndex]
                // S17-H: route through the helper so playbackClock
                // (the focused observable that the scrubber
                // subscribes to) also gets the new duration. A
                // direct `expectedDuration =` write here was
                // leaving the scrubber denominator stale across
                // gapless transitions, so the progress bar
                // visibly compressed when crossing into the next
                // track. Same helper is used by every other
                // play/crossfade path.
                updateExpectedDuration(Double(nextItem.track.durationSeconds))
                // S17-H: removed the premature
                // `addToRecentlyPlayed` and
                // `NotificationCenter.default.post(.trackPlayed)`
                // calls here. Previously the user's Next tap
                // was recording the upcoming track in
                // recently-played and notifying PlaylistManager
                // before the track actually started playing —
                // the user would see the new track in the
                // recently-played list while the previous track
                // was still playing. Now both happen in
                // `advanceGaplessState` (line 2314) when the
                // AVQueuePlayer reports the new track has
                // actually started, which is the user-visible
                // "track changed" moment.
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
        // S17-G: set currentIndex via the store. The mirror
        // subscription will keep currentItem in sync (though
        // the explicit assignment below is the more direct
        // path for this code path).
        queueStore.setCurrentIndex(index)
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
              let matchIdx = queueStore.items.firstIndex(where: { $0.track.videoId == trackIdentifier(for: nowPlaying) }) else {
            return
        }
        // S17-G: set currentIndex via the store. The mirror
        // subscription will keep currentItem in sync.
        queueStore.setCurrentIndex(matchIdx)
        if matchIdx < queueStore.items.count {
            let item = queueStore.items[matchIdx]
            currentItem = item
            // S17-H: push expectedDuration through the helper so
            // playbackClock (and the scrubber) follow the
            // auto-advance. Without this the lock-screen / control-
            // center duration stayed on the previous track for
            // 1-3s after the auto-advance fired (NowPlayingService
            // gets the new duration, but the in-app scrubber uses
            // playbackClock).
            updateExpectedDuration(Double(item.track.durationSeconds))
            dataManager.addToRecentlyPlayed(item.track)
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

        // S17-H: Apple Music / Spotify UX. If the user is more
        // than `previousTrackRestartGracePeriod` into the
        // current track, the first prev-press restarts the
        // current track (seek to 0) instead of going back to
        // the previous one. Without this, the user has to
        // re-find the previous track from the queue, which is
        // jarring after they accidentally tapped a track and
        // want to undo.
        let currentPosition = player?.currentTime().seconds ?? 0
        if currentPosition > previousTrackRestartGracePeriod {
            print("⏮️ previousTrack: more than \(Int(previousTrackRestartGracePeriod))s into track — restarting current")
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
                let remaining = Array(queue[(currentIndex + 1)...])
                // Partition: fresh first, recent last
                let fresh = remaining.filter { !recentVideoIds.contains($0.track.videoId) }
                let recent = remaining.filter { recentVideoIds.contains($0.track.videoId) }
                print("🔀 Smart shuffle: \(fresh.count) fresh + \(recent.count) recent (last 50 played)")
                // S17-G: replace via the store. The mirror subscription
                // updates `currentItem` from the store's new items +
                // currentIndex (which we set below).
                let newQueue = Array(queue[...currentIndex]) + fresh.shuffled() + recent.shuffled()
                queueStore.replace(with: newQueue)
                queueStore.setCurrentIndex(currentIndex)
            }
        } else {
            // Restore original order
            if let current = currentItem {
                // S17-G: replace via the store. Find the current item
                // in the original queue and set the store's index.
                queueStore.replace(with: originalQueue)
                if let newIndex = originalQueue.firstIndex(where: { $0.track.videoId == current.track.videoId }) {
                    queueStore.setCurrentIndex(newIndex)
                }
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

        // S15: cancel any prior player observers before wiring the
        // new ones. `setupPlayerObservers` adds 4 cancellables per
        // call; some call sites (play(item:), gapless crossfade)
        // don't clear the set first, so dead subscriptions
        // accumulated over a long session (200+ after 50 plays).
        // Clearing here means the function is idempotent: it
        // represents "the current player has exactly these 4
        // observers, and nothing else."
        //
        // S17-H: removed the dead `cancellables = cancellables.filter { _ in true }`
        // that preceded the `removeAll()`. The filter was a
        // no-op (predicate returns true for every element), and
        // the 25-line comment block describing an aspiration
        // ("addToPlayerObservers" that was never implemented)
        // was misleading. The `removeAll()` below is what
        // actually does the work. Lifetime-only observers
        // (queueStore mirror, etc.) live in `lifetimeCancellables`
        // and are not touched here.
        let priorPlayerCancellableCount = cancellables.count
        print("🔊 setupPlayerObservers: clearing \(priorPlayerCancellableCount) prior cancellables")
        cancellables.removeAll()
        
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
                    // S17-H follow-up: clear the loading-state timeout —
                    // the player reached ready before the 15s safety net.
                    self?.loadingTimeoutWorkItem?.cancel()
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
                            //
                            // S17-H follow-up: include the underlying
                            // AVPlayer error details so the user can tell
                            // "network timed out" from "track not
                            // streamable" from "backend 500". The previous
                            // generic "Couldn't play this track after
                            // multiple attempts" hid the actual cause —
                            // particularly the recent S17-H bug where
                            // the AsyncClient closed mid-stream and
                            // surfaced as a generic AVPlayer failure.
                            let nsError = self?.player?.currentItem?.error as NSError?
                            let detail = nsError.map { Self.describeAVPlayerError($0) } ?? "unknown error"
                            self?.playbackState = .error("Playback failed: \(detail)")
                            ErrorHandler.shared.show(
                                .playbackFailed("Couldn't play this track (\(detail)). Skipping to the next one."),
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
                    // S17-H follow-up: clear the loading-state timeout
                    // — the player buffered enough before the 15s safety net.
                    self.loadingTimeoutWorkItem?.cancel()
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
            // S17-H / Tier 4: listening-time accounting is now
            // delegated to `ListeningTimeTracker`. The tracker
            // reads `player.rate` itself (the ground-truth
            // check for "audio is actually being produced"),
            // applies the 5s max-tick-delta guard, and saves to
            // DataManager every 10s. PlayerState just pushes the
            // tick. The earlier inline implementation here had
            // the same logic but coupled to PlayerState's
            // state vars (`accumulatedListeningTime`,
            // `lastProgressUpdate`); see commit `88c6de9` for
            // the original S17-H `player.rate` fix.
            listeningTimeTracker.tick(player: player)

            // Save progress periodically (every 5% progress)
            if Int(newProgress * 100) % 5 == 0 {
                if let item = currentItem {
                    dataManager.updatePlaybackProgress(for: item.track.videoId, progress: newProgress)
                }
            }

            // S17-H: removed the polling-based end-of-track trigger
            // (was here, ~lines 2811-2828). The polling was firing
            // 0.5s before the actual AVPlayer end of stream when
            // `effectiveDuration` (from track metadata) was shorter
            // than the actual audio file, which produced an audible
            // "two songs overlapping" symptom. The
            // `.AVPlayerItemDidPlayToEndTime` notification wired up
            // in setupPlayerObservers → playerDidFinishPlaying() is
            // the canonical end signal and fires at the actual end
            // of the audio buffer. Polling is no longer needed and
            // was also missing the content-type special cases
            // (live radio / podcast / audiobook) that
            // playerDidFinishPlaying handles — so a polling fire
            // during a podcast would have auto-advanced to music
            // via the recently-played fallback.
            // The `isHandlingCompletion` flag is still set in
            // handleTrackCompletion (line 2919) as a safety net
            // for any future re-introduction of a polling path or
            // for the case where the AVPlayer notification arrives
            // twice (e.g. on stream-URL refresh).
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
        // S17-H: if a user-initiated skip just landed (Next tap
        // in the last fraction of a second), the user's chosen
        // next track is already playing or about to play via
        // `nextTrack(userSkipped: true)`. The .AVPlayerItemDidPlayToEndTime
        // for the *old* track is firing now (the old item is
        // still in the AVPlayer until it's swapped), and we
        // would otherwise advance again to the track *after*
        // the user's choice. Swallow the auto-advance. The flag
        // is cleared the next time `play(item:)` commits a new
        // current track.
        if userSkippedPendingCompletion {
            print("🏁 User skip landed in the last 0.5s — skipping auto-advance to honor user choice")
            isHandlingCompletion = false
            // The BG task was started by the user-skip path; let
            // the user-skip's own isPlaybackLikelyToKeepUp observer
            // release it. Don't release it here.
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

        // S17-H / Tier 4: flush the listening-time tracker on
        // track completion so the last partial batch (typically
        // < 10s of accumulated time) is persisted before the
        // next track starts. The tracker's `flush()` is
        // idempotent: it no-ops if there's nothing accumulated.
        listeningTimeTracker.flush()
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
    // S17-H: removed the empty `setupRemoteControls()` stub.
    // Remote commands are handled by NowPlayingService, and
    // this function had been a no-op for several sprints. The
    // call site at line 1153 is gone too. `updateRemoteControls`
    // (below) is the real one — it calls NowPlayingService on
    // every currentItem change.

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
