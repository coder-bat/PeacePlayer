//
//  CDTimeCapsule.swift
//  YTAudioPlayer
//
//  Core Data entity for time capsules — sealed song + note unlocked at future date.
//

import Foundation
import CoreData

@objc(CDTimeCapsule)
public class CDTimeCapsule: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDTimeCapsule> {
        NSFetchRequest<CDTimeCapsule>(entityName: "CDTimeCapsule")
    }

    @NSManaged public var id: UUID
    @NSManaged public var noteText: String
    @NSManaged public var createdAt: Date
    @NSManaged public var unlockAt: Date
    @NSManaged public var isOpened: Bool
    @NSManaged public var openedAt: Date?
    @NSManaged public var mood: String?
    @NSManaged public var track: CDTrack?
}

extension CDTimeCapsule {
    var isUnlocked: Bool {
        Date() >= unlockAt
    }

    var isReadyToOpen: Bool {
        isUnlocked && !isOpened
    }

    var daysUntilUnlock: Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: Date(), to: unlockAt)
        return max(0, components.day ?? 0)
    }

    var daysAgo: Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day], from: createdAt, to: Date())
        return max(0, components.day ?? 0)
    }
}
