//
//  NowPlayingActivityAttributes.swift
//  PeacePlayer
//
//  ActivityKit attributes for the "Now Playing" Live Activity.
//
//  A Live Activity is a small, persistent UI surface that
//  appears on the Lock Screen, in the Dynamic Island (iPhone
//  14 Pro+), and in StandBy mode. It shows the current track
//  + minimal playback state without the user having to unlock
//  the device.
//
//  Apple's ActivityKit requires:
//   1. NSSupportsLiveActivities = true in Info.plist
//   2. ActivityAttributes (this file) shared between the app
//      and the widget extension
//   3. A widget that conforms to `Widget` and renders the
//      ActivityConfiguration
//
//  We split the Live Activity UI across:
//   - Compact: Dynamic Island (regular + minimal states)
//   - Expanded: full artwork + title + transport controls
//   - Lock Screen: same as expanded with a play/pause
//
//  Requires iOS 16.1+ (deployed target is 16.0; we gate the
//  API calls on `if #available(iOS 16.1, *)`).
//

import Foundation
import ActivityKit

struct NowPlayingActivityAttributes: ActivityAttributes {
    public typealias ContentState = State

    /// Static attributes (set when the activity is started;
    /// don't change during the activity's lifetime).
    let trackTitle: String
    let trackArtist: String
    let trackAlbum: String?
    let artworkURLString: String?

    /// Dynamic state — pushed as `ContentState` updates.
    public struct State: Codable, Hashable {
        var isPlaying: Bool
        var currentTime: Double
        var duration: Double
        /// Updated by the app on every state change so the
        /// widget can render the correct elapsed time without
        /// re-pulling the whole state.
        var updatedAt: Date
    }
}
