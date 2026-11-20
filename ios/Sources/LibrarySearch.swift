//
//  LibrarySearch.swift
//  YTAudioPlayer
//
//  Searching what the user already has: downloaded songs, liked songs
//  and their own playlists.
//
//  2026-11-21: the Library tab used to have its own search field. It
//  is gone; the Search tab now answers "do I have it?" and "can I get
//  it?" from one field. Library matches are found on the device, with
//  no request and no debounce, so they are on screen while the catalogue
//  search is still on its way.
//

import Foundation
import CoreData

/// What the library holds for a query.
struct LibrarySearchResults: Equatable {
    var tracks: [Track] = []
    var playlists: [Playlist] = []
    /// Which of `tracks` are on disk.
    var downloadedIDs: Set<String> = []

    var isEmpty: Bool { tracks.isEmpty && playlists.isEmpty }
    var count: Int { tracks.count + playlists.count }
}

enum LibrarySearch {
    /// Folds case and accents, so "beyonce" finds "Beyoncé".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How well a track answers a query; nil when it does not.
    /// Lower is better: the title starting with the query, then a word
    /// in the title starting with it, then the title containing it,
    /// then the artist, then the album.
    static func rank(of track: Track, for query: String) -> Int? {
        let q = fold(query)
        guard !q.isEmpty else { return nil }
        let title = fold(track.title)
        if title.hasPrefix(q) { return 0 }
        if title.contains(" " + q) { return 1 }
        if title.contains(q) { return 2 }
        let artists = fold(track.artists.joined(separator: " "))
        if artists.hasPrefix(q) || artists.contains(" " + q) { return 3 }
        if artists.contains(q) { return 4 }
        if fold(track.album).contains(q) { return 5 }
        // Every word of the query somewhere in title + artist:
        // "nina good" finds "Feeling Good" by Nina Simone.
        let words = q.split(separator: " ")
        if words.count > 1 {
            let haystack = title + " " + artists
            if words.allSatisfy({ haystack.contains($0) }) { return 6 }
        }
        return nil
    }

    /// The library's answer to `query`.
    ///
    /// A song that is both downloaded and liked appears once. Within a
    /// rank, downloaded songs come first — they play at once, offline
    /// — and otherwise the order the caller gave is kept.
    static func results(
        for query: String,
        downloaded: [Track],
        liked: [Track],
        playlists: [Playlist]
    ) -> LibrarySearchResults {
        let q = fold(query)
        guard !q.isEmpty else { return LibrarySearchResults() }

        let downloadedIDs = Set(downloaded.map(\.videoId))
        var seen = Set<String>()
        var ranked: [(rank: Int, order: Int, track: Track)] = []
        for (order, track) in (downloaded + liked).enumerated() {
            guard let rank = rank(of: track, for: q), seen.insert(track.videoId).inserted else { continue }
            ranked.append((rank, order, track))
        }
        ranked.sort { ($0.rank, $0.order) < ($1.rank, $1.order) }

        let matchedPlaylists = playlists
            .filter { !$0.isSmart && fold($0.name).contains(q) }
            .sorted { lhs, rhs in
                let l = fold(lhs.name).hasPrefix(q), r = fold(rhs.name).hasPrefix(q)
                return l != r ? l : lhs.modifiedAt > rhs.modifiedAt
            }

        let tracks = ranked.map(\.track)
        return LibrarySearchResults(
            tracks: tracks,
            playlists: matchedPlaylists,
            downloadedIDs: downloadedIDs.intersection(tracks.map(\.videoId))
        )
    }

    /// The songs on disk, newest first.
    static func downloadedTracks(in context: NSManagedObjectContext) -> [Track] {
        let request: NSFetchRequest<CDDownloadedTrack> = CDDownloadedTrack.fetchRequest()
        request.predicate = NSPredicate(format: "trashedAt == nil")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDDownloadedTrack.downloadedAt, ascending: false)]
        let rows = (try? context.fetch(request)) ?? []
        return rows.compactMap { $0.track?.toTrack }
    }
}
