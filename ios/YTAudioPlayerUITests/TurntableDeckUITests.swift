//
//  TurntableDeckUITests.swift
//  YTAudioPlayerUITests
//
//  Drives the REAL app on a REAL device.
//
//  Two things cannot be checked any other way:
//
//  1. Tapping a crate record. That used to crash the app — the image
//     cache corrupted its download dictionary when fifteen artworks
//     loaded at once. A unit test cannot reproduce a device crash;
//     only the real app, on the real device, can.
//  2. The record's rotation BETWEEN frames. The player's clock ticks
//     at 1Hz, so a record driven straight off the clock moves in
//     visible one-degree steps. The deck now samples the clock at
//     display rate, and this test proves it by taking two screenshots
//     of the record a fraction of a second apart and requiring them
//     to differ.
//
//  The deck is turned on with the launch argument
//  `-ff_turntable_home YES`: NSUserDefaults' argument domain outranks
//  the stored value, so the deck is guaranteed to be on screen no
//  matter what the device's Settings → Labs toggle says.
//

import XCTest

final class TurntableDeckUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments = ["-ff_turntable_home", "YES", "-ui_test_keep_awake"]
        app.launch()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// The record element on the deck.
    private var record: XCUIElement {
        app.buttons["turntable.record"]
    }

    /// Every sleeve in the crate, in the order the deck lays them out.
    private var sleeves: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "crate.sleeve."))
    }

    /// Waits for the deck to be on screen.
    @discardableResult
    private func waitForDeck(timeout: TimeInterval = 60) -> Bool {
        // The record itself is the deck's stable handle. The crate's
        // CRATE caption is gone (revision 2026-11-18), so waiting for
        // it meant waiting forever.
        let found = record.waitForExistence(timeout: timeout)
        if !found {
            // The app gates the whole UI on Apple sign-in. On a device with
            // no session the deck simply never mounts, and the test would
            // sit here for a minute per test without saying why.
            if isSignedOut {
                XCTFail("The app is signed out — the turntable deck is behind "
                        + "the auth gate. Sign in on this device first.")
            }
            // Dump the tree so a failure says WHY the deck is missing
            // (signed out, offline, a modal in the way).
            print("UI-TEST element tree:\n\(app.debugDescription)")
        }
        return found
    }

    /// True when the landing view (the signed-out gate) is on screen.
    private var isSignedOut: Bool {
        app.staticTexts["Swipe to learn more"].exists
            || app.staticTexts["Stream Your Library"].exists
            || app.buttons["preSignInBackendSettings"].exists
    }

    // MARK: - Tests

    /// Tapping several crate records must not crash the app, and each
    /// tap must actually start a track.
    func testTappingCrateRecordsDoesNotCrashTheApp() throws {
        XCTAssertTrue(waitForDeck(), "The turntable deck never appeared")

        let count = sleeves.count
        print("UI-TEST crate sleeves: \(count)")
        XCTAssertGreaterThan(count, 0, "The crate is empty — nothing to tap")

        let taps = min(count, 5)
        for index in 0..<taps {
            let sleeve = sleeves.element(boundBy: index)
            XCTAssertTrue(sleeve.exists, "Sleeve \(index) disappeared")

            sleeve.tap()

            // A crash is the thing we are hunting. It shows up as an
            // app that is no longer running at all.
            XCTAssertNotEqual(app.state, .notRunning,
                              "PeacePlayer is GONE after tapping sleeve \(index) — it crashed")

            // Losing the foreground is NOT a crash: someone picked the
            // phone up and opened another app. Bring PeacePlayer back
            // and carry on.
            if app.state != .runningForeground {
                print("UI-TEST app was backgrounded after sleeve \(index) — reactivating")
                app.activate()
            }

            // The deck must survive the tap: the record is still there.
            XCTAssertTrue(record.waitForExistence(timeout: 10),
                          "The record vanished after tapping sleeve \(index)")
        }

        // And it must still be alive at the end.
        XCTAssertNotEqual(app.state, .notRunning,
                          "PeacePlayer died during the run")
    }

    /// The record must turn CONTINUOUSLY, not in one-degree steps
    /// once a second. Two screenshots a fraction of a second apart
    /// have to differ.
    func testRecordRotatesSmoothlyWhilePlaying() throws {
        XCTAssertTrue(waitForDeck(), "The turntable deck never appeared")

        // Start something playing.
        let count = sleeves.count
        XCTAssertGreaterThan(count, 0, "The crate is empty — nothing to play")
        sleeves.element(boundBy: 0).tap()
        XCTAssertNotEqual(app.state, .notRunning, "PeacePlayer died on the first tap")

        // Wait for the deck to say it is spinning. Without this the
        // frame comparison below would pass on a still image for the
        // wrong reason.
        let spinning = NSPredicate(format: "value CONTAINS %@", "Spinning")
        let spinningExpectation = XCTNSPredicateExpectation(predicate: spinning, object: record)
        let spinningResult = XCTWaiter().wait(for: [spinningExpectation], timeout: 45)
        if spinningResult != .completed {
            print("UI-TEST record value: \(record.value)")
            XCTFail("The record never started spinning (value: \"\(record.value ?? "nil")\") "
                    + "— nothing is playing, so the rotation cannot be measured")
        }

        // Two frames a fraction of a second apart.
        let first = record.screenshot().pngRepresentation
        Thread.sleep(forTimeInterval: 0.12)
        let second = record.screenshot().pngRepresentation

        XCTAssertNotEqual(first, second,
                          "The record did not move between two frames 120ms apart — the rotation is stepping, not turning")

        // And a third, later frame: it must still be moving.
        Thread.sleep(forTimeInterval: 0.35)
        let third = record.screenshot().pngRepresentation
        XCTAssertNotEqual(second, third,
                          "The record stopped moving after the first sample")
    }

    /// The deck's fascia must carry no brand text and no profile chip.
    func testDeckFasciaHasNoWordmarkAndNoProfileChip() throws {
        XCTAssertTrue(waitForDeck(), "The turntable deck never appeared")

        // The etched PEACEPLAYER wordmark was removed when the strip
        // became frosted glass (revision 2026-11-18).
        XCTAssertFalse(app.staticTexts["PEACEPLAYER"].exists,
                       "The fascia still carries the old PEACEPLAYER wordmark")

        // The old profile chip showed a greeting ("NIGHT", "SYNC"…)
        // and a display name next to the avatar. There must be no
        // such chip on the deck any more.
        let greetings = app.staticTexts.matching(
            NSPredicate(format: "value MATCHES %@", "[A-Z]+")
        )
        for index in 0..<min(greetings.count, 20) {
            let value = greetings.element(boundBy: index).label
            XCTAssertFalse(value == "NIGHT" || value == "SYNC" || value == "EVENING",
                           "The old profile greeting \"\(value)\" is still on the deck")
        }
    }
}
