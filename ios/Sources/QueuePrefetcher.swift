//
//  QueuePrefetcher.swift
//  YTAudioPlayer
//
//  Smart queue prefetching for continuous playback
//

import Foundation
import Combine

/// Manages automatic queue population and prefetching
class QueuePrefetcher: ObservableObject {
    static let shared = QueuePrefetcher()
    
    private let playerState = PlayerState.shared
    private let batchSize = 10
    private let prefetchThreshold = 3 // When 3 songs left, fetch more
    private var isFetching = false
    private var cancellables = Set<AnyCancellable>()
    private var lastFetchedTrackId: String?
    
    private init() {
        setupPrefetching()
    }
    
    /// Call when starting playback of a track to auto-populate queue
    func autoPopulateQueue(startingFrom track: Track) {
        print("🎵 Auto-populating queue from track: \(track.title)")
        print("🎵 Current queue count: \(playerState.queue.count)")

        // Reset last fetched track ID when starting fresh playback
        // This ensures we can fetch related tracks for the same track again in a new context
        lastFetchedTrackId = nil

        // Clear existing queue if needed (except current item)
        if playerState.queue.isEmpty || playerState.queue.count <= 1 {
            print("🎵 Queue is empty or has 1 item, fetching related tracks...")
            fetchRelatedTracks(for: track.videoId, appendToQueue: true)
        } else {
            print("🎵 Queue already has \(playerState.queue.count) items, skipping auto-populate")
        }
    }

    /// Reset prefetch state - call when user manually clears queue or switches playlists
    func resetPrefetchState() {
        lastFetchedTrackId = nil
        isFetching = false
        cancellables.removeAll()
        setupPrefetching()
    }
    
    private func setupPrefetching() {
        // Monitor queue position to prefetch more
        // Reduced debounce from 0.5s to 0.1s for faster response to user navigation
        playerState.$currentIndex
            .debounce(for: .seconds(0.1), scheduler: DispatchQueue.main)
            .sink { [weak self] index in
                self?.checkAndPrefetch(currentIndex: index)
            }
            .store(in: &cancellables)
    }
    
    private func checkAndPrefetch(currentIndex: Int) {
        guard !isFetching else { return }
        
        let queue = playerState.queue
        let remaining = queue.count - currentIndex - 1
        
        // If less than threshold songs remaining, fetch more
        if remaining <= prefetchThreshold {
            guard let currentTrack = playerState.currentItem?.track else { return }
            
            // Use last track in queue as seed, or current track
            let seedTrackId: String
            if let lastTrack = queue.last?.track {
                seedTrackId = lastTrack.videoId
            } else {
                seedTrackId = currentTrack.videoId
            }
            
            // Avoid duplicate fetches
            guard seedTrackId != lastFetchedTrackId else { return }
            
            fetchRelatedTracks(for: seedTrackId, appendToQueue: true)
        }
    }
    
    private func fetchRelatedTracks(for videoId: String, appendToQueue: Bool) {
        print("🎵 Fetching related tracks for: \(videoId)")
        isFetching = true
        lastFetchedTrackId = videoId
        
        APIService.shared.getRadio(for: videoId)
            .sink(
                receiveCompletion: { [weak self] completion in
                    self?.isFetching = false
                    if case .failure(let error) = completion {
                        print("❌ Queue prefetch failed: \(error)")
                    } else {
                        print("✅ Queue prefetch completed")
                    }
                },
                receiveValue: { [weak self] tracks in
                    print("🎵 Got \(tracks.count) related tracks")
                    self?.addTracksToQueue(tracks, append: appendToQueue)
                }
            )
            .store(in: &cancellables)
    }
    
    private func addTracksToQueue(_ tracks: [Track], append: Bool) {
        print("🎵 Adding tracks to queue. Received: \(tracks.count)")
        
        // Filter out tracks already in queue
        let existingIds = Set(playerState.queue.map { $0.track.videoId })
        let newTracks = tracks.filter { !existingIds.contains($0.videoId) }.prefix(batchSize)
        
        print("🎵 New tracks to add: \(newTracks.count)")
        guard !newTracks.isEmpty else {
            print("🎵 No new tracks to add (all duplicates)")
            return
        }
        
        // Fetch stream URLs and add to queue
        let group = DispatchGroup()
        var streamInfos: [(track: Track, streamUrl: String)] = []
        let processingQueue = DispatchQueue(label: "com.ytaudio.prefetch", attributes: .concurrent)
        
        for track in newTracks {
            group.enter()
            APIService.shared.getStreamUrl(videoId: track.videoId)
                .sink(
                    receiveCompletion: { _ in group.leave() },
                    receiveValue: { streamInfo in
                        processingQueue.async(flags: .barrier) {
                            streamInfos.append((track, streamInfo.streamUrl))
                        }
                    }
                )
                .store(in: &cancellables)
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            
            print("🎵 Fetched \(streamInfos.count) stream URLs, adding to queue...")
            
            // Add tracks in order
            for info in streamInfos {
                let item = QueueItem(
                    track: info.track,
                    streamUrl: info.streamUrl,
                    source: .stream
                )
                
                if append {
                    self.playerState.addToQueue(item)
                } else {
                    // Insert after current
                    self.playerState.addToQueueNext(item)
                }
            }
            
            print("✅ Added \(streamInfos.count) tracks to queue. Total: \(self.playerState.queue.count)")
        }
    }
}
