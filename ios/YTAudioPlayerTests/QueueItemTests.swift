//
//  QueueItemTests.swift
//  YTAudioPlayerTests
//
//  Regression tests for the small but bug-prone QueueItem + Track data
//  structures. These were touched in Sprint 1 (C-5) and Sprint 3 (S3-4)
//  to add the `contentSource: .local` fix and the `replayGain` field.
//  Keeping them under test pins the contract for the rest of the
//  playback code that depends on these invariants.
//

import XCTest
@testable import PeacePlayer

final class QueueItemTests: XCTestCase {

    private func makeTrack(videoId: String = "abc") -> Track {
        Track(
            videoId: videoId,
            title: "Test Track",
            artists: ["Test Artist"],
            album: "Test Album",
            durationSeconds: 180,
            thumbnails: [],
            isExplicit: false,
            videoType: "TRACK"
        )
    }

    // MARK: - S3-4: replayGain threading through QueueItem

    func testQueueItem_replayGain_defaultsToNil() {
        let item = QueueItem(
            track: makeTrack(),
            streamUrl: "https://example.com/s.m4a",
            source: .stream
        )
        XCTAssertNil(item.replayGain, "QueueItem.replayGain should default to nil for back-compat")
    }

    func testQueueItem_replayGain_roundTripsThroughInit() {
        let item = QueueItem(
            track: makeTrack(),
            streamUrl: "https://example.com/s.m4a",
            source: .stream,
            replayGain: -7.5
        )
        XCTAssertEqual(item.replayGain, -7.5)
    }

    // MARK: - C-5: contentSource threading

    func testQueueItem_contentSource_defaultsToYouTube() {
        // Backward-compat: callers that don't specify contentSource
        // (e.g., refreshAndPlayCurrentItem) still get .youtube.
        let item = QueueItem(
            track: makeTrack(),
            streamUrl: "https://example.com/s.m4a",
            source: .stream
        )
        XCTAssertEqual(item.contentSource, .youtube)
    }

    func testQueueItem_contentSource_canBeLocal() {
        let item = QueueItem(
            track: makeTrack(),
            streamUrl: "file:///foo.m4a",
            source: .local(path: "/foo.m4a"),
            contentSource: .local
        )
        XCTAssertEqual(item.contentSource, .local)
    }

    // MARK: - isStreamUrlExpired

    func testIsStreamUrlExpired_freshItem_isFalse() {
        let item = QueueItem(
            track: makeTrack(),
            streamUrl: "https://example.com/s.m4a",
            source: .stream
        )
        XCTAssertFalse(item.isStreamUrlExpired, "Just-created items must not be considered expired")
    }

    func testIsStreamUrlExpired_oldItem_isTrue() {
        // Construct with a createdAt 5 hours ago — past the 4h threshold.
        let oldDate = Date(timeIntervalSinceNow: -5 * 60 * 60)
        let item = QueueItem(
            track: makeTrack(),
            streamUrl: "https://example.com/s.m4a",
            source: .stream,
            createdAt: oldDate
        )
        XCTAssertTrue(item.isStreamUrlExpired, "Items older than 4h should be flagged for URL refresh")
    }

    // MARK: - Equality

    func testEquality_sameIdAndVideoId_isEqual() {
        let track = makeTrack(videoId: "vid-1")
        let a = QueueItem(track: track, streamUrl: "u1", source: .stream)
        let b = QueueItem(track: track, streamUrl: "u2", source: .stream)
        XCTAssertEqual(a, b, "Equality is by id+videoId, not streamUrl")
    }

    func testEquality_differentVideoId_isNotEqual() {
        let a = QueueItem(track: makeTrack(videoId: "vid-1"), streamUrl: "u", source: .stream)
        let b = QueueItem(track: makeTrack(videoId: "vid-2"), streamUrl: "u", source: .stream)
        XCTAssertNotEqual(a, b)
    }
}
