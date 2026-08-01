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
    // S17-H / S17-PLAY (Fix 6, 2026-07-29): distinct from `.loading`.
    // `.loading` is the brief "fetching stream URL" state (~1s on
    // warm cache). `.transcoding` is the longer "backend is
    // downloading + transcoding the audio for the first time"
    // state (~20-30s after Fix 1+2). UI shows a different message
    // so the user knows what's happening, and the 15s loading-
    // state timeout is bypassed for this state (it would fire
    // mid-transcode and surface a false error).
    case transcoding
    case playing
    case paused
    case buffering
    case error(String)

    var isPlaying: Bool {
        self == .playing
    }

    // S17-H / S17-PLAY (Fix 6): `.transcoding` is "loading-like"
    // from the UI's perspective — show the spinner/overlay. But
    // the loading-state timeout is a separate concept; see
    // `isColdPlay` below.
    var isLoading: Bool {
        self == .loading || self == .buffering || self == .transcoding
    }

    /// True if this is a cold-play state where the user is waiting
    /// for a backend transcode (Fix 1+2: ~20-30s). Used to opt out
    /// of the 15s "loading timed out" error toast that would fire
    /// before the transcode is done.
    var isColdPlay: Bool {
        self == .transcoding
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
    // S17-H / Tier 4: was `private`; promoted to internal for
    // `QueueController.performCrossfadeToNextItem` which logs
    // it for crossfade diagnostics.
    var expectedDuration: Double = 0.0

    /// Sprint 2 / C-4 helper: every place that sets expectedDuration
    /// should also call this so PlaybackClock's published value stays
    /// in sync with PlayerState's private mirror.
    func updateExpectedDuration(_ value: Double) {
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
    // S17-H / Tier 4: was `private`; promoted to internal for
    // `QueueController.next()` which reads this to decide
    // whether the `next()` call was triggered by a track
    // completing (so AntiAlgorithm + S17-H race-condition
    // logic can branch accordingly).
    var isHandlingCompletion = false
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
    // S17-H / Tier 4: was `private`; promoted to internal for
    // `QueueController.next()` which sets this to true when
    // the user tapped next (so the in-flight
    // .AVPlayerItemDidPlayToEndTime handler skips its own
    // auto-advance, preventing the user from hearing the
    // track after the one they tapped for).
    var userSkippedPendingCompletion = false
    
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
    // S17-H / Tier 4: was `private var player`; promoted to internal
    // for `GaplessController` (which lives in Models/ too, but in
    // a separate file — `private` is per-file, not per-type).
    // GaplessController reads the player to cast to AVQueuePlayer
    // and mutate its pre-queue. We don't need to expose this to
    // anything outside Models/; if a future refactor wants stricter
    // encapsulation, a protocol that exposes only the
    // AVQueuePlayer view would be the right next step.
    //
    // S17-H / Tier 4: the actual `AVPlayer?` reference (plus the
    // 1Hz time observer, the per-item notification tokens, and
    // the per-player Combine `cancellables`) now lives on
    // `AVPlayerController`. This computed property is a forwarding
    // shim so the ~50 existing call sites
    // (`self.player?.play()`, `self.player = AVPlayer(...)`)
    // continue to work without a sweep of the file.
    var player: AVPlayer? {
        get { avPlayerController.player }
        set { avPlayerController.player = newValue }
    }

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
    // S17-H / Tier 4: was `private`; promoted to internal for
    // `AVPlayerController` (which reads these in
    // `handlePlayerItemStatus` to drive the retry-after-failure
    // path). The internal access is module-wide but only
    // AVPlayerController (in Models/) actually reads them.
    var retryCount = 0
    let maxRetries = 2
    // S17-H / Tier 4: was `private`; promoted to internal for
    // `QueueController.toggleShuffle()` which saves the
    // original queue before shuffling, so toggling shuffle
    // off can restore it.
    var originalQueue: [QueueItem] = []

    // S17-H / Tier 4: was `private`; promoted to internal for
    // `QueueController.prepareNextTrackForCrossfade` (sets
    // to true while preparing, false on completion). Lived
    // between nextTrack and previousTrack on PlayerState
    // pre-extraction; moved next to originalQueue so the
    // QueueController-related state is grouped together.
    var isPreparingNextTrack = false
    // S17-H / Tier 4: was `private var dataManager`; promoted to
    // internal for `GaplessController.handleAutoAdvance()` which
    // calls `dataManager.addToRecentlyPlayed(_:)`. The class
    // already exists as a singleton; the only thing that changes
    // is who can see the property reference.
    var dataManager = DataManager.shared
    // S17-H / Tier 4: listening-time accounting is now owned by
    // `ListeningTimeTracker`. The tracker encapsulates the
    // accumulator, the last-tick timestamp, the 5s max-tick-delta
    // guard, the 10s save cadence, and the `player.rate > 0`
    // ground-truth check. PlayerState just pushes ticks to it from
    // the time observer and calls `reset()` / `flush()` on track
    // boundaries.
    private let listeningTimeTracker = ListeningTimeTracker()

    // S17-H / Tier 4: gapless mode (AVQueuePlayer pre-queue +
    // auto-advance state sync) is now owned by `GaplessController`.
    // `lazy` so we can pass `self` to the controller's init
    // without fighting Swift's "self used before all stored
    // properties are initialized" rule. The controller holds a
    // weak ref back to self, so the lazy doesn't form a cycle.
    // S17-H / Tier 4: was `private`; promoted to internal for
    // `QueueController.next()` which calls
    // `gaplessController.enqueueUpcomingItems()` after a
    // gapless advance.
    lazy var gaplessController = GaplessController(playerState: self)

    // S17-H / Tier 4: the AVPlayer instance + the 1Hz time
    // observer + per-item notification tokens + per-player
    // Combine `cancellables` are now owned by
    // `AVPlayerController`. Same lazy-init pattern as
    // `gaplessController` above (pass self to init, weak
    // ref back from controller). The forwarding `var player`
    // computed property above routes through this controller.
    // S17-H / Tier 4: was `private`; promoted to internal for
    // `QueueController.next()` which accesses the AVPlayer via
    // `avPlayerController.player` to cast to AVQueuePlayer for
    // the gapless advance path.
    lazy var avPlayerController = AVPlayerController(playerState: self)

    // S17-H / Tier 4: the fan-out to `NowPlayingService.shared`
    // (Lock Screen / Control Center metadata) is now owned
    // by `NowPlayingController`. The 7 `NowPlayingService.*`
    // callsites that were sprinkled through PlayerState
    // become 1-line `nowPlayingController.updateNowPlaying()`
    // calls. Same lazy-init pattern.
    private lazy var nowPlayingController = NowPlayingController(playerState: self)

    // S17-H / Tier 4: queue navigation (next, previous) +
    // repeat/shuffle state transitions are now owned by
    // `QueueController`. The ~380 lines of conditional flow
    // (gapless vs crossfade vs autoplay vs repeat-all wrap)
    // that used to live as `nextTrack` / `previousTrack` /
    // `toggleShuffle` / `toggleRepeat` on PlayerState (plus
    // 3 private helpers) are now in QueueController. Same
    // lazy-init pattern as the other controllers.
    private lazy var queueController = QueueController(playerState: self)

    // S17-H / Tier 4 dual-load fix: dedup `play(item:)` calls
    // for the same videoId within a small window. Real-time
    // repro (2026-07-31 13:01:11, "And I Love Her" tap) showed
    // 3 distinct source ports each opening /audio/{vid}.m4a in
    // 307ms — i.e. 3 separate AVPlayer instances racing for the
    // same track. They fought over the audio session and all
    // ended up paused (the user-reported "3-4s load" symptom,
    // often worse — the track didn't play at all).
    //
    // Without this lock, any combination of:
    //   - user tap (HomeView/SearchView/Playlists/...)
    //   - view appear (mini-player rebuilds on tab change)
    //   - media-services reset (handleMediaServicesResetRestart)
    //   - retry path (refreshAndPlayCurrentItem on .failed)
    // can fire `play(track:)` / `play(item:)` 2-3x in <500ms,
    // and the current code creates a fresh AVPlayer for each.
    //
    // Same videoId → drop the duplicate. Different videoId
    // → let the new play preempt (the old one's defer becomes
    // a no-op since the lock no longer matches its videoId,
    // and `play(item:)` calls `stop()` at line 1160 to tear
    // down the previous player before building the new one).
    private var playInFlightVideoId: String?
    private let playInFlightLock = NSLock()

    /// Returns true if the caller owns the in-flight slot for
    /// `videoId` and should proceed to build the AVPlayer.
    /// Returns false if a play for the same videoId is already
    /// in progress (caller should drop the duplicate).
    private func tryBeginPlay(videoId: String) -> Bool {
        playInFlightLock.lock()
        defer { playInFlightLock.unlock() }
        if playInFlightVideoId == videoId {
            print("⚠️ [S17-H dual-load] play dropped duplicate for videoId=\(videoId) (one already in flight)")
            return false
        }
        if let existing = playInFlightVideoId {
            print("🔄 [S17-H dual-load] play preempted: in-flight=\(existing) → new=\(videoId)")
        }
        playInFlightVideoId = videoId
        return true
    }

    /// Release the in-flight slot for `videoId`. Only clears
    /// the slot if the caller still owns it (a preempted call
    /// from a previous videoId becomes a no-op).
    private func endPlay(videoId: String) {
        playInFlightLock.lock()
        defer { playInFlightLock.unlock() }
        if playInFlightVideoId == videoId {
            playInFlightVideoId = nil
        }
    }

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
    /// S17-H / S17-LOCK: was `private`; promoted to internal for
    /// `YTAudioPlayerApp.scenePhase` handler which re-activates
    /// the session on every lock/unlock cycle. iOS can downgrade
    /// the session during a screen lock; re-asserting the
    /// `.playback` category from the app entry point is the
    /// bulletproof fix for the "track pauses when I lock" bug.
    let audioSessionController = AudioSessionController()

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
    // S17-H / Tier 4: was `private`; promoted to internal for
    // `QueueController.previous()` which reads this to decide
    // "restart current track" vs "go to previous track" per
    // the Apple Music / Spotify UX.
    let previousTrackRestartGracePeriod: TimeInterval = 3
    private var cleanupTimer: Timer?  // Store reference for proper cleanup

    // Serial queue for completion handling to prevent race conditions
    private let completionQueue = DispatchQueue(label: "com.ytaudio.completion", qos: .userInitiated)

    // Background task for track transitions when app is backgrounded
    private var trackTransitionBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    // Stall recovery
    // S17-H / Tier 4: was `private`; promoted to internal for
    // `AVPlayerController` (which reads this in
    // `handleIsPlaybackLikelyToKeepUp` to drive the stall
    // recovery path).
    var isPlaybackStalled = false

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
        // (queue count = 1) so the initial `enqueueUpcomingItems`
        // bails on its `guard queueCount > 1`. Then
        // `QueuePrefetcher.autoPopulateQueue` populates the queue
        // a few hundred ms later via async `addToQueue` calls, but
        // by then `play(item:)` has already moved on. Without this
        // subscription, the first track ends, the AVQueuePlayer
        // has no next item, and the auto-advance path is the
        // clunky one (rebuild via `handleAutoAdvance`).
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
                self.gaplessController.enqueueUpcomingItems()
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
            .store(in: &avPlayerController.cancellables)

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
    // S17-H / Tier 4: was `private`; promoted to internal for
    // `AVPlayerController` (which calls this in
    // `handlePlayerItemStatus` and `handleIsPlaybackLikelyToKeepUp`).
    func clearCompletionFlag() {
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
    // S17-H / Tier 4: was `private`; promoted to internal for
    // `AVPlayerController` (which calls this in
    // `handlePlayerItemStatus` to surface a one-line error
    // description in the retry-exhausted toast).
    static func describeAVPlayerError(_ error: NSError) -> String {
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

    // S17-H / Tier 4: was `private`; promoted to internal for
    // `QueueController.next()` which calls this at the start
    // of every track transition (gapless advance, crossfade,
    // autoplay).
    func beginTrackTransitionBackgroundTask() {
        endTrackTransitionBackgroundTask()
        trackTransitionBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "com.peaceplayer.trackTransition") { [weak self] in
            self?.endTrackTransitionBackgroundTask()
        }
        if trackTransitionBackgroundTask != .invalid {
            print("🔒 Background task started for track transition")
        }
    }

    // S17-H / Tier 4: was `private`; promoted to internal for
    // `AVPlayerController` (which calls this in
    // `handlePlayerItemStatus` and `handleIsPlaybackLikelyToKeepUp`
    // to release the BG task we acquired during a track
    // transition).
    func endTrackTransitionBackgroundTask() {
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
            // S17-H / Tier 4 dual-load fix (Layer 2): route through
            // `StreamURLCache` so concurrent `play(track:)` calls for
            // the same videoId share one backend roundtrip (the cache
            // returns a `.share()`-ed publisher + retains the upstream
            // so late subscribers get the same value).
            //
            // Previously bypassed (C-2026-06-28) because the cache
            // hung indefinitely on a fresh install. The root cause
            // was an `NSLock` deadlock when `.sink(receiveCompletion:)`
            // on a `Just` publisher fired immediately and the
            // completion handler re-acquired the same non-recursive
            // lock — fixed in `StreamURLCache` by switching to
            // `NSRecursiveLock` (see `activeFetchLock` at line 57).
            // The dead-lock is gone, so the dedup is safe to re-enable.
            //
            // Note: this layer reduces the number of /stream/ calls
            // (no longer 1 per play(track:) caller). The real
            // multi-AVPlayer fix is the playInFlight dedup at the
            // top of `play(item:)`; this is the lighter-weight
            // network dedup that prevents the same /stream/ storm
            // the real-time repro at 13:01:11 (5 simultaneous
            // /stream/ for 5 different videoIds) made obvious.
            StreamURLCache.shared.getStreamUrl(videoId: track.videoId, preferM4A: true, quality: "low")
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
                .store(in: &avPlayerController.cancellables)
        }
    }

    func play(item: QueueItem, addToQueue: Bool = true) {
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) ENTRY videoId=\(item.track.videoId) title=\(item.track.title) source=\(item.source) currentItem.videoId=\(currentItem?.track.videoId ?? "nil") playbackState=\(playbackState)")
        #endif

        // S17-H / Tier 4 dual-load fix: dedup at the AVPlayer
        // creation site. If another play for the same videoId
        // is already in flight, drop this one. See the
        // `tryBeginPlay` doc for the full race story.
        let __playInFlightVideoId = item.track.videoId
        guard tryBeginPlay(videoId: __playInFlightVideoId) else {
            return
        }
        // Release the in-flight slot when this function exits —
        // success, failure, or early return. A preempted call
        // (different videoId acquired the slot in the meantime)
        // becomes a no-op.
        defer { endPlay(videoId: __playInFlightVideoId) }

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
            gaplessController.enqueueUpcomingItems()
        }

        // Attach audio visualizer tap to this player item
        AudioVisualizerEngine.shared.installTap(on: playerItem)
        
        // Setup observers
        print("🔊 Setting up observers...")
        avPlayerController.setupObservers()
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
        // S17-H / S17-PLAY (Fix 6, 2026-07-29): bump the timeout
        // from 15s to 60s. After Fix 1+2, a cold transcode
        // (backend downloads webm from YouTube + transcodes to
        // m4a) takes 20-30s for a typical track. The previous
        // 15s timeout would fire mid-transcode and surface a
        // false "playback didn't start" error. 60s gives a
        // generous buffer; the timeout still fires for true
        // stalls (network unreachable, YouTube blocking the
        // IP, etc.). For the warm path (~1s to fetch the stream
        // URL) this is a no-op — the timeout gets cancelled the
        // moment playback actually starts.
        scheduleLoadingStateTimeout(after: 60.0, for: item)

        // S17-H / S17-PLAY (Fix 6): if we're still in .loading
        // after 2 seconds, transition to .transcoding. The 2s
        // window lets warm plays (~1s to fetch stream URL) stay
        // on "Loading..." without the more alarming "Preparing
        // your audio..." message. Cold plays (Fix 1+2: 20-30s)
        // flip to .transcoding at 2s, showing the longer-form
        // message with a clearer sub-text.
        let videoId = item.track.videoId
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            // Only transition if the same track is still loading
            // (not playing, not a different track, not already
            // .transcoding).
            if self.playbackState == .loading
                && self.currentItem?.track.videoId == videoId {
                self.playbackState = .transcoding
            }
        }

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
        //
        // S17-H / Tier 4: was `NowPlayingService.shared.updateNowPlaying(...)`
        // inline here. Now goes through NowPlayingController so the
        // fan-out is in one place.
        nowPlayingController.updateNowPlaying()
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "play(item:) POST-updateNowPlaying videoId=\(item.track.videoId)")
        #endif
        
        // Prepare next track for crossfade (with delay to allow queue to populate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.queueController.prepareNextTrackForCrossfade()
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
    // S17-H / Tier 4: was `private`; promoted to internal for
    // `AVPlayerController` (which cancels this in the
    // readyToPlay / isPlaybackLikelyToKeepUp paths so the
    // 15s safety net doesn't fire if the player reached
    // ready first).
    var loadingTimeoutWorkItem: DispatchWorkItem?

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
            .store(in: &avPlayerController.cancellables)
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
            .store(in: &avPlayerController.cancellables)
    }
    
    // S17-H / Tier 4: was `private`; promoted to internal for
    // `AVPlayerController` (which calls this in
    // `handlePlayerItemStatus` to retry after a failure).
    func refreshAndPlayCurrentItem() {
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
            .store(in: &avPlayerController.cancellables)
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

    // S17-H / S17-LOCK: re-assert playback on scene phase
    // .active. The previous `scenePhase` hook in the App entry
    // re-activates the audio session (fixing one half of the
    // "track pauses on background" bug) but the AVPlayer
    // itself can also be paused by iOS when the app goes
    // background (e.g., on screen lock, on app minimize, on
    // route change). Re-asserting the session alone is not
    // enough — the player's `rate` may be 0 when the app
    // comes back to .active, and the user expects the track
    // to keep playing.
    //
    // The check is gated on:
    //  1. `currentItem != nil` (no track to resume)
    //  2. `playbackState != .playing` (track was already playing
    //     — no need to re-assert, the player is fine)
    //  3. `playbackState != .error` (don't try to resume from
    //     an error state, the user already saw the error UI)
    //  4. `player != nil && player.rate == 0` (the actual
    //     symptom: the player is paused by iOS during
    //     background)
    //
    // `playImmediately(atRate:)` is used instead of
    // `player.play()` because the latter can hit a 1-frame
    // rate-0 race (see the S17-H note at line ~1284 in
    // `play(item:)` for the full story).
    func handleScenePhaseActive() {
        guard let item = currentItem else { return }
        // S17-LOCK follow-up: the previous guard was
        // `playbackState == .paused || == .loading`, but
        // the actual scenario is the OPPOSITE — when the
        // user was actively playing (state = .playing),
        // iOS paused the player externally (rate = 0)
        // and left the state stale. Trust `playbackState`
        // as the user's INTENT (`.playing` means "I want
        // this to play") and check `player.rate == 0`
        // as the ACTUAL reality (iOS paused the player).
        // A user who explicitly tapped pause (state =
        // .paused) STAYS paused on .active.
        guard playbackState == .playing else { return }
        // Don't try to resume from an .error state — the
        // user already saw the error UI. `.error` carries
        // a String, so compare via `if case`.
        if case .error = playbackState { return }
        guard let player = player else { return }
        guard player.rate == 0 else { return }
        print("▶️ [S17-LOCK] scenePhase .active: re-asserting playback (user was playing, iOS paused the player)")
        #if DEBUG
        PlayCrashDiagnostics.log(.playback, "S17-LOCK: scenePhase .active resume videoId=\(item.track.videoId)")
        #endif
        player.playImmediately(atRate: playbackRate)
        updateRemoteControls()
    }

    // S17-H / S17-LOCK: called by the AVPlayerController KVO
    // observer on `player.timeControlStatus` whenever the
    // player is paused externally (e.g., by iOS on a route
    // change, on a media-services-reset recovery, on an
    // audio-session interruption that the AudioSessionController
    // didn't catch). Same gating as `handleScenePhaseActive`:
    // only resume if the user's intent was to play
    // (`playbackState == .playing`) and we're not in an
    // error state.
    //
    // Debounced at 500ms so a quick iOS pause-then-resume
    // cycle (which can happen on a route change that's
    // immediately recovered) doesn't trigger a user-visible
    // "play" call.
    private var handleExternalPlayerPauseWorkItem: DispatchWorkItem?

    func handleExternalPlayerPause() {
        handleExternalPlayerPauseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard let item = self.currentItem else { return }
            guard self.playbackState == .playing else { return }
            if case .error = self.playbackState { return }
            guard let player = self.player else { return }
            guard player.rate == 0 else { return }
            print("▶️ [S17-LOCK] external pause detected: re-asserting playback (KVO on timeControlStatus)")
            #if DEBUG
            PlayCrashDiagnostics.log(.playback, "S17-LOCK: external-pause KVO resume videoId=\(item.track.videoId)")
            #endif
            player.playImmediately(atRate: self.playbackRate)
            self.updateRemoteControls()
        }
        handleExternalPlayerPauseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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
        //
        // S17-H / Tier 4: was inline `NowPlayingService.shared.updateNowPlaying(...)`.
        // Now goes through NowPlayingController.
        nowPlayingController.updateNowPlaying()
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
        avPlayerController.removeTimeObserver()
        player?.replaceCurrentItem(with: nil)

        // Cancel quality upgrade timer
        cancelQualityUpgrade()

        // Remove audio visualizer tap
        AudioVisualizerEngine.shared.removeTap()

        // CRITICAL FIX: Cancel all Combine subscriptions to prevent duplicate observers
        avPlayerController.clearCancellables()

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
        avPlayerController.removeTimeObserver()
        cancelQualityUpgrade()
        // S17-H: release the BG task if a track-transition is
        // mid-flight. Without this, a queued nextTrack/autoplay
        // BG task would be orphaned when the user switches from a
        // track to a radio station.
        endTrackTransitionBackgroundTask()
        avPlayerController.clearCancellables()
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
        avPlayerController.setupObservers()
        // S11 fix (Bug 2): refresh Lock Screen / Control Center with
        // the radio station's metadata. Previously Lock Screen kept
        // showing the previous track.
        //
        // S17-H / Tier 4: was inline `NowPlayingService.shared.updateNowPlaying(...)`.
        // Now goes through NowPlayingController (explicit-arg variant
        // for content-type switches where currentItem isn't yet
        // set / is in transition).
        nowPlayingController.updateNowPlaying(
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
        avPlayerController.removeTimeObserver()
        cancelQualityUpgrade()
        // S17-H: see playRadioStation — release BG task on
        // content-type switch.
        endTrackTransitionBackgroundTask()
        avPlayerController.clearCancellables()
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
        avPlayerController.setupObservers()
        // S11 fix (Bug 2): refresh Lock Screen / Control Center with
        // the podcast metadata. Without this, the Lock Screen kept
        // showing whatever track was playing before.
        //
        // S17-H / Tier 4: was inline `NowPlayingService.shared.updateNowPlaying(...)`.
        // Now goes through NowPlayingController.
        nowPlayingController.updateNowPlaying(
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

        avPlayerController.removeTimeObserver()
        cancelQualityUpgrade()
        // S17-H: see playRadioStation — release BG task on
        // content-type switch.
        endTrackTransitionBackgroundTask()
        avPlayerController.clearCancellables()
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
        avPlayerController.setupObservers()
        // S11 fix (Bug 2): refresh Lock Screen / Control Center with
        // audiobook chapter metadata.
        //
        // S17-H / Tier 4: was inline `NowPlayingService.shared.updateNowPlaying(...)`.
        // Now goes through NowPlayingController.
        nowPlayingController.updateNowPlaying(
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
        // and `handleAutoAdvance`'s lookup in `queueStore.items`
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
    
    // MARK: - Volume

    /// S17-H / Tier 4: thin wrappers for the queue /
    /// repeat / shuffle state transitions that now live in
    /// `QueueController`. External callers (the remote
    /// command handler in `YTAudioPlayerApp.swift`, the
    /// previous-button in `FullPlayer.swift`, and the
    /// auto-advance path in `AVPlayerController.handlePlayerItemStatus`)
    /// still call these on `PlayerState`; PlayerState just
    /// delegates to the controller. Keeping the wrappers
    /// (vs. updating every call site) is a 1-commit
    /// mechanical change that keeps the public API of
    /// PlayerState stable.
    func nextTrack(useCrossfade: Bool = true, userSkipped: Bool = false) {
        queueController.next(useCrossfade: useCrossfade, userSkipped: userSkipped)
    }

    func previousTrack() {
        queueController.previous()
    }

    func toggleShuffle() {
        queueController.toggleShuffle()
    }

    func toggleRepeat() {
        queueController.toggleRepeat()
    }

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

    /// S17-H / Tier 4: 1Hz tick handler. Called by
    /// `AVPlayerController.setupObservers` via the periodic
    /// time observer. Reads from `self.player` (forwards to
    /// the controller) and fans out to PlaybackClock,
    /// NowPlayingService, the listening-time tracker, and
    /// the crossfade / podcast / audiobook position
    /// bookkeeping. Kept on PlayerState (not moved into the
    /// controller) because most of the fan-out writes to
    /// PlayerState-owned state.
    func updateProgress() {
        guard let player = player else { return }

        let current = player.currentTime().seconds
        let total = player.currentItem?.duration.seconds ?? 0

        // Log every 10th call (every 5 seconds) to avoid spam
        let effectiveTotal = effectiveDuration > 0 ? effectiveDuration : total
        if Int(current) > 0 && Int(current) % 5 == 0 {
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
        _ = playbackClock.tick(currentSeconds: current, totalSeconds: total, effectiveDuration: effectiveTotal)

        // Update Now Playing info periodically (every ~1 second)
        //
        // S17-H / Tier 4: was inline `NowPlayingService.shared.updatePlaybackTime(...)`.
        // Now goes through NowPlayingController.
        if Int(current) % 2 == 0 {
            nowPlayingController.updatePlaybackTime()
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
                queueController.prepareNextTrackForCrossfade()
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
            // (live radio reconnects to the stream; podcast stops;
            // audiobook auto-advances to the next chapter).
            // The polling logic was removed but the comment
            // remains for historical context — see commit 88c6de9
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

    // S17-H / Tier 4: was `@objc private`; promoted to
    // `@objc internal` for `AVPlayerController` (which calls
    // this from the `.AVPlayerItemDidPlayToEndTime`
    // notification observer). The @objc is required because
    // the observer is registered with
    // `NotificationCenter.default.addObserver(forName:...)`
    // which is Objective-C bridged.
    @objc func playerDidFinishPlaying() {
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

    // S17-H / Tier 4: was `@objc private`; promoted for
    // `AVPlayerController` (which calls this from the
    // `.AVPlayerItemFailedToPlayToEndTime` observer).
    @objc func playerFailedToPlayToEndTime(_ notification: Notification) {
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

    // S17-H / Tier 4: was `@objc private`; promoted for
    // `AVPlayerController` (which calls this from the
    // `.AVPlayerItemPlaybackStalled` observer).
    @objc func playerPlaybackStalled(_ notification: Notification) {
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
                self?.gaplessController.handleAutoAdvance()
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

    // S17-H / Tier 4: was `private`; promoted for
    // `AVPlayerController` (which calls this in
    // `setupObservers` when the duration publisher fires
    // so the Lock Screen shows the new duration).
    func updateRemoteControls() {
        guard let item = currentItem else {
            NowPlayingService.shared.clearNowPlaying()
            return
        }

        // Use effective duration (from track metadata if available)
        let displayDuration = effectiveDuration
        print("🎵 updateRemoteControls - effectiveDuration: \(displayDuration), currentTime: \(currentTime)")

        // S17-H / Tier 4: was inline `NowPlayingService.shared.updateNowPlaying(...)`.
        // Now goes through NowPlayingController. Note: this is the
        // "with explicit currentTime" variant — unlike the
        // no-arg `updateNowPlaying()` (used after a play/pause
        // state change where the Lock Screen just needs the new
        // track + isPlaying/rate, not the current time), this
        // caller (the duration publisher in AVPlayerController)
        // has the actual current time and wants to push it so
        // the Lock Screen scrubber position updates after a
        // seek or a pause-then-resume.
        nowPlayingController.updateNowPlaying(
            track: item.track,
            duration: displayDuration,
            currentTime: currentTime,
            isPlaying: playbackState.isPlaying,
            playbackRate: playbackRate
        )
    }
}
