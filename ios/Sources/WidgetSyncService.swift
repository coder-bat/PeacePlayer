//
//  WidgetSyncService.swift
//  YTAudioPlayer
//
//  Observes PlaylistManager changes and keeps widget shared state in sync.
//  Also sets up Darwin notification observers for real-time widget control.
//

import Foundation
import Combine
import WidgetKit

// MARK: - Global Darwin callback (must be @convention(c), no captures)

private let darwinControlCallback: CFNotificationCallback = { _, _, name, _, _ in
    guard let rawName = name.map({ $0.rawValue as String }) else { return }
    DispatchQueue.main.async {
        switch rawName {
        case DarwinCmd.playPause:    PlayerState.shared.togglePlayPause()
        case DarwinCmd.skipNext:     PlayerState.shared.nextTrack()
        case DarwinCmd.skipPrevious: PlayerState.shared.previousTrack()
        case DarwinCmd.seekForward:  PlayerState.shared.seek(by: Double(NowPlayingService.skipInterval))
        case DarwinCmd.seekBackward: PlayerState.shared.seek(by: -Double(NowPlayingService.skipInterval))
        // S15: clamp the volume delta so widget VU buttons can't
        // push the value out of the 0.0-1.0 range.
        case DarwinCmd.volumeUp:     PlayerState.shared.setVolume(min(1.0, PlayerState.shared.volume + 0.15))
        case DarwinCmd.volumeDown:   PlayerState.shared.setVolume(max(0.0, PlayerState.shared.volume - 0.15))
        case DarwinCmd.setVolume:
            if let v = SharedNowPlayingState.readAndClearPendingVolume() {
                PlayerState.shared.setVolume(v)
                // Patch snapshot immediately so the widget reload shows the new volume.
                // NowPlayingService will write a full update on the next playback event,
                // but we need the correct value before reloadTimelines fires below.
                let cur = SharedNowPlayingState.read()
                SharedNowPlayingState.update(snapshot: NowPlayingSnapshot(
                    title: cur.title, artist: cur.artist,
                    artworkURLString: cur.artworkURLString,
                    isPlaying: cur.isPlaying, progress: cur.progress,
                    nextTitle: cur.nextTitle, nextArtist: cur.nextArtist,
                    currentVolume: Float(v),
                    hasUnlockedCapsule: TimeCapsuleManager.shared.readyToOpen.count > 0
                ))
            }
        case DarwinCmd.executeShortcut:
            _ = ShortcutPlaybackController.shared.executePendingCommand()
        default: break
        }
        // Handled live via Darwin — clear the UserDefaults fallback command so it
        // does not fire a second time when the app next comes to foreground.
        _ = SharedNowPlayingState.readAndClearCommand()
        // Refresh now-playing + resume widgets immediately after command
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlaying)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlayingFull)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.resume)
    }
}

// MARK: - WidgetSyncService

final class WidgetSyncService {
    static let shared = WidgetSyncService()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupDarwinObservers()
        observeLibraryChanges()
        observeDownloadChanges()
    }

    // MARK: Darwin Observers

    private func setupDarwinObservers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        // Use a non-nil sentinel pointer as the observer handle
        let observer = UnsafeMutableRawPointer(bitPattern: 0xDEAD_FEED)!

        for name in [DarwinCmd.playPause, DarwinCmd.skipNext, DarwinCmd.skipPrevious,
                     DarwinCmd.seekForward, DarwinCmd.seekBackward,
                     DarwinCmd.volumeUp, DarwinCmd.volumeDown, DarwinCmd.setVolume,
                     DarwinCmd.executeShortcut] {
            CFNotificationCenterAddObserver(
                center,
                observer,
                darwinControlCallback,
                name as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    // MARK: Library Observation

    private func observeLibraryChanges() {
        // Debounce to avoid hammering widgets on rapid changes
        PlaylistManager.shared.$playlists
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.syncLibraryData() }
            .store(in: &cancellables)

        PlaylistManager.shared.$likedTracks
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.syncLibraryData() }
            .store(in: &cancellables)
    }

    // MARK: Sync

    func syncLibraryData() {
        let widgetPlaylists = PlaylistManager.shared.playlists
            .filter { !$0.isSmart }
            .prefix(6)
            .map { WidgetPlaylist(id: $0.id.uuidString, name: $0.name, trackCount: $0.trackCount) }

        let snapshot = LibrarySnapshot(
            likedTrackCount: PlaylistManager.shared.likedTracks.count,
            playlists: Array(widgetPlaylists)
        )

        SharedNowPlayingState.updateLibrary(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.shuffleFavorites)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.playlists)
    }

    // MARK: Download State Observation
    // 2026-08-12: observe DownloadManager's activeDownloads
    // + downloadQueue + isDownloading, build a one-line summary
    // ("Track Name" or "Track Name +2 more"), and write it into
    // the NowPlayingSnapshot. Reloads the nowPlayingFull widget
    // so the user can see "↓ Downloading X" on the home screen
    // without opening the app.
    //
    // Debounced lightly (200ms) so a rapid burst of download
    // start events (e.g. user taps download on 3 tracks in a row)
    // doesn't hammer App Group writes. The widget's natural
    // refresh cadence is ~15min anyway, so the 200ms debounce
    // is invisible to the user.
    private func observeDownloadChanges() {
        let active = DownloadManager.shared.$activeDownloads
        let pending = DownloadManager.shared.$downloadQueue
        let inFlight = DownloadManager.shared.$isDownloading
        Publishers.CombineLatest3(active, pending, inFlight)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.syncDownloadingState() }
            .store(in: &cancellables)
    }

    /// Build the one-line "downloading" string and rewrite the
    /// snapshot. Idempotent. Called on every download state
    /// change (debounced to 200ms) and on demand from callers
    /// that want to force a sync (e.g. right after a download
    /// starts via the UI).
    func syncDownloadingState() {
        let summary = buildDownloadingSummary()
        var current = SharedNowPlayingState.read()
        // Don't churn App Group writes if the title hasn't
        // changed. The decode → mutate → encode round-trip is
        // cheap but observable in profiling.
        guard current.downloadingTitle != summary else { return }
        current.downloadingTitle = summary
        SharedNowPlayingState.update(snapshot: current)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlayingFull)
    }

    /// Public read-only entry point. Returns the same string
    /// the widget would show, without writing the snapshot.
    /// NowPlayingService calls this on every playback snapshot
    /// write so the widget stays in sync with playback-side
    /// updates. syncDownloadingState() is the WRITE path
    /// (called on DownloadManager publishes); this is the
    /// READ path (called on every snapshot write).
    func snapshotDownloadingSummary() -> String? {
        buildDownloadingSummary()
    }

    /// Build the user-visible "downloading" string from
    /// DownloadManager's state. Returns nil if there's nothing
    /// downloading. Format: first active or queued track title,
    /// with a "+N more" suffix when the queue is longer.
    private func buildDownloadingSummary() -> String? {
        let active = DownloadManager.shared.activeDownloads
        let pending = DownloadManager.shared.downloadQueue
        let total = active.count + pending.count
        guard total > 0 else { return nil }

        // Prefer the currently-downloading track (in active) so
        // the user sees what's actually making progress. Fall
        // back to the first pending if active is empty (the
        // active slot was freed and the next one hasn't been
        // promoted yet — a 1-frame edge case but worth handling).
        let firstTitle: String
        if let first = active.first?.track {
            firstTitle = first.title
        } else if let first = pending.first?.track {
            firstTitle = first.title
        } else {
            return nil
        }

        if total > 1 {
            return "\(firstTitle) +\(total - 1) more"
        }
        return firstTitle
    }

    // MARK: Reload All

    static func reloadAll() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlaying)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlayingFull)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.resume)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.shuffleFavorites)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.playlists)
    }
}
