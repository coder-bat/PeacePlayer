//
//  TurntableDeckQueueTests.swift
//  YTAudioPlayerTests
//
//  "When music starts from somewhere else, the turntable doesn't update
//  correctly with the currently playing song and upcoming songs."
//
//  The deck's data comes from `PlayerState.queue` /
//  `PlayerState.currentIndex`, and both are computed from the separate
//  `QueueStore`. Before the fix the deck only observed `PlayerState`,
//  whose `objectWillChange` never fires for queue mutations — so a
//  track started in the Library tab, from a shortcut or from a
//  notification left the deck showing the old record and an empty
//  shelf.
//
//  These tests pin the wiring at the level that can be checked
//  offline: the deck's data source follows the store, and the tray
//  shows what is coming up.
//

import XCTest
@testable import PeacePlayer

final class TurntableDeckQueueTests: XCTestCase {

    private var savedItems: [QueueItem] = []
    private var savedIndex: Int = -1

    override func setUp() {
        super.setUp()
        // The store is a singleton's, so put it back the way it was.
        savedItems = PlayerState.shared.queueStore.items
        savedIndex = PlayerState.shared.queueStore.currentIndex
    }

    override func tearDown() {
        PlayerState.shared.queueStore.replace(with: savedItems)
        PlayerState.shared.queueStore.setCurrentIndex(savedIndex)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Lets the main queue drain.
    ///
    /// `PlayerState`'s `currentItem` mirror is delivered on the main
    /// queue (`receive(on: DispatchQueue.main)`), so it lands one
    /// runloop turn after the store publishes — the same turn a
    /// SwiftUI view would redraw on.
    private func drainMainQueue() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func makeItem(_ id: String, title: String) -> QueueItem {
        let track = Track(
            videoId: id,
            title: title,
            artists: ["Artist"],
            album: "Album",
            durationSeconds: 210,
            thumbnails: [],
            isExplicit: false,
            videoType: "music"
        )
        return QueueItem(track: track, streamUrl: "https://example.test/\(id)", source: .stream)
    }

    // MARK: - Tests

    /// A track started somewhere else lands in the store, and the
    /// deck's data source follows it.
    func testDeckDataSourceFollowsTheStoreWhenPlaybackStartsElsewhere() {
        let store = PlayerState.shared.queueStore
        store.replace(with: [])
        store.setCurrentIndex(-1)

        let item = makeItem("elsewhere-1", title: "Started Elsewhere")
        store.add(item, maxQueueSize: 50)
        store.setCurrentIndex(store.items.count - 1)
        drainMainQueue()

        XCTAssertEqual(PlayerState.shared.queue.count, 1)
        XCTAssertEqual(PlayerState.shared.currentIndex, 0)
        XCTAssertEqual(PlayerState.shared.queue.first?.track.title, "Started Elsewhere")
        XCTAssertEqual(PlayerState.shared.currentItem?.track.videoId, "elsewhere-1")
    }

    /// The deck's shelf shows the current record first and the records
    /// that come after it — the "upcoming songs" the user asked for.
    func testUpcomingSongsFollowTheCurrentIndex() {
        let store = PlayerState.shared.queueStore
        let items = [
            makeItem("u-0", title: "Current"),
            makeItem("u-1", title: "Next"),
            makeItem("u-2", title: "Later")
        ]
        store.replace(with: items)
        store.setCurrentIndex(1)
        drainMainQueue()

        XCTAssertEqual(PlayerState.shared.currentIndex, 1)
        XCTAssertEqual(PlayerState.shared.currentItem?.track.title, "Next")

        let upcoming = PlayerState.shared.queue
            .enumerated()
            .filter { $0.offset > PlayerState.shared.currentIndex }
            .map { $0.element.track.title }
        XCTAssertEqual(upcoming, ["Later"])
    }

    /// The tray follows the record that is playing. Playback that
    /// starts deep in a long queue (a playlist opened at its
    /// thirtieth track) must still put that record in the tray.
    func testTheTrayFollowsPlaybackStartedDeepInTheQueue() {
        let store = PlayerState.shared.queueStore
        store.replace(with: (0..<40).map { makeItem("deep-\($0)", title: "Deep \($0)") })
        store.setCurrentIndex(30)
        drainMainQueue()

        let window = QueueShelf.window(
            count: PlayerState.shared.queue.count,
            currentIndex: PlayerState.shared.currentIndex
        )
        let titles = PlayerState.shared.queue[window].map(\.track.title)

        XCTAssertTrue(titles.contains("Deep 30"), "The playing record is not in the tray")
        XCTAssertTrue(titles.contains("Deep 31"), "The next record is not in the tray")
    }

    /// Changing the queue must publish, or the deck never re-renders.
    func testQueueChangesPublishToObservers() {
        let store = PlayerState.shared.queueStore
        store.replace(with: [])

        var published = 0
        let token = store.$items.dropFirst().sink { _ in published += 1 }
        defer { token.cancel() }

        store.add(makeItem("pub-1", title: "Published"), maxQueueSize: 50)

        XCTAssertGreaterThan(published, 0, "the queue store did not publish")
    }
}
