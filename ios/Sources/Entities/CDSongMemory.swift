//
//  CDSongMemory.swift
//  YTAudioPlayer
//
//  Core Data entity for per-song memory notes
//

import Foundation
import CoreData

@objc(CDSongMemory)
public class CDSongMemory: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDSongMemory> {
        NSFetchRequest<CDSongMemory>(entityName: "CDSongMemory")
    }

    @NSManaged public var id: UUID
    @NSManaged public var noteText: String
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
    @NSManaged public var track: CDTrack?
}

extension CDSongMemory {
    static func upsert(for track: CDTrack, noteText: String, context: NSManagedObjectContext) -> CDSongMemory {
        let memory = track.memory ?? CDSongMemory(context: context)
        let now = Date()

        if track.memory == nil {
            memory.id = UUID()
            memory.createdAt = now
        }

        memory.noteText = noteText
        memory.updatedAt = now
        memory.track = track
        return memory
    }

    var notePreview: String {
        let compactText = noteText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        if compactText.count <= 72 {
            return compactText
        }

        return String(compactText.prefix(69)) + "..."
    }
}
