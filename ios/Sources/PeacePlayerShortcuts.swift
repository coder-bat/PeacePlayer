//
//  PeacePlayerShortcuts.swift
//  YTAudioPlayer
//

import Foundation
import AppIntents

@available(iOS 16.4, *)
struct PlaylistNameOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        PlaylistManager.shared.playlists
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

@available(iOS 16.4, *)
struct ShuffleLibraryIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Shuffle Library"
    static var description = IntentDescription("Shuffle your downloaded library in Peace Player.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestToContinueInForeground(IntentDialog("Shuffling your library in Peace Player.")) {
            ShortcutPlaybackController.shared.execute(.shuffleLibrary)
        }
        return .result(dialog: "Shuffling your library in Peace Player.")
    }
}

@available(iOS 16.4, *)
struct PlayRecentlyPlayedIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Play Recently Played"
    static var description = IntentDescription("Play your recently played songs in Peace Player.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestToContinueInForeground(IntentDialog("Playing your recently played songs in Peace Player.")) {
            ShortcutPlaybackController.shared.execute(.playRecentlyPlayed)
        }
        return .result(dialog: "Playing your recently played songs in Peace Player.")
    }
}

@available(iOS 16.4, *)
struct PlayPlaylistIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Play Playlist"
    static var description = IntentDescription("Play one of your playlists in Peace Player.")

    @Parameter(title: "Playlist", optionsProvider: PlaylistNameOptionsProvider())
    var playlistName: String

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlistName)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let resolved = ShortcutPlaybackController.shared.resolvePlaylistIdentifier(named: playlistName)
        let command = ShortcutPlaybackCommand.playPlaylist(
            name: resolved?.name ?? playlistName,
            id: resolved?.id
        )
        try await requestToContinueInForeground(IntentDialog("Playing \((resolved?.name ?? playlistName)) in Peace Player.")) {
            ShortcutPlaybackController.shared.execute(command)
        }
        return .result(dialog: "Playing \((resolved?.name ?? playlistName)) in Peace Player.")
    }
}

@available(iOS 16.4, *)
struct PeacePlayerShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        return [
            AppShortcut(
                intent: ShuffleLibraryIntent(),
                phrases: [
                    "Shuffle my library in \(.applicationName)",
                    "Play my library shuffled in \(.applicationName)"
                ],
                shortTitle: "Shuffle Library",
                systemImageName: "shuffle"
            ),
            AppShortcut(
                intent: PlayRecentlyPlayedIntent(),
                phrases: [
                    "Play recently played in \(.applicationName)",
                    "Play my recently played songs in \(.applicationName)"
                ],
                shortTitle: "Recently Played",
                systemImageName: "clock.arrow.circlepath"
            ),
            AppShortcut(
                intent: PlayPlaylistIntent(),
                phrases: [
                    "Play playlist in \(.applicationName)",
                    "Start a playlist in \(.applicationName)"
                ],
                shortTitle: "Play Playlist",
                systemImageName: "music.note.list"
            ),
            // S16: transport + library toggle intents. These are
            // the "Siri can do this now" set the master plan
            // called out (master plan §7.15).
            AppShortcut(
                intent: TogglePlayPauseIntent(),
                phrases: [
                    "Play or pause in \(.applicationName)",
                    "Toggle play in \(.applicationName)",
                    "Pause \(.applicationName)"
                ],
                shortTitle: "Play / Pause",
                systemImageName: "playpause.fill"
            ),
            AppShortcut(
                intent: SkipForwardIntent(),
                phrases: [
                    "Skip forward in \(.applicationName)",
                    "Skip ahead in \(.applicationName)"
                ],
                shortTitle: "Skip Forward",
                systemImageName: "goforward.15"
            ),
            AppShortcut(
                intent: SkipBackwardIntent(),
                phrases: [
                    "Skip backward in \(.applicationName)",
                    "Go back in \(.applicationName)"
                ],
                shortTitle: "Skip Backward",
                systemImageName: "gobackward.15"
            ),
            AppShortcut(
                intent: LikeCurrentTrackIntent(),
                phrases: [
                    "Like this song in \(.applicationName)",
                    "Like this track in \(.applicationName)",
                    "Like what's playing in \(.applicationName)"
                ],
                shortTitle: "Like This Song",
                systemImageName: "heart.fill"
            ),
            AppShortcut(
                intent: StartSongRadioIntent(),
                phrases: [
                    "Start song radio in \(.applicationName)",
                    "Start a radio from this song in \(.applicationName)"
                ],
                shortTitle: "Start Song Radio",
                systemImageName: "antenna.radiowaves.left.and.right"
            )
        ]
    }
}

// MARK: - Transport Intents (S16)

@available(iOS 16.4, *)
struct TogglePlayPauseIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description = IntentDescription("Toggle playback in Peace Player.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestToContinueInForeground(IntentDialog("Toggling playback in Peace Player.")) {
            ShortcutPlaybackController.shared.execute(.togglePlayPause)
        }
        return .result(dialog: "Toggled playback in Peace Player.")
    }
}

@available(iOS 16.4, *)
struct SkipForwardIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Skip Forward"
    static var description = IntentDescription("Skip forward in Peace Player.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestToContinueInForeground(IntentDialog("Skipping forward in Peace Player.")) {
            ShortcutPlaybackController.shared.execute(.skipForward)
        }
        return .result(dialog: "Skipped forward in Peace Player.")
    }
}

@available(iOS 16.4, *)
struct SkipBackwardIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Skip Backward"
    static var description = IntentDescription("Skip backward in Peace Player.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await requestToContinueInForeground(IntentDialog("Skipping backward in Peace Player.")) {
            ShortcutPlaybackController.shared.execute(.skipBackward)
        }
        return .result(dialog: "Skipped backward in Peace Player.")
    }
}

@available(iOS 16.4, *)
struct LikeCurrentTrackIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Like This Song"
    static var description = IntentDescription("Like the currently playing track in Peace Player.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let videoId = PlayerState.shared.currentItem?.track.videoId ?? ""
        let alreadyLiked = !videoId.isEmpty && PlaylistManager.shared.isLiked(trackId: videoId)

        try await requestToContinueInForeground(
            IntentDialog(alreadyLiked ? "Already liked in Peace Player." : "Liking this song in Peace Player.")
        ) {
            ShortcutPlaybackController.shared.execute(.likeCurrentTrack)
        }
        return .result(dialog: alreadyLiked ? "Already liked in Peace Player." : "Liked this song in Peace Player.")
    }
}

@available(iOS 16.4, *)
struct StartSongRadioIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Start Song Radio"
    static var description = IntentDescription("Start a song radio from the currently playing track in Peace Player.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let hasTrack = PlayerState.shared.currentItem?.track.videoId.isEmpty == false
        try await requestToContinueInForeground(
            IntentDialog("Starting song radio in Peace Player.")
        ) {
            ShortcutPlaybackController.shared.execute(.startSongRadio)
        }
        return .result(dialog: hasTrack ? "Started song radio in Peace Player." : "Play a track first, then try again.")
    }
}
