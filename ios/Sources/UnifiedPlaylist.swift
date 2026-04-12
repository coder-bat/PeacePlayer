//
//  UnifiedPlaylist.swift
//  PeacePlayer
//
//  Unified playlist model for local and Plex playlists
//

import Foundation
import SwiftUI
import CoreData

// MARK: - Playlist Source

enum PlaylistSource: Equatable, Hashable {
    case local

    var displayName: String {
        switch self {
        case .local:
            return "Local"
        }
    }

    var iconName: String {
        switch self {
        case .local:
            return "music.note.list"
        }
    }

    var tintColor: Color {
        switch self {
        case .local:
            return Theme.cyberCyan
        }
    }

    var isEditable: Bool {
        switch self {
        case .local:
            return true
        }
    }

    // MARK: - Equatable & Hashable

    static func == (lhs: PlaylistSource, rhs: PlaylistSource) -> Bool {
        switch (lhs, rhs) {
        case (.local, .local):
            return true
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .local:
            hasher.combine("local")
        }
    }
}

// MARK: - Unified Playlist

struct UnifiedPlaylist: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let trackCount: Int
    let source: PlaylistSource
    let artworkURL: URL?
    let isEditable: Bool
    let isSmart: Bool
    let createdAt: Date?
    let updatedAt: Date?

    // Async loader for tracks
    let loadTracks: () async -> [UnifiedTrack]

    init(
        id: String,
        name: String,
        trackCount: Int,
        source: PlaylistSource,
        artworkURL: URL? = nil,
        isEditable: Bool,
        isSmart: Bool = false,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        loadTracks: @escaping () async -> [UnifiedTrack]
    ) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.source = source
        self.artworkURL = artworkURL
        self.isEditable = isEditable
        self.isSmart = isSmart
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.loadTracks = loadTracks
    }

    // MARK: - Convenience Factories

    static func fromCoreData(playlist: CDPlaylist) -> UnifiedPlaylist {
        UnifiedPlaylist(
            id: playlist.id ?? UUID().uuidString,
            name: playlist.name ?? "Untitled",
            trackCount: playlist.trackOrder?.count ?? 0,
            source: .local,
            artworkURL: nil,
            isEditable: true,
            isSmart: playlist.isSmart,
            createdAt: playlist.createdAt,
            updatedAt: playlist.updatedAt,
            loadTracks: {
                await loadCoreDataPlaylistTracks(playlist: playlist)
            }
        )
    }

    // MARK: - Equatable & Hashable

    static func == (lhs: UnifiedPlaylist, rhs: UnifiedPlaylist) -> Bool {
        lhs.id == rhs.id && lhs.source == rhs.source
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(source)
    }
}

// MARK: - Private Helpers

private func loadCoreDataPlaylistTracks(playlist: CDPlaylist) async -> [UnifiedTrack] {
    let context = PersistenceController.shared.container.viewContext

    guard let trackOrder = playlist.trackOrder else { return [] }

    return trackOrder.compactMap { trackId -> UnifiedTrack? in
        let fetchRequest = CDTrack.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "videoId == %@", trackId as String)
        fetchRequest.fetchLimit = 1

        guard let track = try? context.fetch(fetchRequest).first else { return nil }

        // Check if downloaded by fetching CDDownloadedTrack separately
        let downloadFetch = CDDownloadedTrack.fetchRequest()
        downloadFetch.predicate = NSPredicate(format: "videoId == %@", trackId as String)
        downloadFetch.fetchLimit = 1

        if let downloaded = try? context.fetch(downloadFetch).first {
            return UnifiedTrack.fromDownloaded(track: track, downloaded: downloaded)
        }

        return UnifiedTrack.fromCoreData(track: track)
    }
}

// MARK: - Preview Helpers

extension UnifiedPlaylist {
    static var preview: UnifiedPlaylist {
        UnifiedPlaylist(
            id: "preview-1",
            name: "Chill Vibes",
            trackCount: 24,
            source: .local,
            artworkURL: nil,
            isEditable: true,
            loadTracks: { [] }
        )
    }

}
