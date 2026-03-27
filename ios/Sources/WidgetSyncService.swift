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
        case DarwinCmd.seekForward:  PlayerState.shared.seek(by: 15)
        case DarwinCmd.seekBackward: PlayerState.shared.seek(by: -15)
        case DarwinCmd.volumeUp:     PlayerState.shared.setVolume(PlayerState.shared.volume + 0.15)
        case DarwinCmd.volumeDown:   PlayerState.shared.setVolume(PlayerState.shared.volume - 0.15)
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
                    currentVolume: Float(v)
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

    // MARK: Reload All

    static func reloadAll() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlaying)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.nowPlayingFull)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.resume)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.shuffleFavorites)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.playlists)
    }
}
