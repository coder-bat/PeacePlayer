//
//  AudioVisualizerEngineTests.swift
//  YTAudioPlayerTests
//
//  The audio tap used to look up its track with
//  `AVAsset.tracks(withMediaType:)` — a SYNCHRONOUS XPC round-trip to
//  the media daemon. When it ran on the main thread (it did: it was
//  called straight from `PlayerState.play(item:)`) the app froze for
//  as long as the media daemon took to answer, and iOS watchdog-killed
//  it. Tapping a record in the crate triggered it every time
//  (2026-11-18).
//
//  These tests use a server that deliberately stalls, so the old
//  behaviour (block the caller) and the new one (do not) are
//  distinguishable.
//

import XCTest
import Network
import AVFoundation
@testable import PeacePlayer

final class AudioVisualizerEngineTests: XCTestCase {

    /// A loopback HTTP server that stalls before answering, so an
    /// AVAsset property lookup has something real to wait for.
    private final class StallingServer {
        private let listener: NWListener
        private(set) var port: UInt16 = 0

        /// How long the server sits on a request.
        let delay: TimeInterval

        init(delay: TimeInterval) throws {
            self.delay = delay
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: .any)
        }

        func start() throws {
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { [delay] connection in
                connection.start(queue: .global(qos: .userInitiated))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                    // Stall: the asset lookup has to wait for this.
                    Thread.sleep(forTimeInterval: delay)
                    let header = "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: 4\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(header.utf8) + Data([0xFF, 0xFB, 0x90, 0x00]),
                                    completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            _ = ready.wait(timeout: .now() + 5)
            port = listener.port?.rawValue ?? 0
        }

        func stop() { listener.cancel() }

        func url() -> URL {
            URL(string: "http://127.0.0.1:\(port)/track.mp3")!
        }
    }

    /// Installing the tap must return immediately, even when the asset
    /// is slow to answer.
    func testInstallTapDoesNotBlockTheCaller() throws {
        let server = try StallingServer(delay: 4)
        try server.start()
        defer { server.stop() }

        let asset = AVURLAsset(url: server.url())
        let item = AVPlayerItem(asset: asset)
        let engine = AudioVisualizerEngine.shared
        defer { engine.removeTap() }

        let started = Date()
        engine.installTap(on: item)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 1.0,
                          "installTap blocked the caller for \(elapsed)s — the track lookup is synchronous again")
    }

    /// A second install (another track) must not leave the previous
    /// tap attached, and must not block either.
    func testInstallingTwiceIsSafeAndStillDoesNotBlock() throws {
        let server = try StallingServer(delay: 4)
        try server.start()
        defer { server.stop() }

        let engine = AudioVisualizerEngine.shared
        defer { engine.removeTap() }

        let first = AVPlayerItem(asset: AVURLAsset(url: server.url()))
        let second = AVPlayerItem(asset: AVURLAsset(url: server.url()))

        let started = Date()
        engine.installTap(on: first)
        engine.installTap(on: second)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 1.5,
                          "Two installs blocked the caller for \(elapsed)s")
    }
}
