//
//  ImageCacheDeliveryTests.swift
//  YTAudioPlayerTests
//
//  The cache used to hand the CALLER a placeholder (`Just(nil)`) while
//  the download ran in the background, so the view that asked for a
//  cover never received it. The cover only appeared if something else
//  re-rendered the row and the memory cache happened to hold the image
//  by then — the "thumbnails glitch and never load" bug on the deck's
//  crate and queue discs.
//
//  These tests run a tiny HTTP server on the loopback interface and
//  check that the publisher actually delivers the image.
//

import XCTest
import Network
@testable import PeacePlayer

final class ImageCacheDeliveryTests: XCTestCase {

    /// A 1×1 PNG, served as the "artwork".
    private static let pngBytes = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """) ?? Data()

    /// A loopback HTTP server that answers every request with a 1×1 PNG.
    private final class StubServer {
        private let listener: NWListener
        private(set) var port: UInt16 = 0

        init() throws {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: .any)
        }

        func start() throws {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    ready.signal()
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global(qos: .userInitiated))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                    let bytes = ImageCacheDeliveryTests.pngBytes
                    let header = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
                    var response = Data(header.utf8)
                    response.append(bytes)
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            _ = ready.wait(timeout: .now() + 5)
            port = listener.port?.rawValue ?? 0
        }

        func stop() {
            listener.cancel()
        }

        func url(path: String = "/art.png") -> URL {
            URL(string: "http://127.0.0.1:\(port)\(path)")!
        }
    }

    /// The publisher must deliver the downloaded image, not a
    /// placeholder.
    func testPublisherDeliversTheDownloadedImage() throws {
        let server = try StubServer()
        try server.start()
        defer { server.stop() }

        let url = server.url(path: "/delivery-\(UUID().uuidString).png")
        let delivered = expectation(description: "image delivered")
        var received: UIImage?

        let cancellable = ImageCache.shared.image(for: url).sink { image in
            guard let image = image else { return }
            received = image
            delivered.fulfill()
        }
        defer { cancellable.cancel() }

        wait(for: [delivered], timeout: 15)
        XCTAssertNotNil(received, "The cache never delivered the artwork to its caller")
        XCTAssertEqual(received?.size.width, 1)
    }

    /// Two callers asking for the same URL must both get the image —
    /// the second one joins the download that is already running
    /// instead of waiting for a re-render.
    func testTwoCallersForTheSameURLAreBothServed() throws {
        let server = try StubServer()
        try server.start()
        defer { server.stop() }

        let url = server.url(path: "/shared-\(UUID().uuidString).png")

        let first = expectation(description: "first caller")
        let second = expectation(description: "second caller")
        var firstImage: UIImage?
        var secondImage: UIImage?

        let cancellableA = ImageCache.shared.image(for: url).sink { image in
            guard let image = image else { return }
            firstImage = image
            first.fulfill()
        }
        let cancellableB = ImageCache.shared.image(for: url).sink { image in
            guard let image = image else { return }
            secondImage = image
            second.fulfill()
        }
        defer {
            cancellableA.cancel()
            cancellableB.cancel()
        }

        wait(for: [first, second], timeout: 15)
        XCTAssertNotNil(firstImage)
        XCTAssertNotNil(secondImage, "The second caller never received the artwork")
    }

    /// A local file is delivered immediately (this is the path the
    /// offscreen renderer uses to draw real cover art).
    func testLocalFileArtworkIsDelivered() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-file-\(UUID().uuidString).png")
        try Self.pngBytes.write(to: url)

        let delivered = expectation(description: "file image delivered")
        var received: UIImage?

        let cancellable = ImageCache.shared.image(for: url).sink { image in
            guard let image = image else { return }
            received = image
            delivered.fulfill()
        }
        defer { cancellable.cancel() }

        wait(for: [delivered], timeout: 5)
        XCTAssertNotNil(received)
    }
}
