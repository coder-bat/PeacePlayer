//
//  MusicSourceRegistry.swift
//  PeacePlayer
//
//  Central registry for managing all music sources (YouTube, Plex, Local)
//

import Foundation
import Combine

// MARK: - Music Source Protocol

protocol MusicSource {
    var id: String { get }
    var displayName: String { get }
    var isAvailable: Bool { get }
    var iconName: String { get }

    /// Search this source for tracks
    func search(query: String) async throws -> [UnifiedTrack]

    /// Get recently played tracks from this source
    func recentlyPlayed(limit: Int) async throws -> [UnifiedTrack]

    /// Get all tracks (for library view)
    func allTracks() async throws -> [UnifiedTrack]

    /// Get playlists from this source
    func playlists() async throws -> [UnifiedPlaylist]
}

// MARK: - Music Source Registry

/// Central singleton for managing all music sources
@MainActor
class MusicSourceRegistry: ObservableObject {
    static let shared = MusicSourceRegistry()

    // MARK: - Published Properties

    @Published private(set) var sources: [MusicSource] = []
    @Published private(set) var isLoading = false
    @Published var lastError: Error?

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init() {
        setupSources()
    }

    // MARK: - Source Management

    private func setupSources() {
        var newSources: [MusicSource] = []

        // Always add YouTube
        newSources.append(YouTubeSource())

        // Add local/downloads source
        newSources.append(LocalSource())

        sources = newSources
    }

    /// Refresh the list of available sources
    func refreshSources() {
        setupSources()
    }

    // MARK: - Aggregated Operations

    /// Search across all available sources
    func searchAll(query: String) async -> [SourceSearchResult] {
        guard !query.isEmpty else { return [] }

        isLoading = true
        defer { isLoading = false }

        var results: [SourceSearchResult] = []

        // Search all sources in parallel
        await withTaskGroup(of: SourceSearchResult?.self) { group in
            for source in sources where source.isAvailable {
                group.addTask {
                    do {
                        let tracks = try await source.search(query: query)
                        return SourceSearchResult(
                            sourceId: source.id,
                            sourceName: source.displayName,
                            sourceIcon: source.iconName,
                            tracks: tracks
                        )
                    } catch {
                        print("[MusicSourceRegistry] Search failed for \(source.id): \(error)")
                        return nil
                    }
                }
            }

            for await result in group {
                if let result = result {
                    results.append(result)
                }
            }
        }

        // Sort results: prioritize exact matches and local sources
        return results.sorted { lhs, rhs in
            // Local/Downloaded sources first
            let lhsIsLocal = lhs.sourceId == "local"
            let rhsIsLocal = rhs.sourceId == "local"
            if lhsIsLocal != rhsIsLocal { return lhsIsLocal }

            // Then by track count (more results = higher priority)
            return lhs.tracks.count > rhs.tracks.count
        }
    }

    /// Get recently played from all sources
    func recentlyPlayedFromAll(limit: Int = 20) async -> [UnifiedTrack] {
        var allTracks: [UnifiedTrack] = []

        await withTaskGroup(of: [UnifiedTrack].self) { group in
            for source in sources where source.isAvailable {
                group.addTask {
                    do {
                        return try await source.recentlyPlayed(limit: limit)
                    } catch {
                        return []
                    }
                }
            }

            for await tracks in group {
                allTracks.append(contentsOf: tracks)
            }
        }

        // Sort by most recent (if we had timestamps, we'd use them)
        // For now, interleave sources for variety
        return interleaveTracks(allTracks, limit: limit)
    }

    /// Get all tracks from all sources (for unified library)
    func allTracksFromAllSources() async -> [UnifiedTrack] {
        isLoading = true
        defer { isLoading = false }

        var allTracks: [UnifiedTrack] = []

        await withTaskGroup(of: [UnifiedTrack].self) { group in
            for source in sources where source.isAvailable {
                group.addTask {
                    do {
                        return try await source.allTracks()
                    } catch {
                        print("[MusicSourceRegistry] Failed to load tracks from \(source.id): \(error)")
                        return []
                    }
                }
            }

            for await tracks in group {
                allTracks.append(contentsOf: tracks)
            }
        }

        return allTracks
    }

    /// Get all playlists from all sources
    func allPlaylists() async -> [UnifiedPlaylist] {
        var allPlaylists: [UnifiedPlaylist] = []

        await withTaskGroup(of: [UnifiedPlaylist].self) { group in
            for source in sources where source.isAvailable {
                group.addTask {
                    do {
                        return try await source.playlists()
                    } catch {
                        return []
                    }
                }
            }

            for await playlists in group {
                allPlaylists.append(contentsOf: playlists)
            }
        }

        return allPlaylists
    }

    // MARK: - Helper Methods

    /// Get a specific source by ID
    func source(withId id: String) -> MusicSource? {
        sources.first { $0.id == id }
    }

    // MARK: - Private Helpers

    private func interleaveTracks(_ tracks: [UnifiedTrack], limit: Int) -> [UnifiedTrack] {
        // Group by source
        let grouped = Dictionary(grouping: tracks) { track in
            track.source.displayName
        }

        // Interleave: take one from each source in rotation
        var result: [UnifiedTrack] = []
        var indices: [String: Int] = [:]

        while result.count < limit {
            var addedInRound = 0

            for (sourceName, sourceTracks) in grouped.sorted(by: { $0.key < $1.key }) {
                let currentIndex = indices[sourceName, default: 0]
                guard currentIndex < sourceTracks.count else { continue }

                result.append(sourceTracks[currentIndex])
                indices[sourceName] = currentIndex + 1
                addedInRound += 1

                if result.count >= limit { break }
            }

            // Stop if no tracks added in a full round
            if addedInRound == 0 { break }
        }

        return Array(result.prefix(limit))
    }
}

// MARK: - Search Result

struct SourceSearchResult: Identifiable {
    let id = UUID()
    let sourceId: String
    let sourceName: String
    let sourceIcon: String
    let tracks: [UnifiedTrack]
}

// MARK: - Concrete Source Implementations

// MARK: YouTube Source

class YouTubeSource: MusicSource {
    let id = "youtube"
    let displayName = "YouTube"
    let iconName = "play.rectangle.fill"
    var isAvailable: Bool { true }

    func search(query: String) async throws -> [UnifiedTrack] {
        return try await withCheckedThrowingContinuation { continuation in
            APIService.shared.search(query: query, limit: 20)
                .sink(
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            continuation.resume(throwing: error)
                        }
                    },
                    receiveValue: { tracks in
                        let unified = tracks.map { $0.toUnifiedTrack }
                        continuation.resume(returning: unified)
                    }
                )
                .store(in: &Set<AnyCancellable>())
        }
    }

    func recentlyPlayed(limit: Int) async throws -> [UnifiedTrack] {
        // YouTube tracks don't have server-side history
        // Return from local DataManager
        let tracks = DataManager.shared.recentlyPlayed.map { $0.toTrack }
        return tracks.map { $0.toUnifiedTrack }
    }

    func allTracks() async throws -> [UnifiedTrack] {
        // YouTube doesn't have a "library" concept without user auth
        return []
    }

    func playlists() async throws -> [UnifiedPlaylist] {
        // YouTube playlists would require auth
        return []
    }
}

// MARK: Local/Downloaded Source

class LocalSource: MusicSource {
    let id = "local"
    let displayName = "Downloads"
    let iconName = "arrow.down.circle.fill"
    var isAvailable: Bool { true }

    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    func search(query: String) async throws -> [UnifiedTrack] {
        let context = persistence.container.viewContext
        let fetchRequest = CDTrack.fetchRequest()

        // Search in title, artist, or album
        fetchRequest.predicate = NSPredicate(
            format: "(title CONTAINS[cd] %@) OR (ANY artists CONTAINS[cd] %@) OR (album CONTAINS[cd] %@)",
            query, query, query
        )

        let tracks = try context.fetch(fetchRequest)

        // Filter to only downloaded tracks
        return tracks.compactMap { track -> UnifiedTrack? in
            guard let downloaded = track.downloaded else { return nil }
            return UnifiedTrack.fromDownloaded(track: track, downloaded: downloaded)
        }
    }

    func recentlyPlayed(limit: Int) async throws -> [UnifiedTrack] {
        // Get from Core Data play history for local tracks
        let context = persistence.container.viewContext
        let fetchRequest = CDPlayHistory.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "playedAt", ascending: false)]
        fetchRequest.fetchLimit = limit

        let history = try context.fetch(fetchRequest)

        return history.compactMap { historyItem -> UnifiedTrack? in
            guard let track = historyItem.track,
                  let downloaded = track.downloaded else { return nil }
            return UnifiedTrack.fromDownloaded(track: track, downloaded: downloaded)
        }
    }

    func allTracks() async throws -> [UnifiedTrack] {
        let context = persistence.container.viewContext
        let fetchRequest = CDDownloadedTrack.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "downloadedAt", ascending: false)]

        let downloaded = try context.fetch(fetchRequest)

        return downloaded.compactMap { item -> UnifiedTrack? in
            guard let track = item.track else { return nil }
            return UnifiedTrack.fromDownloaded(track: track, downloaded: item)
        }
    }

    func playlists() async throws -> [UnifiedPlaylist] {
        // Local playlists from Core Data
        let context = persistence.container.viewContext
        let fetchRequest = CDPlaylist.fetchRequest()

        let playlists = try context.fetch(fetchRequest)

        return playlists.map { playlist in
            UnifiedPlaylist(
                id: playlist.id ?? UUID().uuidString,
                name: playlist.name ?? "Untitled",
                trackCount: playlist.trackOrder?.count ?? 0,
                source: .local,
                artworkURL: nil,
                isEditable: true,
                loadTracks: {
                    guard let trackOrder = playlist.trackOrder else { return [] }
                    return trackOrder.compactMap { trackId -> UnifiedTrack? in
                        // Find track in Core Data
                        let fetchRequest = CDTrack.fetchRequest()
                        fetchRequest.predicate = NSPredicate(format: "videoId == %@", trackId as String)
                        fetchRequest.fetchLimit = 1
                        guard let track = try? context.fetch(fetchRequest).first,
                              let downloaded = track.downloaded else { return nil }
                        return UnifiedTrack.fromDownloaded(track: track, downloaded: downloaded)
                    }
                }
            )
        }
    }
}

