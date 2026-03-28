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
    
    enum CodingKeys: String, CodingKey {
        case streamUrl
        case mimeType
        case bitrate
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
    
    enum CodingKeys: String, CodingKey {
        case status
        case filePath
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
