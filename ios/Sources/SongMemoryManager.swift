//
//  SongMemoryManager.swift
//  YTAudioPlayer
//
//  Core Data-backed manager for personal song memory notes
//

import Foundation
import CoreData
import Combine

struct SongMemorySnapshot: Identifiable, Equatable {
    let id: UUID
    let videoId: String
    let noteText: String
    let createdAt: Date
    let updatedAt: Date

    var previewText: String {
        let compactText = noteText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")

        if compactText.count <= 72 {
            return compactText
        }

        return String(compactText.prefix(69)) + "..."
    }

    init?(from memory: CDSongMemory) {
        guard let videoId = memory.track?.videoId else { return nil }

        self.id = memory.id
        self.videoId = videoId
        self.noteText = memory.noteText
        self.createdAt = memory.createdAt
        self.updatedAt = memory.updatedAt
    }
}

final class SongMemoryManager: ObservableObject {
    static let shared = SongMemoryManager()

    @Published private(set) var memoriesByVideoId: [String: SongMemorySnapshot] = [:]

    private let persistence = PersistenceController.shared

    private init() {
        refresh()
    }

    func refresh() {
        let context = persistence.viewContext
        let request: NSFetchRequest<CDSongMemory> = CDSongMemory.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDSongMemory.updatedAt, ascending: false)]
        request.relationshipKeyPathsForPrefetching = ["track"]

        do {
            let memories = try context.fetch(request)
            let snapshots = memories.compactMap(SongMemorySnapshot.init(from:))
            memoriesByVideoId = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.videoId, $0) })
        } catch {
            print("❌ Failed to load song memories: \(error)")
            memoriesByVideoId = [:]
        }
    }

    func memory(for track: Track?) -> SongMemorySnapshot? {
        guard let track else { return nil }
        return memoriesByVideoId[track.videoId]
    }

    func hasMemory(for track: Track?) -> Bool {
        memory(for: track) != nil
    }

    func saveMemory(noteText: String, for track: Track) {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let context = persistence.viewContext

        context.performAndWait {
            let trackEntity = CDTrack.fetchOrCreate(videoId: track.videoId, context: context)
            trackEntity.title = track.title
            trackEntity.artists = track.artists
            trackEntity.album = track.album
            trackEntity.durationSeconds = Int32(track.durationSeconds)
            trackEntity.thumbnailURLs = track.thumbnails.map { $0.url.absoluteString }
            trackEntity.isExplicit = track.isExplicit
            trackEntity.videoType = track.videoType

            if trackEntity.createdAt.timeIntervalSince1970 == 0 {
                trackEntity.createdAt = Date()
            }

            _ = CDSongMemory.upsert(for: trackEntity, noteText: trimmed, context: context)

            do {
                try context.save()
            } catch {
                print("❌ Failed to save song memory: \(error)")
            }
        }

        refresh()
    }

    func deleteMemory(for track: Track) {
        let context = persistence.viewContext
        let request: NSFetchRequest<CDSongMemory> = CDSongMemory.fetchRequest()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "track.videoId == %@", track.videoId)

        context.performAndWait {
            do {
                if let memory = try context.fetch(request).first {
                    context.delete(memory)
                    try context.save()
                }
            } catch {
                print("❌ Failed to delete song memory: \(error)")
            }
        }

        refresh()
    }
}
