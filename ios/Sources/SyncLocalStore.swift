import Foundation
import CoreData

struct SyncOwner: Codable, Equatable {
    var origin: String
    var userId: String
    var key: String { SyncMerge.stableID(origin + "|" + userId) }
}

struct SavedSyncLibrary: Codable, Identifiable {
    var id: String = UUID().uuidString
    var owner: SyncOwner?
    var savedAt: Date = Date()
    var snapshot: SyncSnapshot
}

/// One recoverable control file coordinates Core Data and UserDefaults imports.
/// An interrupted import is replayed before another sync; it never authorizes an upload.
@MainActor
final class SyncLocalStore {
    struct Journal: Codable {
        var before: SyncSnapshot
        var target: SyncSnapshot
        var owner: SyncOwner
    }
    struct Control: Codable {
        var owner: SyncOwner?
        var baselines: [String: SyncSnapshot] = [:]
        var archives: [SavedSyncLibrary] = []
        var journal: Journal?
        var lastSuccess: Date?
        var legacyPlaylistsInventoried = false
    }
    private let file: URL
    private(set) var control: Control
    private let captureStore: () throws -> SyncSnapshot
    private let applyStore: (SyncSnapshot) throws -> Void
    private let inventoryLegacy: Bool

    init(file: URL, capture: @escaping () throws -> SyncSnapshot,
         apply: @escaping (SyncSnapshot) throws -> Void, inventoryLegacy: Bool = false) throws {
        self.file = file
        captureStore = capture
        applyStore = apply
        self.inventoryLegacy = inventoryLegacy
        if FileManager.default.fileExists(atPath: file.path) {
            control = try JSONDecoder().decode(Control.self, from: Data(contentsOf: file))
        } else {
            control = Control()
        }
    }

    static func live() throws -> SyncLocalStore {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("BackupRecovery", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try SyncLocalStore(file: directory.appendingPathComponent("control.json"),
            capture: { try captureLive() }, apply: { try applyLive($0) }, inventoryLegacy: true)
        return result
    }

    func capture() throws -> SyncSnapshot {
        var snapshot = try captureStore()
        // Legacy CDPlaylist was a separate, mostly unused store. Inventory once, preserving both copies.
        if !control.legacyPlaylistsInventoried, inventoryLegacy {
            let records = try PersistenceController.shared.viewContext.fetch(CDPlaylist.fetchRequest())
            for record in records {
                let old = Playlist(id: record.id, name: record.name ?? "Recovered playlist",
                    trackIds: (record.trackOrder as? [String]) ?? [], createdAt: record.createdAt,
                    modifiedAt: record.modifiedAt)
                let legacy = SyncPlaylist(old)
                if let current = snapshot.playlists.first(where: { $0.id == legacy.id }) {
                    if current.trackIds != legacy.trackIds || current.name != legacy.name {
                        var recovered = legacy
                        recovered.id = SyncMerge.stableID("legacy-playlist|" + legacy.id)
                        recovered.name += " (Recovered legacy copy)"
                        snapshot.playlists.append(recovered)
                    }
                } else { snapshot.playlists.append(legacy) }
            }
        }
        return try snapshot.validated()
    }

    func recoverIfNeeded() throws {
        guard let journal = control.journal else { return }
        try applyStore(journal.target)
        control.owner = journal.owner
        control.journal = nil
        try persist()
    }

    /// Save the previous owner's data before showing an account's own library.
    func prepare(owner: SyncOwner) throws -> SyncSnapshot {
        try recoverIfNeeded()
        let local = try capture()
        guard control.owner != owner else { return local }
        if local.hasUserData {
            control.archives.append(SavedSyncLibrary(owner: control.owner, snapshot: local))
            try persist()
        }
        // Even a previously known account starts from its last baseline; no other owner's data crosses.
        let own = control.baselines[owner.key] ?? SyncSnapshot()
        try apply(own, owner: owner)
        return own
    }

    func apply(_ snapshot: SyncSnapshot, owner: SyncOwner) throws {
        _ = try snapshot.validated()
        let before = try capture()
        control.journal = Journal(before: before, target: snapshot, owner: owner)
        try persist()
        // These synchronous writes run on MainActor; identity cannot change between them.
        try applyStore(snapshot)
        control.owner = owner
        control.legacyPlaylistsInventoried = true
        control.journal = nil
        try persist()
    }

    func markSynced(_ snapshot: SyncSnapshot, owner: SyncOwner) throws {
        control.baselines[owner.key] = snapshot
        control.lastSuccess = Date()
        try persist()
    }

    func importArchive(id: String, owner: SyncOwner) throws {
        guard let saved = control.archives.first(where: { $0.id == id }) else { return }
        let current = try prepare(owner: owner)
        let merged = try SyncMerge.merge(base: nil, local: saved.snapshot, remote: current)
        try apply(merged, owner: owner)
        // Keep archive recoverable after import as well; no automatic archive deletion.
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(control)
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Disk remains authoritative after a failed control update.
            if let saved = try? Data(contentsOf: file), let previous = try? JSONDecoder().decode(Control.self, from: saved) {
                control = previous
            }
            throw error
        }
    }

    static func captureLive(context: NSManagedObjectContext = PersistenceController.shared.viewContext) throws -> SyncSnapshot {
        let history = try context.fetch(CDPlayHistory.fetchRequest()).compactMap { record -> SyncHistoryEvent? in
            guard let track = record.track else { return nil }
            let date = record.playedAt.timeIntervalSince1970
            return SyncHistoryEvent(id: record.syncEventID ?? SyncHistoryEvent.legacyID(videoId: track.videoId, playedAt: date),
                videoId: track.videoId, playedAt: date, progress: min(1, max(0, record.progress)), completed: record.completed)
        }
        let playlists = PlaylistManager.shared.playlists.filter { !$0.isSmart }.map(SyncPlaylist.init)
        let favorites = Array(PlaylistManager.shared.likedTracks).sorted()
        let ids = Set(playlists.flatMap(\.trackIds) + favorites + history.map(\.videoId))
        var metadata = TrackStore.shared.tracks.filter { ids.contains($0.key) }
        let records = try context.fetch(CDTrack.fetchRequest())
        for record in records where ids.contains(record.videoId) && metadata[record.videoId] == nil {
            metadata[record.videoId] = record.toTrack
        }
        for id in ids where metadata[id] == nil {
            metadata[id] = Track(videoId: id, title: "Recovered track (\(id))", artists: [], album: "",
                durationSeconds: 0, thumbnails: [], isExplicit: false, videoType: "MUSIC_VIDEO_TYPE_ATV")
        }
        return SyncSnapshot(playlists: playlists, favorites: favorites,
            favoriteArtists: FavoriteArtistsManager.shared.getArtists(),
            tracks: Array(metadata.values).sorted { $0.videoId < $1.videoId }, history: history.sorted { $0.id < $1.id })
    }

    static func applyLive(_ snapshot: SyncSnapshot, persistence: PersistenceController = .shared) throws {
        let playlists = try snapshot.playlists.map { try $0.playlist() }
        var metadata = Dictionary(snapshot.tracks.map { ($0.videoId, $0) }, uniquingKeysWith: { _, last in last })
        // 2026-10-02: the server backfills placeholder metadata for any track it
        // cannot describe -- the legacy blob predates stored track metadata, so
        // its migration invents entries titled "Recovered track" purely to keep
        // the envelope valid. Taking the snapshot's copy verbatim let those
        // placeholders overwrite real local titles, artists and durations, and
        // the library filled up with "Recovered track" rows. Prefer our own
        // metadata whenever we have it; the placeholder is a last resort.
        for (id, track) in metadata where track.title.hasPrefix("Recovered track") {
            if let real = TrackStore.shared.getTrack(videoId: id) {
                metadata[id] = real
            }
        }
        let ids = Set(snapshot.playlists.flatMap(\.trackIds) + snapshot.favorites + snapshot.history.map(\.videoId))
        for id in ids where metadata[id] == nil {
            metadata[id] = TrackStore.shared.getTrack(videoId: id) ?? Track(videoId: id,
                title: "Recovered track (\(id))", artists: [], album: "", durationSeconds: 0,
                thumbnails: [], isExplicit: false, videoType: "MUSIC_VIDEO_TYPE_ATV")
        }
        let recent = snapshot.history.sorted { $0.playedAt > $1.playedAt }.reduce(into: [RecentTrack]()) { result, event in
            guard result.count < 50, !result.contains(where: { $0.videoId == event.videoId }),
                  let track = metadata[event.videoId] else { return }
            result.append(RecentTrack(videoId: track.videoId, title: track.title, artists: track.artists,
                album: track.album, durationSeconds: track.durationSeconds, thumbnails: track.thumbnails,
                isExplicit: track.isExplicit, videoType: track.videoType,
                playedAt: Date(timeIntervalSince1970: event.playedAt), playbackProgress: event.progress))
        }
        // Validate serialization before touching either persistence store.
        _ = try JSONEncoder().encode(playlists)
        _ = try JSONEncoder().encode(recent)
        _ = try JSONEncoder().encode(metadata)
        let context = persistence.container.newBackgroundContext()
        try context.performAndWait {
            let existing = try context.fetch(CDTrack.fetchRequest())
            var records = Dictionary(existing.map { ($0.videoId, $0) }, uniquingKeysWith: { first, _ in first })
            for track in metadata.values {
                let record = records[track.videoId] ?? CDTrack.from(track: track, context: context)
                record.title = track.title
                record.artists = track.artists
                record.album = track.album
                record.durationSeconds = Int32(clamping: track.durationSeconds)
                record.thumbnailURLs = track.thumbnails.map { $0.url.absoluteString }
                record.isExplicit = track.isExplicit
                record.videoType = track.videoType
                records[track.videoId] = record
            }
            for record in records.values { record.isLiked = snapshot.favorites.contains(record.videoId) }
            for old in try context.fetch(CDPlayHistory.fetchRequest()) { context.delete(old) }
            for event in snapshot.history {
                guard let track = records[event.videoId] else { throw SyncValidationError.invalidSnapshot }
                let history = CDPlayHistory.create(for: track, progress: event.progress,
                    completed: event.completed, context: context)
                history.playedAt = Date(timeIntervalSince1970: event.playedAt)
                history.syncEventID = event.id
            }
            try context.save()
        }
        let smart = PlaylistManager.shared.playlists.filter(\.isSmart)
        try PlaylistManager.shared.replaceFromBackup(playlists: smart + playlists.filter { !$0.isSmart }, favorites: snapshot.favorites)
        try FavoriteArtistsManager.shared.replaceFromBackup(snapshot.favoriteArtists)
        try DataManager.shared.replaceRecentFromBackup(recent)
        try TrackStore.shared.importBackupMetadata(Array(metadata.values))
        guard UserDefaults.standard.synchronize() else { throw CocoaError(.fileWriteUnknown) }
    }
}
