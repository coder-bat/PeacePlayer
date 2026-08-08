//
//  StreamURLCache.swift
//  YTAudioPlayer
//
//  Caches stream URLs to reduce cold-start playback latency.
//  Modeled on ImageCache.swift.
//

import Foundation
import UIKit
import Combine
import CryptoKit

/// Caches stream URL metadata to memory and disk so playback can start
/// instantly when the user taps a track. Also provides a fire-and-forget
/// prefetch API that warms the backend cache before playback begins.
class StreamURLCache {
    static let shared = StreamURLCache()

    /// S17-G (perf 10 P0-F3): bound the in-memory cache.
    /// `setObject` calls below don't pass a `cost:` parameter, so
    /// `totalCostLimit` is a safety net (NSCache ignores
    /// totalCostLimit when costs aren't set). The real bound is
    /// `countLimit` — 200 covers a heavy listening session (the
    /// user is unlikely to play 200 unique tracks in one sitting)
    /// and is well above the 50-entry ceiling NowPlayingService
    /// uses for its in-memory artwork cache. Previously this
    /// NSCache was unbounded; on a long session the
    /// `StreamInfoWrapper` instances accumulate without eviction
    /// (the disk cache had its own 3h TTL via `cleanOldEntries`,
    /// but the memory cache did not).
    private let memoryCache: NSCache<NSString, StreamInfoWrapper> = {
        let cache = NSCache<NSString, StreamInfoWrapper>()
        cache.countLimit = 200
        cache.totalCostLimit = 5_000_000 // 5 MB safety net
        return cache
    }()

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let diskLock = NSLock()

    /// In-flight fetches. The publisher is shared across concurrent
    /// callers; the cancellable retains the upstream so the
    /// `.share()` doesn't get torn down when all subscribers go away.
    /// S17 (CV-1): previously stored the cancellable and returned a
    /// brand-new `APIService.shared.getStreamUrl(...)` call, which
    /// defeated the entire dedup.
    private var activeFetches: [String: ActiveFetch] = [:]
    // C-2026-06-28: was NSLock. The synchronous .sink() on a Just
    // publisher at line 102 fires receiveCompletion immediately on
    // the subscribing thread, and the completion handler at line 95
    // re-acquires activeFetchLock — but the outer lock at line 77 is
    // still held by that same thread. NSLock is non-recursive, so
    // the thread deadlocks. NSRecursiveLock allows the same thread
    // to re-acquire the lock and breaks the cycle.
    private let activeFetchLock = NSRecursiveLock()

    private let maxDiskAge: TimeInterval = 3 * 60 * 60 // 3 hours (under backend 3.5h TTL)

    private init() {
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesURL.appendingPathComponent("StreamURLCache", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        cleanOldEntries()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    /// S17-H / UpNext-FIX (2026-08-07): synchronous lookup of a
    /// cached stream URL. Returns the URL string if the memory or
    /// disk cache has a non-expired entry for this videoId, or
    /// nil otherwise. Used by the QueuePrefetcher's local-library
    /// fallback to convert a recently-played track into a
    /// playable QueueItem without firing a /stream roundtrip.
    ///
    /// This is the SYNC counterpart to `getStreamUrl(...)`. The
    /// async version kicks off a network fetch on miss; this one
    /// just returns nil. The prefetcher filters out nil items
    /// and the player will fetch the real URL when the track
    /// comes up in the queue anyway.
    func cachedStreamUrl(for videoId: String) -> String? {
        let keyRaw = cacheKey(for: videoId)
        if let wrapper = memoryCache.object(forKey: keyRaw), !wrapper.isExpired {
            return wrapper.streamInfo.streamUrl
        }
        if let wrapper = loadFromDisk(key: keyRaw), !wrapper.isExpired {
            // Warm memory cache for next time
            memoryCache.setObject(wrapper, forKey: keyRaw)
            return wrapper.streamInfo.streamUrl
        }
        return nil
    }

    /// Build the cache key for a videoId. The key folds
    /// (baseURL, token, videoId) together so any change to the
    /// backend host, JWT, or video auto-invalidates the cache.
    /// See the long comment in getStreamUrl() above for the
    /// full reasoning — this is just the shared helper.
    private func cacheKey(for videoId: String) -> NSString {
        let baseURL = APIService.shared.baseURL
        let token = KeychainHelper.shared.read(APIService.authTokenKeychainKey) ?? ""
        let tokenHash = String(token.hashValue)
        return "\(baseURL)|\(tokenHash)|\(videoId)" as NSString
    }

    /// Drop-in replacement for `APIService.shared.getStreamUrl`.
    /// Returns cached value immediately if available; otherwise fetches,
    /// caches, and shares the result across concurrent callers.
    func getStreamUrl(
        videoId: String,
        preferM4A: Bool = true,
        quality: String = "low"
    ) -> AnyPublisher<StreamInfo, APIError> {
        // S17-H follow-up: the cache key is NOT just videoId. The
        // StreamInfo holds a fully-built URL (host + port + token),
        // and the URL construction changes when:
        //   - the user changes Backend Host in Settings
        //   - the user signs out / signs back in (rotates the JWT)
        //   - the iOS code starts appending a new query param
        //     (e.g. the ?token=... auth fix on /proxy-stream)
        // With a plain videoId key, the cache happily returns a
        // stale streamInfo from before those changes — which is
        // exactly the bug we just hit: 3h TTL, cached URL had no
        // ?token= in it, every play was 401 even after the fix
        // shipped.
        //
        // Fold (baseURL, token, videoId) into the key so any
        // change auto-invalidates. We don't need to track every
        // param — baseURL+token captures the practical axis of
        // change. The token is hashed (not stored in the key
        // string) so a logout doesn't leave a JWT in the file
        // system cache filenames.
        let keyRaw = self.cacheKey(for: videoId)

        if let wrapper = memoryCache.object(forKey: keyRaw), !wrapper.isExpired {
            return Just(wrapper.streamInfo)
                .setFailureType(to: APIError.self)
                .eraseToAnyPublisher()
        }

        if let wrapper = loadFromDisk(key: keyRaw), !wrapper.isExpired {
            memoryCache.setObject(wrapper, forKey: keyRaw)
            return Just(wrapper.streamInfo)
                .setFailureType(to: APIError.self)
                .eraseToAnyPublisher()
        }

        activeFetchLock.lock()
        defer { activeFetchLock.unlock() }

        if activeFetches[videoId] == nil {
            // S17 (CV-1): return the SHARED publisher, not a fresh
            // APIService call. The old code stored the cached
            // pipeline in `activeFetches` and then returned a brand
            // new `APIService.shared.getStreamUrl(...)` call,
            // defeating the entire purpose of the dedup. Every
            // playback hit the backend directly, causing 429 storms
            // under any normal listening session.
            let shared = APIService.shared.getStreamUrl(
                videoId: videoId,
                preferM4A: preferM4A,
                quality: quality
            )
            .handleEvents(
                receiveOutput: { [weak self] info in
                    guard let self = self else { return }
                    let wrapper = StreamInfoWrapper(streamInfo: info, createdAt: Date())
                    self.memoryCache.setObject(wrapper, forKey: keyRaw)
                    self.saveToDisk(wrapper: wrapper, key: keyRaw)
                },
                receiveCompletion: { [weak self] _ in
                    guard let self = self else { return }
                    self.activeFetchLock.lock()
                    self.activeFetches.removeValue(forKey: videoId)
                    self.activeFetchLock.unlock()
                }
            )
            .share()
            .eraseToAnyPublisher()

            // `.sink(...)` keeps the upstream publisher alive even
            // with no other subscribers; this is the standard
            // Combine pattern for "fire-and-forget, but also multicast
            // to late subscribers". `activeFetches` retains both the
            // publisher (to give to concurrent callers) and the
            // cancellable (to keep the upstream alive until the
            // publisher's `receiveCompletion` runs and removes it).
            let retainer = shared.sink(receiveCompletion: { _ in }, receiveValue: { _ in })
            activeFetches[videoId] = ActiveFetch(publisher: shared, cancellable: retainer)
            return shared
        }

        // Cache miss but another caller is already in flight — return
        // the shared publisher so they get the result too.
        return activeFetches[videoId]!.publisher
    }

    /// In-flight prefetch set. Prevents duplicate POST /prefetch
    /// requests for the same videoId. The HomeView/SearchView
    /// prefetch calls fire 5+ times per view load, and a single
    /// user session can fire 24+ concurrent /prefetch requests
    /// for a recently-played list of 24 tracks. The backend's
    /// `_transcode_semaphore` caps concurrent transcodes at 6,
    /// so the rest queue. URLSession's per-host connection
    /// limit (default 4-6) and the 60s default timeout cause
    /// most of them to time out with -1001.
    ///
    /// With this set, the 2nd through 24th call for the same
    /// videoId is a no-op — the in-flight URLSessionTask
    /// continues and writes the result to the cache.
    private var inFlightPrefetches: Set<String> = []
    private let inFlightPrefetchLock = NSLock()

    /// Fire-and-forget prefetch that warms the backend cache via `/prefetch`.
    /// Only runs on Wi-Fi to protect metered connections.
    func prefetch(videoId: String) {
        let key = videoId as NSString
        if memoryCache.object(forKey: key) != nil { return }
        if loadFromDisk(key: key) != nil { return }

        // S17-H / PREFETCH-QUEUE-FIX (2026-08-08): skip if a
        // prefetch for this videoId is already in flight. Without
        // this, the iOS app fires 24+ duplicate /prefetch
        // requests (one per HomeView/SearchView/PlaylistDetailView
        // tap-through), all queueing behind the backend's
        // _transcode_semaphore, most timing out at 60s.
        inFlightPrefetchLock.lock()
        let alreadyInFlight = inFlightPrefetches.contains(videoId)
        if !alreadyInFlight {
            inFlightPrefetches.insert(videoId)
        }
        inFlightPrefetchLock.unlock()
        if alreadyInFlight { return }

        guard NetworkMonitor.shared.connectionType == .wifi else {
            // Not on Wi-Fi → release the in-flight slot
            inFlightPrefetchLock.lock()
            inFlightPrefetches.remove(videoId)
            inFlightPrefetchLock.unlock()
            return
        }

        guard let url = URL(string: "\(APIService.shared.baseURL)/prefetch/\(videoId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        // S17-H follow-up: /prefetch requires `require_session_user` on
        // the backend (same auth as /search and /library). Without the
        // Authorization header the call was a silent 401 — the user
        // would never know, but the cache would never warm and the
        // first play after a cold start would have to pay the full
        // yt-dlp extraction cost. Use the central APIService.addAuthHeader
        // helper so the Bearer-token construction is in one place (reads
        // the session token from the keychain under
        // "peaceplayer.session_token").
        APIService.addAuthHeader(to: &request)

        let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            // Release the in-flight slot regardless of outcome
            self?.inFlightPrefetchLock.lock()
            self?.inFlightPrefetches.remove(videoId)
            self?.inFlightPrefetchLock.unlock()

            if let http = response as? HTTPURLResponse {
                print("🔥 StreamURLCache: prefetch \(videoId) -> \(http.statusCode)")
            }
        }
        task.resume()
    }

    /// Prefetch the first several video IDs in a batch.
    func prefetchBatch(videoIds: [String]) {
        for videoId in videoIds.prefix(5) {
            prefetch(videoId: videoId)
        }
    }

    /// S17-H / S17-PLAY (Fix 3A, 2026-07-29): prefetch the next N
    /// queue items after the currently-playing one. Called from the
    /// play-time paths in HomeView/SearchView/PlaylistDetailView/etc
    /// so the user almost never pays the cold-path transcode cost —
    /// the next 3 tracks are likely already in the cache by the time
    /// the user taps Next.
    ///
    /// The existing `prefetchBatch` (list-load path) is wired in 6 view
    /// sites already. THIS path is the play-time equivalent: the
    /// "queue already has items, but the user just tapped track N, so
    /// prefetch N+1..N+3" case. Without this, taps at queue position
    /// > 5 still pay full cold-path cost.
    ///
    /// Network gate: same as `prefetch` — only runs on Wi-Fi to
    /// protect metered connections. The plan calls for a 3-track
    /// lookahead; cover 3 because that's the typical
    /// listen-to-70%-then-tap-Next window.
    func prefetchUpNext(queue: [QueueItem], currentIndex: Int, lookahead: Int = 3) {
        guard NetworkMonitor.shared.connectionType == .wifi else { return }
        let upNext = queue
            .dropFirst(currentIndex + 1)   // skip current and earlier
            .prefix(lookahead)
            .map { $0.track.videoId }
        guard !upNext.isEmpty else { return }
        prefetchBatch(videoIds: upNext)
    }

    // MARK: - Disk Cache

    private func loadFromDisk(key: NSString) -> StreamInfoWrapper? {
        diskLock.lock()
        defer { diskLock.unlock() }

        let fileURL = cacheDirectory.appendingPathComponent((key as String).md5Hash)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let wrapper = try? JSONDecoder().decode(StreamInfoWrapper.self, from: data) else {
            return nil
        }
        return wrapper
    }

    private func saveToDisk(wrapper: StreamInfoWrapper, key: NSString) {
        diskLock.lock()
        defer { diskLock.unlock() }

        let fileURL = cacheDirectory.appendingPathComponent((key as String).md5Hash)
        if let data = try? JSONEncoder().encode(wrapper) {
            try? data.write(to: fileURL)
        }
    }

    private func cleanOldEntries() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            let now = Date()
            guard let contents = try? self.fileManager.contentsOfDirectory(
                at: self.cacheDirectory,
                includingPropertiesForKeys: nil
            ) else { return }

            for file in contents {
                guard let data = try? Data(contentsOf: file),
                      let wrapper = try? JSONDecoder().decode(StreamInfoWrapper.self, from: data),
                      now.timeIntervalSince(wrapper.createdAt) > self.maxDiskAge else {
                    continue
                }
                try? self.fileManager.removeItem(at: file)
            }
        }
    }

    @objc private func handleMemoryWarning() {
        memoryCache.removeAllObjects()
    }
}

// MARK: - Wrapper

/// Holds the shared publisher + the retainer subscription for an
/// in-flight stream URL fetch. S17 (CV-1) — see `getStreamUrl`
/// comment for the dedup story.
private final class ActiveFetch {
    let publisher: AnyPublisher<StreamInfo, APIError>
    let cancellable: AnyCancellable

    init(publisher: AnyPublisher<StreamInfo, APIError>, cancellable: AnyCancellable) {
        self.publisher = publisher
        self.cancellable = cancellable
    }
}

private final class StreamInfoWrapper: NSObject, Codable {
    let streamInfo: StreamInfo
    let createdAt: Date

    init(streamInfo: StreamInfo, createdAt: Date) {
        self.streamInfo = streamInfo
        self.createdAt = createdAt
    }

    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > 3 * 60 * 60
    }
}

private extension String {
    var md5Hash: String {
        let digest = Insecure.MD5.hash(data: Data(self.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
