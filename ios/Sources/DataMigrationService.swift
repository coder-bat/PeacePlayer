//
//  DataMigrationService.swift
//  YTAudioPlayer
//
//  Migrates UserDefaults data to Core Data on first launch
//

import Foundation
import CoreData

class DataMigrationService {
    static let shared = DataMigrationService()

    private let defaults = UserDefaults.standard
    private let persistence = PersistenceController.shared

    private enum Keys {
        static let migrationCompleted = "coredata.migration.completed"
        static let migrationVersion = "coredata.migration.version"
    }

    private init() {}

    // MARK: - Migration Check

    var needsMigration: Bool {
        return !defaults.bool(forKey: Keys.migrationCompleted)
    }

    // MARK: - Perform Migration

    func performMigrationIfNeeded() {
        guard needsMigration else {
            print("✅ Core Data migration already completed")
            return
        }

        print("🔄 Starting Core Data migration...")

        migratePlaylists()
        migrateLikedTracks()
        migrateListeningStats()
        migrateRecentlyPlayed()

        // Mark migration as complete
        defaults.set(true, forKey: Keys.migrationCompleted)
        defaults.set(1, forKey: Keys.migrationVersion)

        print("✅ Core Data migration completed")
    }

    // MARK: - Migration Methods

    private func migratePlaylists() {
        print("🔄 Migrating playlists...")

        // Load playlists from UserDefaults
        guard let data = defaults.data(forKey: "user.playlists"),
              let playlists = try? JSONDecoder().decode([Playlist].self, from: data) else {
            print("⚠️ No playlists to migrate")
            return
        }

        let context = persistence.viewContext

        for playlist in playlists {
            // Check if already exists
            let request: NSFetchRequest<CDPlaylist> = CDPlaylist.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", playlist.id as CVarArg)

            if let existing = try? context.fetch(request).first {
                print("  - Playlist '\(playlist.name)' already exists, skipping")
                continue
            }

            // Create new playlist
            let cdPlaylist = CDPlaylist(context: context)
            cdPlaylist.id = playlist.id
            cdPlaylist.name = playlist.name
            cdPlaylist.playlistDescription = playlist.description
            cdPlaylist.trackOrder = playlist.trackIds
            cdPlaylist.createdAt = playlist.createdAt
            cdPlaylist.modifiedAt = playlist.modifiedAt
            cdPlaylist.isSmart = playlist.isSmart
            cdPlaylist.smartCriteriaType = playlist.smartCriteria?.type.rawValue
            cdPlaylist.artworkSeed = Int32(playlist.artworkSeed)
            cdPlaylist.thumbnailURL = playlist.thumbnailURL

            print("  - Migrated playlist: \(playlist.name)")
        }

        do {
            try context.save()
            print("✅ Migrated \(playlists.count) playlists")
        } catch {
            print("❌ Failed to save playlists: \(error)")
        }
    }

    private func migrateLikedTracks() {
        print("🔄 Migrating liked tracks...")

        // Load liked tracks from UserDefaults
        guard let data = defaults.data(forKey: "user.likedTracks"),
              let likedTracks = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            print("⚠️ No liked tracks to migrate")
            return
        }

        let context = persistence.viewContext

        for videoId in likedTracks {
            // Check if track exists
            let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
            request.predicate = NSPredicate(format: "videoId == %@", videoId)

            if let track = try? context.fetch(request).first {
                // Update existing track
                track.isLiked = true
            } else {
                // Create placeholder track (will be populated when played)
                let track = CDTrack(context: context)
                track.videoId = videoId
                track.title = "Unknown"
                track.artists = []
                track.album = "Unknown"
                track.durationSeconds = 0
                track.thumbnailURLs = []
                track.isExplicit = false
                track.videoType = "UNKNOWN"
                track.createdAt = Date()
                track.isLiked = true
            }
        }

        do {
            try context.save()
            print("✅ Migrated \(likedTracks.count) liked tracks")
        } catch {
            print("❌ Failed to save liked tracks: \(error)")
        }
    }

    private func migrateListeningStats() {
        print("🔄 Migrating listening stats...")

        let totalSeconds = defaults.double(forKey: "totalListeningSeconds")
        let tracksCount = defaults.integer(forKey: "tracksPlayedCount")

        let context = persistence.viewContext
        let stats = CDUserStats.getOrCreate(context: context)
        stats.totalListeningSeconds = totalSeconds
        stats.tracksPlayedCount = Int32(tracksCount)
        stats.lastUpdated = Date()

        do {
            try context.save()
            print("✅ Migrated listening stats: \(Int(totalSeconds / 3600))h, \(tracksCount) tracks")
        } catch {
            print("❌ Failed to save listening stats: \(error)")
        }
    }

    private func migrateRecentlyPlayed() {
        print("🔄 Migrating recently played...")

        // Load recently played from UserDefaults
        guard let data = defaults.data(forKey: "recentlyPlayed"),
              let recentTracks = try? JSONDecoder().decode([RecentTrack].self, from: data) else {
            print("⚠️ No recently played to migrate")
            return
        }

        let context = persistence.viewContext
        var migratedCount = 0

        for recentTrack in recentTracks {
            // Check if track exists
            let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
            request.predicate = NSPredicate(format: "videoId == %@", recentTrack.videoId)

            let track: CDTrack
            if let existing = try? context.fetch(request).first {
                track = existing
            } else {
                // Create track
                track = CDTrack(context: context)
                track.videoId = recentTrack.videoId
                track.title = recentTrack.title
                track.artists = recentTrack.artists
                track.album = recentTrack.album
                track.durationSeconds = Int32(recentTrack.durationSeconds)
                track.thumbnailURLs = recentTrack.thumbnails.map { $0.url.absoluteString }
                track.isExplicit = recentTrack.isExplicit
                track.videoType = recentTrack.videoType
                track.createdAt = recentTrack.playedAt
            }

            // Create play history entry
            let history = CDPlayHistory(context: context)
            history.track = track
            history.playedAt = recentTrack.playedAt
            history.progress = recentTrack.playbackProgress
            history.completed = recentTrack.playbackProgress >= 0.9

            migratedCount += 1
        }

        do {
            try context.save()
            print("✅ Migrated \(migratedCount) recently played tracks")
        } catch {
            print("❌ Failed to save recently played: \(error)")
        }
    }

    // MARK: - Reset Migration

    func resetMigration() {
        defaults.removeObject(forKey: Keys.migrationCompleted)
        defaults.removeObject(forKey: Keys.migrationVersion)
        print("🔄 Migration reset - will run again on next launch")
    }
}
