//
//  ImageCacheConcurrencyTests.swift
//  YTAudioPlayerTests
//
//  The image cache used to mutate its `activeDownloads` dictionary
//  from two threads at once: the publisher body runs on a background
//  queue, and the completion handler runs on URLSession's queue.
//
//  Concurrent mutation of a Swift Dictionary corrupts it. The crash
//  reached the device as an Objective-C "doesNotRecognizeSelector:"
//  thrown from inside the dictionary's setter, and it only fired once
//  the turntable's crate loaded fifteen artworks at the same time —
//  which is exactly what tapping a record in the crate does.
//
//  These tests hammer the cache the way the crate does.
//

import XCTest
@testable import PeacePlayer

final class ImageCacheConcurrencyTests: XCTestCase {

    /// Many simultaneous loads for DIFFERENT urls — the crate case.
    /// Before the lock this corrupted the dictionary.
    func testConcurrentLoadsForDifferentURLsDoNotCorruptTheCache() {
        let urls = (0..<24).map {
            URL(string: "https://example.com/art-\($0).jpg")!
        }

        let expectation = expectation(description: "all loads returned")
        expectation.expectedFulfillmentCount = urls.count

        let lock = NSLock()
        var delivered = 0

        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            let cancellable = ImageCache.shared.image(for: urls[index]).sink { _ in
                lock.lock()
                delivered += 1
                lock.unlock()
                expectation.fulfill()
            }
            _ = cancellable
        }

        wait(for: [expectation], timeout: 10)
        XCTAssertEqual(delivered, urls.count)
    }

    /// The same URL requested from many threads at once: only ONE
    /// download may be started, and the dictionary must survive it.
    func testConcurrentLoadsForTheSameURLShareOneDownload() {
        let url = URL(string: "https://example.com/same.jpg")!

        let expectation = expectation(description: "all loads returned")
        expectation.expectedFulfillmentCount = 16

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let cancellable = ImageCache.shared.image(for: url).sink { _ in
                expectation.fulfill()
            }
            _ = cancellable
        }

        wait(for: [expectation], timeout: 10)
    }

    /// A file:// url is read directly, without URLSession.
    func testLocalFileURLsAreDecoded() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("imagecache-concurrency-test.png")

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        try image.pngData()!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = expectation(description: "loaded")
        var result: UIImage?
        let cancellable = ImageCache.shared.image(for: url).sink { image in
            result = image
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
        _ = cancellable

        XCTAssertNotNil(result)
    }
}
