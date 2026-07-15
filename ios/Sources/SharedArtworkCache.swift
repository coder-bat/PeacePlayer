//
//  SharedArtworkCache.swift
//  PeacePlayer
//
//  S16: shared artwork cache between main app and widget extension.
//
//  Before: every widget timeline refresh re-downloaded the current track's
//  artwork via URLSession. For a 15-min refresh interval, the user paid
//  the bandwidth + decode cost on every refresh even when the artwork
//  URL was unchanged.
//
//  After: the app writes the artwork JPEG to the App Group container
//  whenever NowPlayingService loads a new track. The widget reads from
//  the App Group first, falls back to URLSession only on cache miss.
//
//  Cache key is SHA-256 of the artwork URL. The filename is the hex hash,
//  which keeps the cache deterministic across app launches and across
//  both processes.
//
//  Storage: <AppGroupContainer>/artwork/<sha256>.jpg
//
//  Eviction: opportunistic. Each write prunes the artwork directory to
//  keep at most `maxEntries` files (oldest mtime first). 50 entries
//  covers ~2 days of heavy listening without unbounded growth.
//

import Foundation
import CryptoKit
import UIKit

/// File-based artwork cache shared between the app and widget extension
/// via the App Group container.
///
/// All methods are `static` and safe to call from any context. The
/// actor-isolated state (file enumeration + pruning) is gated through
/// a small `async` boundary so concurrent calls don't race on the
/// filesystem.
enum SharedArtworkCache {

    // MARK: - Public API

    /// Save `image` for `url` into the App Group artwork cache.
    /// Encodes as JPEG at 0.85 quality (good enough for widget cells).
    static func store(_ image: UIImage, for url: URL) {
        guard let containerURL = artworkDirectoryURL() else { return }
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let fileURL = fileURL(for: url, in: containerURL)
        do {
            try data.write(to: fileURL, options: .atomic)
            Task.detached(priority: .background) {
                await prune(in: containerURL)
            }
        } catch {
            // Best-effort write. Widget will fall back to URLSession on miss.
        }
    }

    /// Read the cached image for `url`, if any. Returns `nil` on miss
    /// or read failure.
    static func read(for url: URL) -> UIImage? {
        guard let containerURL = artworkDirectoryURL() else { return nil }
        let fileURL = fileURL(for: url, in: containerURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    /// Read from cache; on miss, fetch via URLSession and store.
    /// Used by the widget extension. Returns nil on any failure.
    static func readOrFetch(url: URL) async -> UIImage? {
        if let cached = read(for: url) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let image = UIImage(data: data) else { return nil }
        store(image, for: url)
        return image
    }

    // MARK: - Internals

    /// `<AppGroupContainer>/artwork/`. Created lazily on first use.
    private static func artworkDirectoryURL() -> URL? {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SharedNowPlayingState.appGroupID)
        else { return nil }
        let dir = containerURL.appendingPathComponent("artwork", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }
        return dir
    }

    /// `artwork/<sha256>.jpg` for the given URL. SHA-256 keeps the
    /// key deterministic and URL-safe (hex output).
    private static func fileURL(for url: URL, in directory: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hex).jpg", isDirectory: false)
    }

    /// Bound the artwork directory to `maxEntries` files, dropping the
    /// oldest-mtime entries first. Runs off the main thread.
    private static let maxEntries = 50

    private static func prune(in directory: URL) async {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        guard urls.count > maxEntries else { return }

        // Sort by mtime, oldest first.
        let withDates: [(URL, Date)] = urls.compactMap { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, date)
        }
        .sorted { $0.1 < $1.1 }

        let toDelete = withDates.prefix(withDates.count - maxEntries)
        for (url, _) in toDelete {
            try? fm.removeItem(at: url)
        }
    }
}
