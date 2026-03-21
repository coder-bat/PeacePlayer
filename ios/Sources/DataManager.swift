//
//  DataManager.swift
//  YTAudioPlayer
//
//  Persistent data management for user preferences, history, and stats
//

import Foundation
import Combine

/// Manages persistent user data including recently played, stats, and playback progress
class DataManager: ObservableObject {
    static let shared = DataManager()
    
    // MARK: - Published Properties
    @Published var recentlyPlayed: [RecentTrack] = []
    @Published var totalListeningSeconds: TimeInterval = 0
    @Published var tracksPlayedCount: Int = 0
    @Published var savedQueue: [QueueItemSnapshot] = []
    
    // MARK: - Private Properties
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // Debounce timer for UserDefaults writes to reduce disk I/O
    private var progressSaveTimer: Timer?
    private var pendingProgressUpdates: [String: Double] = [:]

    private enum Keys {
        static let recentlyPlayed = "recentlyPlayed"
        static let totalListeningSeconds = "totalListeningSeconds"
        static let tracksPlayedCount = "tracksPlayedCount"
        static let savedQueue = "savedQueue"
        static let lastPlayedTrackId = "lastPlayedTrackId"
        static let lastPlaybackProgress = "lastPlaybackProgress"
    }
    
    private init() {
        loadAllData()
    }
    
    // MARK: - Loading
    private func loadAllData() {
        // Load recently played
        if let data = defaults.data(forKey: Keys.recentlyPlayed),
           let decoded = try? decoder.decode([RecentTrack].self, from: data) {
            recentlyPlayed = decoded
        }
        
        // Load stats
        totalListeningSeconds = defaults.double(forKey: Keys.totalListeningSeconds)
        tracksPlayedCount = defaults.integer(forKey: Keys.tracksPlayedCount)
        
        // Load saved queue
        if let data = defaults.data(forKey: Keys.savedQueue),
           let decoded = try? decoder.decode([QueueItemSnapshot].self, from: data) {
            savedQueue = decoded
        }
    }
    
    // MARK: - Recently Played
    
    func addToRecentlyPlayed(_ track: Track, playbackProgress: Double = 0) {
        var updated = recentlyPlayed.filter { $0.videoId != track.videoId }
        
        let recentTrack = RecentTrack(
            videoId: track.videoId,
            title: track.title,
            artists: track.artists,
            album: track.album,
            durationSeconds: track.durationSeconds,
            thumbnails: track.thumbnails,
            isExplicit: track.isExplicit,
            videoType: track.videoType,
            playedAt: Date(),
            playbackProgress: playbackProgress
        )
        
        updated.insert(recentTrack, at: 0)
        
        // Keep only last 50
        if updated.count > 50 {
            updated = Array(updated.prefix(50))
        }
        
        recentlyPlayed = updated
        saveRecentlyPlayed()
        
        // Update stats
        tracksPlayedCount += 1
        saveStats()
    }
    
    func updatePlaybackProgress(for videoId: String, progress: Double) {
        if let index = recentlyPlayed.firstIndex(where: { $0.videoId == videoId }) {
            recentlyPlayed[index].playbackProgress = progress

            // Debounce UserDefaults writes to reduce disk I/O
            // Accumulate updates and save every 2 seconds instead of immediately
            pendingProgressUpdates[videoId] = progress

            progressSaveTimer?.invalidate()
            progressSaveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                self?.flushProgressUpdates()
            }
        }
    }

    /// Flush pending progress updates to UserDefaults
    private func flushProgressUpdates() {
        guard !pendingProgressUpdates.isEmpty else { return }
        saveRecentlyPlayed()
        pendingProgressUpdates.removeAll()
        print("💾 Batched progress updates saved to UserDefaults")
    }
    
    func clearRecentlyPlayed() {
        recentlyPlayed.removeAll()
        saveRecentlyPlayed()
    }
    
    private func saveRecentlyPlayed() {
        if let data = try? encoder.encode(recentlyPlayed) {
            defaults.set(data, forKey: Keys.recentlyPlayed)
        }
    }
    
    // MARK: - Stats
    
    func addListeningTime(_ seconds: TimeInterval) {
        totalListeningSeconds += seconds
        saveStats()
    }
    
    private func saveStats() {
        defaults.set(totalListeningSeconds, forKey: Keys.totalListeningSeconds)
        defaults.set(tracksPlayedCount, forKey: Keys.tracksPlayedCount)
    }
    
    func formattedListeningTime() -> String {
        let hours = Int(totalListeningSeconds / 3600)
        let minutes = Int((totalListeningSeconds.truncatingRemainder(dividingBy: 3600)) / 60)
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    // MARK: - Queue Persistence
    
    func saveQueue(_ items: [QueueItem]) {
        savedQueue = items.map { QueueItemSnapshot(from: $0) }
        if let data = try? encoder.encode(savedQueue) {
            defaults.set(data, forKey: Keys.savedQueue)
        }
    }
    
    func loadQueue() -> [QueueItemSnapshot] {
        return savedQueue
    }
    
    func clearSavedQueue() {
        savedQueue.removeAll()
        defaults.removeObject(forKey: Keys.savedQueue)
    }
    
    // MARK: - Last Playback State
    
    func saveLastPlaybackState(trackId: String, progress: Double) {
        defaults.set(trackId, forKey: Keys.lastPlayedTrackId)
        defaults.set(progress, forKey: Keys.lastPlaybackProgress)
    }
    
    func loadLastPlaybackState() -> (trackId: String?, progress: Double) {
        let trackId = defaults.string(forKey: Keys.lastPlayedTrackId)
        let progress = defaults.double(forKey: Keys.lastPlaybackProgress)
        return (trackId, progress)
    }
    
    func clearLastPlaybackState() {
        defaults.removeObject(forKey: Keys.lastPlayedTrackId)
        defaults.removeObject(forKey: Keys.lastPlaybackProgress)
    }
    
    // MARK: - Reset All
    
    func resetAllData() {
        recentlyPlayed.removeAll()
        savedQueue.removeAll()
        totalListeningSeconds = 0
        tracksPlayedCount = 0
        
        defaults.removeObject(forKey: Keys.recentlyPlayed)
        defaults.removeObject(forKey: Keys.savedQueue)
        defaults.removeObject(forKey: Keys.totalListeningSeconds)
        defaults.removeObject(forKey: Keys.tracksPlayedCount)
        defaults.removeObject(forKey: Keys.lastPlayedTrackId)
        defaults.removeObject(forKey: Keys.lastPlaybackProgress)
    }
}

// MARK: - Data Models

/// A persisted version of a track for recently played
struct RecentTrack: Codable, Identifiable {
    let videoId: String
    let title: String
    let artists: [String]
    let album: String
    let durationSeconds: Int
    let thumbnails: [Thumbnail]
    let isExplicit: Bool
    let videoType: String
    let playedAt: Date
    var playbackProgress: Double
    
    var id: String { videoId }
    
    var toTrack: Track {
        Track(
            videoId: videoId,
            title: title,
            artists: artists,
            album: album,
            durationSeconds: durationSeconds,
            thumbnails: thumbnails,
            isExplicit: isExplicit,
            videoType: videoType
        )
    }
    
    var displayArtist: String {
        artists.joined(separator: ", ")
    }
    
    var artworkURL: URL? {
        thumbnails.last?.url
    }
}

/// A persisted snapshot of a queue item (videoId only - stream URLs expire)
struct QueueItemSnapshot: Codable {
    let videoId: String
    let title: String
    let artists: [String]
    let album: String
    let durationSeconds: Int
    let thumbnails: [Thumbnail]
    let isExplicit: Bool
    let videoType: String
    let savedAt: Date
    
    init(from item: QueueItem) {
        self.videoId = item.track.videoId
        self.title = item.track.title
        self.artists = item.track.artists
        self.album = item.track.album
        self.durationSeconds = item.track.durationSeconds
        self.thumbnails = item.track.thumbnails
        self.isExplicit = item.track.isExplicit
        self.videoType = item.track.videoType
        self.savedAt = Date()
    }
    
    var track: Track {
        Track(
            videoId: videoId,
            title: title,
            artists: artists,
            album: album,
            durationSeconds: durationSeconds,
            thumbnails: thumbnails,
            isExplicit: isExplicit,
            videoType: videoType
        )
    }
}
