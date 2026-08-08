//
//  DeepLinkIntent.swift
//  PeacePlayer
//
//  S18 / v1.6 / P1-5
//
//  Pending deep-link intent for radio / podcast / audiobook routes.
//
//  The deep-link handler in YTAudioPlayerApp posts a deep-link
//  notification (see .openRadioStation, .openPodcastShow,
//  .openAudiobook). ContentView listens and switches the active
//  tab to Home, HomeView listens and pushes the Radio destination
//  onto its NavigationStack, and RadioView consumes the intent on
//  appear to open the right detail sheet.
//
//  Radio stations don't need a "detail" — they're played directly
//  by handleDeepLink. Podcasts and audiobooks need a detail view
//  so the user can pick an episode / chapter to play, hence the
//  intent.
//
//  The intent is one-shot: RadioView consumes it on appear and
//  clears the slot. If the user dismisses the detail sheet
//  without picking anything, the intent is already gone.
//
//  Thread safety: the intent is set from the deep-link handler
//  (main thread) and consumed by RadioView (main thread). The
//  class is not @MainActor-isolated to match DeepLinkIndex —
//  none of the call sites need the strict isolation, and
//  removing it keeps the cache + intent accessible from
//  Combine sinks on background queues if we ever need that.
//

import Foundation

final class DeepLinkIntent {
    static let shared = DeepLinkIntent()

    /// A podcast show the user wants to open. Consumed by RadioView.
    private(set) var pendingPodcastShow: PodcastShow?

    /// An audiobook the user wants to open. Consumed by RadioView.
    private(set) var pendingAudiobook: Audiobook?

    private init() {}

    func setPendingPodcastShow(_ show: PodcastShow) {
        pendingPodcastShow = show
        pendingAudiobook = nil
    }

    func setPendingAudiobook(_ book: Audiobook) {
        pendingAudiobook = book
        pendingPodcastShow = nil
    }

    /// Called by RadioView.task. Returns the pending intent (if any)
    /// and clears the slot.
    func consume() -> (podcastShow: PodcastShow?, audiobook: Audiobook?) {
        let snap = (pendingPodcastShow, pendingAudiobook)
        pendingPodcastShow = nil
        pendingAudiobook = nil
        return snap
    }
}
