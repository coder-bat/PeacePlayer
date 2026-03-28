//
//  PeacePlayerWidget.swift
//  PeacePlayerWidget
//
//  Widget views + timeline provider for PeacePlayer now-playing widget.
//  Supports: systemSmall, systemMedium, accessoryCircular, accessoryRectangular
//

import WidgetKit
import SwiftUI
import UIKit


// MARK: - Timeline Entry

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot
    let artworkImage: UIImage?
}

// MARK: - Timeline Provider

struct NowPlayingProvider: TimelineProvider {

    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(
            date: .now,
            snapshot: NowPlayingSnapshot(
                title: "Peace & Quiet",
                artist: "PeacePlayer",
                artworkURLString: "",
                isPlaying: true,
                progress: 0.4
            ),
            artworkImage: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        let snapshot = SharedNowPlayingState.read()
        Task {
            let image = await fetchArtwork(url: snapshot.artworkURL)
            completion(NowPlayingEntry(date: .now, snapshot: snapshot, artworkImage: image))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let snapshot = SharedNowPlayingState.read()
        Task {
            let image = await fetchArtwork(url: snapshot.artworkURL)
            let entry = NowPlayingEntry(date: .now, snapshot: snapshot, artworkImage: image)
            // Refresh after 15 min; main app also calls WidgetCenter.reloadTimelines on track/play changes
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func fetchArtwork(url: URL?) async -> UIImage? {
        guard let url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Widget Declaration

struct NowPlayingWidget: Widget {
    let kind = "PeacePlayerNowPlaying"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .widgetContainerBackground()
        }
        .configurationDisplayName("Now Playing")
        .description("Shows what's playing in PeacePlayer.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

// MARK: - Container Background Helper

extension View {
    @ViewBuilder
    func widgetContainerBackground() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            self.containerBackground(.black, for: .widget)
        } else {
            self.background(Color.black)
        }
    }
}

// MARK: - Root Widget View (routes by family)

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallNowPlayingView(entry: entry)
        case .systemMedium:
            MediumNowPlayingView(entry: entry)
        case .accessoryCircular:
            AccessoryCircularView(entry: entry)
        case .accessoryRectangular:
            AccessoryRectangularView(entry: entry)
        default:
            SmallNowPlayingView(entry: entry)
        }
    }
}

// MARK: - Small Widget (artwork + title + play button)

struct SmallNowPlayingView: View {
    let entry: NowPlayingEntry

    var body: some View {
        ZStack {
            // Blurred artwork background
            if let img = entry.artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 20)
                    .opacity(0.35)
                    .clipped()
            }

            VStack(spacing: 8) {
                // Artwork thumbnail
                artworkView(size: 64)

                // Track info
                Text(entry.snapshot.hasContent ? entry.snapshot.title : "Not Playing")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                if entry.snapshot.hasContent {
                    Text(entry.snapshot.artist)
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                // Interactive play/pause (iOS 17+)
                if #available(iOSApplicationExtension 17.0, *) {
                    if entry.snapshot.isPlaying {
                        Button(intent: WidgetPlayPauseIntent()) {
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: 26))
                                .foregroundColor(WidgetTheme.cyberCyan)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Link(destination: URL(string: "peaceplayer://resume")!) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 26))
                                .foregroundColor(WidgetTheme.cyberCyan)
                        }
                    }
                } else {
                    Image(systemName: entry.snapshot.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(WidgetTheme.cyberCyan)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func artworkView(size: CGFloat) -> some View {
        Group {
            if let img = entry.artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.15)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.35))
                            .foregroundColor(.gray)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Medium Widget (artwork + title + progress + controls)

struct MediumNowPlayingView: View {
    let entry: NowPlayingEntry

    var body: some View {
        HStack(spacing: 14) {
            // Artwork
            artworkView(size: 80)

            VStack(alignment: .leading, spacing: 6) {
                // Track info
                Text(entry.snapshot.hasContent ? entry.snapshot.title : "Not Playing")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if entry.snapshot.hasContent {
                    Text(entry.snapshot.artist)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(WidgetTheme.cyberCyan)
                            .frame(width: max(0, geo.size.width * CGFloat(entry.snapshot.progress)), height: 3)
                    }
                }
                .frame(height: 6)

                // Controls
                if #available(iOSApplicationExtension 17.0, *) {
                    HStack(spacing: 20) {
                        Button(intent: WidgetSkipPreviousIntent()) {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .buttonStyle(.plain)

                        if entry.snapshot.isPlaying {
                            Button(intent: WidgetPlayPauseIntent()) {
                                Image(systemName: "pause.fill")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(WidgetTheme.cyberCyan)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Link(destination: URL(string: "peaceplayer://resume")!) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(WidgetTheme.cyberCyan)
                            }
                        }

                        Button(intent: WidgetSkipNextIntent()) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    // iOS 16: static icons only (no interaction)
                    HStack(spacing: 20) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.4))
                        Image(systemName: entry.snapshot.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(WidgetTheme.cyberCyan)
                        Image(systemName: "forward.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    @ViewBuilder
    private func artworkView(size: CGFloat) -> some View {
        Group {
            if let img = entry.artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(white: 0.15)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.35))
                            .foregroundColor(.gray)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Lock Screen Circular

struct AccessoryCircularView: View {
    let entry: NowPlayingEntry

    var body: some View {
        ZStack {
            if let img = entry.artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(white: 0.2))
                Image(systemName: entry.snapshot.isPlaying ? "waveform" : "music.note")
                    .font(.system(size: 16))
            }
        }
    }
}

// MARK: - Lock Screen Rectangular

struct AccessoryRectangularView: View {
    let entry: NowPlayingEntry

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.snapshot.isPlaying ? "waveform" : "music.note")
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.snapshot.hasContent ? entry.snapshot.title : "PeacePlayer")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(entry.snapshot.artist.isEmpty ? "Not playing" : entry.snapshot.artist)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Previews

struct NowPlayingWidget_Previews: PreviewProvider {
    static let sampleEntry = NowPlayingEntry(
        date: .now,
        snapshot: NowPlayingSnapshot(
            title: "Neon Nights",
            artist: "Cyber Dreams",
            artworkURLString: "",
            isPlaying: true,
            progress: 0.6
        ),
        artworkImage: nil
    )

    static var previews: some View {
        Group {
            NowPlayingWidgetView(entry: sampleEntry)
                .previewContext(WidgetPreviewContext(family: .systemSmall))

            NowPlayingWidgetView(entry: sampleEntry)
                .previewContext(WidgetPreviewContext(family: .systemMedium))

            NowPlayingWidgetView(entry: sampleEntry)
                .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
        }
        .preferredColorScheme(.dark)
    }
}
