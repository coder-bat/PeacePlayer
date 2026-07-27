//
//  LiveActivityManager.swift
//  PeacePlayer
//
//  Manages the Now Playing Live Activity: starts it when
//  playback begins, updates it as state changes, ends it
//  when playback stops or the user signs out.
//
//  iOS 16.2+ only. Older devices silently no-op (the activity
//  just never appears).
//
//  Duplicate-notification fix (S17-H, see ios/LIVE_ACTIVITY_DUPLICATE_BUG.md):
//  - `pendingLifecycle: Task<Void, Never>?` serializes the end+request
//    sequence so concurrent $currentItem emissions cannot both observe
//    the same `existing` activity and each fire their own
//    `Activity.request`. Without this, rapid skipping leaks N
//    activities to the lock screen.
//  - `refreshActivityForCurrentTrack` compares the *new* attributes
//    against `existing.attributes` and short-circuits to an in-place
//    `update` when the track is the same. This kills the duplicate
//    created by the `loadingItem` → `realItem` transition (same
//    videoId, just stream URL resolves).
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

    /// Serializes activity lifecycle (end + start) so concurrent
    /// `$currentItem` emissions cannot both observe the same
    /// `existing` activity and each fire their own `Activity.request`.
    /// Without this, rapid skipping leaks N activities to the lock
    /// screen — the duplicate-notification bug.
    private var pendingLifecycle: Task<Void, Never>?

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
            scheduleEnd()
            return
        }
        let track = item.track
        let newAttributes = NowPlayingActivityAttributes(
            trackTitle: track.title,
            trackArtist: track.displayArtist,
            trackAlbum: track.album,
            artworkURLString: track.artworkURL?.absoluteString
        )
        let newState = NowPlayingActivityAttributes.ContentState(
            isPlaying: PlayerState.shared.playbackState.isPlaying,
            currentTime: PlayerState.shared.progress,
            duration: Double(track.durationSeconds),
            updatedAt: Date()
        )

        // FIX-1: only end+restart when the track actually changed.
        // The previous code assumed `existing != nil` meant "track
        // changed", which is false during the `loadingItem` →
        // `realItem` transition (same videoId, just stream URL
        // resolves) and false during a `playbackState` change that
        // happens to be routed through this method. In both cases,
        // end+request creates a brand-new Activity visible on the
        // lock screen for no reason. The existing activity for the
        // same track gets a `update(...)` push instead.
        if let existing = activity,
           existing.attributes.trackTitle == newAttributes.trackTitle,
           existing.attributes.trackArtist == newAttributes.trackArtist,
           existing.attributes.artworkURLString == newAttributes.artworkURLString {
            updateActivityState()
            return
        }

        // FIX-2: chain the end+request through `pendingLifecycle`
        // so concurrent $currentItem emissions cannot both observe
        // the same `existing` and both call `Activity.request` for
        // the new track. The previous code's `Task { await ... }`
        // did not serialize against later
        // `refreshActivityForCurrentTrack` calls — the next
        // emission would see the same `existing` and schedule
        // another Task, leaking two `Activity.request` calls.
        let old = pendingLifecycle
        pendingLifecycle = Task { [weak self] in
            await old?.value
            guard let self else { return }
            await self.performEndAndStart(
                existing: self.activity,
                attributes: newAttributes,
                state: newState
            )
        }
    }

    private func performEndAndStart(
        existing: Activity<NowPlayingActivityAttributes>?,
        attributes: NowPlayingActivityAttributes,
        state: NowPlayingActivityAttributes.ContentState
    ) async {
        if let existing = existing {
            // Clear `self.activity` BEFORE awaiting end so
            // concurrent `refreshActivityForCurrentTrack()` calls
            // don't see a ghost "existing" that is already being
            // torn down.
            self.activity = nil
            await existing.end(nil, dismissalPolicy: .immediate)
        }
        startNewActivity(attributes: attributes, state: state)
    }

    private func scheduleEnd() {
        let old = pendingLifecycle
        pendingLifecycle = Task { [weak self] in
            await old?.value
            guard let self else { return }
            await self.performEnd(existing: self.activity)
        }
    }

    private func performEnd(
        existing: Activity<NowPlayingActivityAttributes>?
    ) async {
        guard let existing = existing else { return }
        self.activity = nil
        await existing.end(nil, dismissalPolicy: .immediate)
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
        let old = pendingLifecycle
        pendingLifecycle = Task { [weak self] in
            await old?.value
            guard let self else { return }
            await self.performEnd(existing: self.activity)
        }
    }
}
