//
//  SharedNowPlayingState.swift
//  YTAudioPlayer
//
//  Shared data layer between main app and widget extension.
//  Uses App Group UserDefaults for cross-process state.
//  Uses Darwin notifications for real-time control commands.
//

import Foundation

// MARK: - Widget Kind Constants

enum WidgetKind {
    static let nowPlaying       = "PeacePlayerNowPlaying"
    static let nowPlayingFull   = "PeacePlayerNowPlayingFull"
    static let resume           = "PeacePlayerResume"
    static let shuffleFavorites = "PeacePlayerShuffleFavorites"
    static let playlists        = "PeacePlayerPlaylists"
}

// MARK: - Darwin Notification Names (cross-process IPC)

enum DarwinCmd {
    static let playPause    = "com.peaceplayer.cmd.playPause"
    static let skipNext     = "com.peaceplayer.cmd.skipNext"
    static let skipPrevious = "com.peaceplayer.cmd.skipPrevious"
    static let seekForward  = "com.peaceplayer.cmd.seekForward"
    static let seekBackward = "com.peaceplayer.cmd.seekBackward"
    static let volumeUp     = "com.peaceplayer.cmd.volumeUp"
    static let volumeDown   = "com.peaceplayer.cmd.volumeDown"
    static let setVolume    = "com.peaceplayer.cmd.setVolume"
    static let executeShortcut = "com.peaceplayer.cmd.executeShortcut"
}

// MARK: - Snapshot Models (Codable for App Group UserDefaults)

struct NowPlayingSnapshot: Codable {
    let title: String
    let artist: String
    let artworkURLString: String
    let isPlaying: Bool
    let progress: Double   // 0.0–1.0
    let nextTitle: String
    let nextArtist: String
    let currentVolume: Float  // 0.0–1.0

    var hasContent: Bool    { !title.isEmpty }
    var hasNextTrack: Bool  { !nextTitle.isEmpty }
    var artworkURL: URL?    { URL(string: artworkURLString) }

    // Memberwise init with defaults for new fields (backwards-compatible callers)
    init(
        title: String,
        artist: String,
        artworkURLString: String,
        isPlaying: Bool,
        progress: Double,
        nextTitle: String = "",
        nextArtist: String = "",
        currentVolume: Float = 1.0
    ) {
        self.title = title
        self.artist = artist
        self.artworkURLString = artworkURLString
        self.isPlaying = isPlaying
        self.progress = progress
        self.nextTitle = nextTitle
        self.nextArtist = nextArtist
        self.currentVolume = currentVolume
    }

    // Backwards-compatible decoder: old snapshots won't have the new keys
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title            = try  c.decode(String.self, forKey: .title)
        artist           = try  c.decode(String.self, forKey: .artist)
        artworkURLString = try  c.decode(String.self, forKey: .artworkURLString)
        isPlaying        = try  c.decode(Bool.self,   forKey: .isPlaying)
        progress         = try  c.decode(Double.self, forKey: .progress)
        nextTitle        = (try? c.decodeIfPresent(String.self, forKey: .nextTitle))  ?? ""
        nextArtist       = (try? c.decodeIfPresent(String.self, forKey: .nextArtist)) ?? ""
        currentVolume    = (try? c.decodeIfPresent(Float.self,  forKey: .currentVolume)) ?? 1.0
    }

    static let empty = NowPlayingSnapshot(
        title: "", artist: "", artworkURLString: "", isPlaying: false, progress: 0
    )
}

struct WidgetPlaylist: Codable, Identifiable {
    let id: String       // UUID.uuidString
    let name: String
    let trackCount: Int
}

struct LibrarySnapshot: Codable {
    let likedTrackCount: Int
    let playlists: [WidgetPlaylist]   // first 6 non-smart playlists

    static let empty = LibrarySnapshot(likedTrackCount: 0, playlists: [])
}

struct ShortcutPlaybackCommand: Codable {
    enum Action: String, Codable {
        case shuffleLibrary
        case playRecentlyPlayed
        case playPlaylist
    }

    let action: Action
    let playlistName: String?
    let playlistId: String?

    static let shuffleLibrary = ShortcutPlaybackCommand(action: .shuffleLibrary, playlistName: nil, playlistId: nil)
    static let playRecentlyPlayed = ShortcutPlaybackCommand(action: .playRecentlyPlayed, playlistName: nil, playlistId: nil)

    static func playPlaylist(name: String, id: String? = nil) -> ShortcutPlaybackCommand {
        ShortcutPlaybackCommand(action: .playPlaylist, playlistName: name, playlistId: id)
    }
}

// MARK: - Shared State I/O

struct SharedNowPlayingState {

    static let appGroupID = "group.com.ytaudioplayer.shared"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? UserDefaults.standard
    }

    // MARK: Now Playing (main app writes, widget reads)

    static func update(snapshot: NowPlayingSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: "pp_snapshot")
    }

    static func read() -> NowPlayingSnapshot {
        guard let data = defaults.data(forKey: "pp_snapshot"),
              let snapshot = try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    // MARK: Library (main app writes, widget reads)

    static func updateLibrary(_ snapshot: LibrarySnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: "pp_library")
    }

    static func readLibrary() -> LibrarySnapshot {
        guard let data = defaults.data(forKey: "pp_library"),
              let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    // MARK: UserDefaults Command Fallback (widget → app, executed on foreground)

    enum Command: String {
        case playPause    = "playPause"
        case skipNext     = "skipNext"
        case skipPrevious = "skipPrevious"
    }

    static func writePendingCommand(_ command: Command) {
        defaults.set(command.rawValue, forKey: "pp_cmd")
    }

    static func readAndClearCommand() -> Command? {
        let d = defaults
        guard let raw = d.string(forKey: "pp_cmd"),
              let cmd = Command(rawValue: raw) else { return nil }
        d.removeObject(forKey: "pp_cmd")
        return cmd
    }

    // MARK: Shortcut Playback Command

    static func writePendingShortcutCommand(_ command: ShortcutPlaybackCommand) {
        guard let data = try? JSONEncoder().encode(command) else { return }
        defaults.set(data, forKey: "pp_shortcut_cmd")
    }

    static func readAndClearPendingShortcutCommand() -> ShortcutPlaybackCommand? {
        let d = defaults
        guard let data = d.data(forKey: "pp_shortcut_cmd"),
              let command = try? JSONDecoder().decode(ShortcutPlaybackCommand.self, from: data) else { return nil }
        d.removeObject(forKey: "pp_shortcut_cmd")
        return command
    }

    // MARK: Volume Level (widget tap-to-set; widget writes, app reads on Darwin signal)

    static func writePendingVolume(_ volume: Double) {
        defaults.set(volume, forKey: "pp_pendingVolume")
    }

    static func readAndClearPendingVolume() -> Double? {
        let d = defaults
        guard let v = d.object(forKey: "pp_pendingVolume") as? Double else { return nil }
        d.removeObject(forKey: "pp_pendingVolume")
        return v
    }

    // MARK: Darwin Notification (widget → app, immediate cross-process IPC)

    /// Post from the widget extension to signal the main app immediately.
    static func postDarwinNotification(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }
}
