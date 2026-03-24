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
    @Published var tracks: [DownloadedTrackItem] = []
    @Published var sortOption: LibrarySortOption = .recentlyAdded
    @Published var showDeleteConfirmation = false
    @Published var isLoading = false

    private var cancellables = Set<AnyCancellable>()
    private let persistence = PersistenceController.shared

    var totalSize: Int64 {
        tracks.reduce(0) { $0 + $1.fileSize }
    }

    var totalSizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }

    var sortedTracks: [DownloadedTrackItem] {
        switch sortOption {
        case .recentlyAdded:
            return tracks.sorted { $0.downloadedAt > $1.downloadedAt }
        case .title:
            return tracks.sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .artist:
            return tracks.sorted { $0.artist.lowercased() < $1.artist.lowercased() }
        case .size:
            return tracks.sorted { $0.fileSize > $1.fileSize }
        }
    }

    /// Returns tracks filtered by search query
    func filteredTracks(searchQuery: String) -> [DownloadedTrackItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return sortedTracks
        }

        return sortedTracks.filter { track in
            track.title.lowercased().contains(query) ||
            track.artist.lowercased().contains(query) ||
            track.album.lowercased().contains(query)
        }
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

        do {
            let results = try persistence.viewContext.fetch(request)

            // Debug logging
            print("📚 Library fetch: \(results.count) downloaded track records found")
            for download in results {
                let trackInfo = download.track
                let fileExists = FileManager.default.fileExists(atPath: download.localPath)
                print("  - \(trackInfo?.title ?? "Unknown") (videoId: \(trackInfo?.videoId ?? "nil")) - File exists: \(fileExists)")
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
