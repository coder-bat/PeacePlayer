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

@available(iOS 16.1, *)
struct NowPlayingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            // Lock Screen / StandBy presentation
            NowPlayingLockScreenView(
                attributes: context.attributes,
                state: context.state
            )
            .activityBackgroundTint(Color.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    islandArtwork(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    islandPlayPause(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    islandProgressBar(context: context)
                }
            } compactLeading: {
                islandArtwork(context: context, size: 18)
            } compactTrailing: {
                islandPlayPause(context: context, compact: true)
            } minimal: {
                islandArtwork(context: context, size: 18)
            }
        }
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
                .foregroundColor(.white)
                .lineLimit(1)
            Text(context.attributes.trackArtist)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
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

    var body: some View {
        HStack(spacing: 14) {
            artworkView(artworkURLString: attributes.artworkURLString, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(attributes.trackTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(attributes.trackArtist)
                    .font(.system(size: 12, design: .default))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(1)
                if let album = attributes.trackAlbum, !album.isEmpty {
                    Text(album)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
                progressBar(state: state)
                    .padding(.top, 4)
            }
            Spacer(minLength: 8)
            playPauseIndicator(isPlaying: state.isPlaying)
        }
        .padding(14)
    }
}

// MARK: - Building blocks

private func artworkView(artworkURLString: String?, size: CGFloat) -> some View {
    Group {
        if let s = artworkURLString, let url = URL(string: s) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    placeholderArtwork(size: size)
                }
            }
        } else {
            placeholderArtwork(size: size)
        }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
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
        .foregroundColor(WidgetTheme.cyberCyan)
        .frame(width: compact ? 24 : 32, height: compact ? 24 : 32)
        .background(WidgetTheme.cyberCyan.opacity(0.15))
        .clipShape(Circle())
}

private func progressBar(state: NowPlayingActivityAttributes.ContentState) -> some View {
    let progress = state.duration > 0
        ? min(max(state.currentTime / state.duration, 0), 1)
        : 0
    return GeometryReader { geo in
        ZStack(alignment: .leading) {
            Capsule()
                .fill(WidgetTheme.cyberCyan.opacity(0.15))
            Capsule()
                .fill(WidgetTheme.cyberCyan)
                .frame(width: geo.size.width * progress)
        }
    }
    .frame(height: 3)
}
