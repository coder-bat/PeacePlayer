//
//  CDTimeCapsule.swift
//  YTAudioPlayer
//
//  Core Data entity for time capsules — sealed song + note unlocked at future date.
//
//  2026-07-15 (S17-C, CV-2): added `encryptedNote: Data?` (AES-GCM
//  ciphertext + nonce + tag) and kept `noteText: String` as a
//  legacy plaintext column. New rows write only to `encryptedNote`
//  and leave `noteText` empty. The on-read migration in
//  TimeCapsuleManager upgrades legacy rows: encrypt the existing
//  plaintext, write to `encryptedNote`, then clear `noteText`.
//  After the first read per legacy row, the plaintext column is
//  empty for that row, so the model no longer holds any
//  user-sealed text in clear.
//

import Foundation
import CoreData

@objc(CDTimeCapsule)
public class CDTimeCapsule: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDTimeCapsule> {
        NSFetchRequest<CDTimeCapsule>(entityName: "CDTimeCapsule")
    }

    @NSManaged public var id: UUID
    /// Legacy plaintext column. New capsules leave this empty and
    /// store the sealed note in `encryptedNote` instead. Cleared
    /// for legacy rows on first read after the S17-C upgrade.
    @NSManaged public var noteText: String
    /// AES-GCM ciphertext blob for the sealed note (v3 model).
    /// `nil` for legacy plaintext rows that haven't been migrated
    /// yet; populated on first read. New rows write directly here.
    @NSManaged public var encryptedNote: Data?
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
