//
//  Playlist.swift
//  YTAudioPlayer
//
//  Playlist data models and related types
//

import Foundation

/// Represents a user-created or smart playlist
struct Playlist: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var description: String?
    var trackIds: [String]  // Array of videoIds
    var createdAt: Date
    var modifiedAt: Date
    var isSmart: Bool
    var smartCriteria: SmartCriteria?
    var artworkSeed: Int  // For consistent artwork generation
    var thumbnailURL: String?  // Optional thumbnail URL (e.g., for cloned playlists)
    
    init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        trackIds: [String] = [],
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isSmart: Bool = false,
        smartCriteria: SmartCriteria? = nil,
        thumbnailURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.trackIds = trackIds
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isSmart = isSmart
        self.smartCriteria = smartCriteria
        self.artworkSeed = Int.random(in: 1...1000)
        self.thumbnailURL = thumbnailURL
    }
    
    var trackCount: Int {
        trackIds.count
    }
    
    var isEmpty: Bool {
        trackIds.isEmpty
    }
    
    /// Returns true if this is the special "Liked Songs" playlist
    var isLikedSongsPlaylist: Bool {
        smartCriteria?.type == .favorites
    }
}

/// Criteria for smart/auto-generated playlists
struct SmartCriteria: Codable, Equatable {
    let type: SmartPlaylistType
    var limit: Int?  // Maximum tracks (nil = unlimited)
    var sortBy: SmartSortOption
    
    init(type: SmartPlaylistType, limit: Int? = nil, sortBy: SmartSortOption = .default) {
        self.type = type
        self.limit = limit
        self.sortBy = sortBy
    }
}

/// Types of smart playlists
enum SmartPlaylistType: String, Codable, CaseIterable, Identifiable {
    case recentlyAdded = "Recently Added"
    case recentlyPlayed = "Recently Played"
    case mostPlayed = "Most Played"
    case favorites = "Liked Songs"
    case downloaded = "Downloaded"
    case neverPlayed = "Never Played"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .recentlyAdded: return "clock.badge.checkmark"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .mostPlayed: return "chart.bar.fill"
        case .favorites: return "heart.fill"
        case .downloaded: return "arrow.down.circle.fill"
        case .neverPlayed: return "play.slash"
        }
    }
    
    var color: String {
        switch self {
        case .recentlyAdded: return "FF6B6B"  // Red
        case .recentlyPlayed: return "4ECDC4" // Teal
        case .mostPlayed: return "FFD93D"     // Yellow
        case .favorites: return "FF1756"      // Pink
        case .downloaded: return "6BCB77"     // Green
        case .neverPlayed: return "9B59B6"    // Purple
        }
    }
    
    var defaultDescription: String {
        switch self {
        case .recentlyAdded:
            return "Tracks added to your library in the last 30 days"
        case .recentlyPlayed:
            return "Tracks you've listened to in the last 7 days"
        case .mostPlayed:
            return "Your most played tracks of all time"
        case .favorites:
            return "All tracks you've liked"
        case .downloaded:
            return "Tracks available offline"
        case .neverPlayed:
            return "Tracks in your library you've never listened to"
        }
    }
}

/// Sort options for smart playlists
enum SmartSortOption: String, Codable, CaseIterable {
    case `default` = "Default"
    case recentlyAdded = "Recently Added"
    case alphabetical = "Alphabetical"
    case artist = "Artist"
    
    var id: String { rawValue }
}

/// Represents a track's presence in a playlist (for detailed tracking)
struct PlaylistTrackInfo: Codable {
    let videoId: String
    let addedAt: Date
    let addedBy: String  // "user" or "system"
    var playCount: Int
    var lastPlayedAt: Date?
    
    init(videoId: String, addedAt: Date = Date(), addedBy: String = "user") {
        self.videoId = videoId
        self.addedAt = addedAt
        self.addedBy = addedBy
        self.playCount = 0
        self.lastPlayedAt = nil
    }
}

// MARK: - Playlist Export/Import

/// Structure for exporting playlists to JSON
struct PlaylistExport: Codable {
    let version: Int
    let exportedAt: Date
    let playlists: [Playlist]
    let likedTracks: [String]
    
    static let currentVersion = 1
}

// MARK: - YouTube Playlist (from search)

struct YouTubePlaylist: Identifiable, Codable {
    let playlistId: String
    let title: String
    let author: String
    let videoCount: Int
    let thumbnails: [Thumbnail]
    let description: String
    
    var id: String { playlistId }
    
    var artworkURL: URL? {
        thumbnails.last?.url
    }
}

struct YouTubePlaylistDetails: Codable {
    let playlistId: String
    let title: String
    let author: String
    let videoCount: Int
    let thumbnails: [Thumbnail]
    let description: String
    let tracks: [Track]
}

// MARK: - Album (from the backend's album search)

/// One album, as the backend's album search returns it.
///
/// The backend answers with YouTube Music's own album browse id
/// ("MPREb_..."), the album's title and year, and its cover art. The
/// tracks are not here — they come from `AlbumDetails` when the album
/// is opened.
struct Album: Identifiable, Codable, Equatable {
    /// YouTube Music's browse id for the album.
    let browseId: String
    let title: String
    /// The album's artists, without the type label YouTube Music puts
    /// in front of them ("Album", "Single", "EP").
    let artists: [String]
    /// "1997" and the like; empty when the year is not known.
    let year: String
    /// "Album", "Single" or "EP".
    let type: String
    /// How many tracks the album has. Zero when the backend does not
    /// know yet — album search does not carry the count.
    let trackCount: Int
    let thumbnails: [Thumbnail]
    let thumbnailSmall: Thumbnail?
    let thumbnailLarge: Thumbnail?

    var id: String { browseId }

    /// The cover for a shelf-sized card.
    var artworkURL: URL? {
        thumbnailSmall?.url ?? thumbnails.last?.url
    }

    /// The cover at full size, for a detail card.
    var fullArtworkURL: URL? {
        thumbnailLarge?.url ?? thumbnails.last?.url
    }

    private enum CodingKeys: String, CodingKey {
        case browseId, title, artists, year, type, trackCount
        case thumbnails, thumbnailSmall, thumbnailLarge
    }

    /// The memberwise initializer, written out because the custom
    /// decoder below suppresses Swift's own.
    init(
        browseId: String,
        title: String,
        artists: [String],
        year: String,
        type: String,
        trackCount: Int,
        thumbnails: [Thumbnail],
        thumbnailSmall: Thumbnail?,
        thumbnailLarge: Thumbnail?
    ) {
        self.browseId = browseId
        self.title = title
        self.artists = artists
        self.year = year
        self.type = type
        self.trackCount = trackCount
        self.thumbnails = thumbnails
        self.thumbnailSmall = thumbnailSmall
        self.thumbnailLarge = thumbnailLarge
    }

    /// Decoded leniently: a backend that does not know a field yet
    /// must not empty the whole shelf.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        browseId = try c.decode(String.self, forKey: .browseId)
        title = try c.decode(String.self, forKey: .title)
        artists = try c.decodeIfPresent([String].self, forKey: .artists) ?? []
        year = try c.decodeIfPresent(String.self, forKey: .year) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "Album"
        trackCount = try c.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0
        thumbnails = try c.decodeIfPresent([Thumbnail].self, forKey: .thumbnails) ?? []
        thumbnailSmall = try c.decodeIfPresent(Thumbnail.self, forKey: .thumbnailSmall)
        thumbnailLarge = try c.decodeIfPresent(Thumbnail.self, forKey: .thumbnailLarge)
    }
}

/// An album and the tracks on it.
struct AlbumDetails: Codable, Equatable {
    let browseId: String
    let title: String
    let artists: [String]
    let year: String
    let type: String
    let trackCount: Int
    let thumbnails: [Thumbnail]
    let thumbnailSmall: Thumbnail?
    let thumbnailLarge: Thumbnail?
    /// The album's tracks, in the order they run.
    let tracks: [Track]

    private enum CodingKeys: String, CodingKey {
        case browseId, title, artists, year, type, trackCount
        case thumbnails, thumbnailSmall, thumbnailLarge, tracks
    }

    /// The memberwise initializer, written out because the custom
    /// decoder below suppresses Swift's own.
    init(
        browseId: String,
        title: String,
        artists: [String],
        year: String,
        type: String,
        trackCount: Int,
        thumbnails: [Thumbnail],
        thumbnailSmall: Thumbnail?,
        thumbnailLarge: Thumbnail?,
        tracks: [Track]
    ) {
        self.browseId = browseId
        self.title = title
        self.artists = artists
        self.year = year
        self.type = type
        self.trackCount = trackCount
        self.thumbnails = thumbnails
        self.thumbnailSmall = thumbnailSmall
        self.thumbnailLarge = thumbnailLarge
        self.tracks = tracks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        browseId = try c.decode(String.self, forKey: .browseId)
        title = try c.decode(String.self, forKey: .title)
        artists = try c.decodeIfPresent([String].self, forKey: .artists) ?? []
        year = try c.decodeIfPresent(String.self, forKey: .year) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "Album"
        trackCount = try c.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0
        thumbnails = try c.decodeIfPresent([Thumbnail].self, forKey: .thumbnails) ?? []
        thumbnailSmall = try c.decodeIfPresent(Thumbnail.self, forKey: .thumbnailSmall)
        thumbnailLarge = try c.decodeIfPresent(Thumbnail.self, forKey: .thumbnailLarge)
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
    }
}

// MARK: - Default Playlists

extension Playlist {
    /// Creates the default "Liked Songs" smart playlist
    static func likedSongsPlaylist() -> Playlist {
        Playlist(
            name: "Liked Songs",
            description: "All tracks you've liked",
            isSmart: true,
            smartCriteria: SmartCriteria(type: .favorites, limit: nil, sortBy: .recentlyAdded)
        )
    }
    
    /// Creates the default smart playlists
    static func defaultSmartPlaylists() -> [Playlist] {
        [
            likedSongsPlaylist(),
            Playlist(
                name: "Recently Added",
                description: "Tracks added in the last 30 days",
                isSmart: true,
                smartCriteria: SmartCriteria(type: .recentlyAdded, limit: 50, sortBy: .recentlyAdded)
            ),
            Playlist(
                name: "Recently Played",
                description: "Tracks played in the last 7 days",
                isSmart: true,
                smartCriteria: SmartCriteria(type: .recentlyPlayed, limit: 50, sortBy: .default)
            ),
            Playlist(
                name: "Most Played",
                description: "Your top tracks",
                isSmart: true,
                smartCriteria: SmartCriteria(type: .mostPlayed, limit: 50, sortBy: .default)
            ),
            Playlist(
                name: "Downloaded",
                description: "Available offline",
                isSmart: true,
                smartCriteria: SmartCriteria(type: .downloaded, limit: nil, sortBy: .alphabetical)
            ),
        ]
    }
}
