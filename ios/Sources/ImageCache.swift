//
//  ImageCache.swift
//  YTAudioPlayer
//
//  Image caching system for artwork thumbnails
//

import Foundation
import UIKit
import SwiftUI
import Combine

/// Caches images to memory and disk for better performance
class ImageCache {
    static let shared = ImageCache()
    
    // MARK: - Properties
    
    private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    private var cancellables = Set<AnyCancellable>()
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
        
        // Check memory cache first
        if let image = memoryCache.object(forKey: key) {
            return Just(image).eraseToAnyPublisher()
        }
        
        // Check disk cache
        if let image = loadFromDisk(key: key) {
            memoryCache.setObject(image, forKey: key, cost: image.cacheCost)
            return Just(image).eraseToAnyPublisher()
        }
        
        // Download if not already downloading
        if activeDownloads[url] == nil {
            let download = URLSession.shared.dataTaskPublisher(for: url)
                .map { UIImage(data: $0.data) }
                .catch { _ in Just(nil) }
                .receive(on: DispatchQueue.main)
                .handleEvents(receiveOutput: { [weak self] image in
                    guard let self = self, let image = image else { return }
                    
                    // Store in memory cache
                    self.memoryCache.setObject(image, forKey: key, cost: image.cacheCost)
                    
                    // Store in disk cache
                    self.saveToDisk(image: image, key: key)
                    
                    // Remove from active downloads
                    self.activeDownloads.removeValue(forKey: url)
                })
                .share()
                .eraseToAnyPublisher()
                .sink { _ in }
            
            activeDownloads[url] = download
        }
        
        // Return placeholder while loading
        return Just(nil).eraseToAnyPublisher()
    }
    
    /// Preload images for upcoming tracks
    func preloadImages(urls: [URL]) {
        urls.forEach { url in
            _ = image(for: url)
                .sink(receiveValue: { _ in })
                .store(in: &cancellables)
        }
    }
    
    /// Clear all caches
    func clearCache() {
        memoryCache.removeAllObjects()
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            for file in contents {
                try? fileManager.removeItem(at: file)
            }
        } catch {
            print("❌ Failed to clear disk cache: \(error)")
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
    
    private func loadFromDisk(key: NSString) -> UIImage? {
        let fileURL = cacheDirectory.appendingPathComponent(key.md5Hash)
        
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
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
    var md5Hash: String {
        // Simple hash for demo - in production use proper MD5
        return String(self.hashValue)
    }
}


