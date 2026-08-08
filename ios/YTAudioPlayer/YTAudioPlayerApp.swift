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

                // S18 / v1.6 / P1-7: re-evaluate the daily recap on
                // every foreground. If the user has been away 24+ hours
                // AND the Labs flag is on AND they haven't been
                // permanently disabled by 3 consecutive play days, a
                // 8pm notification is scheduled for the last track.
                DailyRecapNotifier.shared.evaluateRecapState()
            }

            // S18 (QW-1): set the app icon badge to the number of
            // ready-to-open Time Capsules whenever the scene phase
            // changes (any direction). 0 clears the badge. The badge
            // also doubles as a retention nudge — even at 0, the user
            // gets visual confirmation "I'm caught up".
            // Also call WidgetCenter so the home-screen widgets pick
            // up the new state.
            let readyCount = TimeCapsuleManager.shared.readyToOpen.count
            UIApplication.shared.applicationIconBadgeNumber = readyCount

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
        case "track":
            // S18 / P1-5: peaceplayer://track/{videoId} — play
            // a specific track by videoId. Share card QR codes
            // and Spotlight results deep-link here.
            let videoId = url.pathComponents
                .first(where: { $0 != "/" && !$0.isEmpty }) ?? ""
            if !videoId.isEmpty, let track = TrackStore.shared.getTrack(videoId: videoId) {
                PlayerState.shared.play(track: track)
            }
        case "radio", "podcast", "audiobook":
            // S18 / v1.6 / P1-5: deep-link routes for radio/podcast/
            // audiobook. Resolved via DeepLinkIndex, which caches the
            // top-N lists RadioViewModel loads whenever the user opens
            // the Radio tab. Without that cache the routes were silent
            // no-ops; with it, a share-card / Spotlight link to a
            // station / show / book the user has ever browsed works.
            //
            // Format: peaceplayer://radio/{stationId}
            //         peaceplayer://podcast/{feedUrl}
            //         peaceplayer://audiobook/{bookId}
            //
            // The path component may be percent-encoded (esp. feedUrl
            // since it's a full https URL); decode before lookup.
            let raw = url.pathComponents
                .first(where: { $0 != "/" && !$0.isEmpty }) ?? ""
            let key = raw.removingPercentEncoding ?? raw
            switch url.host {
            case "radio":
                if let station = DeepLinkIndex.shared.findStation(key) {
                    // Radio: play directly. No detail view needed —
                    // tapping a station anywhere in the app starts it.
                    PlayerState.shared.playRadioStation(station)
                } else {
                    ErrorHandler.shared.showInfo(
                        "Station not in your library yet — open the Radio tab to browse"
                    )
                }
            case "podcast":
                if let show = DeepLinkIndex.shared.findPodcast(key) {
                    // Podcast: stage the show, then notify. ContentView
                    // switches to the Home tab, HomeView pushes the
                    // Radio destination, and RadioView consumes the
                    // pending intent on appear to open the detail
                    // sheet (which then loads the episode list).
                    DeepLinkIntent.shared.setPendingPodcastShow(show)
                    NotificationCenter.default.post(
                        name: .openPodcastShow,
                        object: show
                    )
                } else {
                    ErrorHandler.shared.showInfo(
                        "Show not in your library yet — open the Radio tab to browse"
                    )
                }
            case "audiobook":
                if let book = DeepLinkIndex.shared.findAudiobook(key) {
                    // Audiobook: same pattern as podcast. The detail
                    // view loads the chapter list and the user picks
                    // where to start.
                    DeepLinkIntent.shared.setPendingAudiobook(book)
                    NotificationCenter.default.post(
                        name: .openAudiobook,
                        object: book
                    )
                } else {
                    ErrorHandler.shared.showInfo(
                        "Book not in your library yet — open the Radio tab to browse"
                    )
                }
            default:
                break
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
