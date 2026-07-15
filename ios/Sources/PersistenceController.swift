//
//  PersistenceController.swift
//  YTAudioPlayer
//
//  Core Data stack manager.
//
//  2026-07-15 (S17-D, CV-6): the previous load-failure handler
//  silently wiped the SQLite store and rebooted the app — fine
//  when the store was known-empty, fatal when the user actually
//  had a Library. Now we surface the failure: a UIAlertController
//  asks the user to choose between backing up the broken store
//  before wiping, or wiping outright. The wipe is no longer the
//  default; it's an explicit user choice. `loadState` is a
//  @Published value the UI layer (and tests) can observe.
//

import CoreData
import os

// MARK: - Value Transformers for Core Data Arrays

@objc(StringArrayTransformer)
final class StringArrayTransformer: NSSecureUnarchiveFromDataTransformer {
    static let name = NSValueTransformerName("StringArrayTransformer")
    override static var allowedTopLevelClasses: [AnyClass] { [NSArray.self, NSString.self] }
    static func register() {
        ValueTransformer.setValueTransformer(StringArrayTransformer(), forName: name)
    }
}

@objc(ThumbnailURLArrayTransformer)
final class ThumbnailURLArrayTransformer: NSSecureUnarchiveFromDataTransformer {
    static let name = NSValueTransformerName("ThumbnailURLArrayTransformer")
    override static var allowedTopLevelClasses: [AnyClass] { [NSArray.self, NSString.self] }
    static func register() {
        ValueTransformer.setValueTransformer(ThumbnailURLArrayTransformer(), forName: name)
    }
}

@objc(TrackOrderArrayTransformer)
final class TrackOrderArrayTransformer: NSSecureUnarchiveFromDataTransformer {
    static let name = NSValueTransformerName("TrackOrderArrayTransformer")
    override static var allowedTopLevelClasses: [AnyClass] { [NSArray.self, NSString.self] }
    static func register() {
        ValueTransformer.setValueTransformer(TrackOrderArrayTransformer(), forName: name)
    }
}

@objc(SeedVideoIdArrayTransformer)
final class SeedVideoIdArrayTransformer: NSSecureUnarchiveFromDataTransformer {
    static let name = NSValueTransformerName("SeedVideoIdArrayTransformer")
    override static var allowedTopLevelClasses: [AnyClass] { [NSArray.self, NSString.self] }
    static func register() {
        ValueTransformer.setValueTransformer(SeedVideoIdArrayTransformer(), forName: name)
    }
}

extension Notification.Name {
    /// Posted on the main thread when a Core Data persistent
    /// store fails to load. The userInfo dict carries the
    /// underlying NSError under the "error" key. `MigrationFailureAlert`
    /// listens for this and presents a UIAlertController; tests
    /// can also listen to assert the failure path.
    static let persistentStoreMigrationFailed = Notification.Name("persistentStoreMigrationFailed")

    /// Posted after a successful wipe / backup + reload, so the
    /// rest of the app (UnifiedLibraryViewModel, TrackStore,
    /// etc.) can re-fetch from the fresh empty store without a
    /// relaunch.
    static let persistentStoreRecovered = Notification.Name("persistentStoreRecovered")
}

/// What the persistent store is doing right now. Exposed via
/// `@Published` so any SwiftUI view (and any other long-lived
/// observer) can react. The pre-S17-D code had no published
/// state — the load was fire-and-forget, so a failure was
/// visible only via the in-memory wipe.
enum PersistentStoreLoadState: Equatable {
    /// Store load is in flight on the Core Data background queue.
    case loading
    /// Store is loaded and the app can read/write.
    case ready
    /// Migration failed. The app is in a degraded state — the
    /// existing SQLite file is on disk but Core Data can't open
    /// it. The user must choose to back it up and wipe, or just
    /// wipe, before the app becomes usable. The associated
    /// NSError is surfaced in `lastError` for the UI to display.
    case migrationFailed
    /// User chose to wipe / back-up + wipe. We're moving the
    /// store file out of the way and asking Core Data to load
    /// again. Briefly visible before `.ready` or `.migrationFailed`.
    case recovering
}

/// S17-D (CV-6) container for the persistent store. Converted
/// from a `struct` to a class so the `@Published` loadState
/// has a stable identity that SwiftUI views can observe. The
/// `init(inMemory:)` and the static `shared` API are unchanged
/// for call-site compatibility — TimeCapsuleManager,
/// UnifiedLibraryViewModel, and the rest still use
/// `PersistenceController.shared.viewContext` exactly as
/// before.
final class PersistenceController: ObservableObject {
    static let shared = PersistenceController()

    /// S17-D (CV-6): exposes the load state. Defaults to
    /// `.loading` because the load starts on `init` and
    /// transitions to `.ready` or `.migrationFailed` on the
    /// Core Data background callback.
    @Published private(set) var loadState: PersistentStoreLoadState = .loading

    /// The most recent load error, if any. Cleared on a
    /// successful recovery.
    @Published private(set) var lastError: Error?

    let container: NSPersistentContainer

    private static let log = Logger(subsystem: "com.ytaudioplayer.PeacePlayer", category: "PersistenceController")

    var viewContext: NSManagedObjectContext {
        container.viewContext
    }

    /// Background context for performing Core Data operations off the main thread
    var backgroundContext: NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        context.automaticallyMergesChangesFromParent = true
        return context
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        backgroundContext
    }

    init(inMemory: Bool = false) {
        // Register custom value transformers BEFORE initializing Core Data
        StringArrayTransformer.register()
        ThumbnailURLArrayTransformer.register()
        TrackOrderArrayTransformer.register()
        SeedVideoIdArrayTransformer.register()
        Self.log.info("Core Data value transformers registered")

        container = NSPersistentContainer(name: "YTAudioPlayer")

        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }

        // S15: tell Core Data to add the persistent store on a
        // background queue, not the main thread. The default
        // behaviour runs the SQLite open + WAL replay on the
        // caller's queue; with `shouldAddStoreAsynchronously =
        // true`, the heavy work happens off-main. viewContext is
        // still available immediately — fetches block on first
        // access until the store is ready, same as before, but the
        // first-frame launch path is no longer gated on disk I/O.
        for description in container.persistentStoreDescriptions {
            description.shouldAddStoreAsynchronously = true
        }

        // S17-D (CV-6): the previous code wiped the store on the
        // first load failure and crashed if the wipe didn't help.
        // The store might not be empty (it is on a fresh install,
        // but an iOS upgrade can hit a model-mismatch on a
        // populated store), and the user has no chance to back
        // the data up before it's gone. New flow:
        //   1. Try the load.
        //   2. On failure: log, set loadState = .migrationFailed,
        //      post a notification, and let the UI present a
        //      "wipe / back-up + wipe" choice. The user picks;
        //      the choice calls `wipeAndReload()` or
        //      `backupAndReload()` below.
        //   3. On success: loadState = .ready.
        //
        // The `MigrationFailureAlert.shared` reference forces
        // the alert singleton to initialize, which registers
        // the NotificationCenter listener before any load
        // callback can fire. Without it, the listener would
        // only register on first access from a SwiftUI view,
        // which is too late on cold launch.
        _ = MigrationFailureAlert.shared
        loadPersistentStores()
    }

    /// Kicks off the persistent-store load. Called from `init`
    /// and from the recovery methods after a wipe / backup.
    /// Async because Core Data's `loadPersistentStores` takes a
    /// completion handler, not a Swift continuation.
    private func loadPersistentStores() {
        let containerRef = container
        containerRef.loadPersistentStores { [weak self] _, error in
            guard let self = self else { return }

            if let error = error as NSError? {
                // S17-D (CV-6): previously a wipe here. Now: log,
                // surface state, post notification, wait for user
                // choice. The wipe is no longer automatic.
                Self.log.error("Persistent store load failed: \(error.localizedDescription, privacy: .public) code=\(error.code) info=\(error.userInfo, privacy: .public)")
                DispatchQueue.main.async {
                    self.loadState = .migrationFailed
                    self.lastError = error
                    NotificationCenter.default.post(
                        name: .persistentStoreMigrationFailed,
                        object: nil,
                        userInfo: ["error": error]
                    )
                }
                return
            }

            Self.log.info("Persistent store loaded successfully")
            DispatchQueue.main.async {
                self.loadState = .ready
                self.lastError = nil
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// User chose "start fresh" in the migration-failure alert.
    /// Removes the SQLite file (and WAL/SHM sidecars) and asks
    /// Core Data to load again, expecting an empty store.
    func wipeAndReload() {
        Self.log.notice("User chose 'wipe and reload' from migration-failure alert")
        DispatchQueue.main.async { self.loadState = .recovering }

        if let storeURL = container.persistentStoreDescriptions.first?.url {
            removeStoreFiles(at: storeURL, logContext: "wipe")
        }

        loadPersistentStores()
    }

    /// User chose "back up & start fresh" in the
    /// migration-failure alert. Moves the broken store file to
    /// a sibling backup file (timestamped) so the user can
    /// extract it via iTunes file sharing if they want, then
    /// asks Core Data to load a fresh empty store.
    func backupAndReload() {
        Self.log.notice("User chose 'back up and reload' from migration-failure alert")
        DispatchQueue.main.async { self.loadState = .recovering }

        if let storeURL = container.persistentStoreDescriptions.first?.url {
            let parent = storeURL.deletingLastPathComponent()
            let backupURL = parent.appendingPathComponent(
                "YTAudioPlayer-\(Int(Date().timeIntervalSince1970)).backup.sqlite"
            )
            do {
                try FileManager.default.moveItem(at: storeURL, to: backupURL)
                let walURL = storeURL.appendingPathExtension("-wal")
                let shmURL = storeURL.appendingPathExtension("-shm")
                // Move sidecars too if they exist; ignore if they don't.
                let walBackup = backupURL.appendingPathExtension("-wal")
                let shmBackup = backupURL.appendingPathExtension("-shm")
                try? FileManager.default.moveItem(at: walURL, to: walBackup)
                try? FileManager.default.moveItem(at: shmURL, to: shmBackup)
                Self.log.info("Backed up broken store to \(backupURL.path, privacy: .public)")
            } catch {
                // If the move fails (e.g. cross-device), fall back
                // to removing the file. The user already saw
                // "we couldn't migrate" and chose to continue —
                // we shouldn't block the app forever on a backup
                // failure.
                Self.log.error("Backup move failed: \(error.localizedDescription, privacy: .public). Falling back to wipe.")
                removeStoreFiles(at: storeURL, logContext: "backup-fallback-wipe")
            }
        }

        loadPersistentStores()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .persistentStoreRecovered, object: nil)
        }
    }

    /// Best-effort removal of the store file + WAL/SHM sidecars.
    /// Each `removeItem` failure is logged but not fatal — we
    /// proceed to the next file so a single stuck WAL doesn't
    /// block the wipe. Returns the list of files that
    /// successfully disappeared, mostly so tests can assert.
    @discardableResult
    private func removeStoreFiles(at storeURL: URL, logContext: String) -> [URL] {
        var removed: [URL] = []
        let candidates = [
            storeURL,
            storeURL.appendingPathExtension("-wal"),
            storeURL.appendingPathExtension("-shm"),
        ]
        for url in candidates {
            do {
                try FileManager.default.removeItem(at: url)
                removed.append(url)
            } catch CocoaError.fileNoSuchFile {
                // Already gone — fine.
            } catch {
                Self.log.error("[\(logContext, privacy: .public)] could not remove \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return removed
    }

    // MARK: - Preview Helper

    static var preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext

        // Create sample data for previews
        for i in 0..<5 {
            let track = CDTrack(context: viewContext)
            track.videoId = "sample\(i)"
            track.title = "Sample Track \(i)"
            track.artists = ["Artist \(i)"]
            track.album = "Sample Album"
            track.durationSeconds = 180
            track.thumbnailURLs = ["https://example.com/thumb\(i).jpg"]
            track.isExplicit = false
            track.videoType = "music_video"
            track.createdAt = Date()
            track.isLiked = i % 2 == 0

            if i < 2 {
                let memory = CDSongMemory(context: viewContext)
                memory.id = UUID()
                memory.noteText = i == 0 ? "This track reminds me of a late-night drive home." : "Played this on repeat while building the app."
                memory.createdAt = Date().addingTimeInterval(Double(-i) * 3600)
                memory.updatedAt = Date().addingTimeInterval(Double(-i) * 1800)
                memory.track = track
            }
        }

        do {
            try viewContext.save()
        } catch {
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }

        return result
    }()

    // MARK: - Context Save Helper

    /// S17-D (CV-6): explicit error surfacing on the view-context
    /// save. The previous `try context.save() { fatalError(...) }`
    /// was correct but unhelpful — the user saw a hard crash with
    /// no recovery path. We now log + rethrow so callers (e.g.
    /// TimeCapsuleManager's encrypt-on-read) can catch + report
    /// without crashing the app.
    func save() throws {
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                Self.log.error("viewContext save failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
    }
}
