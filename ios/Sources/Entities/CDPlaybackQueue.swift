//
//  CDPlaybackQueue.swift
//  YTAudioPlayer
//
//  Core Data entity for playback queue persistence
//

import Foundation
import CoreData

@objc(CDPlaybackQueue)
public class CDPlaybackQueue: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDPlaybackQueue> {
        return NSFetchRequest<CDPlaybackQueue>(entityName: "CDPlaybackQueue")
    }

    @NSManaged public var addedAt: Date
    @NSManaged public var isCurrent: Bool
    @NSManaged public var position: Int32
    @NSManaged public var streamUrl: String?
    @NSManaged public var track: CDTrack?
}

// MARK: - Convenience Methods
extension CDPlaybackQueue {
    /// Fetch all queue items sorted by position
    static func fetchAllSorted(context: NSManagedObjectContext) -> [CDPlaybackQueue] {
        let request: NSFetchRequest<CDPlaybackQueue> = fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDPlaybackQueue.position, ascending: true)]
        do {
            return try context.fetch(request)
        } catch {
            print("❌ Error fetching queue: \(error)")
            return []
        }
    }

    /// Clear all queue items
    static func clearAll(context: NSManagedObjectContext) {
        let request: NSFetchRequest<NSFetchRequestResult> = fetchRequest()
        let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
        deleteRequest.resultType = .resultTypeObjectIDs
        do {
            let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
            if let objectIDs = result?.result as? [NSManagedObjectID] {
                let changes = [NSDeletedObjectsKey: objectIDs]
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
            }
            print("🗑️ Cleared all queue items")
        } catch {
            print("❌ Error clearing queue: \(error)")
        }
    }

    /// Get the current queue item (isCurrent = true)
    static func fetchCurrent(context: NSManagedObjectContext) -> CDPlaybackQueue? {
        let request: NSFetchRequest<CDPlaybackQueue> = fetchRequest()
        request.predicate = NSPredicate(format: "isCurrent == YES")
        request.fetchLimit = 1
        do {
            return try context.fetch(request).first
        } catch {
            print("❌ Error fetching current queue item: \(error)")
            return nil
        }
    }
}
