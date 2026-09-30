import XCTest
import CoreData
@testable import PeacePlayer

private final class SyncStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class SyncIntegrationTests: XCTestCase {
    private func envelope(_ snapshot: SyncSnapshot, revision: Int = 0) throws -> Data {
        try JSONEncoder().encode(SyncEnvelope(schemaVersion: 2, revision: revision, exists: true, snapshot: snapshot))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var context: SyncSessionContext {
        let url = URL(string: "http://sync-test.invalid:8181")!
        return SyncSessionContext(owner: SyncOwner(origin: url.absoluteString, userId: "test-user"),
            backend: BackendIdentity(origin: url, generation: 1), generation: 1, token: "test-only-fixture")
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncStubProtocol.self]
        return URLSession(configuration: config)
    }

    func testUnavailableServerDoesNotChangeUnownedVisibleLibraryOrUpload() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var local = SyncSnapshot(favorites: ["local-song"])
        let store = try SyncLocalStore(file: dir.appendingPathComponent("test.json"), capture: { local }, apply: { local = $0 })
        var methods: [String] = []
        SyncStubProtocol.handler = { request in methods.append(request.httpMethod ?? "GET"); throw URLError(.notConnectedToInternet) }
        defer { SyncStubProtocol.handler = nil }
        let active = context
        let service = SyncService(session: session(), store: store, context: { active })
        await service.syncNow()
        XCTAssertEqual(methods, ["GET"])
        XCTAssertEqual(local.favorites, ["local-song"])
        XCTAssertNil(store.control.owner)
        if case .failed = service.state {} else { XCTFail("Network failure must remain visible") }
    }

    func testFreshRestoreArchivesUnownedDataThenUploadsRemoteWithoutCrossAccountLeak() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var local = SyncSnapshot(favorites: ["old-account-song"])
        let remote = SyncSnapshot(favorites: ["new-account-song"])
        let store = try SyncLocalStore(file: dir.appendingPathComponent("test.json"), capture: { local }, apply: { local = $0 })
        let response = try envelope(remote)
        var methods: [String] = []
        SyncStubProtocol.handler = { request in
            methods.append(request.httpMethod ?? "GET")
            return (200, response)
        }
        defer { SyncStubProtocol.handler = nil }
        let active = context
        let service = SyncService(session: session(), store: store, context: { active })
        await service.syncNow()
        XCTAssertEqual(methods, ["GET", "POST"])
        XCTAssertEqual(local.favorites, ["new-account-song"])
        XCTAssertEqual(store.control.archives.first?.snapshot.favorites, ["old-account-song"])
        XCTAssertEqual(store.control.baselines[active.owner.key]?.favorites, ["new-account-song"])
    }

    func testMalformedResponseAndSaveFailureNeverUpload() async throws {
        for saveFails in [false, true] {
            let dir = try directory()
            defer { try? FileManager.default.removeItem(at: dir) }
            var local = SyncSnapshot(favorites: ["preserved"])
            let store = try SyncLocalStore(file: dir.appendingPathComponent("test.json"), capture: { local }, apply: { snapshot in
                if saveFails { throw CocoaError(.fileWriteOutOfSpace) }
                local = snapshot
            })
            let data = saveFails ? try envelope(SyncSnapshot()) : Data("{\"schemaVersion\":2}".utf8)
            var calls = 0
            SyncStubProtocol.handler = { _ in calls += 1; return (200, data) }
            let active = context
            let service = SyncService(session: session(), store: store, context: { active })
            await service.syncNow()
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(local.favorites, ["preserved"])
            if case .failed = service.state {} else { XCTFail("Failed import must not report success") }
        }
        SyncStubProtocol.handler = nil
    }

    func testJournalReplaysInterruptedImportWithoutLosingBeforeSnapshot() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("test.json")
        var local = SyncSnapshot(favorites: ["before"])
        let broken = try SyncLocalStore(file: file, capture: { local }, apply: { _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try broken.apply(SyncSnapshot(favorites: ["target"]), owner: context.owner))
        XCTAssertEqual(broken.control.journal?.before.favorites, ["before"])
        let recovered = try SyncLocalStore(file: file, capture: { local }, apply: { local = $0 })
        try recovered.recoverIfNeeded()
        XCTAssertEqual(local.favorites, ["target"])
        XCTAssertNil(recovered.control.journal)
    }

    func testAccountSwitchKeepsArchivesUntilExplicitImport() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var local = SyncSnapshot(favorites: ["unowned"])
        let store = try SyncLocalStore(file: dir.appendingPathComponent("test.json"), capture: { local }, apply: { local = $0 })
        _ = try store.prepare(owner: context.owner)
        XCTAssertTrue(local.favorites.isEmpty)
        let saved = try XCTUnwrap(store.control.archives.first)
        try store.importArchive(id: saved.id, owner: context.owner)
        XCTAssertEqual(local.favorites, ["unowned"])
        XCTAssertEqual(store.control.archives.count, 1)
    }

    func testRealStoreAdapterRestoresPublishedPlaylistsAndLinkedHistory() throws {
        // The suite runs on a disposable simulator. The Core Data store is additionally in memory.
        let persistence = PersistenceController(inMemory: true)
        let oldPlaylists = PlaylistManager.shared.playlists
        let oldLikes = Array(PlaylistManager.shared.likedTracks)
        let oldArtists = FavoriteArtistsManager.shared.getArtists()
        let oldRecent = DataManager.shared.recentlyPlayed
        defer {
            try? PlaylistManager.shared.replaceFromBackup(playlists: oldPlaylists, favorites: oldLikes)
            try? FavoriteArtistsManager.shared.replaceFromBackup(oldArtists)
            try? DataManager.shared.replaceRecentFromBackup(oldRecent)
        }
        let playlist = SyncPlaylist(Playlist(name: "Restored ordered mix", trackIds: ["missing", "known"]))
        let events = [
            SyncHistoryEvent(id: "one", videoId: "missing", playedAt: 100.125, progress: 0.25, completed: false),
            SyncHistoryEvent(id: "two", videoId: "missing", playedAt: 101.5, progress: 0.75, completed: false)
        ]
        let snapshot = SyncSnapshot(playlists: [playlist], favorites: ["missing"], history: events)
        try SyncLocalStore.applyLive(snapshot, persistence: persistence)
        XCTAssertEqual(PlaylistManager.shared.playlists.first(where: { $0.id.uuidString.lowercased() == playlist.id })?.trackIds,
            ["missing", "known"])
        XCTAssertEqual(DataManager.shared.recentlyPlayed.first?.videoId, "missing")
        let history = try persistence.viewContext.fetch(CDPlayHistory.fetchRequest())
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.allSatisfy { $0.track?.videoId == "missing" })
        let exported = try SyncLocalStore.captureLive(context: persistence.viewContext)
        XCTAssertEqual(exported.history.count, 2)
        XCTAssertTrue(exported.tracks.contains { $0.videoId == "missing" })
        try SyncLocalStore.applyLive(exported, persistence: persistence)
        XCTAssertEqual(try persistence.viewContext.fetch(CDPlayHistory.fetchRequest()).count, 2)
    }
}
