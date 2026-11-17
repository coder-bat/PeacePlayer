//
//  FeatureFlagsTests.swift
//  YTAudioPlayerTests
//
//  The Turntable flag has to survive a round trip through UserDefaults
//  AND publish the change, because two separate views read it
//  (HomeView swaps the body, ContentView hides the MiniPlayer).
//

import XCTest
@testable import PeacePlayer

final class FeatureFlagsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FeatureFlagsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testTurntableHomeDefaultsToOff() {
        // The Turntable deck replaces the app's entry screen. It must
        // never be on by default - existing users get the current Home
        // until they opt in via Settings -> Labs.
        let flags = FeatureFlags(defaults: defaults)
        XCTAssertFalse(flags.turntableHome)
    }

    func testTurntableHomeReadsPersistedValue() {
        defaults.set(true, forKey: FeatureFlags.turntableHomeKey)
        let flags = FeatureFlags(defaults: defaults)
        XCTAssertTrue(flags.turntableHome)
    }

    func testTurntableHomeWritePersistsAndPublishes() {
        let flags = FeatureFlags(defaults: defaults)
        var observed: Bool?
        let cancellable = flags.$turntableHome.sink { observed = $0 }
        defer { cancellable.cancel() }

        flags.turntableHome = true

        XCTAssertEqual(observed, true, "Change did not publish")
        XCTAssertEqual(defaults.bool(forKey: FeatureFlags.turntableHomeKey), true,
                       "Change did not persist")
    }

    func testTurntableHomeWriteOffPersistsAndPublishes() {
        defaults.set(true, forKey: FeatureFlags.turntableHomeKey)
        let flags = FeatureFlags(defaults: defaults)
        var observed: Bool?
        let cancellable = flags.$turntableHome.sink { observed = $0 }
        defer { cancellable.cancel() }

        flags.turntableHome = false

        XCTAssertEqual(observed, false, "Change did not publish")
        XCTAssertFalse(defaults.bool(forKey: FeatureFlags.turntableHomeKey),
                       "Change did not persist")
    }
}
