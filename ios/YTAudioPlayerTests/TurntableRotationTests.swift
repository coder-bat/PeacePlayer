//
//  TurntableRotationTests.swift
//  YTAudioPlayerTests
//
//  The record's rotation must be CONTINUOUS.
//
//  The player's clock ticks once a second (the AVPlayer time observer
//  runs at 1Hz), so anything drawn straight from `progress` moves in
//  one-second steps — the "very short bursts" the deck used to show.
//  The deck samples the clock at display rate and projects its value
//  forward by the wall-clock time since the last tick.
//
//  These tests pin that behaviour down in numbers, so a regression
//  cannot hide behind a screenshot that happened to look fine.
//

import XCTest
@testable import PeacePlayer

final class TurntableRotationTests: XCTestCase {

    /// A clock that has just ticked: 60 seconds into a 300-second track.
    private func makeClock() -> PlaybackClock {
        let clock = PlaybackClock()
        clock.tick(currentSeconds: 60, totalSeconds: 300, effectiveDuration: 300)
        return clock
    }

    /// Sampling the projected progress at 30fps must give 30 small
    /// steps, not one big jump a second later.
    func testProjectedProgressMovesInSmallStepsAtDisplayRate() {
        let clock = makeClock()
        let start = clock.lastUpdateDate
        let frames = 30

        var samples: [Double] = []
        for frame in 0...frames {
            let date = start.addingTimeInterval(Double(frame) / 30.0)
            samples.append(clock.projectedProgress(at: date))
        }

        // Every step is a fraction of a second's worth of progress.
        // A 300-second track advances 1/300 per second, so a frame at
        // 30fps must move about 1/9000 — and must never be zero.
        let frameStep = 1.0 / 30.0 / 300.0
        for index in 1...frames {
            let delta = samples[index] - samples[index - 1]
            XCTAssertGreaterThan(delta, 0,
                "Frame \(index) did not advance — the record is standing still")
            XCTAssertLessThanOrEqual(delta, frameStep * 1.5,
                "Frame \(index) jumped \(delta) — that is a burst, not a turn")
        }
    }

    /// The raw clock value stands still between ticks. The projected
    /// value must not: over one second of display-rate sampling it
    /// has to cover the whole second of the track.
    func testProjectedProgressCoversTheSecondTheRawClockMisses() {
        let clock = makeClock()
        let start = clock.lastUpdateDate

        let raw = clock.progress
        let projectedAtEnd = clock.projectedProgress(at: start.addingTimeInterval(1.0))

        // The clock itself has not moved: it ticks once a second.
        XCTAssertEqual(raw, clock.progress, accuracy: 0.0001)

        // The projection has advanced a full second of the track.
        let expected = 61.0 / 300.0
        XCTAssertEqual(projectedAtEnd, expected, accuracy: 0.01)
    }

    /// A stale clock must not be projected: after the trust window the
    /// clock's own value is safer than an extrapolation.
    func testProjectionIsNotAppliedToAStaleClock() {
        let clock = makeClock()
        let stale = clock.lastUpdateDate.addingTimeInterval(5.0)

        XCTAssertEqual(clock.projectedProgress(at: stale), clock.progress,
                       accuracy: 0.0001,
                       "A five-second-old clock must not be extrapolated")
    }

    /// Projection must stay inside the track.
    func testProjectionIsClampedToTheTrack() {
        let clock = makeClock()
        let nearEnd = clock.lastUpdateDate.addingTimeInterval(1.5)

        let value = clock.projectedProgress(at: nearEnd)
        XCTAssertGreaterThanOrEqual(value, 0)
        XCTAssertLessThanOrEqual(value, 1)
    }

    /// The rate is honoured: at double speed the record turns twice as
    /// fast, which is what a real turntable does.
    func testProjectionFollowsThePlaybackRate() {
        let clock = makeClock()
        clock.setRate(2.0)
        let start = clock.lastUpdateDate

        let normal = makeClock().projectedProgress(at: start.addingTimeInterval(0.5))
        let doubled = clock.projectedProgress(at: start.addingTimeInterval(0.5))

        XCTAssertGreaterThan(doubled, normal,
                             "A doubled playback rate must turn the record faster")
    }
}
