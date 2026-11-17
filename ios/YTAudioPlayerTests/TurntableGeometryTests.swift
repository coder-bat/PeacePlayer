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
        XCTAssertGreaterThan(end, start, "Arm must sweep inward as the track plays")
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
        var previous = TonearmGeometry.angle(forProgress: 0)
        for step in 1...100 {
            let angle = TonearmGeometry.angle(forProgress: Double(step) / 100.0)
            XCTAssertGreaterThanOrEqual(angle, previous,
                                        "Arm angle went backwards at step \(step)")
            previous = angle
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
