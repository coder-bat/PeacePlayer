//
//  ImageCache.swift
//  YTAudioPlayer
//
//  Image caching system for artwork thumbnails
//

import Foundation
import UIKit
import SwiftUI
import CryptoKit
import Combine

/// Caches images to memory and disk for better performance
class ImageCache {
    static let shared = ImageCache()
    
    // MARK: - Properties
    
    private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    private var cancellables = Set<AnyCancellable>()
    // S15: dedicated Set for preloads so they can be cleared when
    // the preloads complete. Previously they piled up in `cancellables`
    // forever.
    private var preloadCancellables = Set<AnyCancellable>()
    private var activeDownloads: [URL: AnyCancellable] = [:]
    private var cleanupTimer: Timer?

    // Thread safety for disk cache operations
    private let diskCleanupLock = NSLock()

    // Cache configuration
    private let maxMemoryCost = 50 * 1024 * 1024 // 50MB
    private let maxDiskSize = 100 * 1024 * 1024   // 100MB
    private let maxDiskAge: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    
    // MARK: - Initialization
    
    private init() {
        memoryCache.totalCostLimit = maxMemoryCost
        memoryCache.countLimit = 200
        
        // Setup disk cache directory
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cachesURL.appendingPathComponent("ImageCache", isDirectory: true)
        
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Clean up old cache files periodically
        cleanOldCacheFiles()
        
        // Register for memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        // Periodic cleanup every hour
        self.cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.enforceCacheLimits()
        }
    }
    
    deinit {
        cleanupTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Public Methods
    
    /// Get image from cache or download it
    func image(for url: URL) -> AnyPublisher<UIImage?, Never> {
        let key = url.absoluteString as NSString
        #if DEBUG
        PlayCrashDiagnostics.log(.artwork, "ImageCache.image(for:) key=\(key as String) memoryCheck=in_progress")
        #endif

        // Check memory cache first (sync, fast)
        if let image = memoryCache.object(forKey: key) {
            #if DEBUG
            PlayCrashDiagnostics.log(.artwork, "ImageCache HIT (memory) for key=\(key as String)")
            #endif
            return Just(image).eraseToAnyPublisher()
        }

        // S15: disk read + JPEG decode used to run synchronously
        // on the main thread (called from SwiftUI views). A 2MB
        // artwork JPEG took 50-100ms of main-thread stall on first
        // display. Move the disk check + decode to a background
        // utility queue; deliver the result to the subscriber on
        // main. The download path also moved off the main receive
        // for the same reason.
        return Deferred { [weak self] () -> AnyPublisher<UIImage?, Never> in
            guard let self = self else {
                return Just(nil).eraseToAnyPublisher()
            }

            // Try disk cache (sync file read + decode, but on the
            // background queue because of the upstream `subscribe(on:)`).
            if let image = self.loadFromDisk(key: key) {
                self.memoryCache.setObject(image, forKey: key, cost: image.cacheCost)
                #if DEBUG
                PlayCrashDiagnostics.log(.artwork, "ImageCache HIT (disk) for key=\(key as String)")
                #endif
                return Just(image).eraseToAnyPublisher()
            }

            // Download if not already downloading
            if self.activeDownloads[url] == nil {
                let download = URLSession.shared.dataTaskPublisher(for: url)
                    .map { [weak self] output -> UIImage? in
                        // S17-G (perf 10 P0-F6): decode + downsample to
                        // 1024px instead of full-resolution UIImage(data:).
                        // See `decodedImage` for the rationale.
                        self?.decodedImage(data: output.data)
                    }
                    .catch { _ in Just(nil) }
                    // S15: keep the download pipeline off main.
                    // Decoding + caching + disk save all happen on
                    // URLSession's background queue now; only the
                    // final delivery to subscribers hops to main.
                    .handleEvents(receiveOutput: { [weak self] image in
                        guard let self = self, let image = image else { return }

                        // Store in memory cache
                        self.memoryCache.setObject(image, forKey: key, cost: image.cacheCost)

                        // Store in disk cache on a background queue
                        // (JPEG encoding + file write can stall).
                        DispatchQueue.global(qos: .utility).async {
                            self.saveToDisk(image: image, key: key)
                        }

                        // Remove from active downloads
                        self.activeDownloads.removeValue(forKey: url)
                    })
                    .share()
                    .eraseToAnyPublisher()
                    .sink { _ in }

                self.activeDownloads[url] = download
            }

            // Return placeholder while loading
            return Just(nil).eraseToAnyPublisher()
        }
        .subscribe(on: DispatchQueue.global(qos: .userInitiated))
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()
    }
    
    /// Preload images for upcoming tracks
    func preloadImages(urls: [URL]) {
        // S15: store the cancellable in a dedicated Set (not the
        // generic `cancellables`) and clear it when the preloads
        // complete, so we don't accumulate dead subscriptions.
        let group = DispatchGroup()
        for url in urls {
            group.enter()
            let cancellable = image(for: url)
                .sink(receiveValue: { _ in
                    group.leave()
                })
            preloadCancellables.insert(cancellable)
        }
        group.notify(queue: .main) { [weak self] in
            self?.preloadCancellables.removeAll()
        }
    }
    
    /// Clear all caches
    func clearCache() {
        memoryCache.removeAllObjects()

        // S15: disk-cache eviction used to run synchronously on the
        // main thread (memory warning path). Move it to a utility
        // queue so the warning handler returns immediately.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            do {
                let contents = try self.fileManager.contentsOfDirectory(
                    at: self.cacheDirectory,
                    includingPropertiesForKeys: nil
                )
                for file in contents {
                    try? self.fileManager.removeItem(at: file)
                }
            } catch {
                print("❌ Failed to clear disk cache: \(error)")
            }
        }
    }
    
    /// Get cache size in bytes
    func cacheSize() -> UInt64 {
        var size: UInt64 = 0
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])
            for file in contents {
                if let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                   let fileSize = attributes[.size] as? UInt64 {
                    size += fileSize
                }
            }
        } catch {
            print("❌ Failed to calculate cache size: \(error)")
        }
        
        return size
    }
    
    // MARK: - Private Methods
    
    /// S17-G (perf 10 P0-F6): the cache previously used
    /// `UIImage(data:)` which decodes JPEGs at full resolution.
    /// A 4K artwork JPEG becomes a 4000x4000x4 byte (64MB) buffer
    /// in memory — and the row cells only render at 50-100pt. Use
    /// `CGImageSourceCreateThumbnailAtIndex` to decode + downsample
    /// in one step, capped at 1024px on the long edge. This is
    /// the standard pattern for memory-efficient image loading.
    /// Visible quality loss at 1024px is invisible at 50-100pt;
    /// memory savings are 16x for a 4K source.
    private static let maxDecodeDimension: CGFloat = 1024

    private func decodedImage(data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxDecodeDimension
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func loadFromDisk(key: NSString) -> UIImage? {
        let fileURL = cacheDirectory.appendingPathComponent(key.md5Hash)

        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let image = decodedImage(data: data) else {
            return nil
        }

        return image
    }
    
    private func saveToDisk(image: UIImage, key: NSString) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        
        let fileURL = cacheDirectory.appendingPathComponent(key.md5Hash)
        
        do {
            try data.write(to: fileURL)
        } catch {
            print("❌ Failed to save image to disk: \(error)")
        }
    }
    
    private func cleanOldCacheFiles() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            // Prevent concurrent cleanups
            guard self.diskCleanupLock.try() else {
                print("⚠️ Disk cleanup already in progress, skipping")
                return
            }
            defer { self.diskCleanupLock.unlock() }

            do {
                let contents = try self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])

                let now = Date()
                var totalSize: UInt64 = 0
                var files: [(url: URL, date: Date, size: UInt64)] = []

                // Collect file info
                for file in contents {
                    if let attributes = try? self.fileManager.attributesOfItem(atPath: file.path),
                       let creationDate = attributes[.creationDate] as? Date,
                       let size = attributes[.size] as? UInt64 {
                        totalSize += size
                        files.append((file, creationDate, size))
                    }
                }

                // Remove files older than max age
                for file in files {
                    if now.timeIntervalSince(file.date) > self.maxDiskAge {
                        try? self.fileManager.removeItem(at: file.url)
                        totalSize -= file.size
                    }
                }

                // If still over max size, remove oldest files
                if totalSize > self.maxDiskSize {
                    let sortedFiles = files.sorted { $0.date < $1.date }
                    var currentSize = totalSize

                    for file in sortedFiles {
                        if currentSize <= self.maxDiskSize { break }
                        try? self.fileManager.removeItem(at: file.url)
                        currentSize -= file.size
                    }
                }
            } catch {
                print("❌ Failed to clean cache: \(error)")
            }
        }
    }
    
    // MARK: - Memory Management
    
    @objc private func handleMemoryWarning() {
        print("⚠️ Memory warning received - clearing image cache")
        
        // Clear memory cache immediately
        memoryCache.removeAllObjects()
        
        // Cancel pending downloads
        activeDownloads.values.forEach { $0.cancel() }
        activeDownloads.removeAll()
        
        // Clean disk cache on background thread
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.enforceCacheLimits()
        }
    }
    
    /// Enforces cache size limits by removing oldest files
    private func enforceCacheLimits() {
        // Prevent concurrent cleanups
        guard diskCleanupLock.try() else {
            print("⚠️ Disk cleanup already in progress, skipping")
            return
        }
        defer { diskCleanupLock.unlock() }

        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])

            var totalSize: UInt64 = 0
            var files: [(url: URL, date: Date, size: UInt64)] = []

            // Collect file info
            for file in contents {
                if let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                   let creationDate = attributes[.creationDate] as? Date,
                   let size = attributes[.size] as? UInt64 {
                    totalSize += size
                    files.append((file, creationDate, size))
                }
            }

            // If over max size, remove oldest files
            if totalSize > maxDiskSize {
                let sortedFiles = files.sorted { $0.date < $1.date }
                var currentSize = totalSize

                for file in sortedFiles {
                    if currentSize <= maxDiskSize * 8 / 10 { break } // Target 80% of max
                    try? fileManager.removeItem(at: file.url)
                    currentSize -= file.size
                }

                print("✂️ Reduced cache size from \(totalSize / 1024 / 1024)MB to \(currentSize / 1024 / 1024)MB")
            }
        } catch {
            print("❌ Failed to enforce cache limits: \(error)")
        }
    }
}

// MARK: - Helper Extensions

private extension UIImage {
    /// Estimates memory cost without expensive pngData() calculation
    /// Uses dimensions * scale * 4 bytes per pixel (RGBA)
    var cacheCost: Int {
        // For animated images or images with imageSource, use cgImage size
        let pixelWidth = cgImage?.width ?? Int(size.width * scale)
        let pixelHeight = cgImage?.height ?? Int(size.height * scale)
        return pixelWidth * pixelHeight * 4 // 4 bytes per pixel (RGBA)
    }
}

private extension NSString {
    // QW-5 fix: was `String(self.hashValue)` — Swift's hashValue is
    // randomized per process and 64-bit, not collision-resistant. Two
    // distinct artwork URLs whose hashValue collided would overwrite each
    // other's cached file (and could even read the wrong image). Use
    // CryptoKit.Insecure.MD5 for a deterministic 128-bit hash.
    var md5Hash: String {
        let data = Data((self as String).utf8)
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}


