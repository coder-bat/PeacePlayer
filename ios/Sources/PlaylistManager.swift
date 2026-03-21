//
//  PlaylistManager.swift
//  YTAudioPlayer
//
//  Central playlist management with persistence
//

import Foundation
import Combine
import SwiftUI

/// Manages all playlist operations and persistence
class PlaylistManager: ObservableObject {
    static let shared = PlaylistManager()
    
    // MARK: - Published Properties
    
    @Published var playlists: [Playlist] = []
    @Published var likedTracks: Set<String> = []
    @Published private(set) var isLoading = false
    
    // MARK: - Private Properties
    
    private let dataManager = DataManager.shared
    private let defaults = UserDefaults.standard
    var cancellables = Set<AnyCancellable>()
    
    private enum Keys {
        static let playlists = "user.playlists"
        static let likedTracks = "user.likedTracks"
    }
    
    // MARK: - Initialization
    
    private init() {
        loadPlaylists()
        observePlayback()
    }
    
    // MARK: - Persistence
    
    private func loadPlaylists() {
        // Load liked tracks
        if let data = defaults.data(forKey: Keys.likedTracks),
           let tracks = try? JSONDecoder().decode(Set<String>.self, from: data) {
            likedTracks = tracks
        }
        
        // Load user playlists
        if let data = defaults.data(forKey: Keys.playlists),
           let loaded = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = loaded
        } else {
            // First launch - create default smart playlists
            playlists = Playlist.defaultSmartPlaylists()
            savePlaylists()
        }
        
        // Refresh smart playlists on load
        refreshSmartPlaylists()
    }
    
    private func savePlaylists() {
        if let data = try? JSONEncoder().encode(playlists) {
            defaults.set(data, forKey: Keys.playlists)
        }
        
        if let data = try? JSONEncoder().encode(likedTracks) {
            defaults.set(data, forKey: Keys.likedTracks)
        }
    }
    
    // MARK: - Playlist CRUD
    
    @discardableResult
    func createPlaylist(name: String, description: String? = nil, thumbnailURL: String? = nil) -> Playlist {
        let playlist = Playlist(
            name: name,
            description: description,
            trackIds: [],
            thumbnailURL: thumbnailURL
        )
        playlists.append(playlist)
        savePlaylists()
        HapticManager.success()
        return playlist
    }
    
    func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
        savePlaylists()
        HapticManager.light()
    }
    
    func renamePlaylist(id: UUID, newName: String) {
        if let index = playlists.firstIndex(where: { $0.id == id }) {
            playlists[index].name = newName
            playlists[index].modifiedAt = Date()
            savePlaylists()
        }
    }
    
    func updatePlaylistDescription(id: UUID, description: String?) {
        if let index = playlists.firstIndex(where: { $0.id == id }) {
            playlists[index].description = description
            playlists[index].modifiedAt = Date()
            savePlaylists()
        }
    }
    
    func playlist(withId id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }
    
    // MARK: - Track Management
    
    func addTrack(_ track: Track, to playlistId: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        guard !playlists[index].trackIds.contains(track.videoId) else { return }
        
        playlists[index].trackIds.append(track.videoId)
        playlists[index].modifiedAt = Date()
        savePlaylists()
        HapticManager.light()
    }
    
    func addTracks(_ tracks: [Track], to playlistId: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        
        let existingIds = Set(playlists[index].trackIds)
        let newIds = tracks.map { $0.videoId }.filter { !existingIds.contains($0) }
        
        guard !newIds.isEmpty else { return }
        
        playlists[index].trackIds.append(contentsOf: newIds)
        playlists[index].modifiedAt = Date()
        savePlaylists()
    }
    
    func removeTrack(_ trackId: String, from playlistId: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        
        playlists[index].trackIds.removeAll { $0 == trackId }
        playlists[index].modifiedAt = Date()
        savePlaylists()
    }
    
    func removeTracks(at offsets: IndexSet, from playlistId: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        
        playlists[index].trackIds.remove(atOffsets: offsets)
        playlists[index].modifiedAt = Date()
        savePlaylists()
    }
    
    func moveTrack(from source: IndexSet, to destination: Int, in playlistId: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { return }
        
        playlists[index].trackIds.move(fromOffsets: source, toOffset: destination)
        playlists[index].modifiedAt = Date()
        savePlaylists()
    }
    
    func isTrackInPlaylist(_ trackId: String, playlistId: UUID) -> Bool {
        guard let playlist = playlists.first(where: { $0.id == playlistId }) else { return false }
        return playlist.trackIds.contains(trackId)
    }
    
    // MARK: - Like/Favorite System
    
    func toggleLike(trackId: String) {
        if likedTracks.contains(trackId) {
            likedTracks.remove(trackId)
            HapticManager.light()
        } else {
            likedTracks.insert(trackId)
            HapticManager.success()
        }
        savePlaylists()
        
        // Refresh favorites playlist if it exists
        if let index = playlists.firstIndex(where: { $0.isLikedSongsPlaylist }) {
            refreshSmartPlaylist(at: index)
        }
    }
    
    func isLiked(trackId: String) -> Bool {
        likedTracks.contains(trackId)
    }
    
    // MARK: - Smart Playlists
    
    func refreshSmartPlaylists() {
        for (index, playlist) in playlists.enumerated() {
            if playlist.isSmart {
                refreshSmartPlaylist(at: index)
            }
        }
    }
    
    private func refreshSmartPlaylist(at index: Int) {
        guard playlists[index].isSmart,
              let criteria = playlists[index].smartCriteria else { return }
        
        var trackIds: [String] = []
        
        switch criteria.type {
        case .recentlyAdded:
            // Get from recently played that are newer than 30 days
            let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
            trackIds = dataManager.recentlyPlayed
                .filter { $0.playedAt > cutoff }
                .map { $0.videoId }
            
        case .recentlyPlayed:
            // Get from DataManager's recently played (last 7 days)
            let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            trackIds = dataManager.recentlyPlayed
                .filter { $0.playedAt > cutoff }
                .map { $0.videoId }
            
        case .mostPlayed:
            // Sort by play count from DataManager
            // For now, just use recently played order as proxy
            trackIds = dataManager.recentlyPlayed.map { $0.videoId }
            
        case .favorites:
            trackIds = Array(likedTracks)
            
        case .downloaded:
            // This will be populated by LibraryViewModel when it loads
            // For now, leave empty - will be refreshed when library loads
            trackIds = []
            
        case .neverPlayed:
            // Tracks in playlists that aren't in recently played
            let playedIds = Set(dataManager.recentlyPlayed.map { $0.videoId })
            let allTrackIds = playlists.flatMap { $0.trackIds }
            trackIds = Array(Set(allTrackIds).subtracting(playedIds))
        }
        
        // Apply limit
        if let limit = criteria.limit, trackIds.count > limit {
            trackIds = Array(trackIds.prefix(limit))
        }
        
        playlists[index].trackIds = trackIds
    }
    
    /// Call this when library loads to populate the Downloaded smart playlist
    func updateDownloadedPlaylist(with trackIds: [String]) {
        if let index = playlists.firstIndex(where: { $0.smartCriteria?.type == .downloaded }) {
            playlists[index].trackIds = trackIds
            savePlaylists()
        }
    }
    
    // MARK: - Queue Operations
    
    func playPlaylist(_ playlistId: UUID, shuffle: Bool = false) {
        guard let playlist = playlists.first(where: { $0.id == playlistId }) else { return }
        
        var trackIds = playlist.trackIds
        if shuffle {
            trackIds.shuffle()
        }
        
        // Get tracks from TrackStore
        let tracks = trackIds.compactMap { TrackStore.shared.getTrack(videoId: $0) }
        guard !tracks.isEmpty else { return }
        
        // Fetch stream URLs and play
        let playerState = PlayerState.shared
        var streamInfos: [(track: Track, streamUrl: String)] = []
        let group = DispatchGroup()
        let processingQueue = DispatchQueue(label: "com.ytaudio.playlistplay", attributes: .concurrent)
        
        for track in tracks.prefix(20) {
            group.enter()
            APIService.shared.getStreamUrl(videoId: track.videoId)
                .sink(receiveCompletion: { _ in
                    group.leave()
                }, receiveValue: { streamInfo in
                    processingQueue.async(flags: .barrier) {
                        streamInfos.append((track, streamInfo.streamUrl))
                    }
                })
                .store(in: &cancellables)
        }
        
        group.notify(queue: .main) {
            guard !streamInfos.isEmpty else { return }
            
            // Sort by original order using Dictionary for O(1) lookup instead of O(n) first()
            let streamInfoById = Dictionary(uniqueKeysWithValues: streamInfos.map { ($0.track.videoId, $0) })
            let ordered = tracks.prefix(20).compactMap { streamInfoById[$0.videoId] }
            
            // Clear queue and add tracks
            playerState.queue.removeAll()
            for info in ordered {
                let item = QueueItem(
                    track: info.track,
                    streamUrl: info.streamUrl,
                    source: .stream
                )
                playerState.addToQueue(item)
            }
            
            // Play first track
            if !playerState.queue.isEmpty {
                playerState.playQueue(at: 0)
                playerState.showFullPlayer = true
            }
        }
    }
    
    func queuePlaylist(_ playlistId: UUID) {
        // Similar to playPlaylist but appends to existing queue
        guard let playlist = playlists.first(where: { $0.id == playlistId }) else { return }
        
        let trackIds = playlist.trackIds
        let tracks = trackIds.compactMap { TrackStore.shared.getTrack(videoId: $0) }
        guard !tracks.isEmpty else { return }
        
        let playerState = PlayerState.shared
        
        for track in tracks.prefix(20) {
            APIService.shared.getStreamUrl(videoId: track.videoId)
                .sink(receiveCompletion: { _ in }, receiveValue: { streamInfo in
                    let item = QueueItem(
                        track: track,
                        streamUrl: streamInfo.streamUrl,
                        source: .stream
                    )
                    playerState.addToQueue(item)
                })
                .store(in: &cancellables)
        }
    }
    
    // MARK: - Import/Export
    
    func exportPlaylists() -> URL? {
        let export = PlaylistExport(
            version: PlaylistExport.currentVersion,
            exportedAt: Date(),
            playlists: playlists.filter { !$0.isSmart },  // Don't export smart playlists
            likedTracks: Array(likedTracks)
        )
        
        do {
            let data = try JSONEncoder().encode(export)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("YTAudio_Playlists_\(Date().ISO8601Format()).json")
            try data.write(to: url)
            return url
        } catch {
            print("Failed to export playlists: \(error)")
            return nil
        }
    }
    
    func importPlaylists(from url: URL) -> Bool {
        do {
            let data = try Data(contentsOf: url)
            let export = try JSONDecoder().decode(PlaylistExport.self, from: data)
            
            // Merge imported playlists with existing
            let existingIds = Set(playlists.map { $0.id })
            let newPlaylists = export.playlists.filter { !existingIds.contains($0.id) }
            
            playlists.append(contentsOf: newPlaylists)
            
            // Merge liked tracks
            likedTracks.formUnion(export.likedTracks)
            
            savePlaylists()
            refreshSmartPlaylists()
            return true
        } catch {
            print("Failed to import playlists: \(error)")
            return false
        }
    }
    
    // MARK: - YouTube Playlist Actions
    
    func playYouTubePlaylist(_ details: YouTubePlaylistDetails, shuffle: Bool = false) {
        var tracks = details.tracks
        if shuffle {
            tracks.shuffle()
        }
        
        guard !tracks.isEmpty else { return }
        
        let playerState = PlayerState.shared
        var streamInfos: [(track: Track, streamUrl: String)] = []
        let group = DispatchGroup()
        let processingQueue = DispatchQueue(label: "com.ytaudio.ytplaylistplay", attributes: .concurrent)
        
        for track in tracks.prefix(20) {
            group.enter()
            APIService.shared.getStreamUrl(videoId: track.videoId)
                .sink(receiveCompletion: { _ in
                    group.leave()
                }, receiveValue: { streamInfo in
                    processingQueue.async(flags: .barrier) {
                        streamInfos.append((track, streamInfo.streamUrl))
                    }
                })
                .store(in: &cancellables)
        }
        
        group.notify(queue: .main) {
            guard !streamInfos.isEmpty else { return }
            
            // Sort by original order using Dictionary for O(1) lookup instead of O(n) first()
            let streamInfoById = Dictionary(uniqueKeysWithValues: streamInfos.map { ($0.track.videoId, $0) })
            let ordered = tracks.prefix(20).compactMap { streamInfoById[$0.videoId] }
            
            // Clear queue and add tracks
            playerState.queue.removeAll()
            for info in ordered {
                let item = QueueItem(
                    track: info.track,
                    streamUrl: info.streamUrl,
                    source: .stream
                )
                playerState.addToQueue(item)
            }
            
            // Play first track
            if !playerState.queue.isEmpty {
                playerState.playQueue(at: 0)
                playerState.showFullPlayer = true
            }
        }
    }
    
    func queueYouTubePlaylist(_ details: YouTubePlaylistDetails) {
        let tracks = details.tracks
        guard !tracks.isEmpty else { return }
        
        let playerState = PlayerState.shared
        
        for track in tracks.prefix(20) {
            APIService.shared.getStreamUrl(videoId: track.videoId)
                .sink(receiveCompletion: { _ in }, receiveValue: { streamInfo in
                    let item = QueueItem(
                        track: track,
                        streamUrl: streamInfo.streamUrl,
                        source: .stream
                    )
                    playerState.addToQueue(item)
                })
                .store(in: &cancellables)
        }
    }
    
    // MARK: - Helper Methods
    
    func recentlyModifiedPlaylists(limit: Int = 5) -> [Playlist] {
        playlists
            .filter { !$0.isSmart }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(limit)
            .map { $0 }
    }
    
    func playlistsContaining(trackId: String) -> [Playlist] {
        playlists.filter { $0.trackIds.contains(trackId) }
    }
    
    // MARK: - Private Methods
    
    private func observePlayback() {
        // Observe when tracks are played to update smart playlists
        NotificationCenter.default.publisher(for: .trackPlayed)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshSmartPlaylists()
            }
            .store(in: &cancellables)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a track is played (used to update smart playlists)
    static let trackPlayed = Notification.Name("TrackPlayed")
}

// MARK: - View Extensions

extension View {
    /// Shows a sheet to add a track to playlists
    func addToPlaylistSheet(isPresented: Binding<Bool>, track: Track?) -> some View {
        self.sheet(isPresented: isPresented) {
            if let track = track {
                AddToPlaylistSheet(track: track)
            }
        }
    }
}
