import XCTest
@testable import PeacePlayer

final class SyncMergeTests: XCTestCase {
    private func playlist(_ name: String = "Mix", ids: [String] = ["song"]) -> SyncPlaylist {
        SyncPlaylist(Playlist(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: name, description: "Saved mix", trackIds: ids,
            createdAt: Date(timeIntervalSince1970: 100), modifiedAt: Date(timeIntervalSince1970: 200)))
    }

    func testFirstRestoreKeepsRemoteAndLocalDataWithoutInferringDeletion() throws {
        let remote = SyncSnapshot(playlists: [playlist()], favorites: ["remote"], favoriteArtists: ["Artist"])
        let local = SyncSnapshot(favorites: ["local"], favoriteArtists: ["artist"])
        let result = try SyncMerge.merge(base: nil, local: local, remote: remote)
        XCTAssertEqual(result.favorites, ["local", "remote"])
        XCTAssertEqual(result.favoriteArtists.count, 1)
        XCTAssertEqual(result.playlists, remote.playlists)
    }

    func testDeletionSurvivesRepeatedSync() throws {
        let base = SyncSnapshot(playlists: [playlist()], favorites: ["removed", "kept"])
        let local = SyncSnapshot(favorites: ["kept"])
        let merged = try SyncMerge.merge(base: base, local: local, remote: base)
        XCTAssertEqual(merged.favorites, ["kept"])
        XCTAssertTrue(merged.playlists.isEmpty)
        XCTAssertEqual(try SyncMerge.merge(base: merged, local: merged, remote: merged), merged)
    }

    func testConcurrentPlaylistEditsKeepBothOrdersAndStableConflictID() throws {
        let original = playlist()
        var left = original, right = original
        left.trackIds = ["b", "a"]
        right.trackIds = ["a", "c"]
        let base = SyncSnapshot(playlists: [original])
        let local = SyncSnapshot(playlists: [left])
        let remote = SyncSnapshot(playlists: [right])
        let merged = try SyncMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.playlists.count, 2)
        XCTAssertEqual(merged.playlists.first { $0.id == original.id }?.trackIds, ["a", "c"])
        let copy = try XCTUnwrap(merged.playlists.first { $0.id != original.id })
        XCTAssertEqual(copy.trackIds, ["b", "a"])
        XCTAssertNotNil(UUID(uuidString: copy.id))
        XCTAssertEqual(try SyncMerge.merge(base: base, local: local, remote: remote), merged)
        XCTAssertEqual(try SyncMerge.merge(base: base, local: merged, remote: remote), merged)
    }

    func testConcurrentDeleteAndEditKeepsRecoverableEdit() throws {
        let original = playlist()
        var edited = original
        edited.name = "Changed"
        let result = try SyncMerge.merge(base: SyncSnapshot(playlists: [original]),
            local: SyncSnapshot(playlists: [edited]), remote: SyncSnapshot())
        XCTAssertEqual(result.playlists.count, 1)
        XCTAssertNotEqual(result.playlists[0].id, original.id)
    }

    func testDistinctHistoryEventsRoundTripAndDeduplicate() throws {
        let first = SyncHistoryEvent(id: "event1", videoId: "song", playedAt: 123.125, progress: 0.2, completed: false)
        var second = first
        second.id = "event2"
        second.playedAt = 123.25
        let result = try SyncMerge.merge(base: nil, local: SyncSnapshot(history: [first]),
            remote: SyncSnapshot(history: [first, second]))
        XCTAssertEqual(result.history.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(SyncSnapshot.self, from: JSONEncoder().encode(result)), result)
        XCTAssertNotEqual(SyncHistoryEvent.legacyID(videoId: "song", playedAt: first.playedAt),
            SyncHistoryEvent.legacyID(videoId: "song", playedAt: second.playedAt))
    }

    func testPlaylistMetadataRoundTrip() throws {
        let original = playlist()
        let restored = try original.playlist()
        XCTAssertEqual(SyncPlaylist(restored), original)
    }

    func testInvalidBackupIsRejectedBeforeMerge() throws {
        let duplicate = SyncSnapshot(playlists: [playlist(), playlist()])
        XCTAssertThrowsError(try SyncMerge.merge(base: nil, local: SyncSnapshot(), remote: duplicate))
        XCTAssertThrowsError(try SyncEnvelope(schemaVersion: 3, revision: 0, exists: false,
            snapshot: SyncSnapshot()).validated())
        XCTAssertThrowsError(try SyncEnvelope(schemaVersion: 2, revision: 0, exists: false,
            snapshot: SyncSnapshot(favorites: ["song"])).validated())
    }
}
