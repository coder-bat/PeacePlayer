//
//  QueueStoreThreadSafetyTests.swift
//  YTAudioPlayerTests
//
//  The deck logged "Publishing changes from background threads is not
//  allowed" during the on-device UI run.
//
//  `QueueStore.items` and `currentIndex` are `@Published`, and several
//  callers reach the store from a Combine callback that runs on
//  whatever queue the publisher used (the stream-URL cache, the
//  adaptive-quality manager, the gapless controller). A background
//  publish is dropped by SwiftUI, so the deck's queue — and the
//  `currentItem` mirror built on top of it — could stop updating
//  without any visible error.
//
//  The store now routes every mutation through the main thread. These
//  tests pin that behaviour: a mutation issued from a background
//  queue must (a) still be applied and (b) be observed on the main
//  thread.
//

import XCTest
import Combine
@testable import PeacePlayer

final class QueueStoreThreadSafetyTests: XCTestCase {

    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeItem(_ id: String) -> QueueItem {
        let track = Track(
            videoId: id,
            title: "Track \(id)",
            artists: ["Artist"],
            album: "Album",
            durationSeconds: 180,
            thumbnails: [],
            isExplicit: false,
            videoType: "music"
        )
        return QueueItem(track: track, streamUrl: "https://example.test/\(id)", source: .stream)
    }

    /// Runs `work` on a background queue and waits for the main queue
    /// to drain, so any main-thread hop inside the store has landed.
    private func mutateInBackground(_ work: @escaping () -> Void) {
        let done = expectation(description: "background mutation issued")
        DispatchQueue.global(qos: .userInitiated).async {
            work()
            done.fulfill()
        }
        wait(for: [done], timeout: 2.0)
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2.0)
    }

    // MARK: - Tests

    func testBackgroundAddIsAppliedToTheQueue() {
        let store = QueueStore()
        XCTAssertTrue(store.items.isEmpty)

        mutateInBackground {
            store.add(self.makeItem("bg-1"), maxQueueSize: 50)
        }

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.track.videoId, "bg-1")
    }

    func testBackgroundMutationPublishesOnTheMainThread() {
        let store = QueueStore()
        var observedThreads: [Bool] = []

        store.$items
            .sink { _ in observedThreads.append(Thread.isMainThread) }
            .store(in: &cancellables)

        mutateInBackground {
            store.add(self.makeItem("bg-2"), maxQueueSize: 50)
        }

        XCTAssertFalse(observedThreads.isEmpty, "the store never published")
        XCTAssertTrue(
            observedThreads.allSatisfy { $0 },
            "QueueStore published off the main thread: \(observedThreads)"
        )
    }

    func testBackgroundCurrentIndexIsAppliedAndClamped() {
        let store = QueueStore()
        store.replace(with: [makeItem("a"), makeItem("b")])

        mutateInBackground {
            store.setCurrentIndex(1)
        }
        XCTAssertEqual(store.currentIndex, 1)

        // Out of range on a background thread — still clamped, still
        // applied on the main thread.
        mutateInBackground {
            store.setCurrentIndex(99)
        }
        XCTAssertEqual(store.currentIndex, 1)

        mutateInBackground {
            store.setCurrentIndex(-5)
        }
        XCTAssertEqual(store.currentIndex, 0)
    }

    func testBackgroundRemoveKeepsIndexConsistent() {
        let store = QueueStore()
        store.replace(with: [makeItem("a"), makeItem("b"), makeItem("c")])
        store.setCurrentIndex(2)

        mutateInBackground {
            store.remove(at: 0)
        }

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertEqual(store.currentItem?.track.videoId, "c")
    }

    func testBackgroundClearEmptiesTheQueue() {
        let store = QueueStore()
        store.replace(with: [makeItem("a")])
        store.setCurrentIndex(0)

        mutateInBackground {
            store.clear()
        }

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.currentIndex, -1)
    }
}
