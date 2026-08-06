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

    private init() {}

    // MARK: - Setup

    func startObservingPlayerStateIfNeeded(playerState: PlayerState = .shared) {
        guard !hasStartedObserving else { return }
        hasStartedObserving = true

        // Observe queue changes and persist to Core Data
        // S17-G: queue / currentIndex are computed properties on
        // PlayerState, backed by QueueStore. Subscribe to the
        // store's @Published publishers directly.
        playerState.queueStore.$items
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] queue in
                self?.saveQueue(queue, currentIndex: playerState.queueStore.currentIndex)
            }
            .store(in: &cancellables)

        // Observe current index changes
        playerState.queueStore.$currentIndex
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

        // S17-H / UpNext-FIX (2026-08-07): removed the
        // `lastSavedQueueHash` micro-optimization. The 500ms
        // debounce on the queueStore.$items subscription above
        // already coalesces bursts, and the CoreData batch-delete +
        // batch-insert is fast for typical queue sizes (<100). The
        // hash was guarding against a saveQueue call with the
        // exact same contents as last time, but that case only
        // happens on a no-op queue mutation and the wasted
        // CoreData write is negligible compared to the extra
        // property + check.

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
        // S17-H: use NSBatchUpdateRequest for O(1) database-side
        // updates instead of fetching every row, mutating every
        // row, and saving. For a 200-item queue this scales
        // from 200 row mutations + 1 save per track change
        // (called on every advance) to a single SQL UPDATE.
        //
        // Caveat: NSBatchUpdateRequest updates the persistent
        // store directly and bypasses the row cache. We need
        // to refresh the view context so the History / queue
        // list views see the new isCurrent flag. We do that
        // via NSManagedObjectContext.mergeChanges with the
        // batch update result.
        let context = persistence.newBackgroundContext()

        context.perform {
            do {
                // 1) Clear isCurrent on every row except the target index.
                let clearRequest = NSBatchUpdateRequest(entityName: "CDPlaybackQueue")
                clearRequest.predicate = NSPredicate(format: "position != %d", currentIndex)
                clearRequest.propertiesToUpdate = ["isCurrent": false]
                clearRequest.resultType = .updatedObjectIDsResultType

                let clearResult = try context.execute(clearRequest) as? NSBatchUpdateResult
                let clearIDs = clearResult?.result as? [NSManagedObjectID] ?? []

                // 2) Set isCurrent=true on the target row (if it exists).
                let setRequest = NSBatchUpdateRequest(entityName: "CDPlaybackQueue")
                setRequest.predicate = NSPredicate(format: "position == %d", currentIndex)
                setRequest.propertiesToUpdate = ["isCurrent": true]
                setRequest.resultType = .updatedObjectIDsResultType

                let setResult = try context.execute(setRequest) as? NSBatchUpdateResult
                let setIDs = setResult?.result as? [NSManagedObjectID] ?? []

                // 3) Merge the change notifications into the view
                //    context so SwiftUI views reading CDPlaybackQueue
                //    pick up the new isCurrent values.
                let allIDs = clearIDs + setIDs
                if !allIDs.isEmpty {
                    let changes = [NSUpdatedObjectsKey: allIDs]
                    let viewContext = self.persistence.viewContext
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [viewContext])
                }
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
        // S17-H: track which tracks failed to restore so we can
        // surface a one-time error toast at the end. The previous
        // code silently dropped failed restores (the `nil` slots
        // fell out via `compactMap` with no signal to the user).
        // Now: a single toast if any track failed, naming the
        // count, so the user knows why the queue has fewer items
        // than they saved.
        let failedTitles = NSLock()
        var failedCount = 0
        var failedNames: [String] = []
        // S17-H: per-call cancellable set. The previous code
        // stored each `fetchFreshStreamUrl` cancellable into
        // `self.cancellables` (PlaybackQueueManager.shared),
        // which leaked one AnyCancellable per restore call. A
        // user who reopens the app 10 times would accumulate
        // 10×N (N = queue size) dead cancellables. Now each
        // restore uses its own set, which is released when the
        // restore completes.
        var restoreCancellables = Set<AnyCancellable>()

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
            fetchFreshStreamUrl(for: item.track, cancellables: &restoreCancellables) { streamUrl in
                if let url = streamUrl {
                    restoredItems[index] = QueueItem(
                        track: item.track,
                        streamUrl: url,
                        source: .stream
                    )
                } else {
                    // Track the failure for the summary toast.
                    failedTitles.lock()
                    failedCount += 1
                    if failedNames.count < 3 {
                        failedNames.append(item.track.title)
                    }
                    failedTitles.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let validItems = restoredItems.compactMap { $0 }
            print("✅ Restored \(validItems.count)/\(savedItems.count) queue items")
            if failedCount > 0 {
                let names = failedNames.joined(separator: ", ")
                let more = failedCount > failedNames.count ? " and \(failedCount - failedNames.count) more" : ""
                ErrorHandler.shared.show(
                    .parsing("Couldn't restore \(failedCount) track\(failedCount == 1 ? "" : "s") from your last session: \(names)\(more). They may be region-locked or temporarily unavailable.")
                )
            }
            completion(validItems)
        }
    }

    private func fetchFreshStreamUrl(
        for track: Track,
        // S17-H: caller passes its own cancellable set instead of
        // `self.cancellables`. This prevents the per-restore
        // subscription from leaking into the shared set.
        cancellables: inout Set<AnyCancellable>,
        completion: @escaping (String?) -> Void
    ) {
        // Check if local file exists first
        let localURL = AudioFileManager.shared.localFileURL(for: track.videoId)
        if FileManager.default.fileExists(atPath: localURL.path) {
            completion(localURL.absoluteString)
            return
        }

        // Otherwise fetch from API
        StreamURLCache.shared.getStreamUrl(videoId: track.videoId, quality: "low")
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
