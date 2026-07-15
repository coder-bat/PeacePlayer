//
//  LiveActivityManager.swift
//  PeacePlayer
//
//  Manages the Now Playing Live Activity: starts it when
//  playback begins, updates it as state changes, ends it
//  when playback stops or the user signs out.
//
//  iOS 16.1+ only. Older devices silently no-op (the activity
//  just never appears).
//

import Foundation
import ActivityKit
import Combine
import UIKit

@available(iOS 16.2, *)
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<NowPlayingActivityAttributes>?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Start a Live Activity whenever the current track
        // changes. The handler decides whether to start a new
        // activity, update the existing one, or end it.
        if #available(iOS 16.2, *) {
            PlayerState.shared.$currentItem
                .removeDuplicates { $0?.track.videoId == $1?.track.videoId }
                .sink { [weak self] _ in
                    self?.refreshActivityForCurrentTrack()
                }
                .store(in: &cancellables)

            // Update the live activity's isPlaying / currentTime on
            // every playbackState or progress change. We use
            // debounce-less updates here because the system rate-
            // limits the activity updates for us (max ~1 Hz), and
            // we want the user to see immediate state when they
            // pause.
            PlayerState.shared.$playbackState
                .sink { [weak self] _ in
                    self?.updateActivityState()
                }
                .store(in: &cancellables)

            PlayerState.shared.$progress
                .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] _ in
                    self?.updateActivityState()
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Public API

    /// Refresh the activity for the current track. If there's
    /// no track, end any active activity. If the track changed,
    /// start a new activity. Otherwise, just update the state.
    private func refreshActivityForCurrentTrack() {
        guard #available(iOS 16.1, *) else { return }
        guard let item = PlayerState.shared.currentItem else {
            endActivity()
            return
        }
        let track = item.track
        let attributes = NowPlayingActivityAttributes(
            trackTitle: track.title,
            trackArtist: track.displayArtist,
            trackAlbum: track.album,
            artworkURLString: track.artworkURL?.absoluteString
        )
        let state = NowPlayingActivityAttributes.ContentState(
            isPlaying: PlayerState.shared.playbackState.isPlaying,
            currentTime: PlayerState.shared.progress,
            duration: Double(track.durationSeconds),
            updatedAt: Date()
        )

        if let existing = activity {
            // Track changed while activity was running. End the
            // old one and start a new one — Live Activities
            // don't support changing their static attributes
            // (track title etc.) in place.
            Task {
                await existing.end(nil, dismissalPolicy: .immediate)
                self.startNewActivity(attributes: attributes, state: state)
            }
        } else {
            startNewActivity(attributes: attributes, state: state)
        }
    }

    private func startNewActivity(
        attributes: NowPlayingActivityAttributes,
        state: NowPlayingActivityAttributes.ContentState
    ) {
        guard #available(iOS 16.1, *) else { return }
        // Don't start a new activity if the user has Live
        // Activities disabled globally.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }
        do {
            let content = ActivityContent(state: state, staleDate: nil)
            self.activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            // Common reasons: user disabled Live Activities for
            // the app, the user has Low Power Mode on, or the
            // device doesn't support Live Activities. We log
            // and continue without an activity.
            print("⚠️ LiveActivityManager: failed to start activity: \(error)")
            self.activity = nil
        }
    }

    private func updateActivityState() {
        guard #available(iOS 16.1, *) else { return }
        guard let activity = activity,
              let item = PlayerState.shared.currentItem else {
            return
        }
        let state = NowPlayingActivityAttributes.ContentState(
            isPlaying: PlayerState.shared.playbackState.isPlaying,
            currentTime: PlayerState.shared.progress,
            duration: Double(item.track.durationSeconds),
            updatedAt: Date()
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// End any active activity. Called on stop, sign-out, or
    /// when playback ends naturally.
    func endActivity() {
        guard #available(iOS 16.1, *) else { return }
        guard let activity = activity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
    }
}
