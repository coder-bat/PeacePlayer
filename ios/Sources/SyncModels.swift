import Foundation
import CryptoKit

/// Wire dates are Unix seconds, independent of Foundation's Codable Date epoch.
struct SyncPlaylist: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var trackIds: [String]
    var modifiedAt: Double
    var createdAt: Double?
    var description: String?
    var isSmart: Bool?
    var smartCriteria: SmartCriteria?
    var artworkSeed: Int?
    var thumbnailURL: String?

    init(_ playlist: Playlist) {
        id = playlist.id.uuidString.lowercased()
        name = playlist.name
        trackIds = playlist.trackIds
        modifiedAt = playlist.modifiedAt.timeIntervalSince1970
        createdAt = playlist.createdAt.timeIntervalSince1970
        description = playlist.description
        isSmart = playlist.isSmart
        smartCriteria = playlist.smartCriteria
        artworkSeed = playlist.artworkSeed
        thumbnailURL = playlist.thumbnailURL
    }

    func playlist() throws -> Playlist {
        guard let uuid = UUID(uuidString: id) else { throw SyncValidationError.invalidPlaylist }
        var result = Playlist(id: uuid, name: name, description: description, trackIds: trackIds,
            createdAt: Date(timeIntervalSince1970: createdAt ?? modifiedAt),
            modifiedAt: Date(timeIntervalSince1970: modifiedAt), isSmart: isSmart ?? false,
            smartCriteria: smartCriteria, thumbnailURL: thumbnailURL)
        result.artworkSeed = artworkSeed ?? 1
        return result
    }
}

struct SyncHistoryEvent: Codable, Equatable, Identifiable {
    var id: String
    var videoId: String
    var playedAt: Double
    var progress: Double
    var completed: Bool

    /// Legacy events have no UUID. Full precision timestamps preserve distinct listens.
    static func legacyID(videoId: String, playedAt: Double) -> String {
        let micros = playedAt.isFinite && abs(playedAt) < 9_000_000_000_000 ? Int64(playedAt * 1_000_000) : 0
        return SyncMerge.stableID("history|\(videoId)|\(micros)")
    }
}

struct SyncSnapshot: Codable, Equatable {
    var playlists: [SyncPlaylist] = []
    var favorites: [String] = []
    var favoriteArtists: [String] = []
    var tracks: [Track] = []
    var history: [SyncHistoryEvent] = []

    var hasUserData: Bool {
        !playlists.filter { $0.isSmart != true }.isEmpty || !favorites.isEmpty ||
        !favoriteArtists.isEmpty || !history.isEmpty
    }

    func validated() throws -> Self {
        guard Set(playlists.map { $0.id.lowercased() }).count == playlists.count,
              Set(history.map(\.id)).count == history.count,
              Set(tracks.map(\.videoId)).count == tracks.count,
              playlists.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.modifiedAt.isFinite &&
                  ($0.createdAt?.isFinite ?? true) && $0.trackIds.allSatisfy { !$0.isEmpty } }),
              history.allSatisfy({ !$0.id.isEmpty && !$0.videoId.isEmpty && $0.playedAt.isFinite &&
                  $0.progress.isFinite && (0...1).contains($0.progress) }),
              tracks.allSatisfy({ !$0.videoId.isEmpty && $0.durationSeconds >= 0 }),
              favorites.allSatisfy({ !$0.isEmpty }) else { throw SyncValidationError.invalidSnapshot }
        return self
    }
}

struct SyncEnvelope: Codable, Equatable {
    var schemaVersion: Int
    var revision: Int
    var exists: Bool
    var snapshot: SyncSnapshot
    var migratedFromSchemaVersion: Int?

    func validated() throws -> Self {
        guard schemaVersion == 2 else { throw SyncValidationError.unsupportedVersion }
        guard revision >= 0, exists || snapshot == SyncSnapshot() else {
            throw SyncValidationError.invalidSnapshot
        }
        _ = try snapshot.validated()
        return self
    }
}

struct SyncUpload: Encodable {
    let schemaVersion: Int = 2
    var baseRevision: Int
    var operationId: String
    var snapshot: SyncSnapshot
}

enum SyncValidationError: LocalizedError {
    case unsupportedVersion, invalidSnapshot, invalidPlaylist
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "Update the app and backend to use this backup version."
        case .invalidSnapshot, .invalidPlaylist: return "The backup could not be read safely. Your saved library has been preserved."
        }
    }
}

/// Three-way snapshot merge: absence only means deletion when a baseline exists.
enum SyncMerge {
    static func merge(base: SyncSnapshot?, local: SyncSnapshot, remote: SyncSnapshot) throws -> SyncSnapshot {
        _ = try local.validated()
        _ = try remote.validated()
        if let base { _ = try base.validated() }
        var playlists: [SyncPlaylist] = []
        let b = dictionary(base?.playlists ?? [], key: { $0.id.lowercased() })
        let l = dictionary(local.playlists, key: { $0.id.lowercased() })
        let r = dictionary(remote.playlists, key: { $0.id.lowercased() })
        for id in Set(b.keys).union(l.keys).union(r.keys).sorted() {
            let original = b[id], left = l[id], right = r[id]
            if left == right { if let left { playlists.append(left) }; continue }
            if left == original { if let right { playlists.append(right) }; continue }
            if right == original { if let left { playlists.append(left) }; continue }
            // Both sides changed. Keep the server identity and a deterministic local copy.
            if let right { playlists.append(right) }
            if var left {
                left.id = stableID("conflict|\(id)|\(canonical(left))")
                left.name += " (Recovered conflict)"
                playlists.append(left)
            }
        }
        // A prior retry may already contain the deterministic conflict copy.
        playlists = Array(dictionary(playlists, key: { $0.id.lowercased() }).values).sorted { $0.id < $1.id }
        return SyncSnapshot(playlists: playlists,
            favorites: mergeSet(base?.favorites, local.favorites, remote.favorites),
            favoriteArtists: mergeArtists(base?.favoriteArtists, local.favoriteArtists, remote.favoriteArtists),
            tracks: mergeRecords(base?.tracks, local.tracks, remote.tracks, key: \.videoId),
            history: mergeRecords(base?.history, local.history, remote.history, key: \.id))
    }

    private static func mergeSet(_ base: [String]?, _ local: [String], _ remote: [String]) -> [String] {
        let b = Set(base ?? []), l = Set(local), r = Set(remote)
        return l.union(r).subtracting(b.subtracting(l).union(b.subtracting(r))).sorted()
    }

    private static func mergeArtists(_ base: [String]?, _ local: [String], _ remote: [String]) -> [String] {
        let names = dictionary(local + remote, key: { $0.lowercased() })
        return mergeSet(base?.map { $0.lowercased() }, local.map { $0.lowercased() }, remote.map { $0.lowercased() })
            .compactMap { names[$0] }
    }

    private static func mergeRecords<T: Equatable>(_ base: [T]?, _ local: [T], _ remote: [T], key: (T) -> String) -> [T] {
        let b = dictionary(base ?? [], key: key), l = dictionary(local, key: key), r = dictionary(remote, key: key)
        return Set(b.keys).union(l.keys).union(r.keys).sorted().compactMap { id in
            if l[id] == r[id] { return l[id] }
            if l[id] == b[id] { return r[id] }
            if r[id] == b[id] { return l[id] }
            return r[id] ?? l[id]
        }
    }

    private static func dictionary<T>(_ items: [T], key: (T) -> String) -> [String: T] {
        Dictionary(items.map { (key($0), $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private static func canonical<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? ""
    }

    static func stableID(_ value: String) -> String {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }
}
