//
//  CDPlaylist.swift
//  YTAudioPlayer
//
//  Core Data entity for playlists
//

import Foundation
import CoreData

@objc(CDPlaylist)
public class CDPlaylist: NSManagedObject {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<CDPlaylist> {
        return NSFetchRequest<CDPlaylist>(entityName: "CDPlaylist")
    }

    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var playlistDescription: String?
    @NSManaged public var trackOrder: [String]
    @NSManaged public var createdAt: Date
    @NSManaged public var modifiedAt: Date
    @NSManaged public var isSmart: Bool
    @NSManaged public var smartCriteriaType: String?
    @NSManaged public var artworkSeed: Int32
    @NSManaged public var thumbnailURL: String?
}

// MARK: - Convenience Methods
extension CDPlaylist {
    var toPlaylist: Playlist {
        return Playlist(
            id: id,
            name: name,
            description: playlistDescription,
            trackIds: trackOrder,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            isSmart: isSmart,
            smartCriteria: smartCriteriaType.flatMap { type in
                SmartPlaylistType(rawValue: type).map { SmartCriteria(type: $0) }
            },
            thumbnailURL: thumbnailURL
        )
    }

    static func from(playlist: Playlist, context: NSManagedObjectContext) -> CDPlaylist {
        let entity = CDPlaylist(context: context)
        entity.id = playlist.id
        entity.name = playlist.name
        entity.playlistDescription = playlist.description
        entity.trackOrder = playlist.trackIds
        entity.createdAt = playlist.createdAt
        entity.modifiedAt = playlist.modifiedAt
        entity.isSmart = playlist.isSmart
        entity.smartCriteriaType = playlist.smartCriteria?.type.rawValue
        entity.artworkSeed = Int32(playlist.artworkSeed)
        entity.thumbnailURL = playlist.thumbnailURL
        return entity
    }

    var trackCount: Int {
        trackOrder.count
    }

    var isEmpty: Bool {
        trackOrder.isEmpty
    }

    var isLikedSongsPlaylist: Bool {
        smartCriteriaType == SmartPlaylistType.favorites.rawValue
    }
}
