//
//  CDUserStats.swift
//  YTAudioPlayer
//
//  Core Data entity for user statistics
//

import Foundation
import CoreData

@objc(CDUserStats)
public class CDUserStats: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDUserStats> {
        return NSFetchRequest<CDUserStats>(entityName: "CDUserStats")
    }

    @NSManaged public var totalListeningSeconds: Double
    @NSManaged public var tracksPlayedCount: Int32
    @NSManaged public var lastUpdated: Date
}

// MARK: - Convenience Methods
extension CDUserStats {
    static func getOrCreate(context: NSManagedObjectContext) -> CDUserStats {
        let request: NSFetchRequest<CDUserStats> = CDUserStats.fetchRequest()

        if let existing = try? context.fetch(request).first {
            return existing
        }

        let stats = CDUserStats(context: context)
        stats.totalListeningSeconds = 0
        stats.tracksPlayedCount = 0
        stats.lastUpdated = Date()
        return stats
    }

    var formattedListeningTime: String {
        let hours = Int(totalListeningSeconds / 3600)
        let minutes = Int((totalListeningSeconds.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    func addListeningTime(_ seconds: TimeInterval) {
        totalListeningSeconds += seconds
        lastUpdated = Date()
    }

    func incrementTracksPlayed() {
        tracksPlayedCount += 1
        lastUpdated = Date()
    }
}
