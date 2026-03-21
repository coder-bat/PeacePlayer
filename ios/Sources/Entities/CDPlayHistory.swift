//
//  CDPlayHistory.swift
//  YTAudioPlayer
//
//  Core Data entity for play history
//

import Foundation
import CoreData

@objc(CDPlayHistory)
public class CDPlayHistory: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDPlayHistory> {
        return NSFetchRequest<CDPlayHistory>(entityName: "CDPlayHistory")
    }

    @NSManaged public var playedAt: Date
    @NSManaged public var progress: Double
    @NSManaged public var completed: Bool
    @NSManaged public var track: CDTrack?
}

// MARK: - Convenience Methods
extension CDPlayHistory {
    static func create(for track: CDTrack, progress: Double = 0, completed: Bool = false, context: NSManagedObjectContext) -> CDPlayHistory {
        let entity = CDPlayHistory(context: context)
        entity.track = track
        entity.playedAt = Date()
        entity.progress = progress
        entity.completed = completed
        return entity
    }
}
