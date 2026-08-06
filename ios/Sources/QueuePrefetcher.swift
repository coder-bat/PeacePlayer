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

    // CRITICAL FIX: Timeout to prevent isFetching getting stuck
    private var fetchTimeoutTimer: Timer?
    private let fetchTimeout: TimeInterval = 30.0 // 30 second timeout

    // CRITICAL FIX: Track fetch attempts to try different seeds when one fails
    private var failedSeeds: Set<String> = []
    private let maxFailedSeeds = 3

    private init() {
        setupPrefetching()
    }

    /// Reset prefetch state - call when user manually clears queue or switches playlists
    func resetPrefetchState() {
        lastFetchedTrackId = nil
        failedSeeds.removeAll()
        cancelFetchTimeout()
        isFetching = false
        cancellables.removeAll()
        setupPrefetching()
    }

    // CRITICAL FIX: Cancel fetch timeout timer
    private func cancelFetchTimeout() {
        fetchTimeoutTimer?.invalidate()
        fetchTimeoutTimer = nil
    }

    // CRITICAL FIX: Start fetch timeout to prevent isFetching getting stuck
    private func startFetchTimeout() {
        cancelFetchTimeout()
        fetchTimeoutTimer = Timer.scheduledTimer(withTimeInterval: fetchTimeout, repeats: false) { [weak self] _ in
            print("⚠️ QueuePrefetcher: Fetch timeout reached, resetting isFetching flag")
            self?.isFetching = false
            self?.failedSeeds.removeAll()
        }
    }
    
    private func setupPrefetching() {
        // Monitor queue position to prefetch more
        // Reduced debounce from 0.5s to 0.1s for faster response to user navigation
        // S17-G: currentIndex moved to QueueStore. Subscribe to the
        // store's $currentIndex.
        playerState.queueStore.$currentIndex
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

        // CRITICAL FIX: If queue is nearly empty, reset lastFetchedTrackId to allow refetching
        if remaining <= 1 {
            print("🎵 Queue nearly empty (\(remaining) remaining), resetting fetch state")
            lastFetchedTrackId = nil
        }

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

            // CRITICAL FIX: If we've failed with this seed too many times, try current track
            if failedSeeds.contains(seedTrackId) && failedSeeds.count < maxFailedSeeds {
                print("🎵 Seed \(seedTrackId) previously failed, trying current track instead")
                fetchRelatedTracks(for: currentTrack.videoId, appendToQueue: true)
                return
            }

            // Avoid duplicate fetches unless queue is nearly empty (allowing refetch)
            guard seedTrackId != lastFetchedTrackId || remaining <= 1 else {
                print("🎵 Already fetched for seed \(seedTrackId), skipping")
                return
            }

            fetchRelatedTracks(for: seedTrackId, appendToQueue: true)
        }
    }
    
    private func fetchRelatedTracks(for videoId: String, appendToQueue: Bool) {
        print("🎵 Fetching related tracks for: \(videoId)")
        isFetching = true
        lastFetchedTrackId = videoId
        startFetchTimeout() // CRITICAL FIX: Start timeout to prevent stuck state

        APIService.shared.getRadio(for: videoId)
            .sink(
                receiveCompletion: { [weak self] completion in
                    self?.cancelFetchTimeout() // Cancel timeout on completion
                    self?.isFetching = false
                    if case .failure(let error) = completion {
                        print("❌ Queue prefetch failed: \(error)")
                        self?.failedSeeds.insert(videoId) // CRITICAL FIX: Track failed seed
                        // CRITICAL FIX: Try to fetch with a different seed if this one failed
                        self?.tryFallbackFetch()
                    } else {
                        print("✅ Queue prefetch completed")
                        self?.failedSeeds.removeAll() // Clear failed seeds on success
                    }
                },
                receiveValue: { [weak self] tracks in
                    print("🎵 Got \(tracks.count) related tracks")
                    self?.addTracksToQueue(tracks, append: appendToQueue, seedVideoId: videoId)
                }
            )
            .store(in: &cancellables)
    }

    // CRITICAL FIX: Try to fetch with current track as fallback
    private func tryFallbackFetch() {
        guard let currentTrack = playerState.currentItem?.track else {
            // No current track — skip directly to local-library fallback
            // (a tap-before-fetch race can land us here).
            populateQueueFromLocalLibrary(reason: "no-current-track")
            return
        }
        guard !failedSeeds.contains(currentTrack.videoId) else {
            // The current track was already tried and failed as a
            // seed. Skip the redundant /radio call and go straight
            // to the local-library fallback.
            populateQueueFromLocalLibrary(reason: "current-seed-already-failed")
            return
        }
        guard failedSeeds.count < maxFailedSeeds else {
            // S17-H / UpNext-FIX (2026-08-07): instead of just clearing
            // and giving up (the old behavior, which left the user with
            // silence), try the local-library fallback first. If that
            // also comes up empty, THEN clear and bail.
            populateQueueFromLocalLibrary(reason: "too-many-failed-seeds")
            failedSeeds.removeAll()
            return
        }

        print("🎵 Trying fallback fetch with current track: \(currentTrack.title)")
        // Mark the current track as a tried-but-failed seed so the
        // next /radio call (if we end up here again) goes straight
        // to local-library fallback. Without this, the prefetcher
        // could ping-pong between the same two failing seeds.
        failedSeeds.insert(currentTrack.videoId)
        fetchRelatedTracks(for: currentTrack.videoId, appendToQueue: true)
    }

    // S17-H / UpNext-FIX (2026-08-07): when /radio fails (region
    // lock, yt-dlp parser regression, backend down, etc.), fall back
    // to local content the user already has. Priority:
    //   1. Recently played tracks (user has shown interest in these)
    //   2. Downloaded local files (always available, even offline)
    //   3. Empty queue + log a warning (last resort)
    //
    // Each source is bounded to 10 tracks (matching the radio batch
    // size) and respects the user's shuffle state. We dedupe against
    // the current queue so we don't re-add the currently-playing
    // track or anything already queued.
    private func populateQueueFromLocalLibrary(reason: String) {
        print("🎵 UpNext fallback: pulling from local library (reason: \(reason))")

        let existingIds = Set(playerState.queue.map { $0.track.videoId })
        var addedCount = 0

        // Source 1: recently played. These are tracks the user has
        // actually listened to — high signal that they'll want to
        // hear them again. We skip tracks already in the queue and
        // the currently-playing track.
        let recents = DataManager.shared.recentlyPlayed
            .filter { !existingIds.contains($0.videoId) }
            .prefix(batchSize)
        for recent in recents {
            // RecentTrack already exposes a `toTrack` computed
            // property (see DataManager.swift:277). Use it to
            // convert without re-listing every field.
            let track = recent.toTrack
            if let item = makeQueueItem(for: track) {
                playerState.addToQueue(item)
                existingIds.insert(track.videoId)
                addedCount += 1
            }
        }

        // Source 2: downloaded local files. Available offline, no
        // network roundtrip, instant playback. Skips anything we
        // already added from recents.
        if addedCount < batchSize {
            let downloaded = AudioFileManager.shared.allDownloadedFiles()
            for (videoId, url, _) in downloaded {
                if existingIds.contains(videoId) { continue }
                if addedCount >= batchSize { break }
                guard let track = TrackStore.shared.getTrack(videoId: videoId) else { continue }
                let item = QueueItem(
                    track: track,
                    streamUrl: url.absoluteString,
                    source: .local(path: url.path),
                    contentSource: .local
                )
                playerState.addToQueue(item)
                existingIds.insert(videoId)
                addedCount += 1
            }
        }

        if addedCount > 0 {
            print("✅ UpNext fallback: added \(addedCount) tracks from local library")
        } else {
            // Last resort: log a structured warning. The user gets
            // silence after the current track, but at least we have
            // a clear signal in the logs.
            print("⚠️ UpNext fallback: no local content available — queue will be silent after current track")
        }
    }

    // Build a QueueItem for a Track. Tries local file first (instant
    // playback, no /stream roundtrip), falls back to a stream URL
    // fetch via StreamURLCache.
    //
    // Returns nil only if both paths fail (no local file AND no
    // network). The caller treats nil as "skip this track" and
    // moves to the next.
    private func makeQueueItem(for track: Track) -> QueueItem? {
        // Local file: instant, no network. This is the common case
        // for downloaded tracks.
        let localURL = AudioFileManager.shared.localFileURL(for: track.videoId)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return QueueItem(
                track: track,
                streamUrl: localURL.absoluteString,
                source: .local(path: localURL.path),
                contentSource: .local
            )
        }
        // Stream: requires a stream URL. We can't await async here
        // (this is called from a sync context), so we kick off a
        // background fetch and add a placeholder. The player will
        // resolve the real URL when the track comes up in the queue.
        //
        // For the local-library fallback case, the tracks we
        // surface are almost always ones the user has played
        // recently — so their stream URLs are likely already in
        // StreamURLCache. We do a best-effort sync lookup via
        // the cached value.
        if let cached = StreamURLCache.shared.cachedStreamUrl(for: track.videoId) {
            return QueueItem(
                track: track,
                streamUrl: cached,
                source: .stream
            )
        }
        // No local file, no cached stream URL. Skip this track —
        // the prefetcher can't queue something it can't play.
        return nil
    }

    private func addTracksToQueue(_ tracks: [Track], append: Bool, seedVideoId: String) {
        print("🎵 Adding tracks to queue. Received: \(tracks.count)")

        // Filter out tracks already in queue
        let existingIds = Set(playerState.queue.map { $0.track.videoId })
        let newTracks = tracks.filter { !existingIds.contains($0.videoId) }.prefix(batchSize)

        print("🎵 New tracks to add: \(newTracks.count)")

        // CRITICAL FIX: If no new tracks (all duplicates), mark seed as failed and try fallback
        guard !newTracks.isEmpty else {
            print("🎵 No new tracks to add (all duplicates), marking seed as failed")
            failedSeeds.insert(seedVideoId)
            tryFallbackFetch()
            return
        }

        // Clear this seed from failed list since it returned new tracks
        failedSeeds.remove(seedVideoId)
        
        // Fetch stream URLs and add to queue
        let group = DispatchGroup()
        var streamInfos: [(track: Track, streamUrl: String)] = []
        let processingQueue = DispatchQueue(label: "com.ytaudio.prefetch", attributes: .concurrent)
        
        for track in newTracks {
            group.enter()
            StreamURLCache.shared.getStreamUrl(videoId: track.videoId)
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
