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

    /// S17-H (failure modes 4): background serial queue for the
    /// expensive JSON encode. UserDefaults.set is non-blocking
    /// (it batches the disk write), but JSONEncoder.encode on
    /// 10K tracks is ~100ms on the calling thread (always main,
    /// from `addToRecentlyPlayed` etc.). Coalesce so a burst of
    /// 50 saves in 1 second results in 1 encode, not 50.
    private let persistQueue = DispatchQueue(label: "com.ytaudioplayer.trackstore.persist", qos: .utility)
    private var persistScheduled = false

    private init() {
        loadTracks()
    }

    /// Save a single track's metadata
    func saveTrack(_ track: Track) {
        tracks[track.videoId] = track
        schedulePersist()
    }

    /// Save multiple tracks' metadata
    func saveTracks(_ tracks: [Track]) {
        for track in tracks {
            self.tracks[track.videoId] = track
        }
        schedulePersist()
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
        // Synchronous for clearAll — the user explicitly deleted
        // everything, we want it gone before the next read.
        doPersistNow()
    }

    private func loadTracks() {
        guard let data = defaults.data(forKey: tracksKey),
              let decoded = try? JSONDecoder().decode([String: Track].self, from: data) else {
            return
        }
        tracks = decoded
    }

    /// Schedule a coalesced background persist. Multiple calls
    /// before the queue runs result in a single encode of the
    /// latest state. Runs on a utility queue so it doesn't
    /// contend with user actions.
    private func schedulePersist() {
        persistQueue.async { [weak self] in
            guard let self = self else { return }
            if self.persistScheduled { return }
            self.persistScheduled = true
            // Small debounce: a burst of 50 saves over 200ms will
            // hit the same coalesced encode.
            self.persistQueue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                self.persistScheduled = false
                self.doPersistNow()
            }
        }
    }

    /// Synchronously encode + write. Called from `clearAll` (where
    /// we want immediate persistence) and from the coalesced
    /// background path.
    private func doPersistNow() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        defaults.set(data, forKey: tracksKey)
    }
}
