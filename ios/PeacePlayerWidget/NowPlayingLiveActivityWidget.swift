//
//  NowPlayingLiveActivityWidget.swift
//  PeacePlayerWidget
//
//  Lock Screen / Dynamic Island / StandBy Live Activity for
//  the Now Playing track. Reads from
//  `NowPlayingActivityAttributes` (defined in the main app
//  target and shared with the widget extension via the
//  WidgetBundle's `Info.plist`).
//
//  Layout states:
//   - Lock Screen / StandBy: full artwork, title, artist,
//     progress bar, play/pause indicator (the user can't tap
//     controls here — Live Activities don't accept touches
//     for app-defined controls in iOS 16; tap to open the app).
//   - Dynamic Island compact (leading/trailing): 2 small icons
//     (artwork + play/pause).
//   - Dynamic Island minimal: just the artwork.
//   - Dynamic Island expanded: full layout like Lock Screen
//     plus more breathing room.
//

import SwiftUI
import WidgetKit
import ActivityKit
import UIKit

@available(iOS 16.1, *)
struct NowPlayingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            // Lock Screen / StandBy presentation
            NowPlayingLockScreenView(
                attributes: context.attributes,
                state: context.state
            )
            // S18 / v1.6.6: was `Color.black`. Now uses the shared
            // cyberBackground token so the live activity's
            // background matches the rest of the app's chrome
            // (was a fork from CV-6's audit).
            // Deck: the lock screen card is the walnut plinth.
            .activityBackgroundTint(DeckWidget.walnut.opacity(0.96))
            .activitySystemActionForegroundColor(DeckWidget.cream)
            .widgetURL(URL(string: "peaceplayer://player"))
        } dynamicIsland: { context in
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    islandRecord(context: context, size: 52)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    islandPlayPause(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    islandProgressBar(context: context)
                }
            } compactLeading: {
                islandRecord(context: context, size: 22)
            } compactTrailing: {
                DeckWidgetLamp(isLit: context.state.isPlaying, size: 8)
            } minimal: {
                islandRecord(context: context, size: 22)
            }
            .widgetURL(URL(string: "peaceplayer://player"))
        }
    }

    @ViewBuilder
    private func islandRecord(
        context: ActivityViewContext<NowPlayingActivityAttributes>,
        size: CGFloat
    ) -> some View {
        recordView(artworkURLString: context.attributes.artworkURLString,
                   size: size, isPlaying: context.state.isPlaying)
    }

    @ViewBuilder
    private func islandArtwork(
        context: ActivityViewContext<NowPlayingActivityAttributes>,
        size: CGFloat = 44
    ) -> some View {
        artworkView(artworkURLString: context.attributes.artworkURLString, size: size)
    }

    @ViewBuilder
    private func islandPlayPause(
        context: ActivityViewContext<NowPlayingActivityAttributes>,
        compact: Bool = false
    ) -> some View {
        playPauseIndicator(isPlaying: context.state.isPlaying, compact: compact)
    }

    @ViewBuilder
    private func islandProgressBar(
        context: ActivityViewContext<NowPlayingActivityAttributes>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(context.attributes.trackTitle)
                .font(.caption.bold())
                .foregroundColor(DeckWidget.cream)
                .lineLimit(1)
            Text(context.attributes.trackArtist.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(DeckWidget.brass)
                .lineLimit(1)
            progressBar(state: context.state)
                .padding(.top, 2)
        }
    }
}

// MARK: - Lock Screen / StandBy

private struct NowPlayingLockScreenView: View {
    let attributes: NowPlayingActivityAttributes
    let state: NowPlayingActivityAttributes.ContentState

    private var progress: Double {
        state.duration > 0 ? min(max(state.currentTime / state.duration, 0), 1) : 0
    }

    var body: some View {
        HStack(spacing: 14) {
            // The deck in miniature: record with the arm resting on it.
            ZStack {
                recordView(artworkURLString: attributes.artworkURLString,
                           size: 70, isPlaying: state.isPlaying)
                DeckWidgetTonearm(
                    pose: state.isPlaying ? .playing : .lifted,
                    progress: progress,
                    size: 78
                )
            }
            .frame(width: 78, height: 78)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    DeckWidgetLamp(isLit: state.isPlaying, size: 6)
                    Text(state.isPlaying ? "PLAYING" : "PAUSED")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundColor(DeckWidget.brass)
                }
                Text(attributes.trackTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(DeckWidget.cream)
                    .lineLimit(1)
                Text(attributes.trackArtist)
                    .font(.system(size: 12))
                    .foregroundColor(DeckWidget.cream.opacity(0.65))
                    .lineLimit(1)
                progressBar(state: state)
                    .padding(.top, 5)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

// MARK: - Building blocks

private func artworkView(artworkURLString: String?, size: CGFloat) -> some View {
    // S17-G (perf 10 P0-F5): the previous AsyncImage implementation
    // re-downloaded the full 4K artwork on every Dynamic Island
    // re-render (the system re-evaluates the Live Activity view on
    // state updates, screen wakes, and lock screen transitions).
    // Apple's AsyncImage cache is in-memory only and is unreliable
    // across Live Activity re-evaluations, so each render could
    // trigger a fresh network fetch of the 4K JPEG.
    //
    // Now: synchronous read from the App Group artwork cache
    // (SharedArtworkCache). The main app pre-warms the cache via
    // NowPlayingService.loadArtwork → SharedArtworkCache.store
    // whenever a track is loaded. The Live Activity reads from the
    // same on-disk cache, so the artwork is already on the device
    // by the time the Live Activity shows.
    //
    // On a cache miss (first run after install, before any track
    // has loaded) we fall back to the placeholder. The next Live
    // Activity update — triggered by the main app loading a track —
    // will pick up the real artwork.
    Group {
        if let s = artworkURLString,
           let url = URL(string: s),
           let image = SharedArtworkCache.read(for: url) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            placeholderArtwork(size: size)
        }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
}

private func recordView(artworkURLString: String?, size: CGFloat, isPlaying: Bool) -> some View {
    var image: UIImage?
    if let s = artworkURLString, let url = URL(string: s) {
        image = SharedArtworkCache.read(for: url)
    }
    return DeckWidgetRecord(artwork: image, size: size, angle: isPlaying ? 30 : 20)
}

private func placeholderArtwork(size: CGFloat) -> some View {
    ZStack {
        Rectangle()
            .fill(WidgetTheme.cyberSurface)
        Image(systemName: "music.note")
            .font(.system(size: size * 0.5))
            .foregroundColor(WidgetTheme.cyberDim)
    }
}

private func playPauseIndicator(isPlaying: Bool, compact: Bool = false) -> some View {
    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
        .font(.system(size: compact ? 14 : 18, weight: .bold))
        .foregroundColor(DeckWidget.cream)
        .frame(width: compact ? 24 : 32, height: compact ? 24 : 32)
        .background(DeckWidget.anodised)
        .overlay(Circle().strokeBorder(DeckWidget.aluminium.opacity(0.5), lineWidth: 0.75))
        .clipShape(Circle())
}

private func progressBar(state: NowPlayingActivityAttributes.ContentState) -> some View {
    let progress = state.duration > 0
        ? min(max(state.currentTime / state.duration, 0), 1)
        : 0
    return GeometryReader { geo in
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.black.opacity(0.4))
            Capsule()
                .fill(DeckWidget.aluminium)
                .frame(width: geo.size.width * progress)
            Circle()
                .fill(DeckWidget.amberLamp)
                .frame(width: 6, height: 6)
                .shadow(color: DeckWidget.amberLamp.opacity(0.8), radius: 2)
                .offset(x: max(0, geo.size.width * progress - 3))
        }
    }
    .frame(height: 3)
}
