//
//  TurntableGeometryTests.swift
//  YTAudioPlayerTests
//
//  The platter's rotation and the tonearm's sweep are pure geometry
//  with no dependency on the player, which makes them cheap to test
//  and impossible to get subtly wrong at runtime.
//
//  The critical property is monotonicity: rotation and arm angle must
//  only ever move one way as progress increases, and the inverse
//  mapping must round-trip. If that breaks, the record turns backwards
//  when the user scrubs.
//

import XCTest
@testable import PeacePlayer

final class TurntableGeometryTests: XCTestCase {

    // MARK: - Platter

    func testPlatterRotationIsZeroAtStartAndFullTurnAtEnd() {
        XCTAssertEqual(PlatterGeometry.rotation(forProgress: 0), 0, accuracy: 0.001)
        XCTAssertEqual(PlatterGeometry.rotation(forProgress: 1),
                       360 * PlatterGeometry.turnsPerTrack,
                       accuracy: 0.001)
    }

    func testPlatterRotationIsLinearInProgress() {
        XCTAssertEqual(PlatterGeometry.rotation(forProgress: 0.25),
                       360 * PlatterGeometry.turnsPerTrack * 0.25,
                       accuracy: 0.001)
        XCTAssertEqual(PlatterGeometry.rotation(forProgress: 0.5),
                       360 * PlatterGeometry.turnsPerTrack * 0.5,
                       accuracy: 0.001)
    }

    func testPlatterRotationClampsOutOfRangeProgress() {
        XCTAssertEqual(PlatterGeometry.rotation(forProgress: -0.5), 0, accuracy: 0.001)
        XCTAssertEqual(PlatterGeometry.rotation(forProgress: 1.5),
                       360 * PlatterGeometry.turnsPerTrack,
                       accuracy: 0.001)
    }

    func testSheenAngleStaysInZeroToOneRange() {
        for step in 0...20 {
            let p = Double(step) / 20.0
            let a = PlatterGeometry.sheenAngle(forProgress: p)
            XCTAssertTrue((0...1).contains(a), "sheen out of range at \(p): \(a)")
        }
    }

    // MARK: - Platter speed
    //
    // The record turns once every `secondsPerTurn` seconds of audio,
    // whatever the track's length. It is still a pure function of the
    // playback position: the same place in the same track is always
    // the same angle.

    func testRecordTurnsAtTheSameSpeedWhateverTheTrackLength() {
        for duration in [60.0, 183.0, 244.0, 600.0, 3600.0] {
            // One second of audio, as a fraction of this track.
            let degreesPerSecond = PlatterGeometry.rotation(forProgress: 1 / duration, duration: duration)
            // Rounding to a whole number of turns moves the speed by
            // at most half a turn per track — a few percent.
            XCTAssertEqual(degreesPerSecond, 360 / PlatterGeometry.secondsPerTurn, accuracy: 4.0,
                           "A \(Int(duration))s track turns at the wrong speed")
        }
    }

    func testRecordMakesAWholeNumberOfTurnsPerTrack() {
        // So every record ends the way it started, and repeating a
        // track does not snap the artwork round.
        for duration in [1.0, 59.0, 183.0, 244.5, 1800.0] {
            let turns = PlatterGeometry.turns(forDuration: duration)
            XCTAssertEqual(turns, turns.rounded(), accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(turns, 1)
        }
    }

    func testRecordOfUnknownLengthFallsBackToOneTurn() {
        XCTAssertEqual(PlatterGeometry.turns(forDuration: 0), PlatterGeometry.turnsPerTrack)
        XCTAssertEqual(PlatterGeometry.rotation(forProgress: 0.5, duration: 0),
                       PlatterGeometry.rotation(forProgress: 0.5), accuracy: 0.001)
    }

    func testRecordNeverTurnsBackwardsAsTheTrackPlays() {
        var previous = PlatterGeometry.rotation(forProgress: 0, duration: 244)
        for step in 1...1000 {
            let angle = PlatterGeometry.rotation(forProgress: Double(step) / 1000, duration: 244)
            XCTAssertGreaterThan(angle, previous, "Record went backwards at step \(step)")
            previous = angle
        }
    }

    // MARK: - Platter inertia
    //
    // What is drawn eases toward the true angle. These pin the three
    // things that easing must never do: overshoot, go the long way
    // round, or keep turning after the audio has stopped.

    func testShortestArcNeverExceedsHalfATurn() {
        XCTAssertEqual(PlatterGeometry.shortestArc(from: 10, to: 30), 20, accuracy: 0.001)
        XCTAssertEqual(PlatterGeometry.shortestArc(from: 350, to: 10), 20, accuracy: 0.001)
        XCTAssertEqual(PlatterGeometry.shortestArc(from: 10, to: 350), -20, accuracy: 0.001)
        // A seek across the whole track is thousands of degrees away
        // on paper; on the platter it is a fraction of a turn.
        XCTAssertEqual(PlatterGeometry.shortestArc(from: 0, to: 360 * 25 + 90), 90, accuracy: 0.001)
        for target in stride(from: -2000.0, through: 2000.0, by: 37.0) {
            XCTAssertLessThanOrEqual(abs(PlatterGeometry.shortestArc(from: 123, to: target)), 180.0001)
        }
    }

    func testPlatterClosesOnItsTargetWithoutOvershooting() {
        var angle = 0.0
        let target = 90.0
        for _ in 0..<120 {
            let next = PlatterGeometry.follow(current: angle, target: target, elapsed: 1.0 / 60.0)
            XCTAssertGreaterThanOrEqual(next, angle, "The platter went backwards")
            XCTAssertLessThanOrEqual(next, target + 0.0001, "The platter overshot")
            angle = next
        }
        XCTAssertEqual(angle, target, accuracy: 0.1, "The platter had not settled after two seconds")
    }

    func testPlatterSettlesWithinHalfASecondOfAPause() {
        // At playing speed the drawn angle trails the true one by a
        // few degrees. When the audio stops the target stops, and the
        // platter must be at rest — within a degree — half a second
        // later.
        let lag = 360 / PlatterGeometry.secondsPerTurn * PlatterGeometry.settleTime
        var angle = 0.0
        for _ in 0..<30 {
            angle = PlatterGeometry.follow(current: angle, target: lag, elapsed: 1.0 / 60.0)
        }
        XCTAssertEqual(angle, lag, accuracy: 1.0)
    }

    func testPlatterSmoothsTheClocksOneSecondTicks() {
        // The player's clock is corrected once a second, and the
        // correction can land a few hundredths of a second off the
        // projection. Drawn raw, that is a visible twitch every
        // second; eased, no single frame moves much more than a
        // frame's worth of turning.
        let speed = 360 / PlatterGeometry.secondsPerTurn
        let frame = 1.0 / 60.0
        var drawn = 0.0
        var largestStep = 0.0
        for index in 1...600 {
            let time = Double(index) * frame
            // A 40ms hiccup in the target at every whole second.
            let hiccup = (index % 60 == 0) ? speed * 0.04 : 0
            let target = speed * time + hiccup
            let next = PlatterGeometry.follow(current: drawn, target: target, elapsed: frame)
            if index > 60 { largestStep = max(largestStep, abs(next - drawn)) }
            drawn = next
        }
        XCTAssertLessThan(largestStep, speed * frame * 1.6,
                          "A clock correction showed up as a jump in the record")
    }

    func testPlatterHoldsStillWhenNoTimeHasPassed() {
        XCTAssertEqual(PlatterGeometry.follow(current: 42, target: 300, elapsed: 0), 42)
        XCTAssertEqual(PlatterGeometry.follow(current: 42, target: 300, elapsed: -1), 42)
    }

    func testPlatterCatchesUpAtOnceAfterALongGap() {
        // The timeline is paused while nothing plays. The first frame
        // back may be minutes later; the record must simply be right.
        XCTAssertEqual(PlatterGeometry.follow(current: 0, target: 120, elapsed: 90), 120, accuracy: 0.001)
    }

    // MARK: - Tonearm

    func testArmAngleMovesFromStartToEndAcrossTrack() {
        let start = TonearmGeometry.angle(forProgress: 0)
        let end = TonearmGeometry.angle(forProgress: 1)
        XCTAssertEqual(start, TonearmGeometry.startAngle, accuracy: 0.0001)
        XCTAssertEqual(end, TonearmGeometry.endAngle, accuracy: 0.0001)
        // The pivot is on the back-RIGHT of the deck and the arm runs
        // down the right-hand side, so it swings clockwise — toward
        // the spindle — as the stylus travels inward. The sweep is
        // ~25 degrees, the same as a real arm's travel across a side.
        XCTAssertGreaterThan(end, start, "Arm must sweep inward as the track plays")
        XCTAssertEqual(end - start, 25.4 * .pi / 180, accuracy: 0.01)
    }

    func testArmPivotIsOnTheBackRightOfTheDeck() {
        // Every real turntable mounts the arm on the right and the
        // start/stop lever on the left. The deck follows suit.
        XCTAssertGreaterThan(TonearmGeometry.pivotFraction.x, 0.5)
        XCTAssertLessThan(TonearmGeometry.pivotFraction.y, 0.25)
    }

    func testArmPivotStandsClearOfThePlatter() {
        // The pivot is bolted to the plinth, not hovering over the
        // platter's edge.
        let size = CGSize(width: TonearmGeometry.nominalFrame, height: TonearmGeometry.nominalFrame)
        let pivot = TonearmGeometry.pivot(in: size)
        let centre = TonearmGeometry.recordCentre(in: size)
        let distance = hypot(pivot.x - centre.x, pivot.y - centre.y)
        XCTAssertGreaterThan(distance, TonearmGeometry.nominalFrame / 2 + 20)
    }

    func testArmIsLongerThanThePivotToSpindleDistance() {
        // The overhang. Without it the stylus could not reach round
        // the spindle side of the record, and the arm would have to
        // lie across the artwork instead of alongside it.
        let size = CGSize(width: TonearmGeometry.nominalFrame, height: TonearmGeometry.nominalFrame)
        let pivot = TonearmGeometry.pivot(in: size)
        let centre = TonearmGeometry.recordCentre(in: size)
        let overhang = TonearmGeometry.armLength(in: size) - hypot(pivot.x - centre.x, pivot.y - centre.y)
        XCTAssertGreaterThan(overhang, 5)
        XCTAssertLessThan(overhang, 25)
    }

    func testArmAngleIsClampedOutsideZeroToOne() {
        XCTAssertEqual(TonearmGeometry.angle(forProgress: -1),
                       TonearmGeometry.startAngle, accuracy: 0.0001)
        XCTAssertEqual(TonearmGeometry.angle(forProgress: 2),
                       TonearmGeometry.endAngle, accuracy: 0.0001)
    }

    func testArmProgressIsInverseOfAngle() {
        for step in 0...10 {
            let p = Double(step) / 10.0
            let angle = TonearmGeometry.angle(forProgress: p)
            XCTAssertEqual(TonearmGeometry.progress(forAngle: angle), p, accuracy: 0.001)
        }
    }

    func testArmAngleIsMonotonicInProgress() {
        // The arm must never swing back out as progress advances.
        var previous = TonearmGeometry.angle(forProgress: 0)
        for step in 1...100 {
            let angle = TonearmGeometry.angle(forProgress: Double(step) / 100.0)
            XCTAssertGreaterThanOrEqual(angle, previous,
                                        "Arm angle went backwards at step \(step)")
            previous = angle
        }
    }

    // MARK: - Stylus placement
    //
    // The arm's length is fixed, so the stylus rides an arc about the
    // pivot rather than a straight line. These assertions pin that
    // arc to the record: at rest the needle sits on the outer groove,
    // and at the end of the track it sits at the edge of the label.
    // If the geometry drifts, the needle ends up on the felt mat or
    // off the record entirely — and nothing else in the app would
    // notice.

    /// The record's radius in the calibration frame.
    private var recordRadius: CGFloat {
        TonearmGeometry.nominalFrame / 2 * PlatterView.recordDiameter / PlatterView.diameter
    }

    /// The platter's radius in the calibration frame.
    private var platterRadius: CGFloat {
        TonearmGeometry.nominalFrame / 2
    }

    private func radius(ofArmAt angle: Double, fraction: CGFloat = 1) -> CGFloat {
        let size = CGSize(width: TonearmGeometry.nominalFrame,
                          height: TonearmGeometry.nominalFrame)
        let pivot = TonearmGeometry.pivot(in: size)
        let reach = TonearmGeometry.armLength(in: size) * fraction
        let centre = TonearmGeometry.recordCentre(in: size)
        return hypot(pivot.x + reach * CGFloat(cos(angle)) - centre.x,
                     pivot.y + reach * CGFloat(sin(angle)) - centre.y)
    }

    private func stylusRadius(forProgress progress: Double) -> CGFloat {
        let size = CGSize(width: TonearmGeometry.nominalFrame,
                          height: TonearmGeometry.nominalFrame)
        let stylus = TonearmGeometry.stylusPoint(forProgress: progress, in: size)
        let centre = TonearmGeometry.recordCentre(in: size)
        return hypot(stylus.x - centre.x, stylus.y - centre.y)
    }

    func testStylusRestsOnTheOuterGroove() {
        // The record's edge is at 144pt; the lead-in groove is a
        // little inside it.
        XCTAssertEqual(stylusRadius(forProgress: 0), 130, accuracy: 3)
        XCTAssertLessThan(stylusRadius(forProgress: 0), recordRadius - 6)
    }

    func testStylusEndsAtTheLabelEdge() {
        // The paper label is 96pt across, so its edge is 48pt out.
        XCTAssertEqual(stylusRadius(forProgress: 1), 45, accuracy: 3)
    }

    func testStylusStaysOnTheRecordForTheWholeTrack() {
        for step in 0...100 {
            let radius = stylusRadius(forProgress: Double(step) / 100.0)
            XCTAssertLessThanOrEqual(radius, recordRadius, "Stylus left the record at step \(step)")
            XCTAssertGreaterThanOrEqual(radius, 45, "Stylus ran into the label at step \(step)")
        }
    }

    func testStylusMovesInwardAsTheTrackPlays() {
        var previous = stylusRadius(forProgress: 0)
        for step in 1...100 {
            let radius = stylusRadius(forProgress: Double(step) / 100.0)
            XCTAssertLessThanOrEqual(radius, previous,
                                     "Stylus moved outward at step \(step)")
            previous = radius
        }
    }

    func testStylusPlaysTheFrontRightOfTheRecord() {
        // Where a real deck's stylus sits: right of the spindle and
        // toward the listener. That is what keeps the arm off the
        // artwork.
        let size = CGSize(width: TonearmGeometry.nominalFrame,
                          height: TonearmGeometry.nominalFrame)
        let centre = TonearmGeometry.recordCentre(in: size)
        for progress in [0.0, 0.5, 1.0] {
            let stylus = TonearmGeometry.stylusPoint(forProgress: progress, in: size)
            XCTAssertGreaterThan(stylus.x, centre.x, "Stylus crossed to the left at \(progress)")
            XCTAssertGreaterThan(stylus.y, centre.y, "Stylus crossed to the back at \(progress)")
        }
    }

    func testParkedArmIsClearOfThePlatter() {
        // With no record loaded the arm sits in its rest. The stylus
        // and the whole front half of the tube must be off the
        // platter, or the parked arm would hang over a turning rim.
        XCTAssertLessThan(TonearmGeometry.restAngle, TonearmGeometry.startAngle,
                          "The rest is on the wrong side of the lead-in groove")
        for fraction in stride(from: CGFloat(0.5), through: 1.0, by: 0.05) {
            XCTAssertGreaterThan(radius(ofArmAt: TonearmGeometry.restAngle, fraction: fraction),
                                 platterRadius,
                                 "The parked arm overhangs the platter \(Int(fraction * 100))% of the way along")
        }
    }

    func testArmLengthIsConstantSoTheStylusRidesAnArc() {
        // Two different progress values, two different stylus points,
        // but the same distance from the pivot — that is what makes
        // the arm a rigid tube.
        let size = CGSize(width: TonearmGeometry.nominalFrame,
                          height: TonearmGeometry.nominalFrame)
        let pivot = TonearmGeometry.pivot(in: size)
        let length = TonearmGeometry.armLength(in: size)

        for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let stylus = TonearmGeometry.stylusPoint(forProgress: progress, in: size)
            let distance = hypot(stylus.x - pivot.x, stylus.y - pivot.y)
            XCTAssertEqual(distance, length, accuracy: 0.5,
                           "Arm length changed at progress \(progress)")
        }
    }

    func testCartridgeLiesAlongTheGroove() {
        // The headshell is cranked in so the cartridge points along
        // the groove under it. Across the whole side the error must
        // stay small, or the cartridge would visibly sit skewed on the
        // record.
        let size = CGSize(width: TonearmGeometry.nominalFrame,
                          height: TonearmGeometry.nominalFrame)
        let centre = TonearmGeometry.recordCentre(in: size)
        for step in 0...10 {
            let progress = Double(step) / 10
            let stylus = TonearmGeometry.stylusPoint(forProgress: progress, in: size)
            let cartridge = TonearmGeometry.angle(forProgress: progress) + TonearmGeometry.offsetAngle
            // The groove's direction is at right angles to the radius.
            let radial = atan2(Double(stylus.y - centre.y), Double(stylus.x - centre.x))
            var error = (cartridge - (radial + .pi / 2)).truncatingRemainder(dividingBy: .pi)
            if error > .pi / 2 { error -= .pi }
            if error < -.pi / 2 { error += .pi }
            XCTAssertLessThan(abs(error), 6 * .pi / 180,
                              "Cartridge is \(error * 180 / .pi)° off the groove at \(progress)")
        }
    }

    // MARK: - Scrub detents

    func testDetentFiresOnEachTenPercentBoundary() {
        XCTAssertEqual(TonearmGeometry.detent(forProgress: 0.10), 1)
        XCTAssertEqual(TonearmGeometry.detent(forProgress: 0.20), 2)
        XCTAssertEqual(TonearmGeometry.detent(forProgress: 0.55), 5)
    }

    func testDetentIsNilBelowFirstBoundary() {
        XCTAssertNil(TonearmGeometry.detent(forProgress: 0.0))
        XCTAssertNil(TonearmGeometry.detent(forProgress: 0.09))
    }

    func testDetentIsNilAtExactlyZero() {
        XCTAssertNil(TonearmGeometry.detent(forProgress: 0.0))
    }

    func testDetentDoesNotFirePastTheEnd() {
        // 100% is the end of the track - there is no 10th detent.
        XCTAssertNil(TonearmGeometry.detent(forProgress: 1.0))
        XCTAssertNil(TonearmGeometry.detent(forProgress: 1.4))
    }

    func testEachDetentIndexIsUniqueAcrossTheTrack() {
        // Walking the track must produce each detent exactly once, so
        // the haptic fires once per notch rather than continuously.
        var fired: [Int] = []
        for step in 0...1000 {
            let p = Double(step) / 1000.0
            if let detent = TonearmGeometry.detent(forProgress: p) {
                if fired.last != detent {
                    fired.append(detent)
                }
            }
        }
        XCTAssertEqual(fired, [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }

    // MARK: - Arm rest (2026-11-22)

    func testTheRestPostStandsUnderTheParkedArmsTube() {
        // The tube is S-shaped: it does not follow the pivot-to-stylus
        // line, and the post has to be under the tube.
        let length: CGFloat = 192
        let offset = TonearmGeometry.restOffset(length: length)
        // Undo the parked arm's rotation: back in the arm's own frame
        // the post must be a point of the tube.
        let c = CGFloat(cos(-TonearmGeometry.restAngle)), sn = CGFloat(sin(-TonearmGeometry.restAngle))
        let local = CGPoint(x: offset.x * c - offset.y * sn, y: offset.x * sn + offset.y * c)
        let onTube = TonearmGeometry.tubePoint(t: TonearmGeometry.restT, length: length)
        XCTAssertEqual(local.x, onTube.x, accuracy: 0.01)
        XCTAssertEqual(local.y, onTube.y, accuracy: 0.01)
        // And the tube really is off the straight line there.
        XCTAssertGreaterThan(abs(onTube.y), 8)
    }

    func testTheTubeRunsFromThePivotToTheHeadshell() {
        let length: CGFloat = 192
        XCTAssertEqual(TonearmGeometry.tubePoint(t: 0, length: length), .zero)
        let end = TonearmGeometry.tubeEnd(length: length)
        XCTAssertEqual(TonearmGeometry.tubePoint(t: 1, length: length).x, end.x, accuracy: 0.001)
        XCTAssertEqual(TonearmGeometry.tubePoint(t: 1, length: length).y, end.y, accuracy: 0.001)
        XCTAssertLessThan(end.x, length)
    }

    func testTheRestPostIsClearOfThePlatter() {
        let size = CGSize(width: 300, height: 300)
        let pivot = TonearmGeometry.pivot(in: size)
        let offset = TonearmGeometry.restOffset(length: TonearmGeometry.armLength(in: size))
        let post = CGPoint(x: pivot.x + offset.x, y: pivot.y + offset.y)
        let centre = TonearmGeometry.recordCentre(in: size)
        XCTAssertGreaterThan(hypot(post.x - centre.x, post.y - centre.y), 150 + 8)
    }

    func testARecordChangeClearsTheArmBeforeTheRecordMoves() {
        XCTAssertGreaterThanOrEqual(TurntableDeckView.RecordChange.swapAt, 0.25)
        // The new record is down before the arm starts back.
        XCTAssertGreaterThan(
            TurntableDeckView.RecordChange.armBackAt,
            TurntableDeckView.RecordChange.swapAt + PlatterView.liftTime + 0.3
        )
        // All inside the second a change takes to buffer.
        XCTAssertLessThanOrEqual(TurntableDeckView.RecordChange.armBackAt, 1.0)
    }
}
