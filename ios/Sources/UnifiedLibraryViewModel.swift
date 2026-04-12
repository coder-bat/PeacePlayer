//
//  UnifiedLibraryViewModel.swift
//  PeacePlayer
//
//  Unified library view model aggregating tracks from all sources
//

import Foundation
import Combine

// MARK: - Library Source Filter

enum LibrarySourceFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case downloads = "Downloads"
    case plex = "Plex"
    case liked = "Liked"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "music.note"
        case .downloads: return "arrow.down.circle"
        case .plex: return "server.rack"
        case .liked: return "heart.fill"
        }
    }
}

// MARK: - View Model

@MainActor
class UnifiedLibraryViewModel: ObservableObject {
    // MARK: - Published Properties

    @Published var tracks: [UnifiedTrack] = []
    @Published var filteredTracks: [UnifiedTrack] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var sourceFilter: LibrarySourceFilter = .all
    @Published var searchQuery = ""
    @Published var sortOption: LibrarySortOption = .recentlyAdded

    @Published var totalSize: Int64 = 0
    @Published var trackCount: Int = 0

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private let registry = MusicSourceRegistry.shared
    private var allTracks: [UnifiedTrack] = []

    // MARK: - Computed Properties

    var availableSources: [LibrarySourceFilter] {
        var sources: [LibrarySourceFilter] = [.all]

        // Check if we have downloaded tracks
        if hasDownloadedTracks {
            sources.append(.downloads)
        }

        // Check if Plex is connected
        if registry.hasPlexSource {
            sources.append(.plex)
        }

        // Always add liked
        sources.append(.liked)

        return sources
    }

    var hasDownloadedTracks: Bool {
        allTracks.contains { $0.source.isDownloaded }
    }

    var totalSizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }

    // MARK: - Initialization

    init() {
        setupBindings()
    }

    private func setupBindings() {
        // React to filter changes
        $sourceFilter
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyFilters()
            }
            .store(in: &cancellables)

        // React to search query changes
        $searchQuery
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyFilters()
            }
            .store(in: &cancellables)

        // React to sort option changes
        $sortOption
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySorting()
            }
            .store(in: &cancellables)

        // React to registry changes (Plex auth state)
        registry.$sources
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadLibrary()
            }
            .store(in: &cancellables)
    }

    // MARK: - Data Loading

    func loadLibrary() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                // Load from all sources
                allTracks = await registry.allTracksFromAllSources()

                // Calculate stats (for downloaded tracks)
                calculateStats()

                // Apply initial filters
                applyFilters()

                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    // MARK: - Filtering

    private func applyFilters() {
        var filtered = allTracks

        // Apply source filter
        switch sourceFilter {
        case .all:
            // Show all tracks
            break
        case .downloads:
            filtered = filtered.filter { $0.source.isDownloaded }
        case .plex:
            filtered = filtered.filter { $0.source.isPlex }
        case .liked:
            // For liked tracks, we'd need to check Core Data
            // For now, filter to local YouTube tracks that are liked
            filtered = filtered.filter { track in
                if case .youtube = track.source {
                    // Check if liked in DataManager
                    return DataManager.shared.isLiked(trackId: track.id)
                }
                return false
            }
        }

        // Apply search query
        if !searchQuery.isEmpty {
            let query = searchQuery.lowercased()
            filtered = filtered.filter { track in
                track.title.lowercased().contains(query) ||
                track.artist.lowercased().contains(query) ||
                track.album?.lowercased().contains(query) ?? false
            }
        }

        // Apply sorting
        filtered = sortTracks(filtered, by: sortOption)

        filteredTracks = filtered
        trackCount = filtered.count
    }

    private func applySorting() {
        applyFilters()
    }

    private func sortTracks(_ tracks: [UnifiedTrack], by option: LibrarySortOption) -> [UnifiedTrack] {
        switch option {
        case .recentlyAdded:
            // For downloaded tracks, sort by download date
            // For others, keep original order
            return tracks
        case .title:
            return tracks.sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .artist:
            return tracks.sorted {
                let artist1 = $0.artist.lowercased()
                let artist2 = $1.artist.lowercased()
                if artist1 == artist2 {
                    return $0.title.lowercased() < $1.title.lowercased()
                }
                return artist1 < artist2
            }
        case .size:
            // Size sorting only makes sense for downloaded tracks
            // For others, use duration as proxy
            return tracks.sorted { $0.duration > $1.duration }
        }
    }

    // MARK: - Stats

    private func calculateStats() {
        // Calculate total size for downloaded tracks
        totalSize = allTracks.compactMap { track -> Int64? in
            if case .local(let path) = track.source {
                // Try to get file size
                let url = URL(fileURLWithPath: path)
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attributes[.size] as? Int64 {
                    return size
                }
            }
            return nil
        }.reduce(0, +)
    }

    // MARK: - Playback

    func playTrack(_ track: UnifiedTrack) {
        Task {
            do {
                let queueItem = try await track.generateQueueItem()
                PlayerState.shared.play(item: queueItem)
            } catch {
                ErrorHandler.shared.show(.playbackError(error.localizedDescription))
            }
        }
    }

    func playNext(_ track: UnifiedTrack) {
        Task {
            do {
                let queueItem = try await track.generateQueueItem()
                PlayerState.shared.insertNext(queueItem)
                HapticManager.light()
            } catch {
                ErrorHandler.shared.show(.playbackError(error.localizedDescription))
            }
        }
    }

    func addToQueue(_ track: UnifiedTrack) {
        Task {
            do {
                let queueItem = try await track.generateQueueItem()
                PlayerState.shared.addToQueue(queueItem)
                HapticManager.success()
            } catch {
                ErrorHandler.shared.show(.playbackError(error.localizedDescription))
            }
        }
    }

    // MARK: - Track Operations

    func isCurrentlyPlaying(_ track: UnifiedTrack) -> Bool {
        guard let currentItem = PlayerState.shared.currentItem else { return false }
        return currentItem.track.videoId == track.id
    }

    func deleteTrack(_ track: UnifiedTrack) {
        // Only allow deletion for local tracks
        guard case .local(let path) = track.source else { return }

        do {
            try FileManager.default.removeItem(atPath: path)

            // Remove from Core Data
            let context = PersistenceController.shared.container.viewContext
            let fetchRequest = CDDownloadedTrack.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "localPath == %@", path)

            if let downloaded = try context.fetch(fetchRequest).first {
                context.delete(downloaded)
                try context.save()
            }

            // Reload
            loadLibrary()
        } catch {
            ErrorHandler.shared.show(.generic(error.localizedDescription))
        }
    }

    func clearLibrary() {
        // Delete all downloaded tracks
        for track in allTracks where track.source.isDownloaded {
            deleteTrack(track)
        }
    }
}

// MARK: - Error Types

enum UnifiedLibraryError: Error {
    case trackNotAvailable
    case playbackFailed
    case deletionFailed
}
