//
//  Track.swift
//  YTAudioPlayer
//
//  Data models for track metadata
//

import Foundation

/// Represents a track from YouTube Music search
struct Track: Identifiable, Codable, Equatable {
    let videoId: String
    let title: String
    let artists: [String]
    let album: String
    let durationSeconds: Int
    let thumbnails: [Thumbnail]
    let isExplicit: Bool
    let videoType: String
    
    var id: String { videoId }
    
    var displayTitle: String { title }
    
    var displayArtist: String { artists.isEmpty ? "Unknown Artist" : artists.joined(separator: ", ") }
    
    var durationText: String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var artworkURL: URL? { thumbnails.last?.url }
    
    var isAudioTrack: Bool {
        videoType == "MUSIC_VIDEO_TYPE_ATV" || videoType == "MUSIC_VIDEO_TYPE_OMV"
    }
}

struct Thumbnail: Codable, Equatable {
    let url: URL
    let width: Int
    let height: Int
}

struct StreamInfo: Codable {
    let streamUrl: String
    let mimeType: String
    let bitrate: Int

    // S3-4: Replay Gain. Backend can populate this with the track gain in dB
    // extracted from the source's ReplayGain tags (e.g., via yt-dlp's
    // --print "%(replaygain_track_gain)s"). nil means "no data" — the
    // player falls back to user volume with no normalization. Negative
    // values (e.g., -7.5) attenuate; positive values (rare) boost.
    // Optional so older backend responses without the field still decode.
    let replayGain: Double?

    enum CodingKeys: String, CodingKey {
        case streamUrl
        case mimeType
        case bitrate
        case replayGain
    }

    init(streamUrl: String, mimeType: String, bitrate: Int, replayGain: Double? = nil) {
        self.streamUrl = streamUrl
        self.mimeType = mimeType
        self.bitrate = bitrate
        self.replayGain = replayGain
    }
}

struct LocalTrack: Codable, Identifiable {
    let id = UUID()
    let filename: String
    let path: String
    let size: Int
    let sizeHuman: String
    let modified: TimeInterval
    
    var parsedTitle: String {
        let components = filename.replacingOccurrences(of: ".m4a", with: "")
            .components(separatedBy: " - ")
        return components.first ?? filename
    }
    
    var parsedArtist: String {
        let components = filename.replacingOccurrences(of: ".m4a", with: "")
            .components(separatedBy: " - ")
        return components.count > 1 ? components[1] : "Unknown"
    }
}

struct DownloadResponse: Codable {
    let status: String
    let filePath: String
    // S17-H / DOWNLOAD-CDN-FIX (2026-08-08): server-side relative
    // URL the iOS app GETs to pull the converted M4A file. See
    // DownloadManager.performDownload for the iOS-side flow.
    let downloadUrl: String?

    enum CodingKeys: String, CodingKey {
        case status
        case filePath
        case downloadUrl
    }
}

struct SearchResponse: Codable {
    let results: [Track]
}

struct LibraryResponse: Codable {
    let tracks: [LocalTrack]
}

struct LyricsResponse: Codable {
    let lyrics: String
}

/// Represents a single line of lyrics with timestamp
struct LyricsLine: Identifiable, Codable {
    let id = UUID()
    let time: Double
    let text: String

    var timeFormatted: String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "[%02d:%02d]", minutes, seconds)
    }
}

// MARK: - Charts / New Releases Response Models

struct ChartsResponse: Codable {
    let tracks: [Track]
}

struct NewReleasesResponse: Codable {
    let tracks: [Track]
}
