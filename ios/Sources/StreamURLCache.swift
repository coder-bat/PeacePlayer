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

    private let memoryCache = NSCache<NSString, StreamInfoWrapper>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let diskLock = NSLock()

    private var activeFetches: [String: AnyCancellable] = [:]
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

    /// Drop-in replacement for `APIService.shared.getStreamUrl`.
    /// Returns cached value immediately if available; otherwise fetches,
    /// caches, and shares the result across concurrent callers.
    func getStreamUrl(
        videoId: String,
        preferM4A: Bool = true,
        quality: String = "low"
    ) -> AnyPublisher<StreamInfo, APIError> {
        let key = videoId as NSString

        if let wrapper = memoryCache.object(forKey: key), !wrapper.isExpired {
            return Just(wrapper.streamInfo)
                .setFailureType(to: APIError.self)
                .eraseToAnyPublisher()
        }

        if let wrapper = loadFromDisk(key: key), !wrapper.isExpired {
            memoryCache.setObject(wrapper, forKey: key)
            return Just(wrapper.streamInfo)
                .setFailureType(to: APIError.self)
                .eraseToAnyPublisher()
        }

        activeFetchLock.lock()
        defer { activeFetchLock.unlock() }

        if activeFetches[videoId] == nil {
            let fetch = APIService.shared.getStreamUrl(
                videoId: videoId,
                preferM4A: preferM4A,
                quality: quality
            )
            .handleEvents(
                receiveOutput: { [weak self] info in
                    guard let self = self else { return }
                    let wrapper = StreamInfoWrapper(streamInfo: info, createdAt: Date())
                    self.memoryCache.setObject(wrapper, forKey: key)
                    self.saveToDisk(wrapper: wrapper, key: key)
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
            .sink(receiveCompletion: { _ in }, receiveValue: { _ in })

            activeFetches[videoId] = fetch
        }

        return APIService.shared.getStreamUrl(
            videoId: videoId,
            preferM4A: preferM4A,
            quality: quality
        )
    }

    /// Fire-and-forget prefetch that warms the backend cache via `/prefetch`.
    /// Only runs on Wi-Fi to protect metered connections.
    func prefetch(videoId: String) {
        let key = videoId as NSString
        if memoryCache.object(forKey: key) != nil { return }
        if loadFromDisk(key: key) != nil { return }

        guard NetworkMonitor.shared.connectionType == .wifi else { return }

        guard let url = URL(string: "\(APIService.shared.baseURL)/prefetch/\(videoId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                print("🔥 StreamURLCache: prefetch \(videoId) -> \(http.statusCode)")
            }
        }.resume()
    }

    /// Prefetch the first several video IDs in a batch.
    func prefetchBatch(videoIds: [String]) {
        for videoId in videoIds.prefix(5) {
            prefetch(videoId: videoId)
        }
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
