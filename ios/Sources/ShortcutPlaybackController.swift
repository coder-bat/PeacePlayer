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
                print("⚠️ Siri shortcut playlist not found: \(command.playlistName ?? command.playlistId ?? "unknown")")
                return
            }
            PlaylistManager.shared.refreshSmartPlaylists()
            PlaylistManager.shared.playPlaylist(playlist.id)
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
            APIService.shared.getStreamUrl(videoId: track.videoId, quality: "low")
                .sink(
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
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
                    guard !items.isEmpty else { return }

                    playerState.queue = items
                    playerState.currentIndex = 0
                    playerState.playQueue(at: 0)
                    playerState.showFullPlayer = true
                }
            }
        }
    }
}
