//
//  TrackStore.swift
//  YTAudioPlayer
//
//  Persistent storage for track metadata
//

import Foundation

/// Stores track metadata persistently so playlists can display track info
class TrackStore: ObservableObject {
    static let shared = TrackStore()
    
    private let defaults = UserDefaults.standard
    private let tracksKey = "trackStore_metadata"
    
    @Published private(set) var tracks: [String: Track] = [:]
    
    private init() {
        loadTracks()
    }
    
    /// Save a single track's metadata
    func saveTrack(_ track: Track) {
        tracks[track.videoId] = track
        persistTracks()
    }
    
    /// Save multiple tracks' metadata
    func saveTracks(_ tracks: [Track]) {
        for track in tracks {
            self.tracks[track.videoId] = track
        }
        persistTracks()
    }
    
    /// Get a track by videoId
    func getTrack(videoId: String) -> Track? {
        return tracks[videoId]
    }
    
    /// Get multiple tracks by videoIds (returns in same order)
    func getTracks(videoIds: [String]) -> [Track] {
        return videoIds.compactMap { tracks[$0] }
    }
    
    /// Check if we have metadata for a track
    func hasTrack(videoId: String) -> Bool {
        return tracks[videoId] != nil
    }
    
    /// Clear all stored tracks
    func clearAll() {
        tracks.removeAll()
        persistTracks()
    }
    
    private func loadTracks() {
        guard let data = defaults.data(forKey: tracksKey),
              let decoded = try? JSONDecoder().decode([String: Track].self, from: data) else {
            return
        }
        tracks = decoded
    }
    
    private func persistTracks() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        defaults.set(data, forKey: tracksKey)
    }
}
