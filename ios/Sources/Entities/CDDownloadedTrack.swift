//
//  CDDownloadedTrack.swift
//  YTAudioPlayer
//
//  Core Data entity for downloaded track metadata
//

import Foundation
import CoreData

@objc(CDDownloadedTrack)
public class CDDownloadedTrack: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDDownloadedTrack> {
        return NSFetchRequest<CDDownloadedTrack>(entityName: "CDDownloadedTrack")
    }

    @NSManaged public var localPath: String
    @NSManaged public var fileSize: Int64
    @NSManaged public var downloadedAt: Date
    @NSManaged public var quality: String
    @NSManaged public var mimeType: String
    @NSManaged public var track: CDTrack?
}

// MARK: - Convenience Methods
extension CDDownloadedTrack {
    var fileURL: URL? {
        return URL(fileURLWithPath: localPath)
    }

    var fileSizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }

    var exists: Bool {
        guard let url = fileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func create(for track: CDTrack, localPath: String, fileSize: Int64, quality: String = "high", mimeType: String = "audio/mp4", context: NSManagedObjectContext) -> CDDownloadedTrack {
        let entity = CDDownloadedTrack(context: context)
        entity.track = track
        entity.localPath = localPath
        entity.fileSize = fileSize
        entity.quality = quality
        entity.mimeType = mimeType
        entity.downloadedAt = Date()
        return entity
    }
}
