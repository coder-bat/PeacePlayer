//
//  TurntableWiringTests.swift
//  YTAudioPlayerTests
//
//  Guards the two places the Turntable flag touches shared chrome:
//  the BottomBar's mini player and the shared flag store.
//
//  The de-duplication rule is: exactly one now-playing surface is
//  visible on the Home tab. The deck has its own strip, so the global
//  BottomBar must not also show the MiniPlayer there.
//

import XCTest
import SwiftUI
@testable import PeacePlayer

final class TurntableWiringTests: XCTestCase {

    func testBottomBarHidesMiniPlayerWhenAsked() {
        let bar = BottomBar(
            tabBar: CyberpunkTabBar(selectedTab: .constant(0)),
            miniPlayer: AnyView(EmptyView()),
            hidesMiniPlayer: true
        )
        XCTAssertTrue(bar.hidesMiniPlayer, "BottomBar must expose the hide flag")
    }

    func testBottomBarShowsMiniPlayerByDefault() {
        // Every other tab keeps the MiniPlayer. The default must be
        // "visible" so no existing tab changes behaviour.
        let bar = BottomBar(
            tabBar: CyberpunkTabBar(selectedTab: .constant(1)),
            miniPlayer: AnyView(EmptyView())
        )
        XCTAssertFalse(bar.hidesMiniPlayer)
    }

    func testTurntableIsOffByDefaultInSharedStore() {
        // The shared store must not have the flag on unless the user
        // explicitly enabled it in Settings -> Labs.
        //
        // The assertion is about the store's DEFAULT, so it runs against
        // a scratch defaults suite. The simulator's own UserDefaults
        // may have the flag on from a manual run, and that must not
        // make this test flaky.
        let suiteName = "TurntableWiringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let flags = FeatureFlags(defaults: defaults)
        XCTAssertFalse(flags.turntableHome, "Turntable must be opt-in")
    }

    func testFlagKeyMatchesTheLabsToggleKey() {
        // SettingsView binds its toggle to FeatureFlags.turntableHomeKey.
        // If the two ever drift, the toggle would write a key nobody
        // reads and the deck would never appear.
        XCTAssertEqual(FeatureFlags.turntableHomeKey, "ff_turntable_home")
    }
}
