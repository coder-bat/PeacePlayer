//
//  FeatureFlags.swift
//  YTAudioPlayer
//
//  Reactive store for the Labs feature flags.
//
//  Why a store instead of reading UserDefaults inline:
//
//  The Turntable flag has to be read in TWO places — HomeView (swap the
//  body) and ContentView (hide the MiniPlayer). If either of them
//  cached the value in a @State initialiser, flipping the toggle in
//  Settings would leave the deck and the mini player out of sync:
//  the user comes back to Home and sees the old layout with the mini
//  player still there.
//
//  A published ObservableObject fixes that — both readers observe the
//  same instance and re-render the moment the value changes.
//

import Foundation
import Combine

final class FeatureFlags: ObservableObject {

    // MARK: - Keys

    /// Labs toggle for the Turntable Home.
    static let turntableHomeKey = "ff_turntable_home"

    // MARK: - Store

    private let defaults: UserDefaults

    /// Shared instance used by the app UI.
    static let shared = FeatureFlags()

    /// Designated initialiser. The shared instance uses `.standard`;
    /// tests pass an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.turntableHome = defaults.bool(forKey: Self.turntableHomeKey)
    }

    // MARK: - Flags

    /// Turntable Home: the record is the home screen.
    ///
    /// Default OFF. When ON, Home renders the Turntable deck and the
    /// global BottomBar hides the MiniPlayer on the Home tab.
    @Published var turntableHome: Bool {
        didSet {
            guard turntableHome != defaults.bool(forKey: Self.turntableHomeKey) else { return }
            defaults.set(turntableHome, forKey: Self.turntableHomeKey)
        }
    }
}
