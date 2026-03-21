//
//  AudioFileManager.swift
//  YTAudioPlayer
//
//  File system management for downloaded audio files
//

import Foundation

class AudioFileManager {
    static let shared = AudioFileManager()

    private let fileManager = FileManager.default

    // MARK: - Directory Paths

    var downloadsDirectory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloads = documents.appendingPathComponent("Downloads", isDirectory: true)

        // Create directory if it doesn't exist
        if !fileManager.fileExists(atPath: downloads.path) {
            try? fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        }

        return downloads
    }

    var metadataDirectory: URL {
        let metadata = downloadsDirectory.appendingPathComponent(".metadata", isDirectory: true)

        if !fileManager.fileExists(atPath: metadata.path) {
            try? fileManager.createDirectory(at: metadata, withIntermediateDirectories: true)
        }

        return metadata
    }

    // MARK: - File Operations

    func localFileURL(for videoId: String, extension ext: String = "m4a") -> URL {
        return downloadsDirectory.appendingPathComponent("\(videoId).\(ext)")
    }

    func fileExists(for videoId: String, extension ext: String = "m4a") -> Bool {
        let url = localFileURL(for: videoId, extension: ext)
        return fileManager.fileExists(atPath: url.path)
    }

    func fileSize(for videoId: String, extension ext: String = "m4a") -> Int64 {
        let url = localFileURL(for: videoId, extension: ext)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return 0
        }
        return attributes[.size] as? Int64 ?? 0
    }

    func moveDownloadedFile(from tempURL: URL, to videoId: String, extension ext: String = "m4a") throws -> URL {
        let destinationURL = localFileURL(for: videoId, extension: ext)

        // Remove existing file if present
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        // Move file
        try fileManager.moveItem(at: tempURL, to: destinationURL)

        return destinationURL
    }

    func deleteFile(for videoId: String, extension ext: String = "m4a") throws {
        let url = localFileURL(for: videoId, extension: ext)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    /// Delete local file for a videoId (wrapper for deleteFile)
    func deleteLocalFile(videoId: String, extension ext: String = "m4a") {
        do {
            try deleteFile(for: videoId, extension: ext)
            print("🗑️ Deleted local file: \(videoId)")
        } catch {
            print("❌ Failed to delete local file: \(error)")
        }
    }

    // MARK: - Directory Operations

    func allDownloadedFiles() -> [(videoId: String, url: URL, size: Int64)] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        return contents.compactMap { url in
            guard url.pathExtension == "m4a" || url.pathExtension == "webm" else { return nil }

            let videoId = url.deletingPathExtension().lastPathComponent
            let size = fileSize(for: videoId, extension: url.pathExtension)

            return (videoId: videoId, url: url, size: size)
        }
    }

    func totalDownloadedSize() -> Int64 {
        allDownloadedFiles().reduce(0) { $0 + $1.size }
    }

    func clearAllDownloads() throws {
        let files = allDownloadedFiles()
        for file in files {
            try fileManager.removeItem(at: file.url)
        }
    }

    // MARK: - Storage Management

    var availableStorage: Int64 {
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: downloadsDirectory.path) else {
            return 0
        }
        return attributes[.systemFreeSize] as? Int64 ?? 0
    }

    var totalStorage: Int64 {
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: downloadsDirectory.path) else {
            return 0
        }
        return attributes[.systemSize] as? Int64 ?? 0
    }
}
