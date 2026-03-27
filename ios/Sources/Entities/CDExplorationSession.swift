//
//  CDExplorationSession.swift
//  YTAudioPlayer
//
//  Core Data entity for Anti-Algorithm exploration sessions.
//

import Foundation
import CoreData

@objc(CDExplorationSession)
public class CDExplorationSession: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDExplorationSession> {
        NSFetchRequest<CDExplorationSession>(entityName: "CDExplorationSession")
    }

    @NSManaged public var id: UUID
    @NSManaged public var startedAt: Date
    @NSManaged public var seedVideoIds: [String]
    @NSManaged public var explorationRadius: Float
    @NSManaged public var tracksQueued: Int16
    @NSManaged public var tracksCompleted: Int16
    @NSManaged public var tracksSkipped: Int16
    @NSManaged public var tracksLiked: Int16
}

extension CDExplorationSession {
    var completionRate: Float {
        guard tracksQueued > 0 else { return 0 }
        return Float(tracksCompleted) / Float(tracksQueued)
    }

    var likeRate: Float {
        let played = tracksCompleted + tracksSkipped
        guard played > 0 else { return 0 }
        return Float(tracksLiked) / Float(played)
    }
}
