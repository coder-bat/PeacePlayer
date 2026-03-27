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
            )
        ]
    }
}
