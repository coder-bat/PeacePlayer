//
//  DeepLinkIndex.swift
//  PeacePlayer
//
//  S18 / v1.6 / P1-5
//
//  In-memory + UserDefaults-backed cache of radio stations, podcast
//  shows, and audiobooks. The top-N lists are cached here whenever
//  RadioViewModel loads them, so deep-link resolution works for any
//  item the user has ever seen (even if they've since navigated away
//  or restarted the app).
//
//  Without this, peaceplayer://radio/{stationId} /podcast/{feedUrl} /
//  audiobook/{bookId} would only resolve while the user was sitting
//  on the Radio tab — and the radio tab creates a fresh RadioViewModel
//  on every navigation push, so even switching tabs was enough to
//  drop the items out of memory. Persisting to UserDefaults fixes
//  both.
//
//  Capacity is bounded (200 per type) so the cache can't grow
//  unbounded as the user explores new genres. Items are dropped
//  in insertion order (oldest first) when the cap is hit.
//
//  Thread safety: the cache is not @MainActor-isolated because
//  RadioViewModel's Combine sinks fire on background queues, and
//  we'd rather not bounce every cache write through the main
//  queue. The cache is treated as best-effort: UserDefaults is
//  thread-safe; the in-memory dict writes are serialized by
//  Combine's per-subscriber ordering, so two concurrent updates
//  may lose one item but the cache will converge on the next
//  refresh. Deep-link reads happen on the main thread.
//

import Foundation

final class DeepLinkIndex {
    static let shared = DeepLinkIndex()

    // UserDefaults keys. Versioned so a future format change can
    // blow away the old keys without manual migration.
    private let stationsKey = "dlc.stations.v1"
    private let podcastsKey = "dlc.podcasts.v1"
    private let audiobooksKey = "dlc.audiobooks.v1"

    // Max items per type. 200 covers the top-30/genre-30/list-30
    // combinations the user is realistically going to see, with
    // headroom for search results.
    private let maxItemsPerType = 200

    private(set) var stations: [String: RadioStation] = [:]
    private(set) var podcasts: [String: PodcastShow] = [:]    // keyed by feedUrl
    private(set) var audiobooks: [String: Audiobook] = [:]    // keyed by id

    // Insertion order for eviction. Bounded to maxItemsPerType
    // so the memory cost stays predictable.
    private var stationOrder: [String] = []
    private var podcastOrder: [String] = []
    private var audiobookOrder: [String] = []

    private init() {
        hydrate()
    }

    // MARK: - Updates

    func updateStations(_ list: [RadioStation]) {
        for s in list {
            if stations[s.stationuuid] == nil {
                stationOrder.append(s.stationuuid)
            }
            stations[s.stationuuid] = s
        }
        evict(&stationOrder, &stations)
        persist(stations, key: stationsKey)
    }

    func updatePodcasts(_ list: [PodcastShow]) {
        for p in list {
            if podcasts[p.feedUrl] == nil {
                podcastOrder.append(p.feedUrl)
            }
            podcasts[p.feedUrl] = p
        }
        evict(&podcastOrder, &podcasts)
        persist(podcasts, key: podcastsKey)
    }

    func updateAudiobooks(_ list: [Audiobook]) {
        for b in list {
            if audiobooks[b.id] == nil {
                audiobookOrder.append(b.id)
            }
            audiobooks[b.id] = b
        }
        evict(&audiobookOrder, &audiobooks)
        persist(audiobooks, key: audiobooksKey)
    }

    // MARK: - Lookups (for handleDeepLink)

    func findStation(_ stationId: String) -> RadioStation? {
        stations[stationId]
    }

    func findPodcast(_ feedUrl: String) -> PodcastShow? {
        podcasts[feedUrl]
    }

    func findAudiobook(_ bookId: String) -> Audiobook? {
        audiobooks[bookId]
    }

    // MARK: - Persistence

    private func hydrate() {
        if let data = UserDefaults.standard.data(forKey: stationsKey),
           let decoded = try? JSONDecoder().decode([RadioStation].self, from: data) {
            for s in decoded {
                stations[s.stationuuid] = s
                stationOrder.append(s.stationuuid)
            }
        }
        if let data = UserDefaults.standard.data(forKey: podcastsKey),
           let decoded = try? JSONDecoder().decode([PodcastShow].self, from: data) {
            for p in decoded {
                podcasts[p.feedUrl] = p
                podcastOrder.append(p.feedUrl)
            }
        }
        if let data = UserDefaults.standard.data(forKey: audiobooksKey),
           let decoded = try? JSONDecoder().decode([Audiobook].self, from: data) {
            for b in decoded {
                audiobooks[b.id] = b
                audiobookOrder.append(b.id)
            }
        }
    }

    private func persist<T: Codable>(_ dict: [String: T], key: String) {
        let array = Array(dict.values)
        guard let data = try? JSONEncoder().encode(array) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    // MARK: - Eviction

    /// Drop oldest entries when the in-memory order exceeds the cap.
    /// We evict from BOTH the dict and the order list so a future
    /// hydrate() round-trip is consistent.
    private func evict<T>(_ order: inout [String], _ dict: inout [String: T]) {
        while order.count > maxItemsPerType {
            let dropped = order.removeFirst()
            dict.removeValue(forKey: dropped)
        }
    }
}
