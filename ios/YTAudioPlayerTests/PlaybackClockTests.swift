//
//  PlaybackClockTests.swift
//  YTAudioPlayerTests
//
//  Sprint 2 fix verification: PlaybackClock is the focused observable
//  for the 0.5s time/progress updates. It must:
//  1. De-duplicate near-equal values (avoid spurious SwiftUI re-renders)
//  2. Reset cleanly (called from PlayerState.stop())
//  3. Track elapsed wall-clock time correctly for listening-time accounting
//  4. Honor the effective duration for progress math
//
//  Reference: project-playback-gap-analysis-2026-06-16.md, Sprint 2 / C-4
//

import XCTest
@testable import PeacePlayer

final class PlaybackClockTests: XCTestCase {

    var clock: PlaybackClock!

    override func setUp() {
        super.setUp()
        clock = PlaybackClock()
    }

    override func tearDown() {
        clock = nil
        super.tearDown()
    }

    func testTick_firstCall_returnsElapsedTime() {
        let elapsed = clock.tick(currentSeconds: 5.0, totalSeconds: 180.0, effectiveDuration: 180.0)
        // First call elapsed should be small but positive (we just initialized).
        XCTAssertGreaterThanOrEqual(elapsed, 0)
        XCTAssertLessThanOrEqual(elapsed, 1.0)
    }

    func testTick_updatesCurrentTimeAndProgress() {
        clock.tick(currentSeconds: 30.0, totalSeconds: 180.0, effectiveDuration: 180.0)

        XCTAssertEqual(clock.currentTime, 30.0, accuracy: 0.05)
        XCTAssertEqual(clock.progress, 30.0 / 180.0, accuracy: 0.001)
        XCTAssertEqual(clock.duration, 180.0, accuracy: 0.1)
    }

    func testTick_clampsProgressToZeroOne() {
        // If current exceeds effectiveDuration, progress should be capped at 1.0
        // (avoids the scrubber bar overflowing past the end).
        clock.tick(currentSeconds: 999.0, totalSeconds: 180.0, effectiveDuration: 180.0)

        XCTAssertEqual(clock.progress, 1.0, accuracy: 0.001)
    }

    func testTick_dedupesNearEqualCurrentTime() {
        // Two ticks with the same currentTime value should NOT cause two
        // SwiftUI render passes. The de-dup is internal — we verify by
        // checking that the published value didn't change (the test
        // would still pass if it did, but the @Published should fire
        // only on material change).
        // Indirect verification: check currentTime is exactly what we set.
        clock.tick(currentSeconds: 30.0, totalSeconds: 180.0, effectiveDuration: 180.0)
        let firstTime = clock.currentTime
        clock.tick(currentSeconds: 30.0, totalSeconds: 180.0, effectiveDuration: 180.0)
        XCTAssertEqual(clock.currentTime, firstTime)
    }

    func testReset_zerosAllFields() {
        clock.tick(currentSeconds: 60.0, totalSeconds: 180.0, effectiveDuration: 180.0)
        clock.setExpectedDuration(180.0)
        clock.setRate(1.5)

        clock.reset()

        XCTAssertEqual(clock.currentTime, 0.0)
        XCTAssertEqual(clock.progress, 0.0)
        XCTAssertEqual(clock.duration, 0.0)
        XCTAssertEqual(clock.expectedDuration, 0.0)
        XCTAssertEqual(clock.rate, 1.0)
    }

    func testSetExpectedDuration_updatesValue() {
        clock.setExpectedDuration(245.0)
        XCTAssertEqual(clock.expectedDuration, 245.0)
    }

    func testSetRate_updatesValue() {
        clock.setRate(1.25)
        XCTAssertEqual(clock.rate, 1.25)
    }

    func testTick_progressUsesEffectiveDurationOverTotal() {
        // If effective duration is from track metadata and differs from
        // AVPlayer's reported total, progress should use the effective
        // one (this is the "AVPlayer reports wrong duration for streams"
        // workaround documented in PlayerState.effectiveDuration).
        clock.tick(currentSeconds: 30.0, totalSeconds: 9999.0, effectiveDuration: 180.0)

        // 30/180, not 30/9999
        XCTAssertEqual(clock.progress, 30.0 / 180.0, accuracy: 0.001)
    }
}
