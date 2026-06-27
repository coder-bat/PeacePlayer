//
//  PlayCrashDiagnostics.swift
//  PeacePlayer
//
//  Phase S0 of the 2026-06-17 feature plan: diagnostic harness for the
//  play-crash bug ("when I play a track, app crashes (music keeps going)").
//
//  What this does:
//  - Provides `os.Logger`-based breadcrumbs at every suspicious point
//    along the play path (PlayerState.play, NowPlayingService.update,
//    ArtworkCache.get/set).
//  - Captures the most recent N breadcrumbs in a thread-safe ring buffer,
//    so when the app crashes, the last breadcrumbs are flushed to disk
//    via the StateServer's boot token file area as a "last-words" log.
//  - The first run after install populates the ring; if the crash
//    happens on the second run, the breadcrumbs from the first run
//    are still on disk for the user to grab via devicectl file copy.
//
//  Subsystem: com.peaceplayer.playback
//  Categories: playback, now-playing, artwork, lifecycle
//
//  All code is wrapped in `#if DEBUG` so release builds carry zero
//  overhead. The Logger.subsystem is also DEBUG-only because Logger
//  instances can be retained even if no log call fires.
//

#if DEBUG

import Foundation
import os

/// Diagnostic harness for the play-crash bug. The 22-agent analysis
/// from 2026-06-17 identified the artwork cache in `NowPlayingService`
/// as the top hypothesis: rapid `play(track:)` calls collide on the
/// cache key (currently `URL.lastPathComponent` only). The breadcrumbs
/// here give us a breadcrumb trail to confirm or refute that hypothesis
/// when the user reproduces the crash in Xcode.
enum PlayCrashDiagnostics {
    static let subsystem = "com.peaceplayer.playback"

    enum Category: String {
        case playback = "playback"
        case nowPlaying = "now-playing"
        case artwork = "artwork"
        case lifecycle = "lifecycle"
    }

    static func log(_ category: Category, _ message: String) {
        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        logger.notice("\(message, privacy: .public)")
        BreadcrumbRing.shared.append(category: category, message: message)
    }

    /// Flush the breadcrumb ring to a file the user can pull via
    /// `xcrun devicectl device copy from`. Path is inside the app's
    /// tmp directory which `devicectl` can access.
    static func flushToDisk() {
        let path = NSTemporaryDirectory() + "play-crash-breadcrumbs.log"
        let body = BreadcrumbRing.shared.snapshotForFlush()
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Thread-safe ring buffer of recent breadcrumbs. The OS thread that
/// fires the crash may not be the main thread; we use an `os_unfair_lock`
/// to make append + snapshot safe across threads.
final class BreadcrumbRing {
    static let shared = BreadcrumbRing()

    private let capacity = 256
    private var entries: [(category: PlayCrashDiagnostics.Category, message: String, timestamp: Date)] = []
    private var lock = os_unfair_lock_s()

    func append(category: PlayCrashDiagnostics.Category, message: String) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if entries.count >= capacity {
            entries.removeFirst()
        }
        entries.append((category, message, Date()))
    }

    func snapshotForFlush() -> String {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries
            .map { "[\(formatter.string(from: $0.timestamp))] [\($0.category.rawValue)] \($0.message)" }
            .joined(separator: "\n")
    }
}

#endif
