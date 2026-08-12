//
//  LocalFirstQueueItemTests.swift
//  PeacePlayer
//
//  2026-08-12: regression test for the "downloaded tracks silently
//  stream" bug fixed in v1.7.1.
//
//  Background: HomeViewModel.playTrack and SearchViewModel.performPlayTrack
//  used to always go through StreamURLCache.getStreamUrl, which meant
//  tapping a downloaded track in any of these surfaces wasted a /stream
//  roundtrip and (in airplane mode) failed entirely. The fix delegates
//  "play now" to PlayerState.shared.play(track:) — which has the
//  local-first logic — and adds a localFirstQueueItem(for:) helper to
//  SearchViewModel for the addToQueue / playNext paths. This test
//  pins the helper's contract so it can't silently regress to "always
//  stream" again.
//
//  Covered contract:
//    - downloaded track (file on disk + Core Data row) → QueueItem
//      with source: .local(path:) and contentSource: .local
//    - not downloaded (no row, no file) → nil (caller falls through
//      to stream-URL path)
//    - stale row, no file (file deleted via Files.app) → nil, NOT a
//      .local source pointing at a missing path (C-5 fix territory)
//

import XCTest
import CoreData
@testable import PeacePlayer

final class LocalFirstQueueItemTests: XCTestCase {

    // We can't easily inject a custom PersistenceController into
    // SearchViewModel (it uses PersistenceController.shared directly),
    // so these tests seed Core Data via the real shared instance and
    // clean up in tearDown. AudioFileManagerTests uses an in-memory
    // context, but that path is for the isPlayable logic itself —
    // already covered. This test focuses on the *caller's* contract.

    private var viewModel: SearchViewModel!

    override func setUp() {
        super.setUp()
        viewModel = SearchViewModel()
    }

    override func tearDown() {
        // Best-effort cleanup of any rows we seeded.
        let context = PersistenceController.shared.viewContext
        let seededIds = ["test-downloaded-vid", "test-stale-vid", "test-notdownloaded-vid"]
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(format: "track.videoId IN %@", seededIds)
        if let rows = try? context.fetch(request) {
            for row in rows {
                context.delete(row)
            }
            try? context.save()
        }
        for vid in seededIds {
            let url = AudioFileManager.shared.localFileURL(for: vid)
            try? FileManager.default.removeItem(at: url)
        }
        viewModel = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testDownloadedTrack_producesLocalQueueItem() throws {
        let videoId = "test-downloaded-vid"
        try seedDownloadedTrack(videoId: videoId)

        let track = makeTrack(videoId: videoId)
        let item = viewModel.localFirstQueueItem(for: track)

        XCTAssertNotNil(item, "Downloaded track should produce a QueueItem, not nil")
        guard let item = item else { return }

        // Source must be .local (not .stream) — this is the bug we're guarding.
        if case .local(let path) = item.source {
            XCTAssertFalse(path.isEmpty, "Local path should not be empty")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path),
                "Local path should point to an existing file on disk"
            )
        } else {
            XCTFail("Expected source: .local(path:), got \(item.source)")
        }

        // ContentSource must be .local (C-5 fix: this is what stops the
        // red YouTube chip from rendering on a downloaded track in
        // FullPlayer).
        XCTAssertEqual(item.contentSource, .local)
    }

    func testNotDownloadedTrack_returnsNil() {
        let track = makeTrack(videoId: "test-notdownloaded-vid")
        let item = viewModel.localFirstQueueItem(for: track)
        XCTAssertNil(item, "Non-downloaded track should return nil so caller falls through to stream path")
    }

    func testStaleRow_missingFile_returnsNil() throws {
        // C-5 territory: Core Data row exists, but the on-disk file
        // was deleted (e.g., user cleaned up via Files.app). The
        // helper must NOT return a .local QueueItem pointing at a
        // missing path — that would cause AVPlayer to fail on play.
        let videoId = "test-stale-vid"
        try seedDownloadedRowOnly(videoId: videoId)
        // Deliberately NOT calling seedDownloadedTrack (which writes
        // the file) — only the Core Data row exists.

        let track = makeTrack(videoId: videoId)
        let item = viewModel.localFirstQueueItem(for: track)

        XCTAssertNil(item, "Stale row with no file should return nil, not a .local source pointing at a missing path")
    }

    // MARK: - Helpers

    private func makeTrack(videoId: String) -> Track {
        Track(
            videoId: videoId,
            title: "Test Track \(videoId)",
            artists: ["Test Artist"],
            album: "Test Album",
            durationSeconds: 180,
            thumbnails: [],
            isExplicit: false,
            videoType: "MUSIC_VIDEO_TYPE_OMV"
        )
    }

    private func seedDownloadedTrack(videoId: String) throws {
        let context = PersistenceController.shared.viewContext
        let track = CDTrack(context: context)
        track.videoId = videoId
        let row = CDDownloadedTrack(context: context)
        row.track = track
        try context.save()

        // Write a tiny placeholder file so isPlayable's
        // reconciliation sees "row + file = playable".
        let url = AudioFileManager.shared.localFileURL(for: videoId)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "test".data(using: .utf8)!.write(to: url)
    }

    private func seedDownloadedRowOnly(videoId: String) throws {
        let context = PersistenceController.shared.viewContext
        let track = CDTrack(context: context)
        track.videoId = videoId
        let row = CDDownloadedTrack(context: context)
        row.track = track
        try context.save()
        // No file write — this is the "stale row" case.
    }
}
