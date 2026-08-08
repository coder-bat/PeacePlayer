//
//  YTAudioPlayerApp.swift
//  YTAudioPlayer
//

import SwiftUI
import CoreData

@main
struct YTAudioPlayerApp: App {
    @UIApplicationDelegateAdaptor(WalkDJAppDelegate.self) private var appDelegate
    let persistenceController = PersistenceController.shared
    @Environment(\.scenePhase) private var scenePhase

    // Initialise singletons that must start with the app
    private let widgetSync = WidgetSyncService.shared
    private let adaptiveWalkDJ = AdaptiveWalkDJManager.shared

    init() {
        DataMigrationService.shared.performMigrationIfNeeded()
        // Sync library data immediately so widgets show correct state on launch
        WidgetSyncService.shared.syncLibraryData()

        // 2026-06-28: restore the Apple Sign-In session from Keychain.
        // If we have a valid JWT, isAuthenticated flips to true and the
        // main UI renders; otherwise ContentView shows the LandingView.
        AuthService.shared.bootstrap()

        // Phase 2 / ios-qa: spin up the embedded StateServer so the
        // simulator-side test agent can hit the app at `http://127.0.0.1:9999`
        // to take screenshots, read state, drive the UI, etc. The server
        // binds loopback only (and the CoreDevice IPv6 tunnel range) so
        // it can't be reached from the public internet. The whole stack
        // is #if DEBUG-gated so release builds carry zero overhead.
        #if DEBUG
        StateServer.shared.start()
        #endif
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
        .onChange(of: scenePhase) { _, phase in
            // UserDefaults fallback: execute any command written while app was suspended
            if phase == .active {
                if let cmd = SharedNowPlayingState.readAndClearCommand() {
                    executeWidgetCommand(cmd)
                }
                _ = ShortcutPlaybackController.shared.executePendingCommand()
            }

            adaptiveWalkDJ.handleScenePhaseChange(isActive: phase == .active)

            // S17-H / S17-LOCK: re-activate the audio session on
            // every scene-phase change. iOS can downgrade or
            // deactivate the session during the screen-lock
            // transition; calling `activate()` re-asserts the
            // `.playback` category and `setActive(true)` so the
            // AVPlayer keeps playing through the lock. Safe to
            // call repeatedly — the controller is idempotent.
            PlayerState.shared.audioSessionController.activate()

            // S17-H / S17-LOCK: when the app comes back to
            // .active (foreground), re-assert playback if the
            // AVPlayer was paused by iOS during background.
            // The audio session re-activation above only
            // handles the session side; the player itself
            // can be at rate 0 if iOS paused it on lock or
            // minimize. S17-LOCK follow-up: call on BOTH
            // .inactive (coming back from .background) and
            // .active (fully foreground). The .inactive fire
            // catches the player a few hundred ms earlier,
            // which matters when the iOS system immediately
            // re-pauses on .active because it thinks the
            // session is still in the background. A 200ms
            // dispatch delay gives the audio system time to
            // settle before we call playImmediately.
            if phase == .inactive || phase == .active {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    PlayerState.shared.handleScenePhaseActive()
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
        case "shortcut":
            handleShortcutDeepLink(url)
        case "walk-dj":
            adaptiveWalkDJ.handleWalkDJURL(url)
        case "capsule":
            // S18 (P0-5): peaceplayer://capsule/{uuid}
            // The capsuleId is the path component (URL parsing strips
            // the leading "/"). The notification response handler in
            // WalkDJAppDelegate does the same routing.
            let capsuleId = url.pathComponents
                .first(where: { $0 != "/" && !$0.isEmpty }) ?? ""
            if !capsuleId.isEmpty {
                NotificationCenter.default.post(
                    name: .openTimeCapsuleVault,
                    object: nil,
                    userInfo: ["capsuleId": capsuleId]
                )
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

    private func handleShortcutDeepLink(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let action = components.queryItems?.first(where: { $0.name == "action" })?.value,
              let shortcutAction = ShortcutPlaybackCommand.Action(rawValue: action) else { return }

        let playlistName = components.queryItems?.first(where: { $0.name == "playlistName" })?.value
        let playlistId = components.queryItems?.first(where: { $0.name == "playlistId" })?.value

        ShortcutPlaybackController.shared.execute(
            ShortcutPlaybackCommand(
                action: shortcutAction,
                playlistName: playlistName,
                playlistId: playlistId
            )
        )
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
