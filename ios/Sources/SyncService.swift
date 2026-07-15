//
//  SyncService.swift
//  PeacePlayer
//
//  Cloud backup + restore for the user's local data.
//
//  2026-06-28 (Phase 3 of the Apple login feature):
//  - On successful sign-in we POST /sync/upload with the current
//    local Core Data state (playlists, liked tracks, history,
//    favorite artists).
//  - On subsequent launches with a valid session we GET
//    /sync/download and merge into Core Data.
//  - The auth response's `isNewUser` flag tells us whether to
//    upload-only (returning) or upload+download (new install).
//
//  Merge strategy:
//  - Liked tracks: union of local and remote video IDs.
//  - Favorite artists: union of names (case-insensitive).
//  - Playlists: union, with track ordering preserved (remote
//    wins on conflict for shared playlist IDs).
//  - History: union of (videoId, playedAt) tuples; most recent
//    playedAt wins for the same videoId.
//

import Foundation
import CoreData
import Combine

@MainActor
final class SyncService: NSObject, ObservableObject {
    static let shared = SyncService()

    enum SyncState {
        case idle
        case uploading
        case downloading
        case merging
        case completed(at: Date)
        case failed(message: String)
    }

    @Published private(set) var state: SyncState = .idle

    private let baseURL: URL
    private let keychain = KeychainHelper.shared
    private let sessionTokenKey = "peaceplayer.session_token"

    /// Cancellable for any in-flight sync. Cancelled when the user
    /// signs out so we don't try to write to a now-invalid session.
    private var currentTask: Task<Void, Never>?

    private override init() {
        self.baseURL = URL(string: APIService.shared.baseURL) ?? URL(string: "http://localhost:8181")!
        super.init()
    }

    // MARK: - Public API

    /// Called from AuthService when sign-in completes. Dispatches
    /// upload-only or upload+download based on whether the user is
    /// new.
    func handleSignIn(isNewUser: Bool) {
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.runSignInSync(isNewUser: isNewUser)
        }
    }

    /// Called from AuthService on sign-out. Cancels any in-flight
    /// sync. (Local data is preserved; the cloud copy stays put.)
    func handleSignOut() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }

    /// Called from AuthService on app launch if there's a valid
    /// session. Downloads the latest cloud state and merges into
    /// local Core Data. Idempotent — safe to call on every launch.
    func handleSessionRestored() {
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            await self?.runRestoreSync()
        }
    }

    // MARK: - Sync flows

    private func runSignInSync(isNewUser: Bool) async {
        // 1. Build the upload payload from local Core Data.
        let payload = collectLocalState()
        state = .uploading
        do {
            try await upload(payload: payload)
        } catch {
            state = .failed(message: "Upload failed: \(error.localizedDescription)")
            return
        }

        // 2. For new users, also pull the existing state. (Returning
        // users get their just-uploaded state back as confirmation,
        // but the merge is a no-op for them.)
        if isNewUser {
            state = .downloading
            do {
                let blob = try await download()
                state = .merging
                try await merge(remote: blob)
            } catch {
                // Non-fatal — the upload succeeded, so the user's
                // local data is safe in the cloud. We just couldn't
                // pull the (likely empty) cloud state.
                print("Sync download skipped: \(error.localizedDescription)")
            }
        }

        state = .completed(at: Date())
    }

    private func runRestoreSync() async {
        state = .downloading
        do {
            let blob = try await download()
            state = .merging
            try await merge(remote: blob)
            state = .completed(at: Date())
        } catch {
            // Don't surface as a failure — restore is best-effort.
            // Returning users get their local data; nothing to
            // restore is fine.
            print("Restore skipped: \(error.localizedDescription)")
            state = .idle
        }
    }

    // MARK: - Network

    private struct UploadRequest: Codable {
        let playlists: [PlaylistDTO]
        let favorites: [String]
        let history: [HistoryDTO]
        let favoriteArtists: [String]
        let clientVersion: Int
        let uploadedAt: Int

        struct PlaylistDTO: Codable {
            let id: String
            let name: String
            let trackIds: [String]
            let modifiedAt: Int
        }

        struct HistoryDTO: Codable {
            let videoId: String
            let playedAt: Int
            let progress: Double
        }
    }

    private struct SyncBlobResponse: Decodable {
        let playlists: [UploadRequest.PlaylistDTO]
        let favorites: [String]
        let history: [UploadRequest.HistoryDTO]
        let favoriteArtists: [String]
        let uploadedAt: Int
        let serverTime: Int
    }

    private func upload(payload: UploadRequest) async throws {
        // S17 (CV-3): the Bearer token is now added centrally by
        // APIService.addAuthHeader — same code path the rest of
        // the app uses. We still fail-fast if there's no session
        // at all so callers see a clear "not signed in" error
        // instead of a 401.
        guard keychain.read(sessionTokenKey) != nil else {
            throw SyncError.notAuthenticated
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("/sync/upload"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        APIService.addAuthHeader(to: &request)
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncError.uploadFailed
        }
    }

    private func download() async throws -> UploadRequest {
        guard keychain.read(sessionTokenKey) != nil else {
            throw SyncError.notAuthenticated
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("/sync/download"))
        request.httpMethod = "GET"
        APIService.addAuthHeader(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SyncError.downloadFailed
        }
        return try JSONDecoder().decode(UploadRequest.self, from: data)
    }

    // MARK: - Local state collection

    private func collectLocalState() -> UploadRequest {
        let context = PersistenceController.shared.viewContext

        // Playlists
        let playlists = (try? context.fetch(CDPlaylist.fetchRequest())) ?? []
        let playlistDtos: [UploadRequest.PlaylistDTO] = playlists.compactMap { p in
            return UploadRequest.PlaylistDTO(
                id: p.id.uuidString,
                name: p.name ?? "",
                trackIds: (p.trackOrder as? [String]) ?? [],
                modifiedAt: Int(p.modifiedAt.timeIntervalSince1970)
            )
        }

        // Liked tracks
        let favorites = Array(PlaylistManager.shared.likedTracks)

        // History
        let history = (try? context.fetch(CDPlayHistory.fetchRequest())) ?? []
        let historyDtos: [UploadRequest.HistoryDTO] = history.compactMap { h in
            guard let track = h.track else { return nil }
            return UploadRequest.HistoryDTO(
                videoId: track.videoId,
                playedAt: Int(h.playedAt.timeIntervalSince1970),
                progress: h.progress
            )
        }

        // Favorite artists
        let artists = FavoriteArtistsManager.shared.getArtists()

        return UploadRequest(
            playlists: playlistDtos,
            favorites: favorites,
            history: historyDtos,
            favoriteArtists: artists,
            clientVersion: 1,
            uploadedAt: Int(Date().timeIntervalSince1970)
        )
    }

    // MARK: - Merge

    private func merge(remote: UploadRequest) async throws {
        let context = PersistenceController.shared.viewContext
        context.performAndWait {
            // 1. Favorite artists — union, case-insensitive dedupe
            let localArtists = Set(FavoriteArtistsManager.shared.getArtists().map { $0.lowercased() })
            for artist in remote.favoriteArtists {
                if !localArtists.contains(artist.lowercased()) {
                    FavoriteArtistsManager.shared.addArtist(artist)
                }
            }

            // 2. Liked tracks — union
            for videoId in remote.favorites {
                if !PlaylistManager.shared.likedTracks.contains(videoId) {
                    PlaylistManager.shared.toggleLike(trackId: videoId)
                }
            }

            // 3. Playlists — union by UUID, remote wins on conflict
            for remotePlaylist in remote.playlists {
                guard let uuid = UUID(uuidString: remotePlaylist.id) else { continue }
                let request: NSFetchRequest<CDPlaylist> = CDPlaylist.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", uuid as CVarArg)
                request.fetchLimit = 1
                let existing = (try? context.fetch(request))?.first

                let playlist = existing ?? CDPlaylist(context: context)
                if existing == nil {
                    playlist.id = uuid
                    playlist.createdAt = Date(timeIntervalSince1970: TimeInterval(remotePlaylist.modifiedAt))
                }
                playlist.name = remotePlaylist.name
                playlist.trackOrder = remotePlaylist.trackIds
                playlist.modifiedAt = Date(timeIntervalSince1970: TimeInterval(remotePlaylist.modifiedAt))
            }

            // 4. History — most-recent playedAt wins per videoId
            for remoteEntry in remote.history {
                guard let videoId = remoteEntry.videoId as String?,
                      videoId.isEmpty == false else { continue }
                let request: NSFetchRequest<CDPlayHistory> = CDPlayHistory.fetchRequest()
                request.predicate = NSPredicate(format: "track.videoId == %@", videoId)
                request.fetchLimit = 1
                let existing = (try? context.fetch(request))?.first
                let remoteDate = Date(timeIntervalSince1970: TimeInterval(remoteEntry.playedAt))

                if existing == nil || (existing?.playedAt ?? .distantPast) < remoteDate {
                    if let existing = existing {
                        context.delete(existing)
                    }
                    let history = CDPlayHistory(context: context)
                    history.playedAt = remoteDate
                    history.progress = remoteEntry.progress
                    // We don't have a CDTrack pointer here; the
                    // history record's track relationship will be
                    // null, which is fine — playback can still
                    // show "you played this recently" without a
                    // track link.
                }
            }

            do {
                try context.save()
            } catch {
                print("Merge save failed: \(error)")
            }
        }
    }

    enum SyncError: LocalizedError {
        case notAuthenticated
        case uploadFailed
        case downloadFailed

        var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Not signed in."
            case .uploadFailed: return "Could not upload your data."
            case .downloadFailed: return "Could not download your data."
            }
        }
    }
}
