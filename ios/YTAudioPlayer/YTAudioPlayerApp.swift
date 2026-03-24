//
//  YTAudioPlayerApp.swift
//  YTAudioPlayer
//

import SwiftUI
import CoreData

@main
struct YTAudioPlayerApp: App {
    let persistenceController = PersistenceController.shared
    @Environment(\.scenePhase) private var scenePhase

    // Initialise singletons that must start with the app
    private let widgetSync = WidgetSyncService.shared

    init() {
        DataMigrationService.shared.performMigrationIfNeeded()
        // Sync library data immediately so widgets show correct state on launch
        WidgetSyncService.shared.syncLibraryData()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.viewContext)
                .ignoresSafeArea(.keyboard)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
        .onChange(of: scenePhase) { phase in
            // UserDefaults fallback: execute any command written while app was suspended
            if phase == .active {
                if let cmd = SharedNowPlayingState.readAndClearCommand() {
                    executeWidgetCommand(cmd)
                }
            }
        }
    }

    // MARK: - Deep Link Handler

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "peaceplayer" else { return }
        switch url.host {
        case "resume":
            resumePlayback()
        case "shuffle-favorites":
            shuffleFavorites()
        case "queue":
            PlayerState.shared.showQueue = true
        case "playlist":
            if let idStr = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value {
                playPlaylist(id: idStr)
            }
        default:
            break
        }
    }

    private func resumePlayback() {
        let player = PlayerState.shared
        if player.currentItem != nil {
            player.resume()
        } else if let recent = DataManager.shared.recentlyPlayed.first?.toTrack {
            player.play(track: recent)
        }
    }

    private func shuffleFavorites() {
        let ids = Array(PlaylistManager.shared.likedTracks)
        let tracks = TrackStore.shared.getTracks(videoIds: ids).shuffled()
        guard let first = tracks.first else { return }
        PlayerState.shared.play(track: first)
    }

    private func playPlaylist(id: String) {
        guard let playlist = PlaylistManager.shared.playlists.first(where: { $0.id.uuidString == id }),
              let firstId = playlist.trackIds.first,
              let track = TrackStore.shared.getTrack(videoId: firstId) else { return }
        PlayerState.shared.play(track: track)
    }

    // MARK: - Widget Command Fallback

    private func executeWidgetCommand(_ cmd: SharedNowPlayingState.Command) {
        switch cmd {
        case .playPause:    PlayerState.shared.togglePlayPause()
        case .skipNext:     PlayerState.shared.nextTrack()
        case .skipPrevious: PlayerState.shared.previousTrack()
        }
    }
}
