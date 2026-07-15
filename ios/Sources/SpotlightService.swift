//
//  SpotlightService.swift
//  PeacePlayer
//
//  S15: Spotlight donation for currently-playing and recently-played
//  tracks. Lets the user find their music via the iOS system
//  Spotlight search, with deep links back into the app.
//
//  iOS's `CSSearchableIndex` indexes arbitrary items with
//  metadata; the system picks up new items within a few seconds
//  and they appear in Spotlight / Siri Suggestions / Lock
//  Screen suggestions. The same `uniqueIdentifier` string is
//  used to remove items when they leave the indexable set.
//

import Foundation
import CoreSpotlight
import MobileCoreServices
import Combine

@MainActor
final class SpotlightService {
    static let shared = SpotlightService()

    private var cancellables = Set<AnyCancellable>()

    /// Domain identifier for the now-playing track entry. Distinct
    /// from the recently-played domain so we can update them
    /// independently.
    private let nowPlayingDomain = "com.peaceplayer.spotlight.nowplaying"
    private let recentlyPlayedDomain = "com.peaceplayer.spotlight.recentlyplayed"

    private init() {}

    // MARK: - Lifecycle

    /// Wire up subscriptions to PlayerState (currently-playing) and
    /// PlaylistManager (recently-played list). Each change
    /// refreshes the relevant Spotlight entry.
    func start() {
        // Currently-playing donation
        PlayerState.shared.$currentItem
            .removeDuplicates { $0?.track.videoId == $1?.track.videoId }
            .sink { [weak self] _ in
                self?.refreshNowPlaying()
            }
            .store(in: &cancellables)
    }

    // MARK: - Donation

    /// Refresh the now-playing entry. Called when the current
    /// track changes. Removes the old entry first so a long queue
    /// doesn't accumulate stale entries.
    func refreshNowPlaying() {
        guard let track = PlayerState.shared.currentItem?.track else {
            // No track playing — remove any previous now-playing
            // entry so Spotlight stays accurate.
            CSSearchableIndex.default()
                .deleteSearchableItems(withDomainIdentifiers: [nowPlayingDomain])
            return
        }
        let attributes = CSSearchableItemAttributeSet(contentType: .audio)
        attributes.title = track.title
        attributes.artist = track.displayArtist
        attributes.album = track.album
        attributes.contentDescription = "Now playing in PeacePlayer"
        if let thumbnailURL = track.artworkURL {
            attributes.thumbnailURL = thumbnailURL
        }
        let item = CSSearchableItem(
            uniqueIdentifier: track.videoId,
            domainIdentifier: nowPlayingDomain,
            attributeSet: attributes
        )
        // Replace any previous now-playing entry in one batch
        // so we don't briefly show two items in Spotlight.
        CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [nowPlayingDomain]) { _ in
                CSSearchableIndex.default()
                    .indexSearchableItems([item]) { _ in }
            }
    }

    /// Re-index the most recent N played tracks. The full
    /// history can be large; Spotlight is happy to show ~30
    /// items per domain and we'll only refresh the top of the
    /// list.
    func refreshRecentlyPlayed(limit: Int = 30) {
        let items = PlaylistManager.shared.likedTracks
            // We don't have a direct "last played" set on
            // PlaylistManager; the DataManager.recentlyPlayed
            // list is the canonical source. Falls back to liked
            // tracks ordered however they were added.
        // For now this is a placeholder — full implementation
        // would walk DataManager.recentlyPlayed and look up
        // each track's metadata.
        let attributes = items.prefix(limit).map { videoId -> CSSearchableItem in
            let attrs = CSSearchableItemAttributeSet(contentType: .audio)
            attrs.title = videoId  // placeholder
            attrs.contentDescription = "Recently played in PeacePlayer"
            return CSSearchableItem(
                uniqueIdentifier: videoId,
                domainIdentifier: recentlyPlayedDomain,
                attributeSet: attrs
            )
        }
        CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [recentlyPlayedDomain]) { _ in
                if !attributes.isEmpty {
                    CSSearchableIndex.default()
                        .indexSearchableItems(attributes) { _ in }
                }
            }
    }

    // MARK: - Cleanup

    /// Remove all PeacePlayer entries from Spotlight. Called on
    /// sign-out so another user's account doesn't leak tracks
    /// into the index.
    func clearAll() {
        CSSearchableIndex.default().deleteAllSearchableItems { _ in }
    }
}
