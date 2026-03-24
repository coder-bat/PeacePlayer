//
//  PlaybackQueueManager.swift
//  YTAudioPlayer
//
//  Manages playback queue persistence using Core Data
//

import Foundation
import Combine
import CoreData

/// Manages saving and loading the playback queue to/from Core Data
class PlaybackQueueManager: ObservableObject {
    static let shared = PlaybackQueueManager()

    private let persistence = PersistenceController.shared
    private var cancellables = Set<AnyCancellable>()
    private var hasStartedObserving = false

    // Track the last saved queue state to avoid redundant saves
    private var lastSavedQueueHash: Int?

    private init() {}

    // MARK: - Setup

    func startObservingPlayerStateIfNeeded(playerState: PlayerState = .shared) {
        guard !hasStartedObserving else { return }
        hasStartedObserving = true

        // Observe queue changes and persist to Core Data
        playerState.$queue
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] queue in
                self?.saveQueue(queue, currentIndex: playerState.currentIndex)
            }
            .store(in: &cancellables)

        // Observe current index changes
        playerState.$currentIndex
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] currentIndex in
                self?.updateCurrentItem(currentIndex: currentIndex)
            }
            .store(in: &cancellables)
    }

    // MARK: - Save Queue

    func saveQueue(_ queue: [QueueItem], currentIndex: Int = 0) {
        // Skip if queue is empty (we'll clear instead)
        guard !queue.isEmpty else {
            clearSavedQueue()
            return
        }

        // Check if queue has actually changed using a simple hash
        let queueHash = queue.map { $0.track.videoId }.joined().hashValue
        guard queueHash != lastSavedQueueHash else { return }
        lastSavedQueueHash = queueHash

        let context = persistence.newBackgroundContext()

        context.perform { [weak self] in
            guard let self = self else { return }

            do {
                // Clear existing queue
                let fetchRequest: NSFetchRequest<NSFetchRequestResult> = CDPlaybackQueue.fetchRequest()
                let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
                deleteRequest.resultType = .resultTypeObjectIDs

                let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
                if let objectIDs = result?.result as? [NSManagedObjectID] {
                    let changes = [NSDeletedObjectsKey: objectIDs]
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
                }

                // Save new queue items
                for (index, item) in queue.enumerated() {
                    self.saveQueueItem(item, position: index, currentIndex: currentIndex, context: context)
                }

                try context.save()

                DispatchQueue.main.async {
                    print("💾 Saved \(queue.count) queue items to Core Data")
                }
            } catch {
                DispatchQueue.main.async {
                    print("❌ Error saving queue: \(error)")
                }
            }
        }
    }

    private func saveQueueItem(_ item: QueueItem, position: Int, currentIndex: Int, context: NSManagedObjectContext) {
        // Fetch or create the track entity
        let trackEntity = CDTrack.fetchOrCreate(
            videoId: item.track.videoId,
            context: context
        ) { entity in
            entity.title = item.track.title
            entity.artists = item.track.artists
            entity.album = item.track.album
            entity.durationSeconds = Int32(item.track.durationSeconds)
            entity.thumbnailURLs = item.track.thumbnails.map { $0.url.absoluteString }
            entity.isExplicit = item.track.isExplicit
            entity.videoType = item.track.videoType
            entity.createdAt = Date()
            entity.isLiked = false
        }

        // Create queue entry
        let queueEntry = CDPlaybackQueue(context: context)
        queueEntry.position = Int32(position)
        queueEntry.addedAt = item.createdAt
        queueEntry.isCurrent = (position == currentIndex)
        queueEntry.track = trackEntity

        // Store stream URL only for local files (they don't expire)
        if case .local = item.source {
            queueEntry.streamUrl = item.streamUrl
        }
    }

    private func updateCurrentItem(currentIndex: Int) {
        let context = persistence.newBackgroundContext()

        context.perform {
            do {
                // Fetch all queue items
                let request: NSFetchRequest<CDPlaybackQueue> = CDPlaybackQueue.fetchRequest()
                request.sortDescriptors = [NSSortDescriptor(keyPath: \CDPlaybackQueue.position, ascending: true)]
                let items = try context.fetch(request)

                // Update isCurrent flag
                for (index, item) in items.enumerated() {
                    item.isCurrent = (index == currentIndex)
                }

                try context.save()
            } catch {
                print("❌ Error updating current item: \(error)")
            }
        }
    }

    // MARK: - Load Queue

    /// Loads the persisted queue and returns track information for stream URL refetching
    func loadQueue() -> [(track: Track, wasLocal: Bool, streamUrl: String?)] {
        let context = persistence.viewContext

        let request: NSFetchRequest<CDPlaybackQueue> = CDPlaybackQueue.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDPlaybackQueue.position, ascending: true)]

        do {
            let items = try context.fetch(request)

            let result = items.compactMap { item -> (track: Track, wasLocal: Bool, streamUrl: String?)? in
                guard let track = item.track else { return nil }
                let wasLocal = item.streamUrl != nil
                return (track: track.toTrack, wasLocal: wasLocal, streamUrl: item.streamUrl)
            }

            print("📂 Loaded \(result.count) queue items from Core Data")
            return result
        } catch {
            print("❌ Error loading queue: \(error)")
            return []
        }
    }

    /// Restores the queue by fetching fresh stream URLs for each track
    func restoreQueue(completion: @escaping ([QueueItem]) -> Void) {
        let savedItems = loadQueue()
        guard !savedItems.isEmpty else {
            completion([])
            return
        }

        var restoredItems: [QueueItem?] = Array(repeating: nil, count: savedItems.count)
        let group = DispatchGroup()

        for (index, item) in savedItems.enumerated() {
            // If it was a local file and still exists, use the local path
            if item.wasLocal,
               let streamUrl = item.streamUrl,
               FileManager.default.fileExists(atPath: URL(string: streamUrl)?.path ?? "") {
                restoredItems[index] = QueueItem(
                    track: item.track,
                    streamUrl: streamUrl,
                    source: .local(path: URL(string: streamUrl)!.path)
                )
                continue
            }

            // Otherwise, fetch a fresh stream URL
            group.enter()
            fetchFreshStreamUrl(for: item.track) { streamUrl in
                if let url = streamUrl {
                    restoredItems[index] = QueueItem(
                        track: item.track,
                        streamUrl: url,
                        source: .stream
                    )
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let validItems = restoredItems.compactMap { $0 }
            print("✅ Restored \(validItems.count)/\(savedItems.count) queue items")
            completion(validItems)
        }
    }

    private func fetchFreshStreamUrl(for track: Track, completion: @escaping (String?) -> Void) {
        // Check if local file exists first
        let localURL = AudioFileManager.shared.localFileURL(for: track.videoId)
        if FileManager.default.fileExists(atPath: localURL.path) {
            completion(localURL.absoluteString)
            return
        }

        // Otherwise fetch from API
        APIService.shared.getStreamUrl(videoId: track.videoId, quality: "low")
            .sink(
                receiveCompletion: { result in
                    if case .failure(let error) = result {
                        print("❌ Failed to restore stream URL for \(track.title): \(error)")
                        completion(nil)
                    }
                },
                receiveValue: { streamInfo in
                    completion(streamInfo.streamUrl)
                }
            )
            .store(in: &cancellables)
    }

    // MARK: - Clear Queue

    func clearSavedQueue() {
        lastSavedQueueHash = nil

        let context = persistence.newBackgroundContext()

        context.perform {
            do {
                let request: NSFetchRequest<NSFetchRequestResult> = CDPlaybackQueue.fetchRequest()
                let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
                deleteRequest.resultType = .resultTypeObjectIDs

                let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
                if let objectIDs = result?.result as? [NSManagedObjectID] {
                    let changes = [NSDeletedObjectsKey: objectIDs]
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
                }

                try context.save()
                print("🗑️ Cleared saved queue from Core Data")
            } catch {
                print("❌ Error clearing queue: \(error)")
            }
        }
    }

    // MARK: - Get Current Queue Position

    func getSavedCurrentIndex() -> Int {
        let context = persistence.viewContext

        let request: NSFetchRequest<CDPlaybackQueue> = CDPlaybackQueue.fetchRequest()
        request.predicate = NSPredicate(format: "isCurrent == YES")
        request.fetchLimit = 1

        do {
            if let current = try context.fetch(request).first {
                return Int(current.position)
            }
        } catch {
            print("❌ Error fetching current index: \(error)")
        }

        return 0
    }
}

// MARK: - CDTrack Extension

extension CDTrack {
    /// Fetches an existing track or creates a new one
    static func fetchOrCreate(
        videoId: String,
        context: NSManagedObjectContext,
        configure: ((CDTrack) -> Void)? = nil
    ) -> CDTrack {
        let request: NSFetchRequest<CDTrack> = fetchRequest()
        request.predicate = NSPredicate(format: "videoId == %@", videoId)
        request.fetchLimit = 1

        if let existing = try? context.fetch(request).first {
            return existing
        }

        let entity = CDTrack(context: context)
        entity.videoId = videoId
        configure?(entity)
        return entity
    }
}
