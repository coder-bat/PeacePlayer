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

// MARK: - v1.9.0 cycle types

/// A prepared set of auto-download candidates waiting for
/// user confirmation (or auto-confirm by timer). The cycle
/// has been computed (candidates selected, preconditions
/// checked) but no downloads have been kicked off yet.
///
/// `id` is the cycle's identity — SwiftUI uses it to
/// distinguish cycles for animations and to let
/// `commitCycle(_:source:)` reject stale cycles if the
/// user backed out and re-prepared between prepare and
/// commit.
struct PendingCycle: Equatable, Identifiable {
    let id: UUID
    let candidates: [Track]
    let estimatedBytes: Int64
    let createdAt: Date
    let tierBreakdown: TierBreakdown

    /// The source to use when this cycle commits. Always
    /// `.auto` for the normal auto-cycle — the user-confirmed
    /// vs auto-confirmed distinction is on the CycleSummary,
    /// not the download tier.
    let downloadSource: DownloadSource

    static func == (lhs: PendingCycle, rhs: PendingCycle) -> Bool {
        lhs.id == rhs.id
    }
}

/// How the candidate set was assembled. Drives the
/// "Liked artists (3) / Recently played (2)" filter chips
/// in the Review sheet.
struct TierBreakdown: Equatable {
    let fromLikedArtists: Int
    let fromRecentlyPlayed: Int
    var total: Int { fromLikedArtists + fromRecentlyPlayed }
}

/// What happened after a cycle committed. Drives the
/// post-run undo toast and the Settings status line.
struct CycleSummary: Equatable, Identifiable {
    let id: UUID
    let addedVideoIds: [String]
    let failedVideoIds: [String]
    let bytesEstimated: Int64
    /// v1.9.0: real bytes are read from CDDownloadedTrack.fileSize
    /// after commit. In Phase B this is still an estimate
    /// (~5 MB/track) — Phase C replaces it with the actual
    /// sum once downloads complete.
    let bytesActual: Int64
    let committedAt: Date
    let source: CommitSource

    /// Where the commit came from. Used by the UI to
    /// decide whether to show the undo toast (yes for
    /// user-confirmed, yes for auto-confirmed) and by
    /// future analytics to learn which path users prefer.
    enum CommitSource: String, Equatable {
        case userConfirmed
        case autoConfirmed
    }

    var undoAvailable: Bool {
        !addedVideoIds.isEmpty
    }
}

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

    /// 2026-09-08: grace window between marking a track as
    /// "scheduled for cleanup" and the actual file move. During
    /// this window the track stays in the library, still
    /// playable, and the banner shows the countdown. After the
    /// window elapses, the next foreground moves the files to
    /// trash (recoverable for the trash retention period).
    /// Default 24h — long enough to notice, short enough that
    /// "I forgot to deal with it" doesn't leave the device
    /// gradually filling.
    @AppStorage("smartLibrary.cleanupGraceSeconds") var cleanupGraceSeconds: Int = 86_400  // 24h

    /// 2026-09-08: how long trashed files are kept before
    /// permanent delete. During this window the user can restore
    /// from Settings → Trash. Default 7d — matches iOS Photos
    /// "Recently Deleted" expectation without making it a
    /// "save anything forever" feature.
    @AppStorage("smartLibrary.trashRetentionDays") var trashRetentionDays: Int = 7

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

    // MARK: - v1.9.0 cycle state (publish/commit split)

    /// The currently-pending auto-download cycle, if any.
    /// Nil = no cycle in flight. Non-nil = candidates are
    /// ready and waiting for user action (Download / Review /
    /// Skip) or auto-confirm.
    @Published private(set) var pendingCandidates: PendingCycle? = nil

    /// The deadline at which `pendingCandidates` will
    /// auto-confirm. Nil when there is no pending cycle or
    /// when auto-confirm is off (`autoConfirmSeconds <= 0`).
    @Published private(set) var autoConfirmDeadline: Date? = nil

    /// The most recently committed cycle's result. Set when
    /// `commitCycle(_:source:)` finishes, cleared by
    /// `dismissSummary()` or by the next commit.
    @Published private(set) var lastCycleSummary: CycleSummary? = nil

    /// 2026-09-08: the currently-pending ask-before-cleanup
    /// batch. Nil = nothing scheduled (or the 24h grace has
    /// already been auto-committed and there's nothing new).
    /// Non-nil = tracks are marked `cleanupScheduledAt`,
    /// the banner is showing, and the user has until
    /// `expiresAt` to review and decide.
    @Published private(set) var pendingCleanup: PendingCleanup? = nil

    /// 2026-09-08: the most recent committed cleanup. Set when
    /// `commitPendingCleanup` (or the auto-grace path) finishes.
    /// Drives the post-run toast with Undo (restore from trash).
    /// Cleared by `dismissCleanupSummary()` or by the next commit.
    @Published private(set) var lastCleanupSummary: CleanupSummary? = nil

    /// 2026-09-08: total bytes currently held in trash. Drives
    /// the Settings → Trash section's "X MB recoverable" line.
    @Published private(set) var trashBytes: Int64 = 0

    /// v1.9.0: user-configurable auto-confirm window.
    /// Stored in seconds. 0 = off (no auto-confirm, user
    /// must explicitly tap Download). Default 0 (Off) —
    /// the user requested the "library ready" auto-fire
    /// behavior to be opt-in rather than default-on. The
    /// previous v1.8.2 default was 300 (5 min).
    /// Surfaced in Settings as a Picker: Off / 1m / 5m / 15m / 30m.
    @AppStorage("smartLibrary.autoConfirmSeconds") var autoConfirmSeconds: Int = 0

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

    // v1.9.0: handle to the active auto-confirm Task. Cancelled
    // when the user commits, skips, or the cycle is cancelled for
    // any reason (background, toggle off, network change). When
    // it fires, the cycle commits with source: .autoConfirmed.
    private var autoConfirmTask: Task<Void, Never>? = nil

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
        // 2026-09-08: rebuild the pending-cleanup banner
        // state on launch. If the user closed the app with
        // a banner showing, the CoreData rows still have
        // `cleanupScheduledAt` set — the banner just needs
        // to be reconstructed from them. Same for trash
        // bytes (the trash directory persists across
        // launches; the in-memory `trashBytes` needs to be
        // populated).
        refreshPendingCleanup()
        refreshTrashBytes()
    }

    private func loadState() {
        if let data = defaults.data(forKey: Keys.autoDownloadedIds),
           let decoded = try? decoder.decode(Set<String>.self, from: data) {
            autoDownloadedVideoIds = decoded
        }
        // v1.9.0 (r2) migration: existing users on v1.8.2
        // have autoConfirmSeconds = 300 (the old default)
        // persisted. The new default is 0 (Off) per
        // user request — "only download if the user
        // confirms". A one-time reset for the old default
        // value ensures the migration is invisible;
        // users who explicitly set a custom value are
        // left alone.
        let storedAutoConfirm = defaults.integer(forKey: "smartLibrary.autoConfirmSeconds")
        if storedAutoConfirm == 300 {
            defaults.set(0, forKey: "smartLibrary.autoConfirmSeconds")
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
                guard isWiFi else {
                    // v1.9.0: WiFi dropped → cancel any
                    // pending cycle. The cycle is only valid
                    // on WiFi, so leaving it pending on
                    // cellular would either commit on
                    // cellular (bad — burns user data) or
                    // sit forever waiting for WiFi to
                    // come back (also bad — stale state).
                    self?.cancelPendingCycle(reason: "WiFi dropped")
                    return
                }
                self?.runAutoDownloadIfDue()
            }
            .store(in: &cancellables)

        // v1.9.0: when the network becomes metered (Low
        // Data Mode, hotspot), cancel any pending cycle.
        // Metered is one of the prepare-preconditions; if
        // it flips true after prepare but before commit,
        // the next prepare would have skipped anyway.
        // Cancelling here matches the user's mental
        // model: "I turned on Low Data Mode, the app
        // should respect that".
        NetworkMonitor.shared.$isMetered
            .removeDuplicates()
            .sink { [weak self] isMetered in
                guard isMetered else { return }
                self?.cancelPendingCycle(reason: "network became metered")
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

        // v1.9.0: cancel the pending cycle when the user
        // toggles the master switch off. The cycle is
        // invalid while the toggle is off; leaving it
        // pending would either commit anyway (defeats
        // the toggle) or sit forever waiting for the
        // toggle to come back (also bad — stale state).
        //
        // @AppStorage is a property wrapper but the
        // $ projection gives a Binding, not a Combine
        // publisher. We observe UserDefaults directly
        // via KVO publisher. The key matches the
        // @AppStorage key verbatim. We compare values
        // in the sink (not via removeDuplicates) so the
        // publisher's first value doesn't fire and
        // accidentally cancel a cycle before any user
        // action has happened.
        UserDefaults.standard
            .publisher(for: \.smartLibraryAutoDownloadEnabled)
            .sink { [weak self] enabled in
                guard !enabled else { return }
                self?.cancelPendingCycle(reason: "autoDownloadEnabled toggled off")
            }
            .store(in: &cancellables)

        // v1.9.0: cancel the pending cycle on app
        // backgrounding. The user has left the app;
        // the 5-min auto-confirm timer is invalidated
        // and the next foreground re-prepares with
        // fresh candidates. This matches the
        // "Cancel + re-prepare" decision from the
        // planning phase.
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                self?.cancelPendingCycle(reason: "app backgrounded")
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

    /// v1.9.0: Run the auto-download cycle's *prepare*
    /// phase. Computes candidates and publishes them to
    /// `pendingCandidates`. The actual downloads happen
    /// when the user confirms (via the Smart Library card)
    /// or the auto-confirm timer fires.
    ///
    /// v1.8.2: dropped the 24h debounce. The product
    /// intent is "always have library ready" — every WiFi
    /// connect + every foreground is a chance to top up.
    /// The hard limiter is now maxLibraryTracks: if the
    /// library is already at the cap, we skip (so a user
    /// with a 200-track manual library doesn't get spammed
    /// with auto-downloads they don't need). The 30s
    /// debounce on the WiFi trigger (in setupHooks) is
    /// the only rate limiting.
    ///
    /// All other preconditions (toggle, WiFi, metered,
    /// backend, free space) are checked inside
    /// `prepareCycle()`.
    func runAutoDownloadIfDue() {
        guard autoDownloadEnabled else { return }
        Task { await prepareCycle() }
    }

    /// v1.9.0: prepare an auto-download cycle and publish
    /// it to `pendingCandidates`. The cycle is then either
    /// committed by the user (via the card), committed by
    /// the auto-confirm timer, or cancelled (toggle off,
    /// backgrounding, network change).
    ///
    /// Idempotent: if a cycle is already pending, the
    /// existing one is left in place (the new prepare is
    /// a no-op). This prevents thrashing the candidate
    /// list if `runAutoDownloadIfDue` is called multiple
    /// times in quick succession (e.g., on a WiFi
    /// reconnect that fires two path updates within the
    /// 30s debounce).
    func prepareCycle() async {
        // If a cycle is already pending, leave it alone.
        // A new prepare is a no-op — the user can still
        // act on the existing cycle.
        guard pendingCandidates == nil else { return }

        // Re-check all preconditions. A user could have
        // toggled autoDownloadEnabled off, the network
        // could have changed, etc., between the trigger
        // and the actual run.
        guard autoDownloadEnabled else { return }
        guard NetworkMonitor.shared.connectionType == .wifi else { return }
        guard !NetworkMonitor.shared.isMetered else { return }
        guard NetworkMonitor.shared.isBackendReachable else { return }
        guard freeDiskSpace() > minFreeBytes else { return }

        // Library-cap check. If the user already has
        // maxLibraryTracks or more downloaded, skip the
        // cycle (don't top up a full library).
        let currentCount = currentDownloadedTrackCount()
        if currentCount >= maxLibraryTracks {
            // Don't update lastAutoDownloadAt / count —
            // we didn't actually do anything. Just record
            // the skip reason so the status line can show
            // it.
            lastAutoDownloadSkippedReason = "Library full (\(currentCount)/\(maxLibraryTracks))"
            return
        }
        lastAutoDownloadSkippedReason = nil

        // Compute candidates. Returns nil if the
        // liked-artists + recently-played lists are
        // empty (or all candidates are already
        // downloaded). We don't surface "no candidates"
        // to the user via the card — that's a silent
        // skip, not a pending cycle.
        guard let cycle = await computePendingCycle() else {
            return
        }

        // Publish. The card (Phase C) will observe
        // `pendingCandidates` and show the UI.
        pendingCandidates = cycle
        scheduleAutoConfirm(for: cycle)
    }

    /// v1.9.0: commit a pending cycle. Downloads the
    /// candidates via DownloadManager and publishes a
    /// `CycleSummary` to `lastCycleSummary`.
    ///
    /// `source` is the commit trigger — user-confirmed
    /// (tapped Download) or auto-confirmed (5-min timer
    /// fired). It drives the post-run toast copy.
    ///
    /// The cycle's `id` is matched against the current
    /// `pendingCandidates.id` — a stale cycle (e.g., the
    /// user backed out and re-prepared) is silently
    /// v1.9.0: replace the current pending cycle with a
    /// user-edited version and commit it in one step.
    /// Called from SmartLibraryReviewSheet when the user
    /// taps "Download N" with a modified candidate list.
    ///
    /// The flow:
    ///   1. Match against the current pendingCandidates.id
    ///      (stale-cycle guard, same as commitCycle).
    ///   2. Replace pendingCandidates with the modified
    ///      cycle (new id, new candidates).
    ///   3. Commit immediately.
    ///
    /// Why a separate method: commitCycle's stale-cycle
    /// guard would reject a modified cycle because the
    /// id doesn't match. replaceAndCommit deliberately
    /// bypasses the guard by writing the modified cycle
    /// to pendingCandidates first, then committing. The
    /// user has explicitly chosen this list — the
    /// "stale" cycle check doesn't apply.
    func replaceAndCommit(_ cycle: PendingCycle, source: CycleSummary.CommitSource) async {
        // Stale guard: only allow replacement if there's
        // an active pending cycle. If the auto-confirm
        // already fired and a commit is in flight, this
        // is a no-op.
        guard pendingCandidates != nil else { return }
        pendingCandidates = cycle
        await commitCycle(cycle, source: source)
    }

    /// rejected. This prevents the "I cancelled but it
    /// downloaded anyway" bug if the auto-confirm timer
    /// fires just as the user re-prepares.
    func commitCycle(_ cycle: PendingCycle, source: CycleSummary.CommitSource) async {
        // Stale-cycle guard. If the user has already
        // cancelled or re-prepared, do nothing.
        guard pendingCandidates?.id == cycle.id else { return }

        // Clear the pending state + cancel the auto-
        // confirm timer. The card will hide; the post-run
        // toast will appear when the commit completes.
        cancelAutoConfirmTimer()
        autoConfirmDeadline = nil
        pendingCandidates = nil

        isAutoDownloading = true
        defer { isAutoDownloading = false }

        var addedVideoIds: [String] = []
        var failedVideoIds: [String] = []
        var bytesEstimated: Int64 = 0
        var downloadedCount = 0

        for track in cycle.candidates {
            // Per-iteration library-count re-check. The
            // count at prepare time might have changed
            // between then and now (user manually
            // downloaded a track, a previous cycle is
            // still finishing). Stop the moment we hit
            // the cap, even mid-cycle.
            let nowCount = currentDownloadedTrackCount()
            if nowCount >= maxLibraryTracks { break }

            // Per-iteration isAlreadyDownloaded re-check.
            // A track may have been downloaded between
            // prepare and commit (e.g., user manually
            // downloaded it).
            if DownloadManager.shared.isAlreadyDownloaded(track) {
                // If it was previously auto-set and the
                // user manually re-downloaded it, the
                // tier-upgrade fix (Phase A) has already
                // pruned it from the auto set. Don't
                // touch it.
                continue
            }
            DownloadManager.shared.download(track, source: cycle.downloadSource)
            markAsAutoDownloaded(track.videoId)
            downloadedCount += 1
            addedVideoIds.append(track.videoId)
            bytesEstimated += 5_000_000
        }

        // Update the "last auto-download" status fields.
        // These drive the Settings status line, not the
        // card or the post-run toast.
        lastAutoDownloadAt = Date()
        lastAutoDownloadCount = downloadedCount
        lastAutoDownloadBytesEstimated = bytesEstimated
        defaults.set(lastAutoDownloadAt, forKey: Keys.lastAutoDownloadAt)
        defaults.set(downloadedCount, forKey: Keys.lastAutoDownloadCount)
        defaults.set(Int(bytesEstimated), forKey: Keys.lastAutoDownloadBytesEstimated)

        // Build and publish the post-run summary. The
        // post-run toast observes this.
        let summary = CycleSummary(
            id: UUID(),
            addedVideoIds: addedVideoIds,
            failedVideoIds: failedVideoIds,
            bytesEstimated: bytesEstimated,
            // v1.9.0: real bytes are not yet measured
            // (they require waiting for downloads to
            // complete, which is async). Phase C
            // replaces this with a sum of
            // CDDownloadedTrack.fileSize from the
            // committed tracks.
            bytesActual: bytesEstimated,
            committedAt: Date(),
            source: source
        )
        lastCycleSummary = summary

        // v1.9.0: post-run undo toast. The UndoService is
        // a process-wide singleton observed by
        // UndoToastView (rendered globally in ContentView,
        // above the tab bar + MiniPlayer). Registering an
        // undo here makes the toast appear the moment the
        // commit lands; the user gets immediate feedback
        // that the cycle ran.
        //
        // The restore closure is the undoLastCycle() call
        // — it walks addedVideoIds and deletes the
        // downloads. See the undoLastCycle() docstring
        // for the in-flight edge case.
        if !addedVideoIds.isEmpty {
            let count = addedVideoIds.count
            let bytesString = byteString(bytesEstimated)
            UndoService.shared.registerUndo(
                message: "Added \(count) \(count == 1 ? "track" : "tracks") · ~\(bytesString)",
                restore: { [weak self] in
                    Task { [weak self] in
                        await self?.undoLastCycle()
                    }
                },
                showUndoButton: true
            )
        }
    }

    /// v1.9.0: undo the most recent cycle's downloads.
    /// Walks the `addedVideoIds` in `lastCycleSummary`
    /// and deletes each one via `DownloadManager`. The
    /// `.downloadDeleted` notification will fire per
    /// deletion and the `setupHooks` listener at the top
    /// of this file removes the videoId from
    /// `autoDownloadedVideoIds` automatically.
    ///
    /// In-flight edge case: if the user taps Undo within
    /// a few seconds of the commit (before all downloads
    /// have completed), the in-flight downloads will
    /// continue. `deleteDownload` for an in-flight
    /// download will:
    ///   - remove the CDDownloadedTrack row (if it
    ///     exists yet) — the .downloadDeleted handler
    ///     removes it from autoDownloadedVideoIds
    ///   - delete the local file (no-op if not yet on
    ///     disk)
    ///   - the in-flight download will complete and
    ///     re-add the row + file
    /// The net effect: an Undo during downloads is
    /// partially honored — tracks that already
    /// completed are removed, in-flight ones stick
    /// around. This is the same behavior as the
    /// "deleted a track from the library while it was
    /// still downloading" edge case elsewhere in the
    /// app. Fixing it properly would require hooking
    /// into BackgroundDownloadService to cancel active
    /// tasks by videoId, which is out of scope for v1.
    @discardableResult
    func undoLastCycle() async -> Bool {
        guard let summary = lastCycleSummary else { return false }
        guard !summary.addedVideoIds.isEmpty else { return false }
        for videoId in summary.addedVideoIds {
            DownloadManager.shared.deleteDownload(videoId: videoId)
        }
        lastCycleSummary = nil
        return true
    }

    /// Format bytes as a human-readable string (e.g.
    /// "24 MB"). Used by the post-run toast and the
    /// Settings status line.
    private func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// v1.9.0: cancel a pending cycle. Clears
    /// `pendingCandidates`, cancels the auto-confirm
    /// timer, and clears the deadline. Called by:
    ///   - the Smart Library card's Skip button
    ///   - the autoDownloadEnabled toggle being flipped off
    ///   - the app being backgrounded
    ///   - WiFi dropping or becoming metered
    ///
    /// `reason` is a debug-only log string; not surfaced
    /// in the UI.
    func cancelPendingCycle(reason: String? = nil) {
        guard pendingCandidates != nil else { return }
        cancelAutoConfirmTimer()
        autoConfirmDeadline = nil
        pendingCandidates = nil
        if let reason = reason, ProcessInfo.processInfo.environment["OS_ACTIVITY_MODE"] != "disable" {
            print("🛑 [SmartLibrary] Cancelled pending cycle: \(reason)")
        }
    }

    /// v1.9.0: dismiss the post-run summary card / toast.
    /// Called by the user tapping "Got it" or the
    /// 24h-TTL auto-dismiss.
    func dismissSummary() {
        lastCycleSummary = nil
    }

    /// v1.9.0: human-readable countdown text for the
    /// "Auto-confirming in 4:32" line in the card. Returns
    /// nil if no auto-confirm is scheduled (either no
    /// pending cycle, or auto-confirm is off).
    var autoConfirmRemainingFormatted: String? {
        guard let deadline = autoConfirmDeadline else { return nil }
        let remaining = max(0, Int(deadline.timeIntervalSinceNow))
        let m = remaining / 60
        let s = remaining % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Private: auto-confirm timer

    /// v1.9.0: schedule the auto-confirm Task for a
    /// freshly-prepared cycle. Cancels any previously-
    /// scheduled timer (a new prepare replaces the old).
    private func scheduleAutoConfirm(for cycle: PendingCycle) {
        cancelAutoConfirmTimer()
        let seconds = autoConfirmSeconds
        guard seconds > 0 else {
            // Off — no auto-confirm. The user must
            // explicitly tap Download or Skip.
            autoConfirmDeadline = nil
            return
        }
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        autoConfirmDeadline = deadline
        let cycleId = cycle.id
        autoConfirmTask = Task { [weak self] in
            let nanos = UInt64(seconds) * 1_000_000_000
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                // Stale-cycle guard: if the user cancelled
                // or re-prepared in the meantime, the
                // current pendingCandidates will have a
                // different id (or be nil).
                guard self.pendingCandidates?.id == cycleId else { return }
                let pending = self.pendingCandidates
                self.autoConfirmTask = nil
                guard let pending = pending else { return }
                Task { await self.commitCycle(pending, source: .autoConfirmed) }
            }
        }
    }

    /// v1.9.0: cancel the auto-confirm timer. Safe to
    /// call when no timer is scheduled.
    private func cancelAutoConfirmTimer() {
        autoConfirmTask?.cancel()
        autoConfirmTask = nil
    }

    /// 2026-09-08: v1.9.3 — ask-before-cleanup flow.
    ///
    /// On every foreground (and on storage emergency), the
    /// cycle does one of two things:
    ///
    ///   - **Emergency** (free space < emergencyThresholdBytes):
    ///     immediate delete with the same priority rules as
    ///     before. No trash, no undo — this is a safety net
    ///     to keep the device from filling up entirely. The
    ///     post-run toast has no Undo button.
    ///
    ///   - **Normal**: the cycle (a) purges trash older than
    ///     `trashRetentionDays`, (b) commits any previously-
    ///     scheduled cleanups whose `cleanupGraceSeconds` has
    ///     elapsed (moves files to trash), (c) re-computes
    ///     the eligible candidates and either marks them
    ///     `cleanupScheduledAt` (first time) or leaves them
    ///     alone (already pending within the grace window),
    ///     and (d) clears the flag on tracks that are no
    ///     longer eligible (e.g. the user played them).
    ///
    /// The "re-compute on every foreground" model is
    /// deliberate: a track the user just played shouldn't
    /// still be scheduled. Re-running the cycle is cheap
    /// (one CoreData fetch + a tier lookup per row).
    func runCleanupIfDue(emergency: Bool) {
        guard cleanupEnabled else { return }
        if !emergency, freeDiskSpace() < emergencyThresholdBytes {
            // Promote to emergency: storage pressure wins
            // over the ask-first UX. We still call
            // runCleanupCycle but flag the emergency path
            // so the post-run toast has no Undo button.
            Task { await runCleanupCycle(emergency: true) }
            return
        }
        Task { await runCleanupCycle(emergency: emergency) }
    }

    /// 2026-09-08: manual trigger from Settings → "Clean up now".
    /// Goes through the same flow as the auto-cycle: marks
    /// the current candidates as scheduled, then immediately
    /// commits them (skipping the 24h grace) so the user
    /// sees the trash move + post-run toast right away.
    /// Bypasses the storage-emergency check.
    func runCleanupNow() {
        guard cleanupEnabled else { return }
        Task { await runCleanupNowFlow() }
    }

    /// Internal: Settings "Clean up now" implementation.
    /// Marks current candidates, then commits the resulting
    /// batch immediately. Returns true if anything was
    /// trashed.
    private func runCleanupNowFlow() async {
        isCleaningUp = true
        defer { isCleaningUp = false }

        // Step 1: purge expired trash from previous rounds
        let purged = CleanupTrash.shared.purgeExpired(retentionDays: trashRetentionDays)
        if purged > 0 {
            print("🗑️ [SmartLibrary] manual: purged \(purged) bytes of expired trash")
        }
        refreshTrashBytes()

        // Step 2: commit any past-grace items from a prior
        // auto-cycle (e.g. user kept the app closed for 3
        // days — the 24h-elapsed items would otherwise sit
        // indefinitely).
        let committedExpired = await commitExpiredScheduledCleanups()
        if committedExpired > 0 {
            print("🗑️ [SmartLibrary] manual: committed \(committedExpired) past-grace items to trash")
        }

        // Step 3: compute current candidates and mark them.
        let candidates = await computeCleanupCandidates()
        if candidates.isEmpty {
            // Nothing to clean. Surface as a toast so the
            // user knows the tap landed.
            ErrorHandler.shared.showInfo("Library is already tidy — nothing to clean up.")
            return
        }

        // Mark them (so the row state is consistent), then
        // immediately commit (move to trash).
        await markCandidatesForCleanup(candidates)
        let count = await commitPendingCleanupNow()
        if count > 0 {
            // commitPendingCleanupNow already updates
            // lastCleanupAt/Count/BytesFreed and posts the
            // Undo toast.
        }
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
    ///
    /// 2026-09-08: excludes trashed rows so the count
    /// matches what the user sees in the library (the
    /// library view also filters trashed).
    func currentDownloadedTrackCount() -> Int {
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(format: "trashedAt == nil")
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
        request.predicate = NSPredicate(format: "trashedAt == nil")
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
    /// by "user likely wants this".
    ///
    /// Tier weighting (2026-09-14, equal-weight split):
    /// the per-cycle cap is split 50/50 between "liked
    /// artists" and "recently played" so neither source
    /// dominates. Tier 1 gets up to `halfCap` slots
    /// (1 search result per liked artist, capped at halfCap
    /// artists probed). Tier 2 gets the remaining slots
    /// filled with recently-played tracks; if tier 1
    /// underfills, tier 2 overflows into the unused tier-1
    /// slots so we never waste capacity.
    ///
    /// v1.9.0: bumped the artist probe cap from 5 to 10.
    /// Users with 20+ liked artists were only seeing the
    /// first 5 of them represented in auto-downloads — a
    /// silent truncation that read as "my library only knows
    /// about 5 of my favourite artists". 10 is a balance
    /// against the per-cycle cap (20 by default — bumping
    /// above 20 starts to feel aggressive on a slow WiFi
    /// reconnect).
    /// v1.9.0: Compute auto-download candidates and wrap
    /// them in a `PendingCycle`. The cycle is not yet
    /// published — `prepareCycle()` does the precondition
    /// checks and then publishes it.
    ///
    /// Returns nil if no candidates could be assembled
    /// (no liked artists AND no recently played, or all
    /// candidates are already downloaded).
    ///
    /// Returns a non-nil cycle even if `candidates` is
    /// empty after filtering — `prepareCycle()` decides
    /// whether an empty cycle is worth publishing (it's
    /// not — empty cycles return early without publishing).
    private func computePendingCycle() async -> PendingCycle? {
        let maxPerCycle = autoDownloadMaxPerCycle
        // Equal-weight split: each tier gets up to halfCap.
        // Tier 2 overflows into unused tier-1 slots so the
        // total still approaches maxPerCycle when one tier
        // is sparse. max(1, ...) avoids a degenerate 0-cap
        // when maxPerCycle is configured very low.
        let halfCap = max(1, maxPerCycle / 2)

        let likedArtists = FavoriteArtistsManager.shared.getArtists()
        let recentlyPlayedTracks = DataManager.shared.recentlyPlayed
            .map { $0.toTrack }
            .filter { !DownloadManager.shared.isAlreadyDownloaded($0) }

        // Tier 1: 1 search result per liked artist (up to
        // halfCap artists). search() returns the artist's
        // top track (or newest, depending on backend
        // ranking) which serves as a proxy for "new release
        // or top track". We deduplicate across artists to
        // avoid the same track appearing twice.
        var tier1Candidates: [Track] = []
        var seenVideoIds = Set<String>()

        for artist in likedArtists.prefix(halfCap) {
            if let track = await firstSearchResult(for: artist, excluding: seenVideoIds) {
                tier1Candidates.append(track)
                seenVideoIds.insert(track.videoId)
            }
        }

        // Tier 2: recently-played tracks that aren't already
        // downloaded. Cap is the remainder of maxPerCycle
        // after tier 1, so tier 2 overflows into unused
        // tier-1 slots (e.g. user has 2 liked artists and
        // tier 1 only fills 2 → tier 2 gets up to
        // maxPerCycle-2 slots).
        let tier2Cap = maxPerCycle - tier1Candidates.count
        var tier2Candidates: [Track] = []
        for track in recentlyPlayedTracks {
            if tier2Candidates.count >= tier2Cap { break }
            if seenVideoIds.contains(track.videoId) { continue }
            tier2Candidates.append(track)
            seenVideoIds.insert(track.videoId)
        }

        let candidates = tier1Candidates + tier2Candidates
        guard !candidates.isEmpty else { return nil }

        // Cap the final list. (Both tiers are already
        // computed up to autoDownloadMaxPerCycle, so this
        // is a belt-and-suspenders.)
        let capped = Array(candidates.prefix(autoDownloadMaxPerCycle))
        guard !capped.isEmpty else { return nil }

        let breakdown = TierBreakdown(
            fromLikedArtists: tier1Candidates.count,
            fromRecentlyPlayed: tier2Candidates.count
        )

        return PendingCycle(
            id: UUID(),
            candidates: capped,
            estimatedBytes: Int64(capped.count) * 5_000_000,
            createdAt: Date(),
            tierBreakdown: breakdown,
            downloadSource: .auto
        )
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

    // v1.9.0: runAutoDownloadCycle has been removed.
    // The cycle is now split into prepareCycle() (preconditions
    // + compute + publish) and commitCycle(_:source:) (download).
    // See the v1.9.0 block comments above for the rationale.

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
        // v1.9.0: use computePendingCycle (returns a
        // PendingCycle wrapping the candidates + tier
        // breakdown). The Refresh flow ignores the
        // PendingCycle wrapper and just walks the
        // candidates — it doesn't publish to
        // pendingCandidates (that's reserved for the
        // auto-cycle's user-confirm flow).
        let candidates = (await computePendingCycle())?.candidates ?? []
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

    // MARK: - Private: cleanup cycle (v1.9.3 ask-before-cleanup)

    /// v1.9.3: dispatcher. Emergency path runs the old
    /// immediate-delete logic (no trash, no undo). Normal
    /// path runs the new scheduled flow.
    private func runCleanupCycle(emergency: Bool) async {
        guard cleanupEnabled else { return }
        if emergency {
            await runEmergencyCleanup()
            return
        }
        await runScheduledCleanup()
    }

    /// 2026-09-08: emergency cleanup. Free space dropped
    /// below `emergencyThresholdBytes` — delete immediately
    /// with the same priority rules as v1.9.2. No trash,
    /// no undo. Safety net, not a UX feature.
    private func runEmergencyCleanup() async {
        isCleaningUp = true
        defer { isCleaningUp = false }

        let downloaded = fetchDownloadedTracksFromCoreData()
        let protectedVideoIds = currentProtectedVideoIds()
        let timeCapsuleVideoIds = fetchTimeCapsuleVideoIds()
        let lastPlayedByVideoId = lastPlayedLookup()

        // Tier check + recency check (same as before).
        var toRemove = downloaded.filter { entry in
            if protectedVideoIds.contains(entry.videoId) { return false }
            if timeCapsuleVideoIds.contains(entry.videoId) { return false }
            let lastPlayed = lastPlayedByVideoId[entry.videoId]
            return shouldAutoRemove(videoId: entry.videoId, lastPlayedAt: lastPlayed)
        }

        // If the simple filter found nothing, drop the
        // recency check (keep tier + protection) and take
        // everything eligible so the device can breathe.
        if toRemove.isEmpty {
            toRemove = downloaded.filter { entry in
                if protectedVideoIds.contains(entry.videoId) { return false }
                if timeCapsuleVideoIds.contains(entry.videoId) { return false }
                if tier(for: entry.videoId) == .liked { return false }
                return true
            }
        }

        // Sort: auto first, then largest.
        toRemove.sort { lhs, rhs in
            let lAuto = tier(for: lhs.videoId) == .auto ? 0 : 1
            let rAuto = tier(for: rhs.videoId) == .auto ? 0 : 1
            if lAuto != rAuto { return lAuto < rAuto }
            return lhs.fileSize > rhs.fileSize
        }

        // Cap to "just enough to clear the threshold".
        var bytesFreed: Int64 = 0
        var trimmed: [DownloadedEntry] = []
        for entry in toRemove {
            trimmed.append(entry)
            bytesFreed += entry.fileSize
            if freeDiskSpace() + bytesFreed > emergencyThresholdBytes {
                break
            }
        }
        toRemove = trimmed

        // Hard delete. Clear scheduledAt first so the row
        // isn't left in a weird half-state if delete fails.
        var deletedCount = 0
        var actualFreed: Int64 = 0
        for entry in toRemove {
            // Clear any pending scheduled-cleanup flag on the
            // row before we delete it (defensive — the row is
            // about to be deleted anyway, but a crash between
            // here and the delete would leave a "scheduled"
            // row pointing at a half-deleted file).
            clearScheduledFlagIfPresent(videoId: entry.videoId)
            DownloadManager.shared.deleteDownload(videoId: entry.videoId)
            deletedCount += 1
            actualFreed += entry.fileSize
        }

        lastCleanupAt = Date()
        lastCleanupCount = deletedCount
        lastCleanupBytesFreed = actualFreed
        persistLastCleanupStats()

        // Post-run summary (no Undo — emergency is not
        // recoverable). UI may still choose to show a toast
        // without the button.
        if deletedCount > 0 {
            let summary = CleanupSummary(
                id: UUID(),
                trashedVideoIds: toRemove.map { $0.videoId },
                bytesFreed: actualFreed,
                committedAt: Date(),
                source: .emergency
            )
            lastCleanupSummary = summary

            let mb = byteString(actualFreed)
            ErrorHandler.shared.showInfo(
                "Storage low · freed \(mb) (auto-cleanup)"
            )
        }
    }

    /// 2026-09-08: scheduled cleanup. Four steps:
    ///   1. Purge trash older than `trashRetentionDays`
    ///   2. Commit scheduled items whose grace has elapsed
    ///   3. Compute fresh candidates and mark them
    ///   4. Clear scheduledAt on tracks that are no longer
    ///      eligible (e.g. the user played them since the
    ///      last foreground)
    /// The published `pendingCleanup` is updated to the
    /// current state after every step so the banner can
    /// react immediately.
    private func runScheduledCleanup() async {
        isCleaningUp = true
        defer { isCleaningUp = false }

        // 1. Purge expired trash from previous rounds.
        let purged = CleanupTrash.shared.purgeExpired(retentionDays: trashRetentionDays)
        if purged > 0 {
            print("🗑️ [SmartLibrary] purged \(purged) bytes of expired trash")
        }
        refreshTrashBytes()

        // 2. Commit any past-grace items to trash. This
        // covers the "user ignored the banner for 24h" case
        // — the next foreground picks them up and moves
        // them to the recoverable trash bucket.
        let committedCount = await commitExpiredScheduledCleanups()
        refreshPendingCleanup()

        // 3. Compute fresh candidates.
        let candidates = await computeCleanupCandidates()

        // 4. Reconcile: for every currently-eligible
        // candidate, ensure cleanupScheduledAt is set (or
        // re-set if it was cleared by a play). For every
        // currently-ineligible track with a non-nil
        // scheduledAt, clear the flag.
        await reconcileScheduledFlags(candidates: candidates)
        refreshPendingCleanup()

        // 5. Update "last cleanup" timestamp. We update
        // it every cycle (even if nothing was committed)
        // because the cycle did work — it purged trash,
        // it auto-committed past-grace items, it
        // re-evaluated candidates. The Settings status
        // line reads this as "the cycle ran at HH:MM",
        // not "we deleted N tracks at HH:MM".
        lastCleanupAt = Date()
        lastCleanupCount = committedCount
        lastCleanupBytesFreed = 0  // bytesFreed is per-commit, not per-cycle
        persistLastCleanupStats()
    }

    /// 2026-09-08: find rows whose `cleanupScheduledAt` is
    /// past the grace window and move them to trash. This
    /// is the "auto-commit after 24h" path.
    /// Returns the number of items committed.
    @discardableResult
    private func commitExpiredScheduledCleanups() async -> Int {
        let now = Date()
        let grace = TimeInterval(cleanupGraceSeconds)
        let downloaded = fetchDownloadedTracksFromCoreData()
        let expired = downloaded.filter { entry in
            guard let scheduled = entry.scheduledAt else { return false }
            return now.timeIntervalSince(scheduled) > grace
        }
        guard !expired.isEmpty else { return 0 }

        var trashedVideoIds: [String] = []
        var bytesFreed: Int64 = 0
        for entry in expired {
            // Move file to trash first. If the file is
            // already gone (user deleted via Files.app),
            // the move returns nil and we just clean up
            // the row.
            if let trashedURL = CleanupTrash.shared.moveToTrash(videoId: entry.videoId) {
                bytesFreed += trashedURL.fileSizeIfExists() ?? 0
            } else {
                bytesFreed += entry.fileSize  // best-effort, file may be gone
            }
            markAsTrashed(videoId: entry.videoId, trashedURL: nil)
            trashedVideoIds.append(entry.videoId)
        }

        let summary = CleanupSummary(
            id: UUID(),
            trashedVideoIds: trashedVideoIds,
            bytesFreed: bytesFreed,
            committedAt: Date(),
            source: .graceExpired
        )
        lastCleanupSummary = summary
        refreshTrashBytes()

        if !trashedVideoIds.isEmpty {
            registerCleanupUndoToast(summary: summary)
        }
        return trashedVideoIds.count
    }

    /// 2026-09-08: compute the current cleanup candidates
    /// (eligible + not-protected, regardless of whether
    /// they're already scheduled). Used by both the
    /// scheduled flow (to know what to mark) and the
    /// manual "Clean up now" flow (to know what to trash).
    private func computeCleanupCandidates() async -> [DownloadedEntry] {
        let downloaded = fetchDownloadedTracksFromCoreData()
        let protectedVideoIds = currentProtectedVideoIds()
        let timeCapsuleVideoIds = fetchTimeCapsuleVideoIds()
        let lastPlayedByVideoId = lastPlayedLookup()

        return downloaded.filter { entry in
            if protectedVideoIds.contains(entry.videoId) { return false }
            if timeCapsuleVideoIds.contains(entry.videoId) { return false }
            let lastPlayed = lastPlayedByVideoId[entry.videoId]
            return shouldAutoRemove(videoId: entry.videoId, lastPlayedAt: lastPlayed)
        }
    }

    /// 2026-09-08: write `cleanupScheduledAt = Date()` on
    /// every candidate row. Idempotent — re-marking an
    /// already-scheduled row is a no-op (it just bumps the
    /// scheduledAt forward, which is the wrong behavior
    /// for the grace window — we want the original
    /// scheduledAt to be the reference). So callers should
    /// only invoke this for new (not-yet-scheduled) candidates.
    private func markCandidatesForCleanup(_ candidates: [DownloadedEntry]) async {
        let context = PersistenceController.shared.viewContext
        let videoIds = candidates.map { $0.videoId }
        guard !videoIds.isEmpty else { return }
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(
            format: "track.videoId IN %@ AND cleanupScheduledAt == nil",
            videoIds
        )
        let rows = (try? context.fetch(request)) ?? []
        let now = Date()
        for row in rows {
            row.cleanupScheduledAt = now
        }
        try? context.save()
    }

    /// 2026-09-08: reconcile scheduled flags against the
    /// current candidate set. Marks new candidates, clears
    /// the flag on tracks that are no longer eligible.
    /// Cheap (O(n) in downloaded count).
    private func reconcileScheduledFlags(candidates: [DownloadedEntry]) async {
        let context = PersistenceController.shared.viewContext
        let candidateIds = Set(candidates.map { $0.videoId })

        // 1. Clear scheduledAt on downloaded rows that are
        //    not in the current candidate set.
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(format: "cleanupScheduledAt != nil")
        let scheduledRows = (try? context.fetch(request)) ?? []
        var cleared = 0
        for row in scheduledRows {
            guard let videoId = row.track?.videoId else { continue }
            if !candidateIds.contains(videoId) {
                row.cleanupScheduledAt = nil
                cleared += 1
            }
        }
        if cleared > 0 {
            print("🧹 [SmartLibrary] cleared \(cleared) stale scheduledAt flags")
        }

        // 2. Mark new candidates that don't yet have a
        //    scheduledAt. Reusing the same row from the
        //    fetch above would require a follow-up; do a
        //    fresh fetch for the un-marked candidates.
        let unmarked = candidates.filter { entry in
            !scheduledRows.contains { $0.track?.videoId == entry.videoId }
        }
        if !unmarked.isEmpty {
            let markRequest: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
            markRequest.predicate = NSPredicate(
                format: "track.videoId IN %@",
                unmarked.map { $0.videoId }
            )
            let rows = (try? context.fetch(markRequest)) ?? []
            let now = Date()
            for row in rows where row.cleanupScheduledAt == nil {
                row.cleanupScheduledAt = now
            }
        }

        try? context.save()
    }

    /// 2026-09-08: rebuild `pendingCleanup` from the
    /// current CoreData state. Called after every
    /// schedule/commit so the banner reflects reality.
    func refreshPendingCleanup() {
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(format: "cleanupScheduledAt != nil AND trashedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDDownloadedTrack.cleanupScheduledAt, ascending: true)]
        let rows = (try? context.fetch(request)) ?? []

        let entries: [CleanupEntry] = rows.compactMap { row in
            guard let videoId = row.track?.videoId,
                  let scheduled = row.cleanupScheduledAt else { return nil }
            return CleanupEntry(
                videoId: videoId,
                title: row.track?.title ?? "Unknown",
                artist: row.track?.displayArtist ?? "Unknown",
                thumbnailURL: row.track?.artworkURL,
                fileSize: row.fileSize,
                scheduledAt: scheduled,
                tier: tier(for: videoId)
            )
        }
        let bytes: Int64 = entries.reduce(0) { $0 + $1.fileSize }
        if entries.isEmpty {
            pendingCleanup = nil
        } else {
            // The grace countdown is anchored to the EARLIEST
            // scheduledAt — that's the first item to expire.
            // Plus cleanupGraceSeconds.
            let earliest = entries.map { $0.scheduledAt }.min() ?? Date()
            let expires = earliest.addingTimeInterval(TimeInterval(cleanupGraceSeconds))
            pendingCleanup = PendingCleanup(
                id: UUID(),
                entries: entries,
                estimatedBytesFreed: bytes,
                expiresAt: expires
            )
        }
    }

    /// 2026-09-08: move all currently-scheduled tracks to
    /// trash. Called from "Clean up now" in the banner or
    /// the Settings button. Returns the count committed.
    @discardableResult
    func commitPendingCleanupNow() async -> Int {
        guard let pending = pendingCleanup, !pending.isEmpty else { return 0 }
        var trashedVideoIds: [String] = []
        var bytesFreed: Int64 = 0
        for entry in pending.entries {
            if let trashedURL = CleanupTrash.shared.moveToTrash(videoId: entry.videoId) {
                bytesFreed += trashedURL.fileSizeIfExists() ?? entry.fileSize
            } else {
                bytesFreed += entry.fileSize
            }
            markAsTrashed(videoId: entry.videoId, trashedURL: nil)
            trashedVideoIds.append(entry.videoId)
        }
        let summary = CleanupSummary(
            id: UUID(),
            trashedVideoIds: trashedVideoIds,
            bytesFreed: bytesFreed,
            committedAt: Date(),
            source: .userConfirmed
        )
        lastCleanupSummary = summary
        pendingCleanup = nil
        refreshTrashBytes()

        lastCleanupAt = Date()
        lastCleanupCount = trashedVideoIds.count
        lastCleanupBytesFreed = bytesFreed
        persistLastCleanupStats()

        if !trashedVideoIds.isEmpty {
            registerCleanupUndoToast(summary: summary)
        }
        return trashedVideoIds.count
    }

    /// 2026-09-08: cancel all scheduled cleanups (the
    /// "Cancel all" button in the review sheet, or
    /// Settings → "Cancel scheduled cleanups").
    func cancelPendingCleanup() {
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(format: "cleanupScheduledAt != nil")
        let rows = (try? context.fetch(request)) ?? []
        for row in rows {
            row.cleanupScheduledAt = nil
        }
        try? context.save()
        pendingCleanup = nil
    }

    /// 2026-09-08: cancel a single scheduled track (the X
    /// button on a row in the review sheet).
    func cancelCleanupItem(videoId: String) {
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(format: "track.videoId == %@", videoId)
        request.fetchLimit = 1
        if let row = (try? context.fetch(request))?.first {
            row.cleanupScheduledAt = nil
            try? context.save()
        }
        refreshPendingCleanup()
    }

    /// 2026-09-08: restore a trashed track (from the
    /// post-run Undo or from Settings → Trash). Returns
    /// true on success.
    @discardableResult
    func restoreFromTrash(videoId: String) -> Bool {
        // Find the trashed file in .trash/. We need the
        // exact URL because the file is in a different
        // directory from the active downloads.
        guard let trashed = CleanupTrash.shared.listTrashed().first(where: { $0.videoId == videoId }) else {
            return false
        }
        guard CleanupTrash.shared.restoreFromTrash(trashedURL: trashed.url) else {
            return false
        }
        // Update the row: clear trashedAt, update localPath
        // to the active downloads path.
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(format: "track.videoId == %@", videoId)
        request.fetchLimit = 1
        if let row = (try? context.fetch(request))?.first {
            row.trashedAt = nil
            row.localPath = AudioFileManager.shared.localFileURL(for: videoId).path
            row.downloadedAt = Date()  // refresh so the user knows it's "fresh"
            try? context.save()
        }
        refreshTrashBytes()
        return true
    }

    /// 2026-09-08: permanently delete a single trashed
    /// file + its row. Used by Settings → Trash → "Delete
    /// now" (skip the 7d retention).
    func permanentlyDeleteTrashed(videoId: String) {
        guard let trashed = CleanupTrash.shared.listTrashed().first(where: { $0.videoId == videoId }) else {
            return
        }
        CleanupTrash.shared.permanentlyDelete(trashedURL: trashed.url)
        // Delete the CoreData row.
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(format: "track.videoId == %@", videoId)
        request.fetchLimit = 1
        if let row = (try? context.fetch(request))?.first {
            context.delete(row)
            try? context.save()
        }
        refreshTrashBytes()
    }

    /// 2026-09-08: list all currently-trashed files.
    /// Public so Settings can render the trash section.
    var trashedFiles: [TrashedFile] {
        CleanupTrash.shared.listTrashed()
    }

    /// 2026-09-08: total bytes currently in trash.
    /// Refreshed on every cycle + on every restore/delete
    /// so the Settings row stays current.
    func refreshTrashBytes() {
        trashBytes = CleanupTrash.shared.totalTrashedSize()
    }

    /// 2026-09-08: dismiss the post-run cleanup summary
    /// (e.g. when the user taps the X on the toast or
    /// when a new cleanup cycle starts).
    func dismissCleanupSummary() {
        lastCleanupSummary = nil
    }

    // MARK: - Private: cleanup helpers

    /// Set `trashedAt = Date()` on the row, optionally
    /// update `localPath` if a specific trash URL is
    /// provided. The `cleanupScheduledAt` flag is cleared
    /// — the row is no longer "scheduled", it's "trashed".
    private func markAsTrashed(videoId: String, trashedURL: URL?) {
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(format: "track.videoId == %@", videoId)
        request.fetchLimit = 1
        if let row = (try? context.fetch(request))?.first {
            row.trashedAt = Date()
            row.cleanupScheduledAt = nil
            if let trashedURL = trashedURL {
                row.localPath = trashedURL.path
            }
            try? context.save()
        }
    }

    /// Clear the `cleanupScheduledAt` flag for a row, if
    /// set. Used by the emergency-cleanup path right
    /// before deletion.
    private func clearScheduledFlagIfPresent(videoId: String) {
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(format: "track.videoId == %@", videoId)
        request.fetchLimit = 1
        if let row = (try? context.fetch(request))?.first, row.cleanupScheduledAt != nil {
            row.cleanupScheduledAt = nil
            try? context.save()
        }
    }

    /// Build the post-run Undo toast for a successful
    /// cleanup commit. The restore closure moves the
    /// files back from trash and re-inserts the row's
    /// `localPath` to the active downloads directory.
    private func registerCleanupUndoToast(summary: CleanupSummary) {
        let count = summary.trashedVideoIds.count
        let bytesString = byteString(summary.bytesFreed)
        UndoService.shared.registerUndo(
            message: "Cleaned up \(count) \(count == 1 ? "track" : "tracks") · freed \(bytesString)",
            restore: { [weak self] in
                Task { [weak self] in
                    await self?.undoLastCleanup(summaryId: summary.id)
                }
            },
            showUndoButton: true
        )
    }

    /// 2026-09-08: restore the tracks from a previous
    /// cleanup commit. Walks the videoIds in the saved
    /// summary, calls `restoreFromTrash` for each. Tracks
    /// that were restored in the meantime (because the
    /// user re-downloaded them) are silently skipped —
    /// `restoreFromTrash` returns false for them and the
    /// UI just shows a partial success.
    @discardableResult
    func undoLastCleanup(summaryId: UUID) async -> Bool {
        guard let summary = lastCleanupSummary, summary.id == summaryId else { return false }
        var restoredCount = 0
        for videoId in summary.trashedVideoIds {
            if restoreFromTrash(videoId: videoId) {
                restoredCount += 1
            }
        }
        if restoredCount > 0 {
            ErrorHandler.shared.showInfo(
                "Restored \(restoredCount) \(restoredCount == 1 ? "track" : "tracks") from trash"
            )
        }
        lastCleanupSummary = nil
        return restoredCount > 0
    }

    /// Set of videoIds currently protected from cleanup:
    /// the playing track + queued tracks. Cheap (queue
    /// size is bounded).
    private func currentProtectedVideoIds() -> Set<String> {
        Set(
            PlayerState.shared.queue.map { $0.track.videoId } +
            (PlayerState.shared.currentItem.map { [$0.track.videoId] } ?? [])
        )
    }

    /// lastPlayedAt lookup from `DataManager.recentlyPlayed`.
    private func lastPlayedLookup() -> [String: Date] {
        Dictionary(
            uniqueKeysWithValues: DataManager.shared.recentlyPlayed.map { ($0.videoId, $0.playedAt) }
        )
    }

    /// Persist the "last cleanup" stats to UserDefaults.
    private func persistLastCleanupStats() {
        defaults.set(lastCleanupAt, forKey: Keys.lastCleanupAt)
        defaults.set(lastCleanupCount, forKey: Keys.lastCleanupCount)
        defaults.set(Int(lastCleanupBytesFreed), forKey: Keys.lastCleanupBytesFreed)
    }

    /// Direct CoreData fetch. Returns [(videoId, fileSize)].
    /// Avoids the LibraryViewModel UI wrapper since cleanup
    /// is a model-level concern.
    ///
    /// 2026-09-08: changed to return `DownloadedEntry` so
    /// the new scheduled-cleanup flow can read
    /// `cleanupScheduledAt` without a second fetch. Excludes
    /// trashed rows — those are in the .trash/ directory
    /// and shouldn't be considered "active downloads" for
    /// candidate computation.
    private func fetchDownloadedTracksFromCoreData() -> [DownloadedEntry] {
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(format: "trashedAt == nil")
        do {
            let rows = try context.fetch(request)
            return rows.compactMap { row in
                guard let videoId = row.track?.videoId else { return nil }
                return DownloadedEntry(
                    videoId: videoId,
                    fileSize: row.fileSize,
                    scheduledAt: row.cleanupScheduledAt
                )
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

// MARK: - UserDefaults KVO bridge (v1.9.0)
//
// Why this exists: @AppStorage in a non-View context
// works as a property wrapper, but `self.$autoDownloadEnabled`
// returns a `Binding<Bool>`, not a Combine publisher. To
// observe toggle changes from this manager (so we can
// cancel a pending cycle when the user flips the switch
// off), we need a publisher. The standard pattern is a
// `@objc dynamic` key-path extension on UserDefaults.
//
// The key string MUST match the @AppStorage key
// verbatim ("smartLibrary.autoDownloadEnabled") —
// SwiftUI's @AppStorage stores under the literal key,
// and the KVO publisher reads from the same key.

extension UserDefaults {
    @objc dynamic var smartLibraryAutoDownloadEnabled: Bool {
        // Read the bool with a default of true (matching
        // the @AppStorage default). registerDefaults
        // would be cleaner but the @AppStorage default
        // and the KVO reader need to agree; we mirror
        // the default here.
        bool(forKey: "smartLibrary.autoDownloadEnabled")
    }
}

// MARK: - 2026-09-08 internal types

/// Internal value type for the cleanup pipeline. Bundles
/// the few fields the cycle needs from each
/// `CDDownloadedTrack` row so we can do one CoreData
/// fetch per cycle instead of one per candidate.
struct DownloadedEntry: Equatable {
    let videoId: String
    let fileSize: Int64
    /// Non-nil if this row is currently scheduled for
    /// cleanup and the 24h grace hasn't elapsed yet.
    let scheduledAt: Date?
}

// MARK: - URL helpers

extension URL {
    /// Best-effort file size lookup. Returns nil if the
    /// file doesn't exist (e.g. user deleted via Files.app
    /// between scheduling and committing) or the stat fails
    /// for any reason. Used by the trash-move path so a
    /// missing source file doesn't poison the bytes-freed
    /// accounting.
    func fileSizeIfExists() -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attrs[.size] as? Int64
    }
}



// MARK: - Download tier (file-scope)

/// Tier for a downloaded track, used by the cleanup logic
/// (and exposed for any future UI that wants to show a tier
/// badge). Liked is the highest tier and is checked first;
/// an auto-downloaded track that the user later liked becomes
/// .liked, never to be auto-removed.
///
/// 2026-09-08: hoisted to file scope from inside
/// `SmartLibraryManager` so cleanup-related structs declared
/// at file scope (CleanupEntry, PendingCleanup, CleanupSummary)
/// can reference it without being implicitly @MainActor-isolated
/// via the enclosing class.
enum DownloadTier: Equatable {
    case liked
    case auto
    case manual
}


// MARK: - v1.9.3 cleanup types

/// A single candidate for cleanup: the track info + the file
/// metadata (size for the banner total, scheduledAt for the
/// "elapses in 23h" countdown, tier for the per-row filter chips).
struct CleanupEntry: Equatable, Identifiable {
    let videoId: String
    let title: String
    let artist: String
    let thumbnailURL: URL?
    let fileSize: Int64
    let scheduledAt: Date
    let tier: DownloadTier

    var id: String { videoId }

}

/// A prepared set of cleanup candidates waiting for the 24h
/// grace to elapse (or for the user to tap "Clean up now").
/// Computed every foreground from the current library state —
/// the same way the auto-download cycle is.
///
/// Lifecycle:
///   1. `runCleanupIfDue` marks eligible tracks with
///      `cleanupScheduledAt` and publishes this struct.
///   2. The banner binds to it; per-row cancel mutates the
///      `cleanupScheduledAt` on the row and the published
///      struct is rebuilt on the next foreground (or
///      `refreshPendingCleanup()` for instant UI feedback).
///   3. Either the user taps "Clean up now" (commits
///      immediately) or the 24h grace elapses (auto-commits
///      on the next foreground).
struct PendingCleanup: Identifiable {
    let id: UUID
    let entries: [CleanupEntry]
    let estimatedBytesFreed: Int64
    let expiresAt: Date

    /// The earliest scheduledAt + grace window. The banner's
    /// "Cleanup in 23h" countdown reads from this.
    var cleanupIn: TimeInterval {
        max(0, expiresAt.timeIntervalSinceNow)
    }

    var isEmpty: Bool { entries.isEmpty }

}

/// What happened after a cleanup commit. Drives the post-run
/// toast with Undo (restore from trash). The restore is real —
/// the files were moved to `Library/Downloads/.trash/`, not
/// deleted, so the undo has a 7-day window before `purgeExpired`
/// permanently removes them.
struct CleanupSummary: Identifiable {
    let id: UUID
    let trashedVideoIds: [String]
    let bytesFreed: Int64
    let committedAt: Date
    let source: CommitSource

    enum CommitSource: String, Equatable {
        /// User tapped "Clean up now" in the banner or
        /// Settings — explicit, intentional.
        case userConfirmed
        /// 24h grace elapsed and the next foreground auto-
        /// committed. Still a real, recoverable cleanup.
        case graceExpired
        /// Storage emergency path (< 1GB free). No trash —
        /// immediate delete for safety. No undo.
        case emergency
    }

    var isRecoverable: Bool {
        source != .emergency && !trashedVideoIds.isEmpty
    }

}
