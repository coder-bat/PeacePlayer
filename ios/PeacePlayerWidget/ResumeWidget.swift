//
//  ResumeWidget.swift
//  PeacePlayerWidget
//
//  "Resume Playing" widget — shows current/last track, tap to jump back in.
//  Sizes: systemSmall, systemMedium
//

import WidgetKit
import SwiftUI
import UIKit


// MARK: - Entry & Provider

struct ResumeEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot
    let artworkImage: UIImage?
}

struct ResumeProvider: TimelineProvider {

    func placeholder(in context: Context) -> ResumeEntry {
        ResumeEntry(
            date: .now,
            snapshot: NowPlayingSnapshot(
                title: "Peace & Quiet",
                artist: "PeacePlayer",
                artworkURLString: "",
                isPlaying: false,
                progress: 0.6
            ),
            artworkImage: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ResumeEntry) -> Void) {
        let snap = SharedNowPlayingState.read()
        Task {
            let image = await fetchArtwork(url: snap.artworkURL)
            completion(ResumeEntry(date: .now, snapshot: snap, artworkImage: image))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ResumeEntry>) -> Void) {
        let snap = SharedNowPlayingState.read()
        Task {
            let image = await fetchArtwork(url: snap.artworkURL)
            let entry = ResumeEntry(date: .now, snapshot: snap, artworkImage: image)
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func fetchArtwork(url: URL?) async -> UIImage? {
        guard let url,
              let (data, _) = try? await URLSession.shared.data(from: url)
        else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Widget Declaration

struct ResumeWidget: Widget {
    let kind = "PeacePlayerResume"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ResumeProvider()) { entry in
            ResumeWidgetView(entry: entry)
                .widgetContainerBackground()
        }
        .configurationDisplayName("Resume Playing")
        .description("Tap to jump back into your music.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Root View

struct ResumeWidgetView: View {
    let entry: ResumeEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium: MediumResumeView(entry: entry)
        default:            SmallResumeView(entry: entry)
        }
    }
}

// MARK: - Small

struct SmallResumeView: View {
    let entry: ResumeEntry

    private var resumeURL: URL { URL(string: "peaceplayer://resume")! }

    var body: some View {
        ZStack {
            WidgetTheme.cyberBg

            if let img = entry.artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 18)
                    .opacity(0.18)
                    .clipped()
            }

            // Cyan/magenta glow border
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [WidgetTheme.cyberCyan.opacity(0.6), WidgetTheme.cyberMagenta.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            VStack(spacing: 7) {
                artworkView(size: 58)

                Text(entry.snapshot.hasContent ? entry.snapshot.title : "Nothing Playing")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                    Text("RESUME")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                }
                .foregroundColor(WidgetTheme.cyberCyan)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(WidgetTheme.cyberCyan.opacity(0.12))
                .clipShape(Capsule())
            }
            .padding(10)
        }
        .widgetURL(resumeURL)
    }

    @ViewBuilder
    private func artworkView(size: CGFloat) -> some View {
        Group {
            if let img = entry.artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                WidgetTheme.cyberBg
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: size * 0.38))
                            .foregroundColor(WidgetTheme.cyberCyan.opacity(0.7))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(WidgetTheme.cyberCyan.opacity(0.35), lineWidth: 0.5)
        )
    }
}

// MARK: - Medium

struct MediumResumeView: View {
    let entry: ResumeEntry

    private var resumeURL: URL { URL(string: "peaceplayer://resume")! }

    var body: some View {
        ZStack {
            WidgetTheme.cyberBg

            if let img = entry.artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 24)
                    .opacity(0.12)
                    .clipped()
            }

            HStack(spacing: 14) {
                artworkView(size: 82)

                VStack(alignment: .leading, spacing: 5) {
                    // Status chip
                    HStack(spacing: 5) {
                        Circle()
                            .fill(entry.snapshot.isPlaying ? WidgetTheme.cyberCyan : Color.gray)
                            .frame(width: 5, height: 5)
                        Text(entry.snapshot.isPlaying ? "PLAYING" : "PAUSED")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(entry.snapshot.isPlaying ? WidgetTheme.cyberCyan : .gray)
                    }

                    Text(entry.snapshot.hasContent ? entry.snapshot.title : "Nothing Playing")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)

                    if entry.snapshot.hasContent {
                        Text(entry.snapshot.artist)
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    // Progress bar
                    if entry.snapshot.hasContent {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.1))
                                    .frame(height: 3)
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [WidgetTheme.cyberCyan, WidgetTheme.cyberMagenta],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(
                                        width: max(0, geo.size.width * CGFloat(entry.snapshot.progress)),
                                        height: 3
                                    )
                            }
                        }
                        .frame(height: 3)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8))
                        Text("TAP TO RESUME")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(WidgetTheme.cyberCyan)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .widgetURL(resumeURL)
    }

    @ViewBuilder
    private func artworkView(size: CGFloat) -> some View {
        Group {
            if let img = entry.artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                WidgetTheme.cyberBg
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: size * 0.38))
                            .foregroundColor(WidgetTheme.cyberCyan.opacity(0.7))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    LinearGradient(
                        colors: [WidgetTheme.cyberCyan.opacity(0.5), WidgetTheme.cyberMagenta.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
}
