//
//  NowPlayingServiceTests.swift
//  YTAudioPlayerTests
//
//  S3-2 fix verification: NowPlayingService.skipInterval is the live
//  UserDefaults-backed configuration for the lock-screen / headphone
//  skip-forward / skip-backward interval. It must:
//  1. Default to 15 seconds when the key has never been set
//  2. Reject out-of-range values (e.g., 7) and fall back to 15
//  3. Accept the 5/10/15/30/45/60 options
//  4. Round-trip through UserDefaults correctly
//
//  Reference: project-playback-gap-analysis-2026-06-16.md, S3-2 / QW-12
//

import XCTest
@testable import PeacePlayer

final class NowPlayingServiceTests: XCTestCase {

    let key = NowPlayingService.skipIntervalKey

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testSkipInterval_defaultIsFifteen() {
        // No value set → 15s preserves legacy behavior.
        XCTAssertEqual(NowPlayingService.skipInterval, 15)
    }

    func testSkipInterval_acceptsAllDocumentedOptions() {
        for option in NowPlayingService.skipIntervalOptions {
            UserDefaults.standard.set(option, forKey: key)
            XCTAssertEqual(
                NowPlayingService.skipInterval, option,
                "skipInterval should return \(option) when set in UserDefaults"
            )
        }
    }

    func testSkipInterval_rejectsOutOfRangeValue() {
        // 7 is not in the allowlist; we should not crash and should
        // not propagate 7 to PlayerState.seek (which would skip oddly).
        UserDefaults.standard.set(7, forKey: key)
        XCTAssertEqual(NowPlayingService.skipInterval, 15, "Out-of-range value should fall back to default 15")
    }

    func testSkipInterval_rejectsNegativeValue() {
        UserDefaults.standard.set(-30, forKey: key)
        XCTAssertEqual(NowPlayingService.skipInterval, 15)
    }

    func testSkipInterval_rejectsZeroAndOne() {
        UserDefaults.standard.set(0, forKey: key)
        XCTAssertEqual(NowPlayingService.skipInterval, 15, "0 is UserDefaults's 'no value' sentinel — treat as missing")
        UserDefaults.standard.set(1, forKey: key)
        XCTAssertEqual(NowPlayingService.skipInterval, 15, "1s skip is not in the allowlist")
    }

    func testSkipIntervalOptions_areExactlyTheDocumentedSet() {
        // Pin the API contract: if someone adds a new option, the test
        // reminds them to update AudioSettings' picker too.
        XCTAssertEqual(
            NowPlayingService.skipIntervalOptions,
            [5, 10, 15, 30, 45, 60]
        )
    }
}
