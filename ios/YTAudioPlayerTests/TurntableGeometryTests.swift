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

    // MARK: - Tonearm

    func testArmAngleMovesFromStartToEndAcrossTrack() {
        let start = TonearmGeometry.angle(forProgress: 0)
        let end = TonearmGeometry.angle(forProgress: 1)
        XCTAssertEqual(start, TonearmGeometry.startAngle, accuracy: 0.0001)
        XCTAssertEqual(end, TonearmGeometry.endAngle, accuracy: 0.0001)
        // The pivot is on the back-RIGHT of the deck, so the arm
        // sweeps anticlockwise (through 180°) as the stylus travels
        // inward. The sweep itself is ~28 degrees, the same as a real
        // arm's travel across a side.
        XCTAssertLessThan(end, start, "Arm must sweep inward as the track plays")
        XCTAssertEqual(start - end, 28.3 * .pi / 180, accuracy: 0.01)
    }

    func testArmPivotIsOnTheBackRightOfTheDeck() {
        // Every real turntable mounts the arm on the right and the
        // start/stop lever on the left. The deck follows suit.
        XCTAssertGreaterThan(TonearmGeometry.pivotFraction.x, 0.5)
        XCTAssertLessThan(TonearmGeometry.pivotFraction.y, 0.25)
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
        // The record must never turn backwards as progress advances.
        // With the pivot on the right the arm's angle decreases.
        var previous = TonearmGeometry.angle(forProgress: 0)
        for step in 1...100 {
            let angle = TonearmGeometry.angle(forProgress: Double(step) / 100.0)
            XCTAssertLessThanOrEqual(angle, previous,
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

    private func stylusRadius(forProgress progress: Double) -> CGFloat {
        let size = CGSize(width: TonearmGeometry.nominalFrame,
                          height: TonearmGeometry.nominalFrame)
        let stylus = TonearmGeometry.stylusPoint(forProgress: progress, in: size)
        let centre = TonearmGeometry.recordCentre(in: size)
        return hypot(stylus.x - centre.x, stylus.y - centre.y)
    }

    func testStylusRestsOnTheOuterGroove() {
        // The record's edge is at 138pt; the outer groove is just
        // inside it.
        XCTAssertEqual(stylusRadius(forProgress: 0), 130, accuracy: 3)
    }

    func testStylusEndsAtTheLabelEdge() {
        // The paper label is 96pt across, so its edge is 48pt out.
        XCTAssertEqual(stylusRadius(forProgress: 1), 45, accuracy: 3)
    }

    func testStylusStaysOnTheRecordForTheWholeTrack() {
        for step in 0...100 {
            let radius = stylusRadius(forProgress: Double(step) / 100.0)
            XCTAssertLessThanOrEqual(radius, 138, "Stylus left the record at step \(step)")
            XCTAssertGreaterThanOrEqual(radius, 45, "Stylus left the label at step \(step)")
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
}
