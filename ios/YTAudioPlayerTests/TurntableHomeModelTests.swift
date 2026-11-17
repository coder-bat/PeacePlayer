//
//  TurntableHomeModelTests.swift
//  YTAudioPlayerTests
//
//  The crate's sleeve list and the RPM switch's rate mapping.
//
//  The sleeve list matters because the crate is the Home screen's
//  only browse surface now: a duplicate sleeve would show the same
//  track twice, and an artist whose suggestion list failed to load
//  would silently shrink the crate.
//

import XCTest
@testable import PeacePlayer

final class TurntableHomeModelTests: XCTestCase {

    func testSleevesAreFlattenedFromAllArtists() {
        let a = makeTrack(id: "a", title: "Alpha")
        let b = makeTrack(id: "b", title: "Beta")
        let sleeves = TurntableHomeModel.sleeves(from: ["Artist One": [a], "Artist Two": [b]], limit: 10)
        XCTAssertEqual(sleeves.count, 2)
        XCTAssertEqual(Set(sleeves.map(\.videoId)), Set(["a", "b"]))
    }

    func testSleevesRespectLimit() {
        let tracks = (0..<8).map { makeTrack(id: "t\($0)", title: "T\($0)") }
        let sleeves = TurntableHomeModel.sleeves(from: ["Artist": tracks], limit: 4)
        XCTAssertEqual(sleeves.count, 4)
    }

    func testSleevesAreDeduplicatedByTrack() {
        let a = makeTrack(id: "a", title: "Alpha")
        let sleeves = TurntableHomeModel.sleeves(from: ["One": [a], "Two": [a]], limit: 10)
        XCTAssertEqual(sleeves.count, 1, "The same track must not appear twice in the crate")
    }

    func testSleevesAreEmptyForNoSuggestions() {
        XCTAssertTrue(TurntableHomeModel.sleeves(from: [:], limit: 10).isEmpty)
    }

    func testSleevesAreDeterministicAcrossCalls() {
        // The crate must not reshuffle itself on every Home render.
        let a = makeTrack(id: "a", title: "Alpha")
        let b = makeTrack(id: "b", title: "Beta")
        let first = TurntableHomeModel.sleeves(from: ["Zebra": [b], "Apple": [a]], limit: 10)
        let second = TurntableHomeModel.sleeves(from: ["Zebra": [b], "Apple": [a]], limit: 10)
        XCTAssertEqual(first.map(\.videoId), second.map(\.videoId))
    }

    func testPlaybackRateForRPM() {
        XCTAssertEqual(TurntableHomeModel.playbackRate(forRPM: false), 1.0, accuracy: 0.001)
        XCTAssertEqual(TurntableHomeModel.playbackRate(forRPM: true), 1.25, accuracy: 0.001)
    }

    func testPlaybackRateStaysInsidePlayerStateAllowedRange() {
        // PlayerState.setPlaybackRate rejects anything outside 0.5...3.0.
        // The 45 RPM chip must not silently no-op.
        for is45 in [false, true] {
            let rate = TurntableHomeModel.playbackRate(forRPM: is45)
            XCTAssertTrue((0.5...3.0).contains(rate),
                          "Rate \(rate) would be rejected by setPlaybackRate")
        }
    }

    private func makeTrack(id: String, title: String) -> Track {
        Track(videoId: id,
             title: title,
             artists: ["Artist"],
             album: "Album",
             durationSeconds: 180,
             thumbnails: [],
             isExplicit: false,
             videoType: "MUSIC_VIDEO_TYPE_ATV")
    }
}
