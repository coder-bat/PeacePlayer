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
//      + UIApplication.willEnterForegroundNotification. Debounced
//      to once per 24h via UserDefaults timestamp.
//    - Cleanup: UIApplication.willEnterForegroundNotification.
//      Debounced to once per 7d via UserDefaults timestamp.
//      Storage emergency (< 1GB free) bypasses the debounce and
//      prioritises auto-downloaded removals first.
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
    @Published private(set) var lastCleanupAt: Date?
    @Published private(set) var lastCleanupCount: Int = 0
    @Published private(set) var lastCleanupBytesFreed: Int64 = 0
    @Published private(set) var isAutoDownloading: Bool = false
    @Published private(set) var isCleaningUp: Bool = false

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

        // App foreground → run both cycles (each has its own
        // debounce). The willEnterForegroundNotification is
        // the canonical "user is back in the app" signal;
        // .active scene phase also fires here but the
        // notification has a cleaner contract for our purposes.
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                self?.runAutoDownloadIfDue()
                self?.runCleanupIfDue(emergency: false)
            }
            .store(in: &cancellables)

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

    /// Run the auto-download cycle if it's due. Debounced
    /// to once per 24h (lastAutoDownloadAt). All other
    /// preconditions are checked inside runAutoDownloadCycle.
    func runAutoDownloadIfDue() {
        guard autoDownloadEnabled else { return }
        if let last = lastAutoDownloadAt, Date().timeIntervalSince(last) < 24 * 3600 {
            return
        }
        Task { await runAutoDownloadCycle() }
    }

    /// Run the auto-cleanup cycle if it's due. Debounced
    /// to once per 7d (lastCleanupAt). Storage-emergency
    /// path (free space < emergencyThresholdBytes) bypasses
    /// the debounce and is triggered automatically inside.
    /// If `emergency` is true, bypasses the debounce and
    /// prioritises auto-downloaded removals.
    func runCleanupIfDue(emergency: Bool) {
        guard cleanupEnabled else { return }
        if !emergency, let last = lastCleanupAt, Date().timeIntervalSince(last) < 7 * 24 * 3600 {
            return
        }
        // Storage emergency check: if free space is below
        // threshold AND we're not already in an emergency
        // pass, run emergency cleanup.
        if !emergency, freeDiskSpace() < emergencyThresholdBytes {
            Task { await runCleanupCycle(emergency: true) }
            return
        }
        Task { await runCleanupCycle(emergency: emergency) }
    }

    /// Manual trigger from Settings → "Clean up now". Bypasses
    /// the debounce and the storage-emergency check.
    func runCleanupNow() {
        guard cleanupEnabled else { return }
        Task { await runCleanupCycle(emergency: false) }
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
    /// (up to 5 artists) first, then recently-played tracks
    /// that aren't downloaded yet, filling the remainder of
    /// the per-cycle cap.
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

        for artist in likedArtists.prefix(5) {
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

    /// Fetch the first search result for an artist query that
    /// isn't already in the `excluding` set. Returns nil on
    /// failure or if all results are already candidates.
    /// Bounded by a 5s timeout — a hung backend shouldn't
    /// block the auto-download cycle indefinitely.
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
                        // the exclusion set and not already
                        // downloaded. (The exclusion set is the
                        // dedup across multiple artists in this
                        // cycle — without it, the same track
                        // could appear twice if the user has 2
                        // liked artists and the backend ranks
                        // the same song for both.)
                        let pick = tracks.first { track in
                            !excluding.contains(track.videoId) &&
                            !DownloadManager.shared.isAlreadyDownloaded(track)
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

        isAutoDownloading = true
        defer { isAutoDownloading = false }

        let candidates = await computeAutoDownloadCandidates()

        var downloadedCount = 0
        var bytesEstimated: Int64 = 0
        for track in candidates {
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
            DownloadManager.shared.download(track)
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
