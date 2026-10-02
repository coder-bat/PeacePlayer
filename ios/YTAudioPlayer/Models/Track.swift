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
    // v1.8.5 / S18-SMALL-LARGE-THUMBNAILS: BE now returns an
    // explicit small (~120-240px) and large (~480-720px) URL
    // picked from the ytmusicapi list. Optional for backward
    // compat — old BE responses just leave these nil and the
    // iOS falls back to `thumbnails.last`.
    let thumbnailSmall: Thumbnail?
    let thumbnailLarge: Thumbnail?
    let isExplicit: Bool
    let videoType: String

    // v1.8.5: explicit memberwise init with defaults for the
    // new optional fields. This keeps the synthesized Codable
    // decoder working (decoder ignores default values) and lets
    // call sites construct a Track without specifying the new
    // fields. Five call sites were broken by the struct change:
    // PlayerState.swift:2059/2118/2195, AdaptiveWalkDJManager.swift:313,
    // AddToPlaylistSheet.swift:267, and the two test makeTrack
    // helpers. They all work again because of these defaults.
    init(
        videoId: String,
        title: String,
        artists: [String],
        album: String,
        durationSeconds: Int,
        thumbnails: [Thumbnail],
        thumbnailSmall: Thumbnail? = nil,
        thumbnailLarge: Thumbnail? = nil,
        isExplicit: Bool,
        videoType: String
    ) {
        self.videoId = videoId
        self.title = title
        self.artists = artists
        self.album = album
        self.durationSeconds = durationSeconds
        self.thumbnails = thumbnails
        self.thumbnailSmall = thumbnailSmall
        self.thumbnailLarge = thumbnailLarge
        self.isExplicit = isExplicit
        self.videoType = videoType
    }

    // v1.8.5: custom decoder so missing JSON fields default to
    // nil. Swift's auto-synthesized decoder requires the field
    // to be present (even if Optional) — without this, old BE
    // responses without thumbnailSmall/large would fail to
    // decode and the iOS app would silently show zero results.
    private enum CodingKeys: String, CodingKey {
        case videoId, title, artists, album, durationSeconds
        case thumbnails, thumbnailSmall, thumbnailLarge
        case isExplicit, videoType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try c.decode(String.self, forKey: .videoId)
        title = try c.decode(String.self, forKey: .title)
        artists = try c.decode([String].self, forKey: .artists)
        album = try c.decode(String.self, forKey: .album)
        durationSeconds = try c.decode(Int.self, forKey: .durationSeconds)
        thumbnails = try c.decode([Thumbnail].self, forKey: .thumbnails)
        thumbnailSmall = try c.decodeIfPresent(Thumbnail.self, forKey: .thumbnailSmall)
        thumbnailLarge = try c.decodeIfPresent(Thumbnail.self, forKey: .thumbnailLarge)
        isExplicit = try c.decode(Bool.self, forKey: .isExplicit)
        videoType = try c.decode(String.self, forKey: .videoType)
    }

    var id: String { videoId }

    var displayTitle: String { title }

    var displayArtist: String { artists.isEmpty ? "Unknown Artist" : artists.joined(separator: ", ") }

    var durationText: String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // v1.8.5 / S18-SMALL-LARGE-THUMBNAILS: prefer the small URL
    // for row cells (50pt @ 3x = 150px render), fall back to
    // the old `thumbnails.last` for old BE responses.
    var artworkURL: URL? {
        thumbnailSmall?.url ?? thumbnails.last?.url
    }

    // NEW: explicit full-res URL for detail views, share cards,
    // and the now-playing widget. Same fallback chain.
    var fullArtworkURL: URL? {
        thumbnailLarge?.url ?? thumbnails.last?.url
    }

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

    // 2026-10-02: the backend reads these from the file's own embedded tags
    // and its .id sidecar. They are optional so responses from an older backend
    // still decode; the filename-derived values below remain the fallback.
    let title: String?
    let artist: String?
    let album: String?
    let videoId: String?

    // Prefer the real embedded metadata. The filename convention is
    // inconsistent -- "21 Guns - Green Day" is Title-Artist but
    // "Coldplay - Paradise (Official Video) - Coldplay" is Artist-Title-Artist
    // -- so parsing it is a guess that silently produces wrong credits.
    var parsedTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        let components = filename.replacingOccurrences(of: ".m4a", with: "")
            .components(separatedBy: " - ")
        return components.first ?? filename
    }

    var parsedArtist: String {
        if let artist, !artist.trimmingCharacters(in: .whitespaces).isEmpty { return artist }
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
