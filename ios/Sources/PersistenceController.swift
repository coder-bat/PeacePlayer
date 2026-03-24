//
//  PersistenceController.swift
//  YTAudioPlayer
//
//  Core Data stack manager
//

import CoreData

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
        container = NSPersistentContainer(name: "YTAudioPlayer")

        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { description, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
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
