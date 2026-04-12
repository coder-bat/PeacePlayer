//
//  UnifiedTrack.swift
//  PeacePlayer
//
//  Unified track protocol for seamless multi-source playback
//

import Foundation
import SwiftUI

// MARK: - Track Source

/// Represents the origin of a track in the system
enum TrackSource: Equatable, Hashable {
    case youtube
    case local(path: String)

    var displayName: String {
        switch self {
        case .youtube:
            return "YouTube"
        case .local:
            return "Downloaded"
        }
    }

    var iconName: String {
        switch self {
        case .youtube:
            return "play.rectangle.fill"
        case .local:
            return "arrow.down.circle.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .youtube:
            return .red
        case .local:
            return .green
        }
    }

    var isDownloaded: Bool {
        if case .local = self { return true }
        return false
    }

    // MARK: - Equatable

    static func == (lhs: TrackSource, rhs: TrackSource) -> Bool {
        switch (lhs, rhs) {
        case (.youtube, .youtube):
            return true
        case (.local(let lhsPath), .local(let rhsPath)):
            return lhsPath == rhsPath
        default:
            return false
        }
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        switch self {
        case .youtube:
            hasher.combine("youtube")
        case .local(let path):
            hasher.combine("local")
            hasher.combine(path)
        }
    }
}

// MARK: - Playable Protocol

/// Protocol for any content that can be played in PeacePlayer
protocol Playable: Identifiable {
    var id: String { get }
    var title: String { get }
    var artist: String { get }
    var album: String? { get }
    var duration: TimeInterval { get }
    var artworkURL: URL? { get }
    var source: TrackSource { get }
    var isExplicit: Bool { get }

    /// Generate a QueueItem for playback
    func generateQueueItem() async throws -> QueueItem

    /// Check if this track is available offline
    var isAvailableOffline: Bool { get }
}

// MARK: - Unified Track

/// A concrete implementation of Playable that wraps any source
struct UnifiedTrack: Playable, Equatable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval
    let artworkURL: URL?
    let source: TrackSource
    let isExplicit: Bool

    // Source-specific data
    let youtubeVideoId: String?
    let localFilePath: String?

    // Playback generation closure (avoids storing heavy objects)
    private let queueItemGenerator: (() async throws -> QueueItem)?

    init(
        id: String,
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval,
        artworkURL: URL? = nil,
        source: TrackSource,
        isExplicit: Bool = false,
        youtubeVideoId: String? = nil,
        localFilePath: String? = nil,
        queueItemGenerator: (() async throws -> QueueItem)? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.source = source
        self.isExplicit = isExplicit
        self.youtubeVideoId = youtubeVideoId
        self.localFilePath = localFilePath
        self.queueItemGenerator = queueItemGenerator
    }

    func generateQueueItem() async throws -> QueueItem {
        if let generator = queueItemGenerator {
            return try await generator()
        }

        // Fallback: create basic QueueItem based on source
        switch source {
        case .youtube:
            guard let videoId = youtubeVideoId else {
                throw UnifiedTrackError.missingSourceData
            }
            return try await generateYouTubeQueueItem(videoId: videoId)

        case .local(let path):
            return generateLocalQueueItem(path: path)
        }
    }

    var isAvailableOffline: Bool {
        if case .local = source { return true }
        return false
    }

    // MARK: - Convenience Factory Methods

    static func fromYouTube(track: Track) -> UnifiedTrack {
        UnifiedTrack(
            id: track.videoId,
            title: track.title,
            artist: track.displayArtist,
            album: track.album,
            duration: TimeInterval(track.durationSeconds ?? 0),
            artworkURL: track.artworkURL,
            source: .youtube,
            isExplicit: track.isExplicit,
            youtubeVideoId: track.videoId,
            queueItemGenerator: {
                return try await generateYouTubeQueueItem(for: track)
            }
        )
    }

    static func fromDownloaded(track: CDTrack, downloaded: CDDownloadedTrack) -> UnifiedTrack {
        UnifiedTrack(
            id: track.videoId ?? "",
            title: track.title ?? "Unknown",
            artist: track.artists?.first ?? "Unknown Artist",
            album: track.album,
            duration: TimeInterval(track.duration),
            artworkURL: track.thumbnailURL,
            source: .local(path: downloaded.localPath ?? ""),
            isExplicit: track.isExplicit,
            localFilePath: downloaded.localPath,
            queueItemGenerator: {
                let trackModel = track.toTrack
                return QueueItem(
                    track: trackModel,
                    streamUrl: downloaded.localPath ?? "",
                    source: .local(path: downloaded.localPath ?? "")
                )
            }
        )
    }

    static func fromCoreData(track: CDTrack) -> UnifiedTrack {
        UnifiedTrack(
            id: track.videoId ?? "",
            title: track.title ?? "Unknown",
            artist: track.artists?.first ?? "Unknown Artist",
            album: track.album,
            duration: TimeInterval(track.duration),
            artworkURL: track.thumbnailURL,
            source: .youtube, // Assume YouTube for legacy tracks
            isExplicit: track.isExplicit,
            youtubeVideoId: track.videoId
        )
    }

    // MARK: - Equatable & Hashable

    static func == (lhs: UnifiedTrack, rhs: UnifiedTrack) -> Bool {
        lhs.id == rhs.id && lhs.source == rhs.source
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(source)
    }
}

// MARK: - Errors

enum UnifiedTrackError: Error {
    case missingSourceData
    case streamUrlGenerationFailed
    case playbackNotAvailable
}

// MARK: - Private Helpers

private func generateYouTubeQueueItem(for track: Track) async throws -> QueueItem {
    return try await withCheckedThrowingContinuation { continuation in
        APIService.shared.getStreamUrl(videoId: track.videoId)
            .sink(
                receiveCompletion: { completion in
                    if case .failure(let error) = completion {
                        continuation.resume(throwing: error)
                    }
                },
                receiveValue: { streamInfo in
                    let item = QueueItem(
                        track: track,
                        streamUrl: streamInfo.streamUrl,
                        source: .stream
                    )
                    continuation.resume(returning: item)
                }
            )
            .store(in: &Set<AnyCancellable>())
    }
}

private func generateYouTubeQueueItem(videoId: String) async throws -> QueueItem {
    // First fetch track info, then stream URL
    throw UnifiedTrackError.playbackNotAvailable
}

private func generateLocalQueueItem(path: String) -> QueueItem {
    // Create a basic track for local file
    let track = Track(
        videoId: "local_\(path.hashValue)",
        title: (path as NSString).lastPathComponent,
        artists: ["Unknown Artist"],
        album: nil,
        durationSeconds: 0,
        thumbnails: [],
        isExplicit: false,
        videoType: "music"
    )

    return QueueItem(
        track: track,
        streamUrl: path,
        source: .local(path: path)
    )
}

// MARK: - Extensions

extension Track {
    var toUnifiedTrack: UnifiedTrack {
        UnifiedTrack.fromYouTube(track: self)
    }
}

extension CDTrack {
    var toUnifiedTrack: UnifiedTrack {
        UnifiedTrack.fromCoreData(track: self)
    }
}
