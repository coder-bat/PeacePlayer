//
//  CDTrack.swift
//  YTAudioPlayer
//
//  Core Data entity for track metadata
//

import Foundation
import CoreData

@objc(CDTrack)
public class CDTrack: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDTrack> {
        return NSFetchRequest<CDTrack>(entityName: "CDTrack")
    }

    @NSManaged public var videoId: String
    @NSManaged public var title: String
    @NSManaged public var artists: [String]
    @NSManaged public var album: String
    @NSManaged public var durationSeconds: Int32
    @NSManaged public var thumbnailURLs: [String]
    @NSManaged public var isExplicit: Bool
    @NSManaged public var videoType: String
    @NSManaged public var createdAt: Date
    @NSManaged public var isLiked: Bool
    @NSManaged public var memory: CDSongMemory?
    @NSManaged public var playHistory: Set<CDPlayHistory>?
    @NSManaged public var download: CDDownloadedTrack?
    @NSManaged public var queueEntry: CDPlaybackQueue?
    @NSManaged public var timeCapsule: CDTimeCapsule?
}

// MARK: - Generated accessors for playHistory
extension CDTrack {
    @objc(addPlayHistoryObject:)
    @NSManaged public func addToPlayHistory(_ value: CDPlayHistory)

    @objc(removePlayHistoryObject:)
    @NSManaged public func removeFromPlayHistory(_ value: CDPlayHistory)

    @objc(addPlayHistory:)
    @NSManaged public func addToPlayHistory(_ values: Set<CDPlayHistory>)

    @objc(removePlayHistory:)
    @NSManaged public func removeFromPlayHistory(_ values: Set<CDPlayHistory>)
}

// MARK: - Convenience Methods
extension CDTrack {
    var toTrack: Track {
        return Track(
            videoId: videoId,
            title: title,
            artists: artists,
            album: album,
            durationSeconds: Int(durationSeconds),
            thumbnails: thumbnailURLs.compactMap { urlString in
                guard let url = URL(string: urlString) else { return nil }
                return Thumbnail(url: url, width: 0, height: 0)
            },
            isExplicit: isExplicit,
            videoType: videoType
        )
    }

    static func from(track: Track, context: NSManagedObjectContext) -> CDTrack {
        let entity = CDTrack(context: context)
        entity.videoId = track.videoId
        entity.title = track.title
        entity.artists = track.artists
        entity.album = track.album
        entity.durationSeconds = Int32(track.durationSeconds)
        entity.thumbnailURLs = track.thumbnails.map { $0.url.absoluteString }
        entity.isExplicit = track.isExplicit
        entity.videoType = track.videoType
        entity.createdAt = Date()
        entity.isLiked = false
        return entity
    }

    var displayArtist: String {
        artists.isEmpty ? "Unknown Artist" : artists.joined(separator: ", ")
    }

    var artworkURL: URL? {
        guard let urlString = thumbnailURLs.last else { return nil }
        return URL(string: urlString)
    }

    var memoryPreviewText: String? {
        memory?.notePreview
    }

    var durationText: String {
        let minutes = Int(durationSeconds) / 60
        let seconds = Int(durationSeconds) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
