//
//  DataManager.swift
//  YTAudioPlayer
//
//  Persistent data management for user preferences, history, and stats
//

import Foundation
import Combine
import CoreData

/// Manages persistent user data including recently played, stats, and playback progress
class DataManager: ObservableObject {
    static let shared = DataManager()
    
    // MARK: - Published Properties
    @Published var recentlyPlayed: [RecentTrack] = []
    @Published var totalListeningSeconds: TimeInterval = 0
    @Published var tracksPlayedCount: Int = 0
    // S17-H: removed `savedQueue` (JSON snapshot of the queue).
    // It was never read by the restore path (CoreData via
    // PlaybackQueueManager is the source of truth) and was just
    // a duplicate write that drifted from the CoreData truth. The
    // `dataManager.saveQueue(_:)` call sites in PlayerState
    // (formerly in addToQueue/addToQueueNext) are also removed.
    
    // MARK: - Private Properties
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let persistence = PersistenceController.shared

    // Debounce timer for UserDefaults writes to reduce disk I/O
    private var progressSaveTimer: Timer?
    private var pendingProgressUpdates: [String: Double] = [:]

    private enum Keys {
        static let recentlyPlayed = "recentlyPlayed"
        static let totalListeningSeconds = "totalListeningSeconds"
        static let tracksPlayedCount = "tracksPlayedCount"
        // S17-H: removed `savedQueue` (JSON snapshot key) — see
        // the matching comment on the @Published var.
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

        // S17-H: removed the JSON saved-queue load. PlaybackQueueManager
        // (CoreData) is the source of truth; this branch was never
        // read by the restore path and was duplicating writes.
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
        persistPlayHistory(for: track, playbackProgress: playbackProgress)
        
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
        // S11 fix (Bug 8): also persist the most-recent track id and
        // its progress so the resume block on HomeView can seek to the
        // correct position instead of always starting from 0.
        if let currentTrackId = pendingProgressUpdates.keys.first,
           let currentProgress = pendingProgressUpdates[currentTrackId] {
            saveLastPlaybackState(trackId: currentTrackId, progress: currentProgress)
        }
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
        persistListeningTime(seconds)
    }
    
    private func saveStats() {
        defaults.set(totalListeningSeconds, forKey: Keys.totalListeningSeconds)
        defaults.set(tracksPlayedCount, forKey: Keys.tracksPlayedCount)
    }

    private func persistPlayHistory(for track: Track, playbackProgress: Double) {
        let context = persistence.newBackgroundContext()

        context.perform {
            let trackEntity = CDTrack.fetchOrCreate(videoId: track.videoId, context: context)
            trackEntity.title = track.title
            trackEntity.artists = track.artists
            trackEntity.album = track.album
            trackEntity.durationSeconds = Int32(track.durationSeconds)
            trackEntity.thumbnailURLs = track.thumbnails.map { $0.url.absoluteString }
            trackEntity.isExplicit = track.isExplicit
            trackEntity.videoType = track.videoType
            if trackEntity.value(forKey: "createdAt") == nil {
                trackEntity.createdAt = Date()
            }

            _ = CDPlayHistory.create(
                for: trackEntity,
                progress: playbackProgress,
                completed: playbackProgress >= 0.9,
                context: context
            )

            let stats = CDUserStats.getOrCreate(context: context)
            stats.incrementTracksPlayed()

            do {
                try context.save()
            } catch {
                print("❌ Failed to persist play history: \(error)")
            }
        }
    }

    private func persistListeningTime(_ seconds: TimeInterval) {
        let context = persistence.newBackgroundContext()

        context.perform {
            let stats = CDUserStats.getOrCreate(context: context)
            stats.addListeningTime(seconds)

            do {
                try context.save()
            } catch {
                print("❌ Failed to persist listening stats: \(error)")
            }
        }
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
    // S17-H: removed the entire JSON queue persistence layer
    // (saveQueue / loadQueue / clearSavedQueue / QueueItemSnapshot).
    // PlaybackQueueManager (CoreData) is the only restore path the
    // app reads on launch; the JSON path was written on every
    // addToQueue / addToQueueNext and was never read, drifting
    // from the CoreData truth. PlayerState.addToQueue /
    // addToQueueNext no longer call dataManager.saveQueue.

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
        totalListeningSeconds = 0
        tracksPlayedCount = 0

        defaults.removeObject(forKey: Keys.recentlyPlayed)
        // S17-H: removed the savedQueue defaults cleanup (no
        // longer writing the key).
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
        artists.isEmpty ? "Unknown Artist" : artists.joined(separator: ", ")
    }
    
    var artworkURL: URL? {
        thumbnails.last?.url
    }
}
