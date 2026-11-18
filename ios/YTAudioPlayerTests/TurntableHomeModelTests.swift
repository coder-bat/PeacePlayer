//
//  TurntableHomeModelTests.swift
//  YTAudioPlayerTests
//
//  The crate's sleeve list and the crate's grid geometry.
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

    func testCrateHoldsThreeRowsOfSleeves() {
        // The crate shows five sleeves across and three rows deep, so
        // the first screenful holds fifteen records.
        XCTAssertEqual(CrateGrid.columnCount, 5)
        XCTAssertEqual(CrateGrid.visibleRows, 3)
        XCTAssertGreaterThanOrEqual(CrateGrid.columnCount * CrateGrid.visibleRows, 15)
    }

    func testCrateContentsFillFromTheQueueAndRecentlyPlayed() {
        // The suggestions alone rarely fill three rows. The queue and
        // the recently-played shelf top the crate up so the deck does
        // not look half empty.
        let suggestion = makeTrack(id: "s1", title: "Suggested")
        let queued = makeTrack(id: "q1", title: "Queued")
        let recent = makeTrack(id: "r1", title: "Recent")

        let contents = TurntableHomeModel.crateContents(
            suggestions: ["Artist": [suggestion]],
            queue: [QueueItem(track: queued, streamUrl: "u", source: .stream)],
            recent: [RecentTrack(videoId: "r1", title: "Recent", artists: ["Artist"],
                                 album: "Album", durationSeconds: 100, thumbnails: [],
                                 isExplicit: false, videoType: "MUSIC_VIDEO_TYPE_ATV",
                                 playedAt: Date(), playbackProgress: 0)],
            limit: 15
        )

        XCTAssertEqual(contents.map(\.videoId), ["s1", "q1", "r1"])
    }

    func testCrateContentsDoNotRepeatATrack() {
        let track = makeTrack(id: "same", title: "Same")
        let contents = TurntableHomeModel.crateContents(
            suggestions: ["Artist": [track]],
            queue: [QueueItem(track: track, streamUrl: "u", source: .stream)],
            recent: [],
            limit: 15
        )
        XCTAssertEqual(contents.count, 1)
    }

    func testCrateContentsRespectTheLimit() {
        let many = (0..<30).map { makeTrack(id: "t\($0)", title: "T\($0)") }
        let contents = TurntableHomeModel.crateContents(
            suggestions: ["Artist": many],
            queue: [],
            recent: [],
            limit: 15
        )
        XCTAssertEqual(contents.count, 15)
    }

    func testCrateRowsAreFiveAcrossAndThreeDeep() {
        let many = (0..<15).map { makeTrack(id: "t\($0)", title: "T\($0)") }
        let rows = CrateGrid.rows(from: many)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first?.count, 5)
        XCTAssertEqual(rows.last?.count, 5)
    }

    func testAShortLastRowIsStillOneRow() {
        let many = (0..<12).map { makeTrack(id: "t\($0)", title: "T\($0)") }
        let rows = CrateGrid.rows(from: many)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.last?.count, 2)
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
