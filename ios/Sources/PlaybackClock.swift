//
//  PlaybackClock.swift
//  YTAudioPlayer
//
//  Sprint 2 / C-4 fix: focused observable for the 0.5s time/progress updates.
//
//  PlayerState is a god object — every @Published change re-renders every
//  view that observes it. The periodic time observer fires every 0.5s and
//  wrote to `currentTime` and `progress` directly on PlayerState, forcing
//  FullPlayer, MiniPlayer, QueueView, and any other observer to re-evaluate
//  their bodies. The dominant-color computation, lyrics view, and scrubber
//  binding all ran every 0.5s as a result.
//
//  PlaybackClock holds ONLY the time/progress state. The scrubber observes
//  this object directly, so a change here only re-renders the scrubber
//  subtree, not the full player chrome. PlayerState retains its currentTime
//  and progress as computed properties that read from this clock, so all
//  existing call sites continue to work without churn.
//

import Foundation
import Combine

/// Observable time/progress source. Writes happen on the main queue
/// (the AVPlayer periodic time observer is configured with
/// `queue: .main`), so the @Published mutations are safe to consume
/// from any thread in practice. Not marked @MainActor so the many
/// call sites in PlayerState (which is not main-actor-isolated) can
/// invoke `tick(...)` directly without dispatch hops.
final class PlaybackClock: ObservableObject {
    /// Current playback time in seconds (0.0 ... duration).
    @Published private(set) var currentTime: Double = 0.0

    /// Current progress as a 0.0...1.0 fraction of effective duration.
    @Published private(set) var progress: Double = 0.0

    /// Total duration in seconds from AVPlayer (may be inaccurate for some streams).
    @Published private(set) var duration: Double = 0.0

    /// Expected duration from track metadata (more reliable than AVPlayer's
    /// for some stream formats). Set by PlayerState when a track is loaded.
    @Published private(set) var expectedDuration: Double = 0.0

    /// Playback rate (0.5 to 2.0). Used for the Now Playing display.
    @Published private(set) var rate: Float = 1.0

    private var lastUpdateTime: Date = Date()

    /// When the clock last ticked.
    ///
    /// The AVPlayer time observer runs at 1Hz, so `currentTime` alone
    /// moves in one-second steps. A view that animates from the clock
    /// (the turntable's record, the tonearm) projects the value
    /// forward by the wall-clock time elapsed since this instant, so
    /// the motion is smooth without the hot path ticking faster.
    private(set) var lastUpdateDate: Date = Date()

    init() {}

    /// Reset to zero. Called from PlayerState.stop().
    func reset() {
        currentTime = 0.0
        progress = 0.0
        duration = 0.0
        expectedDuration = 0.0
        rate = 1.0
        lastUpdateTime = Date()
        lastUpdateDate = lastUpdateTime
    }

    /// Update from the periodic time observer. Returns the elapsed
    /// (wall-clock) seconds since the last call so callers can do
    /// accumulated-listening-time accounting.
    @discardableResult
    func tick(currentSeconds: Double, totalSeconds: Double, effectiveDuration: Double) -> TimeInterval {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastUpdateTime)
        lastUpdateTime = now
        lastUpdateDate = now

        // Only publish if values changed materially. This avoids spurious
        // SwiftUI re-renders when AVPlayer reports the same value twice.
        if abs(currentTime - currentSeconds) > 0.05 {
            currentTime = currentSeconds
        }
        if abs(duration - totalSeconds) > 0.1 {
            duration = totalSeconds
        }
        let denom = effectiveDuration > 0 ? effectiveDuration : max(totalSeconds, 1)
        let newProgress = max(0, min(1, currentSeconds / denom))
        if abs(progress - newProgress) > 0.001 {
            progress = newProgress
        }
        return elapsed
    }

    /// Set the expected duration from track metadata (typically from
    /// `Track.durationSeconds`).
    func setExpectedDuration(_ value: Double) {
        if abs(expectedDuration - value) > 0.1 {
            expectedDuration = value
        }
    }

    /// Set the playback rate (e.g., from setPlaybackRate).
    func setRate(_ value: Float) {
        if abs(rate - value) > 0.01 {
            rate = value
        }
    }

    /// The position in the track, projected forward to `date`.
    ///
    /// The clock only ticks once a second, so a view that draws
    /// straight from `progress` moves in one-second jumps — a record
    /// that "turns" in visible bursts. Projecting the last known
    /// position forward by the wall-clock time since the last tick
    /// makes the motion continuous at any sampling rate, while the
    /// value still comes from the player's own position in the track.
    ///
    /// The projection is only trusted for a short window (2 seconds):
    /// after that the clock is stale and its own value is safer.
    func projectedProgress(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(lastUpdateDate)
        guard elapsed > 0, elapsed < 2 else { return progress }

        let projected = currentTime + elapsed * Double(rate)
        let total = duration > 0 ? duration : expectedDuration
        guard total > 0 else { return progress }
        return min(1, max(0, projected / total))
    }
}
