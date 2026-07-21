//
//  LibraryViewModel.swift
//  YTAudioPlayer
//
//  Library view model using Core Data
//

import Foundation
import Combine
import CoreData

struct DownloadedTrackItem: Identifiable {
    let id: String
    let videoId: String
    let title: String
    let artist: String
    let album: String
    let durationSeconds: Int
    let fileSize: Int64
    let fileSizeFormatted: String
    let downloadedAt: Date
    let localPath: String
    let thumbnailURL: URL?
    let track: Track

    init(from download: CDDownloadedTrack) {
        let cdTrack = download.track
        self.videoId = cdTrack?.videoId ?? ""
        self.id = videoId
        self.title = cdTrack?.title ?? "Unknown"
        self.artist = cdTrack?.displayArtist ?? "Unknown"
        self.album = cdTrack?.album ?? "Unknown"
        self.durationSeconds = Int(cdTrack?.durationSeconds ?? 0)
        self.fileSize = download.fileSize
        self.fileSizeFormatted = download.fileSizeFormatted
        self.downloadedAt = download.downloadedAt
        self.localPath = download.localPath
        self.thumbnailURL = cdTrack?.artworkURL
        self.track = cdTrack?.toTrack ?? Track(
            videoId: videoId,
            title: title,
            artists: [artist],
            album: album,
            durationSeconds: Int(cdTrack?.durationSeconds ?? 0),
            thumbnails: [],
            isExplicit: false,
            videoType: "UNKNOWN"
        )
    }
}

class LibraryViewModel: ObservableObject {
    @Published var tracks: [DownloadedTrackItem] = [] {
        didSet {
            _sortedCache = nil
            _filteredCache = nil
            // S17-G (perf 10 P0-F2): rebuild the search index
            // when the library changes. The build is O(n × tokens)
            // which is the same cost as a single linear scan, but
            // every subsequent search is O(query_tokens × matches)
            // instead of O(n).
            rebuildSearchIndex()
        }
    }
    @Published var sortOption: LibrarySortOption = .recentlyAdded {
        didSet { _sortedCache = nil; _filteredCache = nil }
    }
    @Published var showDeleteConfirmation = false
    @Published var isLoading = false

    private var cancellables = Set<AnyCancellable>()
    private let persistence = PersistenceController.shared
    private var _sortedCache: [DownloadedTrackItem]?
    private var _filteredCache: (query: String, result: [DownloadedTrackItem])?
    /// S17-G (perf 10 P0-F2): token → track-IDs index. Keys are
    /// lowercased, whitespace-split tokens from title + artist +
    /// album. Values are ALL track IDs that contain that token
    /// somewhere in those fields. A multi-token search intersects
    /// the value sets. We index IDs (not DownloadedTrackItem)
    /// because the struct doesn't conform to Hashable; the final
    /// mapping from IDs to items is O(n) once at the end of the
    /// search.
    ///
    /// Memory: ~10K tracks × 5 tokens × ~8 bytes/ID + dictionary
    /// overhead ≈ 1-2 MB. The token keys dominate; the dictionary
    /// deduplicates them, so we hold ~5-10K unique tokens.
    private var _searchIndex: [String: Set<String>] = [:]
    /// S17-G: track-ID → item map for O(1) resolution from the
    /// search index to the actual DownloadedTrackItem. Rebuilt
    /// on `tracks` didSet alongside the search index.
    private var _itemsById: [String: DownloadedTrackItem] = [:]

    var totalSize: Int64 {
        tracks.reduce(0) { $0 + $1.fileSize }
    }

    var totalSizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }

    var sortedTracks: [DownloadedTrackItem] {
        if let cached = _sortedCache { return cached }
        let sorted: [DownloadedTrackItem]
        switch sortOption {
        case .recentlyAdded:
            sorted = tracks.sorted { $0.downloadedAt > $1.downloadedAt }
        case .title:
            sorted = tracks.sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .artist:
            sorted = tracks.sorted { $0.artist.lowercased() < $1.artist.lowercased() }
        case .size:
            sorted = tracks.sorted { $0.fileSize > $1.fileSize }
        }
        _sortedCache = sorted
        return sorted
    }

    /// Returns tracks filtered by search query (cached per render cycle)
    func filteredTracks(searchQuery: String) -> [DownloadedTrackItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let cached = _filteredCache, cached.query == query {
            return cached.result
        }

        let result: [DownloadedTrackItem]
        if query.isEmpty {
            result = sortedTracks
        } else {
            // S17-G (perf 10 P0-F2): use the token index for
            // multi-token or longer queries. For very short
            // single-token queries (< 4 chars), the index only
            // has full words — fall back to a linear scan so
            // partial matches like "em" → "eminem" still work.
            let queryTokens = tokenize(query)
            if queryTokens.isEmpty {
                result = sortedTracks
            } else if queryTokens.count == 1, queryTokens[0].count < 4 {
                result = sortedTracks.filter { track in
                    let combined = "\(track.title) \(track.artist) \(track.album)".lowercased()
                    return combined.contains(queryTokens[0])
                }
            } else {
                // Token-index lookup with set intersection on
                // track IDs, then map back to items in sort order.
                var matches: Set<String>?
                for token in queryTokens {
                    guard let tokenMatches = _searchIndex[token], !tokenMatches.isEmpty else {
                        matches = []
                        break
                    }
                    if matches == nil {
                        matches = tokenMatches
                    } else {
                        matches!.formIntersection(tokenMatches)
                    }
                }
                let matchedIds = matches ?? []
                // Resolve IDs to items in the cached sort order
                // so the search results match the unfiltered list
                // order. firstIndex(of:) on `[String]` is O(n), but
                // we only do it for the matched subset, so total
                // cost is O(n) regardless of how many matched.
                let sortOrderIds = sortedTracks.map { $0.id }
                result = matchedIds
                    .sorted { sortOrderIds.firstIndex(of: $0) ?? Int.max < sortOrderIds.firstIndex(of: $1) ?? Int.max }
                    .compactMap { _itemsById[$0] }
            }
        }
        _filteredCache = (query, result)
        return result
    }

    // MARK: - Search index

    /// Tokenize a string into lowercased non-empty tokens.
    private func tokenize(_ s: String) -> [String] {
        s.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Rebuild the search index from the current `tracks`. Called
    /// on `tracks` didSet. Idempotent; safe to call multiple times.
    private func rebuildSearchIndex() {
        var index: [String: Set<String>] = [:]
        var byId: [String: DownloadedTrackItem] = [:]
        for track in tracks {
            byId[track.id] = track
            let tokens = Set(
                tokenize(track.title) +
                tokenize(track.artist) +
                tokenize(track.album)
            )
            for token in tokens {
                index[token, default: []].insert(track.id)
            }
        }
        _searchIndex = index
        _itemsById = byId
    }

    init() {
        loadLibrary()

        // Observe changes to DownloadManager
        DownloadManager.shared.$completedDownloads
            .sink { [weak self] _ in
                self?.loadLibrary()
            }
            .store(in: &cancellables)
    }

    func loadLibrary() {
        isLoading = true

        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDDownloadedTrack.downloadedAt, ascending: false)]
        request.fetchBatchSize = 50

        do {
            let results = try persistence.viewContext.fetch(request)

            // Debug logging — move file I/O off main thread
            let resultSnapshots = results.map { (title: $0.track?.title, videoId: $0.track?.videoId, path: $0.localPath) }
            let count = results.count
            Task.detached(priority: .utility) {
                print("📚 Library fetch: \(count) downloaded track records found")
                for info in resultSnapshots {
                    let fileExists = FileManager.default.fileExists(atPath: info.path)
                    print("  - \(info.title ?? "Unknown") (videoId: \(info.videoId ?? "nil")) - File exists: \(fileExists)")
                }
            }

            // Filter out records with missing files or invalid data
            tracks = results.compactMap { download in
                // Skip if no track relationship
                guard download.track != nil else {
                    print("⚠️ Skipping download with no track relationship: \(download.localPath)")
                    return nil
                }
                return DownloadedTrackItem(from: download)
            }

            print("✅ Loaded \(tracks.count) valid tracks into library")
            isLoading = false
        } catch {
            print("❌ Error loading library: \(error)")
            tracks = []
            isLoading = false
        }
    }

    func playTrack(_ track: DownloadedTrackItem) {
        let trackObj = track.track

        // Play using PlayerState's local-first method
        PlayerState.shared.play(track: trackObj)
    }

    func deleteTrackAt(_ offsets: IndexSet) {
        let tracksToDelete = offsets.map { sortedTracks[$0] }
        deleteTracks(tracksToDelete.map { $0.videoId })
    }

    func deleteTracks(_ videoIds: [String]) {
        for videoId in videoIds {
            DownloadManager.shared.deleteDownload(videoId: videoId)
        }

        // Refresh the library
        loadLibrary()

        // Update the Downloaded smart playlist
        updateDownloadedPlaylist()
    }

    func clearLibrary() {
        // Get all downloaded tracks
        let allVideoIds = tracks.map { $0.videoId }

        // Delete them all
        deleteTracks(allVideoIds)
    }

    func playNextTrack(_ track: DownloadedTrackItem) {
        let trackObj = track.track
        let localURL = AudioFileManager.shared.localFileURL(for: track.videoId)
        let item = QueueItem(
            track: trackObj,
            streamUrl: localURL.absoluteString,
            source: .local(path: localURL.path),
            contentSource: .local
        )
        PlayerState.shared.addToQueueNext(item)
    }

    func addToQueue(_ track: DownloadedTrackItem) {
        let trackObj = track.track
        let localURL = AudioFileManager.shared.localFileURL(for: track.videoId)
        let item = QueueItem(
            track: trackObj,
            streamUrl: localURL.absoluteString,
            source: .local(path: localURL.path),
            contentSource: .local
        )
        PlayerState.shared.addToQueue(item)
    }

    func isCurrentlyPlaying(_ track: DownloadedTrackItem) -> Bool {
        guard let currentItem = PlayerState.shared.currentItem else { return false }
        return currentItem.track.videoId == track.videoId
    }

    private func updateDownloadedPlaylist() {
        // Update the Downloaded smart playlist in PlaylistManager
        let downloadedIds = tracks.map { $0.videoId }
        PlaylistManager.shared.updateDownloadedPlaylist(with: downloadedIds)
    }
}
