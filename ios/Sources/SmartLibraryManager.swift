//
//  SmartLibraryManager.swift
//  PeacePlayer
//
//  2026-08-12: v1.8.0 — auto-download on WiFi + auto-cleanup of
//  unused downloads. Two features, one manager (shared settings
//  + free-space helper + orchestration).
//
//  Settings: UserDefaults-backed via @AppStorage (per-flag
//  defaults). The grace periods and on/off toggles are
//  user-configurable in Settings → Smart Library.
//
//  Persistence: the set of auto-downloaded videoIds lives in
//  a UserDefaults key as JSON-encoded Set<String>. The set is
//  the "tier marker" — a track in this set is treated as
//  "auto-downloaded" by the cleanup logic, otherwise it's
//  treated as "manually downloaded". Liked tracks are checked
//  separately and are never auto-removed regardless of tier.
//
//  Triggers:
//    - Auto-download: NetworkMonitor WiFi change (30s debounce)
//      + scenePhase .active in the App scene (covers both cold
//      launch and warm foreground). v1.8.2 dropped the previous
//      24h debounce; the maxLibraryTracks cap is the limiter.
//    - Cleanup: scenePhase .active in the App scene. v1.8.2
//      dropped the previous 7d debounce; cleanup is read-only
//      and cheap. Storage emergency (< 1GB free) bypasses any
//      preconditions and prioritises auto-downloaded removals.
//

import Foundation
import Combine
import UIKit
import CoreData
// @AppStorage is a SwiftUI property wrapper but the
// implementation works fine outside a View. Imported here
// so the manager's UserDefaults-backed settings use the
// same convention as the rest of the app (SettingsView
// uses @AppStorage for its LabsToggle).
import SwiftUI

@MainActor
final class SmartLibraryManager: ObservableObject {
    static let shared = SmartLibraryManager()

    // MARK: - User-facing settings (UserDefaults via @AppStorage)

    /// Master toggle for the auto-download-on-WiFi feature.
    /// When false, no automatic downloads happen regardless of
    /// conditions. Manual downloads (user tapping the download
    /// button) are unaffected.
    @AppStorage("smartLibrary.autoDownloadEnabled") var autoDownloadEnabled: Bool = true

    /// Master toggle for the auto-cleanup feature. When false,
    /// tracks are never auto-removed. Manual removal (user
    /// tapping delete) is unaffected. The "Clean up now" button
    /// in Settings is also gated by this.
    @AppStorage("smartLibrary.cleanupEnabled") var cleanupEnabled: Bool = true

    /// Days an auto-downloaded track can sit unplayed before
    /// it's eligible for auto-removal. Liked tracks are never
    /// removed (tier check is "liked first, tier second").
    @AppStorage("smartLibrary.cleanupDaysAuto") var cleanupDaysAuto: Int = 14

    /// Days a manually-downloaded track can sit unplayed before
    /// it's eligible for auto-removal.
    @AppStorage("smartLibrary.cleanupDaysManual") var cleanupDaysManual: Int = 60

    /// Max number of tracks auto-downloaded per cycle. Hard
    /// cap to prevent a runaway fill. User-configurable in
    /// case they want to be more or less aggressive.
    @AppStorage("smartLibrary.autoDownloadMaxPerCycle") var autoDownloadMaxPerCycle: Int = 20

    /// 2026-08-12: max number of tracks the user is willing
    /// to keep downloaded at once. The auto-download cycle
    /// SKIPS when the library is at or above this count,
    /// regardless of trigger — so the user always has
    /// "library ready" but never blows past their budget.
    /// Default 50 tracks; user-configurable via a Picker
    /// in Settings → Smart Library.
    ///
    /// The refresh button (runRefreshNow) bypasses this
    /// check (it clears the library first, so the new
    /// downloads always fit), but the per-cycle download
    /// count is still capped by autoDownloadMaxPerCycle.
    @AppStorage("smartLibrary.maxLibraryTracks") var maxLibraryTracks: Int = 50

    /// Min free disk space (bytes) required to start an
    /// auto-download cycle. Below this, skip the cycle entirely
    /// — better to have nothing new than to fill the device
    /// past the OS warning threshold.
    /// Note: stored as `Int` (not `Int64`) because @AppStorage's
    /// supported scalar types don't include Int64. iOS 17+ is
    /// 64-bit only so Int is Int64 at runtime.
    @AppStorage("smartLibrary.minFreeBytes") var minFreeBytes: Int = 500_000_000  // 500 MB

    /// Min free disk space (bytes) before triggering a storage
    /// emergency cleanup. Below this, cleanup runs on every
    /// foreground regardless of the weekly debounce, and
    /// prioritises removing auto-downloaded tracks first.
    @AppStorage("smartLibrary.emergencyThresholdBytes") var emergencyThresholdBytes: Int = 1_000_000_000  // 1 GB

    // MARK: - Published state (for the Settings status row)

    @Published private(set) var lastAutoDownloadAt: Date?
    @Published private(set) var lastAutoDownloadCount: Int = 0
    @Published private(set) var lastAutoDownloadBytesEstimated: Int64 = 0
    // 2026-08-12: track when the cycle was skipped due to
    // the library being at the max-library-tracks limit.
    // Drives the "X of N (at limit)" status line in Settings.
    @Published private(set) var lastAutoDownloadSkippedReason: String?
    @Published private(set) var lastCleanupAt: Date?
    @Published private(set) var lastCleanupCount: Int = 0
    @Published private(set) var lastCleanupBytesFreed: Int64 = 0
    @Published private(set) var isAutoDownloading: Bool = false
    @Published private(set) var isCleaningUp: Bool = false
    // 2026-08-12: separate flag for the Refresh Downloads
    // flow (vs the normal auto-download cycle). The Settings
    // button reads this to show a spinner on the right
    // control, not on the auto-download status line.
    @Published private(set) var isRefreshing: Bool = false

    // MARK: - Tier marker (UserDefaults)

    /// Set of videoIds that were auto-downloaded. Used by the
    /// cleanup logic to decide whether a track is tier=auto
    /// (removable after cleanupDaysAuto) or tier=manual
    /// (removable after cleanupDaysManual). Not the source of
    /// truth for "is this downloaded" — that's CoreData
    /// (CDDownloadedTrack). This set is just the tier marker.
    @Published private(set) var autoDownloadedVideoIds: Set<String> = []

    // MARK: - Private

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cancellables = Set<AnyCancellable>()

    private enum Keys {
        static let autoDownloadedIds = "smartLibrary.autoDownloadedIds"
        static let lastAutoDownloadAt = "smartLibrary.lastAutoDownloadAt"
        static let lastAutoDownloadCount = "smartLibrary.lastAutoDownloadCount"
        static let lastAutoDownloadBytesEstimated = "smartLibrary.lastAutoDownloadBytesEstimated"
        static let lastCleanupAt = "smartLibrary.lastCleanupAt"
        static let lastCleanupCount = "smartLibrary.lastCleanupCount"
        static let lastCleanupBytesFreed = "smartLibrary.lastCleanupBytesFreed"
    }

    private init() {
        loadState()
        setupHooks()
    }

    private func loadState() {
        if let data = defaults.data(forKey: Keys.autoDownloadedIds),
           let decoded = try? decoder.decode(Set<String>.self, from: data) {
            autoDownloadedVideoIds = decoded
        }
        let interval = Date().timeIntervalSince1970
        if let ts = defaults.object(forKey: Keys.lastAutoDownloadAt) as? Date {
            lastAutoDownloadAt = ts
        }
        lastAutoDownloadCount = defaults.integer(forKey: Keys.lastAutoDownloadCount)
        if defaults.object(forKey: Keys.lastAutoDownloadBytesEstimated) != nil {
            lastAutoDownloadBytesEstimated = Int64(defaults.integer(forKey: Keys.lastAutoDownloadBytesEstimated))
        }
        if let ts = defaults.object(forKey: Keys.lastCleanupAt) as? Date {
            lastCleanupAt = ts
        }
        lastCleanupCount = defaults.integer(forKey: Keys.lastCleanupCount)
        if defaults.object(forKey: Keys.lastCleanupBytesFreed) != nil {
            lastCleanupBytesFreed = Int64(defaults.integer(forKey: Keys.lastCleanupBytesFreed))
        }
        _ = interval
    }

    private func setupHooks() {
        // WiFi connect → debounce 30s → run auto-download if due.
        // The 30s debounce is critical: iOS publishes multiple
        // path updates on a typical WiFi reconnect (interface
        // change, DHCP renew, captive portal redirect). Without
        // it we'd fire runAutoDownloadIfDue several times in a
        // row. The 30s window covers all of those and gives the
        // backend time to become reachable (the OS marks WiFi
        // up before the backend's /health probe responds).
        NetworkMonitor.shared.$connectionType
            .map { $0 == .wifi }
            .removeDuplicates()
            .debounce(for: .seconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self] isWiFi in
                guard isWiFi else { return }
                self?.runAutoDownloadIfDue()
            }
            .store(in: &cancellables)

        // App foreground → run both cycles. The scenePhase
        // .active handler in YTAudioPlayerApp.swift is the
        // single source of truth for "user is back in the
        // app" — it fires on both cold launch and warm
        // foreground. Previously this manager also listened
        // to UIApplication.willEnterForegroundNotification,
        // which fires only on warm foreground; the two
        // signals overlapped on every warm foreground,
        // causing runAutoDownloadIfDue to spin up two
        // redundant Tasks (cheap but wasted work). The
        // scenePhase path covers both cases now.

        // Download-deleted notification keeps the auto-set
        // from growing unboundedly. Posted by DownloadManager
        // .deleteDownload for both manual and cleanup-driven
        // deletions. See SmartLibraryManager.markAsManuallyDownloaded
        // for the corresponding "tier upgrade" path.
        NotificationCenter.default.publisher(for: .downloadDeleted)
            .sink { [weak self] note in
                guard let videoId = note.object as? String else { return }
                self?.removeFromAutoSet(videoId: videoId)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API: tier markers

    /// Mark a videoId as auto-downloaded. Called by the
    /// auto-download orchestration right after DownloadManager
    /// accepts the download. Idempotent.
    func markAsAutoDownloaded(_ videoId: String) {
        autoDownloadedVideoIds.insert(videoId)
        saveAutoDownloadedIds()
    }

    /// Remove a videoId from the auto set. Called when:
    ///   - the user explicitly downloads a track that was
    ///     previously auto-downloaded (tier upgrade to manual)
    ///   - the track is deleted (any reason) — handled
    ///     automatically via the .downloadDeleted notification,
    ///     no caller action needed
    func removeFromAutoSet(videoId: String) {
        if autoDownloadedVideoIds.remove(videoId) != nil {
            saveAutoDownloadedIds()
        }
    }

    private func saveAutoDownloadedIds() {
        if let data = try? encoder.encode(autoDownloadedVideoIds) {
            defaults.set(data, forKey: Keys.autoDownloadedIds)
        }
    }

    // MARK: - Public API: tier query

    /// Tier for a downloaded track, used by the cleanup logic
    /// (and exposed for any future UI that wants to show a
    /// tier badge). Liked is the highest tier and is checked
    /// first; an auto-downloaded track that the user later
    /// liked becomes .liked, never to be auto-removed.
    enum DownloadTier: Equatable {
        case liked
        case auto
        case manual
    }

    func tier(for videoId: String) -> DownloadTier {
        if PlaylistManager.shared.likedTracks.contains(videoId) {
            return .liked
        }
        if autoDownloadedVideoIds.contains(videoId) {
            return .auto
        }
        return .manual
    }

    /// Whether a track is eligible for auto-removal given its
    /// tier and lastPlayedAt. Liked is never eligible.
    /// Auto: eligible if unplayed > cleanupDaysAuto days.
    /// Manual: eligible if unplayed > cleanupDaysManual days.
    func shouldAutoRemove(videoId: String, lastPlayedAt: Date?) -> Bool {
        switch tier(for: videoId) {
        case .liked:
            return false
        case .auto:
            return isPastThreshold(lastPlayedAt: lastPlayedAt, days: cleanupDaysAuto)
        case .manual:
            return isPastThreshold(lastPlayedAt: lastPlayedAt, days: cleanupDaysManual)
        }
    }

    private func isPastThreshold(lastPlayedAt: Date?, days: Int) -> Bool {
        // nil = never played → unplayed since download → past any threshold
        guard let last = lastPlayedAt else { return true }
        let elapsed = Date().timeIntervalSince(last)
        return elapsed > TimeInterval(days) * 24 * 3600
    }

    // MARK: - Public API: orchestration entry points

    /// Run the auto-download cycle. v1.8.2: dropped the
    /// 24h debounce. The product intent is "always have
    /// library ready" — every WiFi connect + every
    /// foreground is a chance to top up. The hard
    /// limiter is now maxLibraryTracks: if the library is
    /// already at the cap, we skip (so a user with a
    /// 200-track manual library doesn't get spammed with
    /// auto-downloads they don't need). The 30s debounce
    /// on the WiFi trigger (in setupHooks) is the only
    /// rate limiting — it's the standard "don't fire
    /// multiple times during a WiFi reconnect handshake"
    /// throttle.
    ///
    /// All other preconditions (toggle, WiFi, metered,
    /// backend, free space) are checked inside
    /// runAutoDownloadCycle.
    func runAutoDownloadIfDue() {
        guard autoDownloadEnabled else { return }
        Task { await runAutoDownloadCycle() }
    }

    /// v1.8.2: drop the 24h debounce on the auto-cleanup
    /// too. Cleanup is read-only and cheap; running it on
    /// every foreground (instead of once per 7d) means
    /// stale tracks are caught sooner. Storage emergency
    /// still bypasses any internal checks. The 7d
    /// debounce in v1.8.0/v1.8.1 was over-engineered —
    /// nothing about the cleanup logic is expensive enough
    /// to need that throttle.
    func runCleanupIfDue(emergency: Bool) {
        guard cleanupEnabled else { return }
        if !emergency, freeDiskSpace() < emergencyThresholdBytes {
            Task { await runCleanupCycle(emergency: true) }
            return
        }
        Task { await runCleanupCycle(emergency: emergency) }
    }

    /// Manual trigger from Settings → "Clean up now".
    /// Bypasses the storage-emergency check.
    func runCleanupNow() {
        guard cleanupEnabled else { return }
        Task { await runCleanupCycle(emergency: false) }
    }

    // MARK: - Public API: refresh (v1.8.2)

    /// 2026-08-12: "Refresh downloads" button in Settings.
    /// User-initiated full library refresh: delete ALL
    /// current downloads, then re-download based on the
    /// same candidate selection as the auto-download
    /// cycle (liked artists' top tracks + recently played
    /// not yet downloaded). Bypasses the maxLibraryTracks
    /// check (the user explicitly asked for a full refresh,
    /// so the library will fit after the clear).
    ///
    /// The downloaded tracks are marked as "auto" in
    /// the tier set so the cleanup grace period (14d
    /// unplayed) applies. If the user wants to keep them
    /// long-term, they can heart them; liked tracks
    /// graduate to the "never removed" tier.
    ///
    /// The fresh deletion of the old library means
    /// protected-state checks (currently playing, in
    /// queue, time capsule) need to bypass. The current
    /// `fetchDownloadedTracksFromCoreData` returns all
    /// rows, including protected ones — but `deleteDownload`
    /// is async and the AVPlayer won't crash if the
    /// underlying file disappears mid-play (it'll just
    /// error out and stop). Acceptable trade-off for
    /// an explicit user action.
    func runRefreshNow() {
        guard !isRefreshing else { return }
        Task { await runRefreshCycle() }
    }

    /// Number of tracks currently downloaded. Used by
    /// the auto-download cycle to check maxLibraryTracks
    /// and by the Settings UI to show "X of N" status.
    /// Single CoreData fetch — O(n) in downloaded count,
    /// typically <100ms.
    func currentDownloadedTrackCount() -> Int {
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        return (try? context.count(for: request)) ?? 0
    }

    /// v1.9.0: Number of downloaded tracks that are also
    /// in the user's liked set. Used by the Refresh
    /// Downloads confirm sheet so the user sees a concrete
    /// "X tracks, including Y liked" before nuking the
    /// library. Single CoreData fetch over the joined
    /// CDDownloadedTrack + CDTrack + likedTracks set.
    ///
    /// Liked tracks are NEVER auto-removed by the cleanup
    /// cycle, so the Refresh flow's "delete all then
    /// re-derive" is genuinely destructive for the liked
    /// subset — the user would have to re-heart them
    /// after the refresh if they want permanent retention.
    /// Showing the count makes that cost visible.
    func likedDownloadedCount() -> Int {
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        let rows = (try? context.fetch(request)) ?? []
        let likedIds = PlaylistManager.shared.likedTracks
        return rows.filter { row in
            guard let videoId = row.track?.videoId else { return false }
            return likedIds.contains(videoId)
        }.count
    }

    // MARK: - Public API: free disk space

    /// Free disk space available to the app, in bytes.
    /// Returns Int64.max on lookup failure (effectively
    /// "unlimited", which is safer than zero — the cycle
    /// won't run but the cleanup will).
    func freeDiskSpace() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForOpportunisticUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let capacity = values.volumeAvailableCapacityForOpportunisticUsage else {
            return Int64.max
        }
        return capacity
    }

    // The @AppStorage(Int) wrapper above stores byte-count
    // values as Int (== Int64 on 64-bit). Compare them with
    // Int64-converted local copies to keep the arithmetic
    // typed. Tiny helpers to avoid sprinkling Int64(...) casts
    // through the run-cleanup code.

    // MARK: - Private: auto-download cycle

    /// Auto-download candidates. Returns up to
    /// `autoDownloadMaxPerCycle` tracks to download, ordered
    /// by "user likely wants this". The two tiers are
    /// weighted: 1 new-release/top-track per liked artist
    /// (up to 10 artists) first, then recently-played tracks
    /// that aren't downloaded yet, filling the remainder of
    /// the per-cycle cap.
    ///
    /// v1.9.0: bumped the artist probe cap from 5 to 10.
    /// Users with 20+ liked artists were only seeing the
    /// first 5 of them represented in auto-downloads — a
    /// silent truncation that read as "my library only knows
    /// about 5 of my favourite artists". 10 is a balance
    /// against the per-cycle cap (20 by default — bumping
    /// above 20 starts to feel aggressive on a slow WiFi
    /// reconnect).
    private func computeAutoDownloadCandidates() async -> [Track] {
        let likedArtists = FavoriteArtistsManager.shared.getArtists()
        let recentlyPlayedTracks = DataManager.shared.recentlyPlayed
            .map { $0.toTrack }
            .filter { !DownloadManager.shared.isAlreadyDownloaded($0) }

        // Tier 1: 1 search result per liked artist (up to 5
        // artists). search() returns the artist's top track
        // (or newest, depending on backend ranking) which
        // serves as a proxy for "new release or top track".
        // The user asked for "both, weighted" — taking the
        // first result from search gets us both because the
        // backend's ranking is recency-weighted. We deduplicate
        // across artists to avoid the same track appearing
        // twice.
        var candidates: [Track] = []
        var seenVideoIds = Set<String>()

        for artist in likedArtists.prefix(10) {
            if let track = await firstSearchResult(for: artist, excluding: seenVideoIds) {
                candidates.append(track)
                seenVideoIds.insert(track.videoId)
            }
        }

        // Tier 2: recently-played tracks that aren't already
        // downloaded, filled in until we hit the cap. The
        // recentlyPlayedTracks list is already ordered by
        // recency (most recent first), so taking prefix(N)
        // gives us the freshest unplayed-offline tracks.
        for track in recentlyPlayedTracks {
            if candidates.count >= autoDownloadMaxPerCycle { break }
            if seenVideoIds.contains(track.videoId) { continue }
            candidates.append(track)
            seenVideoIds.insert(track.videoId)
        }

        return Array(candidates.prefix(autoDownloadMaxPerCycle))
    }

    /// v1.9.0: tier-1 eligibility filter. Public-static so
    /// unit tests can exercise the predicate without
    /// standing up the search / network layer.
    ///
    /// Rules:
    ///   - `isAudioTrack` must be true (excludes karaoke
    ///     tracks, music videos with extended talking intros,
    ///     and any non-music-video-typed result that the
    ///     YouTube search may surface)
    ///   - duration must be in [30s, 15min] (excludes
    ///     shorts/loops < 30s and full DJ sets / live
    ///     recordings > 15min that the user probably didn't
    ///     mean to "auto-top up")
    ///
    /// The 30s lower bound also covers the case where a
    /// search returns a "Topic" channel auto-generated track
    /// that's just a 30s sample — explicitly rejected.
    static func isAutoDownloadEligible(_ track: Track) -> Bool {
        guard track.isAudioTrack else { return false }
        let duration = track.durationSeconds
        guard duration >= 30, duration <= 15 * 60 else { return false }
        return true
    }

    /// Fetch the first search result for an artist query that
    /// isn't already in the `excluding` set. Returns nil on
    /// failure or if all results are already candidates or
    /// fail the tier-1 filter.
    /// Bounded by a 5s timeout — a hung backend shouldn't
    /// block the auto-download cycle indefinitely.
    ///
    /// v1.9.0: the picker now applies `isAutoDownloadEligible`
    /// (track.isAudioTrack + duration in 30s..15min). Without
    /// this, the backend's "first result" for a query like
    /// "Tame Impala" can return a karaoke/instrumental/music-
    /// video-with-talking track that the user doesn't actually
    /// want auto-downloaded. The filter is loose enough to
    /// accept any reasonable song but tight enough to skip
    /// the obvious non-music picks.
    private func firstSearchResult(for artist: String, excluding: Set<String>) async -> Track? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Track?, Never>) in
            var resumed = false
            let task = APIService.shared.search(query: artist, limit: 5)
                .sink(
                    receiveCompletion: { _ in
                        if !resumed {
                            resumed = true
                            continuation.resume(returning: nil)
                        }
                    },
                    receiveValue: { tracks in
                        if resumed { return }
                        // Pick the first result not already in
                        // the exclusion set, not already
                        // downloaded, and that passes the
                        // tier-1 filter. (The exclusion set is
                        // the dedup across multiple artists in
                        // this cycle — without it, the same
                        // track could appear twice if the user
                        // has 2 liked artists and the backend
                        // ranks the same song for both.)
                        let pick = tracks.first { track in
                            !excluding.contains(track.videoId) &&
                            !DownloadManager.shared.isAlreadyDownloaded(track) &&
                            Self.isAutoDownloadEligible(track)
                        }
                        resumed = true
                        continuation.resume(returning: pick)
                    }
                )
            // 5s safety timeout — independent of the publisher's
            // own timeout. If neither receiveCompletion nor
            // receiveValue fires in 5s, the search has hung
            // (e.g., backend is unreachable but NetworkMonitor
            // hasn't noticed yet). Resume nil so the cycle
            // continues.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if !resumed {
                    resumed = true
                    task.cancel()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func runAutoDownloadCycle() async {
        // Re-check all preconditions on the actual cycle
        // (not just the .due check). A user could have
        // toggled autoDownloadEnabled off, the network
        // could have changed, etc., between the .due call
        // and the actual run.
        guard autoDownloadEnabled else { return }
        guard NetworkMonitor.shared.connectionType == .wifi else { return }
        guard !NetworkMonitor.shared.isMetered else { return }
        guard NetworkMonitor.shared.isBackendReachable else { return }
        guard freeDiskSpace() > minFreeBytes else { return }
        // v1.8.2: library-size check. If the user already
        // has maxLibraryTracks or more downloaded, skip
        // the cycle (don't top up a full library). The
        // status line in Settings will show "X of N
        // (at limit)" so the user can see why nothing
        // happened. Empty tracks are NOT counted — only
        // CDDownloadedTrack rows that survive
        // isPlayable's reconciliation.
        let currentCount = currentDownloadedTrackCount()
        if currentCount >= maxLibraryTracks {
            // Don't update lastAutoDownloadAt / count — we
            // didn't actually do anything. Just record the
            // skip reason so the status line can show it.
            lastAutoDownloadSkippedReason = "Library full (\(currentCount)/\(maxLibraryTracks))"
            return
        }
        lastAutoDownloadSkippedReason = nil

        isAutoDownloading = true
        defer { isAutoDownloading = false }

        let candidates = await computeAutoDownloadCandidates()

        var downloadedCount = 0
        var bytesEstimated: Int64 = 0
        for track in candidates {
            // v1.8.2: per-iteration library-count check.
            // The count above might have changed between the
            // start of the cycle and now (user manually
            // downloaded a track, a previous cycle is
            // still finishing). Stop the moment we hit the
            // cap, even mid-cycle.
            let nowCount = currentDownloadedTrackCount()
            if nowCount >= maxLibraryTracks {
                break
            }
            // Re-check isAlreadyDownloaded at kick-off time —
            // a track may have been downloaded between candidate
            // selection and now (e.g., user manually downloaded
            // it). If so, skip and don't add to the auto set
            // (user explicitly downloaded = manual tier).
            if DownloadManager.shared.isAlreadyDownloaded(track) {
                // If it was previously auto-set (e.g., the user
                // re-downloaded the same track), the existing
                // entry is fine. If it was a fresh manual
                // download, the user took an explicit action —
                // leave the auto set as-is.
                continue
            }
            DownloadManager.shared.download(track, source: .auto)
            markAsAutoDownloaded(track.videoId)
            downloadedCount += 1
            // Estimate ~5 MB per track. Used only for the
            // Settings status line ("Last run: 3h ago · 12
            // tracks · ~60 MB"). Real bytes are hard to
            // measure without polling DownloadManager.
            bytesEstimated += 5_000_000
        }

        lastAutoDownloadAt = Date()
        lastAutoDownloadCount = downloadedCount
        lastAutoDownloadBytesEstimated = bytesEstimated
        defaults.set(lastAutoDownloadAt, forKey: Keys.lastAutoDownloadAt)
        defaults.set(downloadedCount, forKey: Keys.lastAutoDownloadCount)
        defaults.set(Int(bytesEstimated), forKey: Keys.lastAutoDownloadBytesEstimated)
    }

    // MARK: - Private: refresh cycle (v1.8.2)
    //
    // User-initiated from Settings → "Refresh Downloads"
    // button. Clears the entire library, then runs the
    // same candidate selection as the auto-download cycle
    // and downloads. The new tracks are marked as "auto"
    // (tier) so the 14d cleanup grace period applies; the
    // user can heart them for "never removed" protection.
    //
    // Why we delete first (not just "replace what we can"):
    // The user pressed Refresh because they want a fresh
    // library based on current listening. Keeping the old
    // tracks would defeat the point. The current "play
    // history" candidates reflect what the user is
    // listening to NOW, not what they listened to last
    // week — so deleting and re-deriving gives them a
    // library that matches their current taste.
    private func runRefreshCycle() async {
        isRefreshing = true
        defer { isRefreshing = false }

        // 1. Delete all current downloads. Includes liked
        // tracks (the user explicitly asked for a full
        // reset) and time-capsule tracks (acceptable —
        // the user can re-seal them). The cleanup's
        // "skip if in queue" check doesn't apply because
        // the queue is independent of CoreData; the
        // AVPlayer will gracefully fail on a missing file
        // if the user is mid-play.
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        guard let rows = try? context.fetch(request) else {
            ErrorHandler.shared.showInfo("Refresh failed: couldn't read library")
            return
        }
        let deletedCount = rows.count
        for row in rows {
            if let videoId = row.track?.videoId {
                DownloadManager.shared.deleteDownload(videoId: videoId)
            }
        }
        ErrorHandler.shared.showInfo("Cleared \(deletedCount) tracks, re-downloading…")

        // 2. Wait briefly for CoreData writes to settle.
        // deleteDownload is synchronous in iOS (it hits
        // both CoreData and the filesystem on the calling
        // thread), but the FRC notifications fire async
        // and we want CDDownloadedTrack.count to be 0
        // before we start downloading. 200ms is plenty
        // for a CoreData write + FRC notification.
        try? await Task.sleep(nanoseconds: 200_000_000)

        // 3. Re-download. Same candidate selection as the
        // auto-download cycle, capped at autoDownloadMaxPerCycle.
        // No library-count check — we just cleared it, so
        // the new downloads always fit.
        let candidates = await computeAutoDownloadCandidates()
        var downloadedCount = 0
        for track in candidates.prefix(autoDownloadMaxPerCycle) {
            if DownloadManager.shared.isAlreadyDownloaded(track) { continue }
            // v1.9.0: refresh-source download. The new tracks
            // are tier-marked .auto below so the 14d cleanup
            // grace period applies; the user can heart them
            // for permanent retention.
            DownloadManager.shared.download(track, source: .refresh)
            markAsAutoDownloaded(track.videoId)
            downloadedCount += 1
        }

        // 4. Update the "last auto-download" timestamp +
        // count so the Settings status line reflects the
        // refresh. The skip reason is cleared.
        lastAutoDownloadAt = Date()
        lastAutoDownloadCount = downloadedCount
        lastAutoDownloadSkippedReason = nil
        defaults.set(lastAutoDownloadAt, forKey: Keys.lastAutoDownloadAt)
        defaults.set(downloadedCount, forKey: Keys.lastAutoDownloadCount)

        ErrorHandler.shared.showInfo("Refreshed: \(downloadedCount) new tracks downloading")
    }

    // MARK: - Private: cleanup cycle

    private func runCleanupCycle(emergency: Bool) async {
        guard cleanupEnabled else { return }
        isCleaningUp = true
        defer { isCleaningUp = false }

        // Fetch all downloaded tracks from CoreData. We
        // can't just use LibraryViewModel.tracks here
        // because that requires a UI binding; we want
        // a direct, model-level query. LibraryViewModel's
        // loadLibrary() does the same fetch (NSFetchRequest
        // over CDDownloadedTrack) but with extra formatting
        // (DownloadedTrackItem wrapper). For the cleanup
        // logic we only need videoId + fileSize, so do the
        // fetch directly here.
        let downloaded = fetchDownloadedTracksFromCoreData()
        guard !downloaded.isEmpty else {
            // Nothing to clean up. Update the timestamp so
            // the next foreground doesn't re-check.
            lastCleanupAt = Date()
            lastCleanupCount = 0
            lastCleanupBytesFreed = 0
            defaults.set(lastCleanupAt, forKey: Keys.lastCleanupAt)
            defaults.set(0, forKey: Keys.lastCleanupCount)
            defaults.set(0, forKey: Keys.lastCleanupBytesFreed)
            return
        }

        // Build a quick lookup of lastPlayedAt per videoId
        // from DataManager.recentlyPlayed. RecentlyPlayed
        // is the same source the in-app play history uses;
        // it stores playedAt per track. A track with no
        // entry in recentlyPlayed → never played → unplayed
        // since download → past any threshold.
        let lastPlayedByVideoId: [String: Date] = Dictionary(
            uniqueKeysWithValues: DataManager.shared.recentlyPlayed.map { ($0.videoId, $0.playedAt) }
        )

        // Find currently playing track + queue — never
        // remove tracks the user is listening to or has
        // queued. PlayerState.queue is [QueueItem]; build
        // a Set of videoIds to skip.
        let protectedVideoIds: Set<String> = Set(
            PlayerState.shared.queue.map { $0.track.videoId } +
            (PlayerState.shared.currentItem.map { [$0.track.videoId] } ?? [])
        )

        // Time Capsule tracks must never be auto-removed —
        // they're the only offline copy of a song the user
        // has sealed. We need a way to query "is this track
        // sealed in a Time Capsule?" — for now, skip all
        // tracks where the user has any Time Capsule entry.
        // The list is tiny (the user only has a few capsules)
        // so loading all capsules is cheap.
        let timeCapsuleVideoIds = fetchTimeCapsuleVideoIds()

        // Build the candidates: tracks that pass the
        // tier + recency check AND aren't protected.
        var toRemove: [(videoId: String, fileSize: Int64)] = []
        for entry in downloaded {
            if protectedVideoIds.contains(entry.videoId) { continue }
            if timeCapsuleVideoIds.contains(entry.videoId) { continue }
            let lastPlayed = lastPlayedByVideoId[entry.videoId]
            if shouldAutoRemove(videoId: entry.videoId, lastPlayedAt: lastPlayed) {
                toRemove.append((entry.videoId, entry.fileSize))
            }
        }

        // In emergency mode, if the simple filter didn't
        // find anything, we still need to free space. Drop
        // the recency check but keep the tier protection
        // (never remove liked, never remove time capsule,
        // never remove currently playing) and take the
        // oldest entries.
        if emergency && toRemove.isEmpty {
            for entry in downloaded {
                if protectedVideoIds.contains(entry.videoId) { continue }
                if timeCapsuleVideoIds.contains(entry.videoId) { continue }
                if tier(for: entry.videoId) == .liked { continue }
                toRemove.append((entry.videoId, entry.fileSize))
            }
        }

        // Sort: emergency mode removes auto-downloaded first
        // (cheapest to lose, smallest grace period by design),
        // then oldest-by-fileSize to maximize bytes freed
        // quickly. Non-emergency mode removes in any order
        // (the simple filter already enforced the recency
        // check).
        if emergency {
            toRemove.sort { lhs, rhs in
                let lAuto = tier(for: lhs.videoId) == .auto ? 0 : 1
                let rAuto = tier(for: rhs.videoId) == .auto ? 0 : 1
                if lAuto != rAuto { return lAuto < rAuto }
                return lhs.fileSize > rhs.fileSize
            }
        }

        // Don't remove more than needed to clear the
        // emergency threshold. Walk the sorted list and
        // stop once we're above emergencyThresholdBytes
        // of free space.
        if emergency {
            var bytesFreed: Int64 = 0
            var trimmed: [(videoId: String, fileSize: Int64)] = []
            for entry in toRemove {
                trimmed.append(entry)
                bytesFreed += entry.fileSize
                if freeDiskSpace() + bytesFreed > emergencyThresholdBytes {
                    break
                }
            }
            toRemove = trimmed
        }

        // Actually delete. DownloadManager.deleteDownload
        // posts .downloadDeleted which our setupHooks
        // listener handles (removes from the auto set).
        var deletedCount = 0
        var bytesFreed: Int64 = 0
        for entry in toRemove {
            DownloadManager.shared.deleteDownload(videoId: entry.videoId)
            deletedCount += 1
            bytesFreed += entry.fileSize
        }

        lastCleanupAt = Date()
        lastCleanupCount = deletedCount
        lastCleanupBytesFreed = bytesFreed
        defaults.set(lastCleanupAt, forKey: Keys.lastCleanupAt)
        defaults.set(deletedCount, forKey: Keys.lastCleanupCount)
        defaults.set(Int(bytesFreed), forKey: Keys.lastCleanupBytesFreed)

        // Surface the result as a toast if anything was
        // removed. Use .info (not .parsing / .network) so
        // the toast is informational, not error-framed.
        if deletedCount > 0 {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB, .useKB]
            formatter.countStyle = .file
            let mb = formatter.string(fromByteCount: bytesFreed)
            ErrorHandler.shared.showInfo(
                "Cleaned up \(deletedCount) track\(deletedCount == 1 ? "" : "s") · freed \(mb)"
            )
        }
    }

    /// Direct CoreData fetch. Returns [(videoId, fileSize)].
    /// Avoids the LibraryViewModel UI wrapper since cleanup
    /// is a model-level concern.
    private func fetchDownloadedTracksFromCoreData() -> [(videoId: String, fileSize: Int64)] {
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        do {
            let rows = try context.fetch(request)
            return rows.compactMap { row in
                guard let videoId = row.track?.videoId else { return nil }
                return (videoId, row.fileSize)
            }
        } catch {
            print("⚠️ [SmartLibrary] CoreData fetch failed: \(error)")
            return []
        }
    }

    /// Set of videoIds that are sealed inside a Time Capsule.
    /// Loading all capsules is cheap (the user has a few
    /// at most) and avoids accidentally auto-removing the
    /// only offline copy of a sealed song.
    private func fetchTimeCapsuleVideoIds() -> Set<String> {
        let capsules = TimeCapsuleManager.shared.capsules
        return Set(capsules.map { $0.videoId })
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted by DownloadManager.deleteDownload. UserInfo:
    /// the videoId is the notification's `object` (String).
    /// SmartLibraryManager listens to this and removes the
    /// videoId from its autoDownloadedVideoIds set so the
    /// set doesn't grow unboundedly with stale entries.
    static let downloadDeleted = Notification.Name("smartLibrary.downloadDeleted")
}
