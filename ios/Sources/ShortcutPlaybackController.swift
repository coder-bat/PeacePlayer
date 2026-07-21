//
//  ShortcutPlaybackController.swift
//  YTAudioPlayer
//

import Foundation
import Combine
import CoreData

final class ShortcutPlaybackController {
    static let shared = ShortcutPlaybackController()

    private let persistence = PersistenceController.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    @discardableResult
    func executePendingCommand() -> Bool {
        guard let command = SharedNowPlayingState.readAndClearPendingShortcutCommand() else { return false }
        execute(command)
        return true
    }

    func execute(_ command: ShortcutPlaybackCommand) {
        switch command.action {
        case .shuffleLibrary:
            shuffleLibrary()
        case .playRecentlyPlayed:
            playRecentlyPlayed()
        case .playPlaylist:
            guard let playlist = resolvePlaylist(id: command.playlistId, name: command.playlistName) else {
                // S13: Siri shortcut ended without a playlist match —
                // surface the failure so the user understands why their
                // command didn't trigger playback. Previous behavior was
                // print-only.
                ErrorHandler.shared.show(.notFound)
                print("⚠️ Siri shortcut playlist not found: \(command.playlistName ?? command.playlistId ?? "unknown")")
                return
            }
            PlaylistManager.shared.refreshSmartPlaylists()
            PlaylistManager.shared.playPlaylist(playlist.id)
        case .pause:
            PlayerState.shared.pause()
        case .resume:
            PlayerState.shared.resume()
        case .togglePlayPause:
            PlayerState.shared.togglePlayPause()
        case .skipForward:
            PlayerState.shared.skipForward()
        case .skipBackward:
            PlayerState.shared.skipBackward()
        case .likeCurrentTrack:
            // Operates on whatever is currently playing. If nothing is
            // playing, the call is a no-op (toggleLike on an empty
            // id just no-ops in PlaylistManager).
            if let videoId = PlayerState.shared.currentItem?.track.videoId, !videoId.isEmpty {
                if !PlaylistManager.shared.isLiked(trackId: videoId) {
                    PlaylistManager.shared.toggleLike(trackId: videoId)
                }
            }
        case .unlikeCurrentTrack:
            if let videoId = PlayerState.shared.currentItem?.track.videoId, !videoId.isEmpty {
                if PlaylistManager.shared.isLiked(trackId: videoId) {
                    PlaylistManager.shared.toggleLike(trackId: videoId)
                }
            }
        case .startSongRadio:
            // S16: start a song radio from the current track. The
            // notification observer in ContentView picks it up and
            // pushes the Radio view.
            if let track = PlayerState.shared.currentItem?.track {
                NotificationCenter.default.post(name: .startSongRadio, object: track)
                HapticManager.light()
            }
        }
    }

    func resolvePlaylistIdentifier(named name: String) -> (id: String, name: String)? {
        guard let playlist = resolvePlaylist(id: nil, name: name) else { return nil }
        return (playlist.id.uuidString, playlist.name)
    }

    private func shuffleLibrary() {
        PlaylistManager.shared.refreshSmartPlaylists()
        let tracks = personalLibraryTracks()

        guard !tracks.isEmpty else {
            // S13: silent failure for an empty library. The user invoked
            // the Siri shortcut expecting a shuffle; if there's nothing
            // to shuffle, surface the empty state.
            ErrorHandler.shared.show(.unknown("No tracks in your library to shuffle. Download some music first."))
            print("⚠️ Siri shortcut found no personal library tracks to shuffle")
            return
        }

        TrackStore.shared.saveTracks(tracks)
        queueAndPlay(tracks.shuffled())
    }

    private func personalLibraryTracks() -> [Track] {
        var tracksById: [String: Track] = [:]

        func collect(_ track: Track?) {
            guard let track, !track.videoId.isEmpty else { return }
            tracksById[track.videoId] = track
        }

        let context = persistence.viewContext
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.relationshipKeyPathsForPrefetching = ["track"]
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDDownloadedTrack.downloadedAt, ascending: false)]

        do {
            let downloads = try context.fetch(request)
            for download in downloads {
                collect(download.track?.toTrack)
            }
        } catch {
            // S13: surface Core Data fetch failures when assembling the
            // library for a Siri shuffle — silent failure is misleading.
            ErrorHandler.shared.show(.parsing("Couldn't read your library for the Siri shortcut."))
            print("❌ Failed to load downloaded tracks for Siri shortcut: \(error)")
        }

        for recentTrack in DataManager.shared.recentlyPlayed {
            collect(recentTrack.toTrack)
        }

        let libraryTrackIds = Set(
            PlaylistManager.shared.playlists.flatMap(\.trackIds) +
            Array(PlaylistManager.shared.likedTracks)
        )

        for trackId in libraryTrackIds {
            collect(TrackStore.shared.getTrack(videoId: trackId))
        }

        return Array(tracksById.values)
    }

    private func playRecentlyPlayed() {
        let tracks = DataManager.shared.recentlyPlayed.map(\.toTrack)
        guard !tracks.isEmpty else {
            // S13: silent "no recently played tracks" failure for Siri
            // intent. Tell the user nothing played back.
            ErrorHandler.shared.show(.unknown("No recently played tracks yet. Play something first, then try again."))
            print("⚠️ Siri shortcut found no recently played tracks")
            return
        }

        TrackStore.shared.saveTracks(tracks)
        queueAndPlay(tracks)
    }

    private func resolvePlaylist(id: String?, name: String?) -> Playlist? {
        let playlists = PlaylistManager.shared.playlists

        if let id, let uuid = UUID(uuidString: id), let match = playlists.first(where: { $0.id == uuid }) {
            return match
        }

        guard let name else { return nil }
        let normalizedTarget = normalizedPlaylistName(name)

        if let exact = playlists.first(where: { normalizedPlaylistName($0.name) == normalizedTarget }) {
            return exact
        }

        return playlists.first { normalizedPlaylistName($0.name).contains(normalizedTarget) }
    }

    private func normalizedPlaylistName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    private func queueAndPlay(_ tracks: [Track]) {
        let orderedTracks = Array(tracks.prefix(20))
        guard !orderedTracks.isEmpty else { return }

        let playerState = PlayerState.shared
        var itemsByVideoId: [String: QueueItem] = [:]
        let group = DispatchGroup()
        let mutationQueue = DispatchQueue(label: "com.ytaudio.shortcutplayback.queue")

        for track in orderedTracks {
            let localURL = AudioFileManager.shared.localFileURL(for: track.videoId)
            if FileManager.default.fileExists(atPath: localURL.path) {
                mutationQueue.sync {
                    itemsByVideoId[track.videoId] = QueueItem(
                        track: track,
                        streamUrl: localURL.absoluteString,
                        source: .local(path: localURL.path)
                    )
                }
                continue
            }

            group.enter()
            StreamURLCache.shared.getStreamUrl(videoId: track.videoId, quality: "low")
                .sink(
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            // S13: per-track stream URL resolution failed.
                            // We don't pop a toast per failure (we may be
                            // resolving 20 tracks) — track count mismatch
                            // is handled at .notify below.
                            print("❌ Failed to resolve track for Siri shortcut: \(error)")
                        }
                        group.leave()
                    },
                    receiveValue: { streamInfo in
                        mutationQueue.async {
                            itemsByVideoId[track.videoId] = QueueItem(
                                track: track,
                                streamUrl: streamInfo.streamUrl,
                                source: .stream
                            )
                        }
                    }
                )
                .store(in: &cancellables)
        }

        group.notify(queue: .main) {
            mutationQueue.async {
                let items = orderedTracks.compactMap { itemsByVideoId[$0.videoId] }

                DispatchQueue.main.async {
                    // S13: if any tracks failed to resolve, surface a single
                    // summary toast rather than per-track (which would
                    // flood). The user gets to know their Siri shortcut
                    // partially completed.
                    if items.isEmpty {
                        ErrorHandler.shared.show(.playbackFailed("Couldn't load any tracks for the shortcut. Try again or check your connection."))
                        return
                    } else if items.count < orderedTracks.count {
                        let missing = orderedTracks.count - items.count
                        ErrorHandler.shared.show(.unknown("Loaded \(items.count) of \(orderedTracks.count) tracks — \(missing) unavailable."))
                    }

                    // S17-G: queue is now a computed property
                    // backed by QueueStore. Replace via the store
                    // and set the index the same way.
                    playerState.queueStore.replace(with: items)
                    playerState.queueStore.setCurrentIndex(0)
                    playerState.playQueue(at: 0)
                    playerState.showFullPlayer = true
                }
            }
        }
    }
}
