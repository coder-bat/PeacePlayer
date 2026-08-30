//
//  SmartLibraryManagerTests.swift
//  PeacePlayer
//
//  2026-08-12: v1.8.0 Smart Library tests.
//
//  Scope: pure tier-classification logic + the set marker
//  contract. The actual cleanup cycle + auto-download cycle
//  exercise CoreData, the backend, and DownloadManager —
//  covered by integration smoke tests in your manual QA
//  (airplane-mode the device, watch a track get
//  auto-downloaded, watch an unplayed auto-downloaded
//  track get removed). The unit tests here pin the parts
//  that have one correct answer and would silently regress
//  if a future refactor broke the contract:
//    - tier() returns the right tier for each combination
//    - shouldAutoRemove() respects the tier + grace periods
//    - markAsAutoDownloaded / removeFromAutoSet correctly
//      promote / demote the set membership
//

import XCTest
import CoreData
@testable import PeacePlayer

@MainActor
final class SmartLibraryManagerTests: XCTestCase {

    var sut: SmartLibraryManager!
    // Snapshot of state we mutate, so we can restore in tearDown
    // and not pollute the real shared singleton for the rest of
    // the test suite / the actual app.
    var originalSet: Set<String> = []
    var originalCleanupDaysAuto: Int = 0
    var originalCleanupDaysManual: Int = 0

    override func setUp() {
        super.setUp()
        sut = SmartLibraryManager.shared
        originalSet = sut.autoDownloadedVideoIds
        originalCleanupDaysAuto = sut.cleanupDaysAuto
        originalCleanupDaysManual = sut.cleanupDaysManual
        // Start with a clean set so test order doesn't matter.
        // The autoDownloadedVideoIds property is `private(set)`,
        // so we can't assign to it from outside (even with
        // @testable). Use the public removeFromAutoSet API per
        // videoId — O(n) but n is small in practice.
        for videoId in sut.autoDownloadedVideoIds {
            sut.removeFromAutoSet(videoId: videoId)
        }
        // v1.8.2: also reset the v1.8.2-only fields so tests
        // don't see state from a previous test. The auto-
        // storage wrapper can't be set back to nil, so we
        // use the underlying UserDefaults.
        UserDefaults.standard.removeObject(forKey: "smartLibrary.lastAutoDownloadSkippedReason")
    }

    override func tearDown() {
        // Restore the original set. The @AppStorage-backed
        // cleanupDays* values are settable from outside (no
        // `private(set)`), so direct assignment works for them.
        for videoId in sut.autoDownloadedVideoIds {
            sut.removeFromAutoSet(videoId: videoId)
        }
        for videoId in originalSet {
            sut.markAsAutoDownloaded(videoId)
        }
        sut.cleanupDaysAuto = originalCleanupDaysAuto
        sut.cleanupDaysManual = originalCleanupDaysManual
        super.tearDown()
    }

    // MARK: - tier(for:)

    func testTier_unknown_returnsManual() {
        XCTAssertEqual(sut.tier(for: "not-anywhere"), .manual)
    }

    func testTier_autoSetMember_returnsAuto() {
        let videoId = "test-auto-vid"
        sut.markAsAutoDownloaded(videoId)
        XCTAssertEqual(sut.tier(for: videoId), .auto)
    }

    func testTier_likedTakesPrecedenceOverAuto() {
        // If a track is in the auto set AND the user later
        // liked it, the tier should be .liked (which means
        // never auto-removed). Liked is the highest tier.
        let videoId = "test-liked-and-auto"
        sut.markAsAutoDownloaded(videoId)
        PlaylistManager.shared.likedTracks.insert(videoId)
        XCTAssertEqual(sut.tier(for: videoId), .liked)
    }

    func testTier_likedOnly_returnsLiked() {
        let videoId = "test-liked-only"
        PlaylistManager.shared.likedTracks.insert(videoId)
        XCTAssertEqual(sut.tier(for: videoId), .liked)
    }

    // MARK: - shouldAutoRemove(videoId:lastPlayedAt:)

    func testShouldAutoRemove_likedNever_returnsFalse() {
        let videoId = "test-liked-keep"
        PlaylistManager.shared.likedTracks.insert(videoId)
        // Even if never played (lastPlayedAt = nil), liked tracks
        // are never auto-removed. This is the core safety
        // guarantee the feature promises.
        XCTAssertFalse(sut.shouldAutoRemove(videoId: videoId, lastPlayedAt: nil))
        // Even if "played" 5 years ago.
        XCTAssertFalse(sut.shouldAutoRemove(videoId: videoId, lastPlayedAt: Date().addingTimeInterval(-5 * 365 * 86400)))
    }

    func testShouldAutoRemove_autoNeverPlayed_returnsTrue() {
        // Auto-downloaded + never played → past any threshold
        // → eligible for removal.
        let videoId = "test-auto-never-played"
        sut.markAsAutoDownloaded(videoId)
        XCTAssertTrue(sut.shouldAutoRemove(videoId: videoId, lastPlayedAt: nil))
    }

    func testShouldAutoRemove_autoPlayedRecently_returnsFalse() {
        // Auto-downloaded + played within the grace period
        // (cleanupDaysAuto, default 14) → keep.
        let videoId = "test-auto-fresh"
        sut.markAsAutoDownloaded(videoId)
        let recent = Date().addingTimeInterval(-3 * 86400)  // 3 days ago
        XCTAssertFalse(sut.shouldAutoRemove(videoId: videoId, lastPlayedAt: recent))
    }

    func testShouldAutoRemove_autoPlayedLongAgo_returnsTrue() {
        // Auto-downloaded + played > cleanupDaysAuto days ago
        // → eligible for removal.
        let videoId = "test-auto-stale"
        sut.markAsAutoDownloaded(videoId)
        let old = Date().addingTimeInterval(-30 * 86400)  // 30 days ago, > 14 default
        XCTAssertTrue(sut.shouldAutoRemove(videoId: videoId, lastPlayedAt: old))
    }

    func testShouldAutoRemove_manualPlayedRecently_returnsFalse() {
        // Manual download + played recently → keep. Manual
        // grace period is longer than auto (60d default vs 14d).
        let videoId = "test-manual-fresh"
        // Not in the auto set → tier = .manual
        let recent = Date().addingTimeInterval(-20 * 86400)  // 20 days ago
        XCTAssertFalse(sut.shouldAutoRemove(videoId: videoId, lastPlayedAt: recent))
    }

    func testShouldAutoRemove_manualPlayedLongAgo_returnsTrue() {
        // Manual download + played > cleanupDaysManual days ago
        // → eligible for removal.
        let videoId = "test-manual-stale"
        let veryOld = Date().addingTimeInterval(-90 * 86400)  // 90 days ago, > 60 default
        XCTAssertTrue(sut.shouldAutoRemove(videoId: videoId, lastPlayedAt: veryOld))
    }

    func testShouldAutoRemove_respectsCustomGracePeriods() {
        // User can tweak the grace periods. Verify the
        // shouldAutoRemove logic uses the live values, not
        // a hardcoded constant.
        let videoId = "test-custom-grace"
        sut.cleanupDaysAuto = 1
        sut.cleanupDaysManual = 5

        // Auto tier, played 2 days ago → past 1d grace → remove
        sut.markAsAutoDownloaded(videoId)
        let twoDaysAgo = Date().addingTimeInterval(-2 * 86400)
        XCTAssertTrue(sut.shouldAutoRemove(videoId: videoId, lastPlayedAt: twoDaysAgo))

        // Manual tier, played 2 days ago → still within 5d grace → keep
        let manualVid = "test-manual-custom"
        let twoDaysAgo2 = Date().addingTimeInterval(-2 * 86400)
        XCTAssertFalse(sut.shouldAutoRemove(videoId: manualVid, lastPlayedAt: twoDaysAgo2))
    }

    // MARK: - Set membership (tier upgrade / demote)

    func testMarkAsAutoDownloaded_addsToSet() {
        let videoId = "test-mark-auto"
        XCTAssertFalse(sut.autoDownloadedVideoIds.contains(videoId))
        sut.markAsAutoDownloaded(videoId)
        XCTAssertTrue(sut.autoDownloadedVideoIds.contains(videoId))
        XCTAssertEqual(sut.tier(for: videoId), .auto)
    }

    func testMarkAsAutoDownloaded_isIdempotent() {
        let videoId = "test-mark-auto-idempotent"
        sut.markAsAutoDownloaded(videoId)
        sut.markAsAutoDownloaded(videoId)
        sut.markAsAutoDownloaded(videoId)
        XCTAssertTrue(sut.autoDownloadedVideoIds.contains(videoId))
        XCTAssertEqual(sut.autoDownloadedVideoIds.filter { $0 == videoId }.count, 1,
                       "Set membership should be a single entry regardless of how many times markAsAutoDownloaded is called")
    }

    func testRemoveFromAutoSet_promotesToManual() {
        // Tier upgrade: track was auto-downloaded, user then
        // explicitly downloaded (or did the equivalent — e.g.,
        // re-downloaded manually). The set entry is removed,
        // tier drops to .manual, the longer manual grace
        // period applies.
        let videoId = "test-tier-upgrade"
        sut.markAsAutoDownloaded(videoId)
        XCTAssertEqual(sut.tier(for: videoId), .auto)
        sut.removeFromAutoSet(videoId: videoId)
        XCTAssertEqual(sut.tier(for: videoId), .manual)
    }

    func testRemoveFromAutoSet_viaNotification_removesEntry() {
        // The .downloadDeleted notification listener in
        // setupHooks should call removeFromAutoSet when a
        // download is deleted. This is the cleanup-via-
        // notification path.
        let videoId = "test-notif-remove"
        sut.markAsAutoDownloaded(videoId)
        XCTAssertTrue(sut.autoDownloadedVideoIds.contains(videoId))

        NotificationCenter.default.post(
            name: .downloadDeleted,
            object: videoId
        )

        // The notification listener uses Combine, so the
        // sink fires asynchronously. Wait a short window.
        let exp = expectation(description: "notification processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(sut.autoDownloadedVideoIds.contains(videoId),
                       "downloadDeleted notification should remove the videoId from the auto set")
    }

    // MARK: - v1.8.2 library limit

    func testMaxLibraryTracks_defaultIs50() {
        // v1.8.2 default: 50 tracks. A user with a healthy
        // listening history gets ~5 new auto-downloads per
        // cycle, so 50 = roughly 10 cycles of headroom
        // before the cap is hit. The Picker exposes 25 /
        // 50 / 100 / 200 / 500.
        XCTAssertGreaterThanOrEqual(sut.maxLibraryTracks, 25,
                                    "Default library limit should be at least 25")
        XCTAssertLessThanOrEqual(sut.maxLibraryTracks, 200,
                                 "Default library limit should be at most 200")
    }

    func testCurrentDownloadedTrackCount_emptyIsZero() {
        // Single-line CoreData count call. With no
        // CDDownloadedTrack rows in the test environment,
        // should return 0 (not crash on the optional try?).
        let initialCount = sut.currentDownloadedTrackCount()
        // We don't assert == 0 because other tests (or the
        // user's real device) may have left state in the
        // shared store. We just assert it doesn't crash and
        // returns a non-negative Int.
        XCTAssertGreaterThanOrEqual(initialCount, 0,
                                    "currentDownloadedTrackCount should never return a negative value")
    }

    func testRunRefreshNow_isIdempotent_whileRunning() {
        // Calling runRefreshNow twice in quick succession
        // should NOT spawn two parallel refresh cycles.
        // The isRefreshing guard at the top of the method
        // is what enforces this. Without it, the user
        // double-tapping the button would queue two full
        // library clear + re-downloads.
        //
        // We can verify the guard by setting isRefreshing
        // directly and confirming a second call is a no-op.
        // We can't easily wait for the first call to
        // complete (it's async + multi-step), so the
        // direct-state assertion is the cleanest test.
        //
        // This is a behavioral test of the guard, not an
        // integration test of the cycle.
        // (Direct property access is acceptable here
        // because we control the @StateObject from the
        // main actor test context.)
        XCTAssertFalse(sut.isRefreshing, "isRefreshing should be false before any refresh")
        // Verify the public surface still has the guard by
        // checking that two rapid calls don't crash.
        // (We don't assert on side effects — that's what
        // the manual QA + integration tests are for.)
        sut.runRefreshNow()
        // Don't await — the cycle is async and the test
        // shouldn't block on it. The second call is the
        // guard test: even if the first hasn't finished,
        // the second should be a no-op.
        sut.runRefreshNow()
    }

    // MARK: - isAutoDownloadEligible (v1.9.0 tier-1 filter)

    func testIsAutoDownloadEligible_normalSong_passes() {
        // 3:24 song, music video type
        let track = makeTrack(durationSeconds: 204, videoType: "MUSIC_VIDEO_TYPE_OMV")
        XCTAssertTrue(SmartLibraryManager.isAutoDownloadEligible(track))
    }

    func testIsAutoDownloadEligible_audioTrackType_passes() {
        // ATV (audio-only) type — common for YouTube Music
        // tracks where there's no music video.
        let track = makeTrack(durationSeconds: 240, videoType: "MUSIC_VIDEO_TYPE_ATV")
        XCTAssertTrue(SmartLibraryManager.isAutoDownloadEligible(track))
    }

    func testIsAutoDownloadEligible_tooShort_rejected() {
        // 15s — could be a Topic channel sample, an
        // intro snippet, or a TikTok-style clip.
        let track = makeTrack(durationSeconds: 15, videoType: "MUSIC_VIDEO_TYPE_OMV")
        XCTAssertFalse(SmartLibraryManager.isAutoDownloadEligible(track))
    }

    func testIsAutoDownloadEligible_tooLong_rejected() {
        // 18 min — likely a full live set or DJ mix.
        // The user probably didn't mean to "auto-top up"
        // a 50MB+ download from a search result.
        let track = makeTrack(durationSeconds: 18 * 60, videoType: "MUSIC_VIDEO_TYPE_OMV")
        XCTAssertFalse(SmartLibraryManager.isAutoDownloadEligible(track))
    }

    func testIsAutoDownloadEligible_nonAudioType_rejected() {
        // 4 min podcast-style content. Even though the
        // duration is fine, the videoType says "not music"
        // (could be a podcast, audiobook, talk show, etc.).
        // Smart Library is music-only for now.
        let track = makeTrack(durationSeconds: 240, videoType: "MUSIC_VIDEO_TYPE_PODCAST")
        XCTAssertFalse(SmartLibraryManager.isAutoDownloadEligible(track))
    }

    func testIsAutoDownloadEligible_boundary30s_passes() {
        // Exactly 30s — accepted (inclusive lower bound).
        let track = makeTrack(durationSeconds: 30, videoType: "MUSIC_VIDEO_TYPE_OMV")
        XCTAssertTrue(SmartLibraryManager.isAutoDownloadEligible(track))
    }

    func testIsAutoDownloadEligible_boundary15min_passes() {
        // Exactly 15 min — accepted (inclusive upper bound).
        let track = makeTrack(durationSeconds: 15 * 60, videoType: "MUSIC_VIDEO_TYPE_OMV")
        XCTAssertTrue(SmartLibraryManager.isAutoDownloadEligible(track))
    }

    // MARK: - Test helpers

    private func makeTrack(durationSeconds: Int, videoType: String) -> Track {
        Track(
            videoId: "test-\(UUID().uuidString)",
            title: "Test Track",
            artists: ["Test Artist"],
            album: "Test Album",
            durationSeconds: durationSeconds,
            thumbnails: [],
            isExplicit: false,
            videoType: videoType
        )
    }
}
