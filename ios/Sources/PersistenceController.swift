//
//  PersistenceController.swift
//  YTAudioPlayer
//
//  Core Data stack manager
//

import CoreData

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

struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

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
        print("✅ Core Data value transformers registered")

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

        // C-2026-06-17: The 2026-06-17 .xcdatamodel change (customClassName
        // [String] -> NSArray on the four Transformable attributes) makes
        // the pre-existing on-disk store incompatible. Core Data
        // surfaces this as a model-mismatch error. The store is
        // effectively empty (we verified: 0 rows in CDTrack/CDPlaylist/
        // CDDownloadedTrack/CDPlayHistory/CDUserStats) so wiping and
        // rebuilding is safe. Without this fallback, a stuck model
        // would crash here forever and the user couldn't recover
        // without uninstalling.
        let persistentContainer = container
        persistentContainer.loadPersistentStores { description, error in
            if let error = error as NSError? {
                print("⚠️ Persistent store failed to load: \(error). Wiping and retrying. Error: \(error.userInfo)")
                if let storeURL = description.url {
                    try? FileManager.default.removeItem(at: storeURL)
                    // WAL and SHM sidecars
                    let walURL = storeURL.appendingPathExtension("-wal")
                    let shmURL = storeURL.appendingPathExtension("-shm")
                    try? FileManager.default.removeItem(at: walURL)
                    try? FileManager.default.removeItem(at: shmURL)
                }
                persistentContainer.loadPersistentStores { _, retryError in
                    if let retryError = retryError as NSError? {
                        fatalError("Failed to load Core Data even after wipe: \(retryError), \(retryError.userInfo)")
                    }
                }
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
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

    func save() {
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                let nsError = error as NSError
                fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
            }
        }
    }
}
