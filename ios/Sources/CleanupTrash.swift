//
//  CleanupTrash.swift
//  PeacePlayer
//
//  2026-09-08: v1.9.3 — Trash directory for the new ask-before-cleanup
//  flow. Holds files that have been moved out of the active downloads
//  directory but are still recoverable for a 7-day grace window. After
//  the grace window the files are permanently deleted by `purgeExpired`.
//
//  Layout:
//
//    Documents/
//      Downloads/
//        {videoId}.m4a              ← active downloads (playable)
//        .trash/
//          {videoId}.m4a            ← recently cleaned (recoverable)
//
//  Sits next to the active downloads directory so a user who hooks up
//  iTunes File Sharing can browse both folders. The leading dot in
//  `.trash` keeps file pickers from showing it as a real file.
//
//  All operations are best-effort. Missing source files (already
//  removed by the user via Files.app) are no-ops; restore collisions
//  (a re-downloaded track already in active downloads) are refused,
//  not overwritten.
//

import Foundation

/// 2026-09-08: Trash helper for the ask-before-cleanup flow.
/// Companion to AudioFileManager — moves files into a `.trash/`
/// directory under Downloads/ and back, plus a periodic purge.
final class CleanupTrash {
    static let shared = CleanupTrash()

    private let fileManager = FileManager.default

    /// Default trash retention. After this many days, files are
    /// permanently deleted by `purgeExpired`. Tuned to match the
    /// iOS Photos "Recently Deleted" expectation without going
    /// overboard (Photos gives 30d; users here expect a tighter
    /// window because cleanup is opt-in per-cycle, not the only
    /// way files are ever removed).
    static let defaultRetentionDays: Int = 7

    private init() {}

    // MARK: - Paths

    /// The trash directory, auto-created on first access.
    /// Lives at Documents/Downloads/.trash/ alongside the active
    /// downloads. The leading dot hides it from Files.app's
    /// document browser and iTunes File Sharing's default view.
    var trashDirectory: URL {
        let downloads = AudioFileManager.shared.downloadsDirectory
        let trash = downloads.appendingPathComponent(".trash", isDirectory: true)
        if !fileManager.fileExists(atPath: trash.path) {
            try? fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        }
        return trash
    }

    // MARK: - Move / Restore

    /// Move a downloaded file to the trash directory.
    /// Returns the new URL on success, nil if the source file is
    /// already gone (e.g. user deleted it via Files.app between
    /// scheduling and committing) or the move failed.
    ///
    /// Filename conflicts (re-trash of the same videoId, which
    /// shouldn't happen in normal flow but is possible if the user
    /// re-downloaded + re-cleaned a track within the retention
    /// window) get a numeric suffix so the older copy is preserved.
    @discardableResult
    func moveToTrash(videoId: String, extension ext: String = "m4a") -> URL? {
        let sourceURL = AudioFileManager.shared.localFileURL(for: videoId, extension: ext)
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return nil
        }
        let destURL = uniqueURL(for: trashDirectory.appendingPathComponent(sourceURL.lastPathComponent))
        do {
            try fileManager.moveItem(at: sourceURL, to: destURL)
            return destURL
        } catch {
            print("⚠️ [CleanupTrash] failed to move \(videoId) to trash: \(error)")
            return nil
        }
    }

    /// Move a file from trash back to the active downloads
    /// directory. Returns true on success.
    ///
    /// If a file with the same videoId already exists in the
    /// active downloads (the user re-downloaded the track while
    /// it was in trash), the restore is refused — overwriting a
    /// fresh download with a stale trash copy would be a data
    /// loss. The caller should surface this to the user.
    @discardableResult
    func restoreFromTrash(trashedURL: URL) -> Bool {
        let videoId = trashedURL.deletingPathExtension().lastPathComponent
        let ext = trashedURL.pathExtension
        let destURL = AudioFileManager.shared.localFileURL(for: videoId, extension: ext)
        guard fileManager.fileExists(atPath: trashedURL.path) else {
            return false
        }
        if fileManager.fileExists(atPath: destURL.path) {
            // Active download already exists — don't overwrite.
            return false
        }
        do {
            try fileManager.moveItem(at: trashedURL, to: destURL)
            return true
        } catch {
            print("⚠️ [CleanupTrash] failed to restore \(videoId): \(error)")
            return false
        }
    }

    /// Permanently delete one trashed file by URL.
    /// Used by Settings → Trash → "Delete now" (skip-the-7d-grace).
    func permanentlyDelete(trashedURL: URL) -> Bool {
        guard fileManager.fileExists(atPath: trashedURL.path) else { return false }
        do {
            try fileManager.removeItem(at: trashedURL)
            return true
        } catch {
            print("⚠️ [CleanupTrash] failed to permanently delete: \(error)")
            return false
        }
    }

    // MARK: - Listing

    /// Enumerate every file currently in trash, with size and the
    /// file's modification date (treated as the trash time — we
    /// update mtime on move so the purge ordering is correct).
    func listTrashed() -> [TrashedFile] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: trashDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents.compactMap { url in
            guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  attrs.isRegularFile == true else { return nil }
            let videoId = url.deletingPathExtension().lastPathComponent
            return TrashedFile(
                videoId: videoId,
                url: url,
                size: Int64(attrs.fileSize ?? 0),
                trashedAt: attrs.contentModificationDate ?? Date.distantPast
            )
        }
        .sorted { $0.trashedAt > $1.trashedAt }  // newest first
    }

    /// Total bytes currently in trash.
    func totalTrashedSize() -> Int64 {
        listTrashed().reduce(0) { $0 + $1.size }
    }

    // MARK: - Purge

    /// Permanently delete trashed files older than `retentionDays`.
    /// Returns total bytes freed. Called from `runCleanupIfDue` on
    /// every foreground — cheap, runs in milliseconds for typical
    /// trash sizes (< 50 files).
    @discardableResult
    func purgeExpired(retentionDays: Int = CleanupTrash.defaultRetentionDays) -> Int64 {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        var bytesFreed: Int64 = 0
        for entry in listTrashed() where entry.trashedAt < cutoff {
            do {
                try fileManager.removeItem(at: entry.url)
                bytesFreed += entry.size
            } catch {
                print("⚠️ [CleanupTrash] failed to purge \(entry.videoId): \(error)")
            }
        }
        return bytesFreed
    }

    // MARK: - Internal

    /// Generate a unique destination URL inside the trash directory.
    /// Adds `-1`, `-2`, ... suffix on filename collision (e.g. a
    /// track was re-downloaded and re-cleaned within the retention
    /// window). Bounded to 100 attempts to avoid infinite loops on
    /// a degenerate trash state.
    private func uniqueURL(for url: URL) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let parent = url.deletingLastPathComponent()
        for n in 1...100 {
            let candidate = parent.appendingPathComponent("\(base)-\(n).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}

/// A file currently in the trash directory.
struct TrashedFile: Identifiable {
    let videoId: String
    let url: URL
    let size: Int64
    let trashedAt: Date

    var id: String { url.path }
}
