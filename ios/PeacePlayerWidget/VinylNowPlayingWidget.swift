//
//  VinylNowPlayingWidget.swift
//  PeacePlayerWidget
//
//  Medium widget featuring a real spinning vinyl record as the
//  centerpiece. Inspired by the Stitch design "Neon Nocturne":
//    - Vinyl disc on the LEFT (with album art as the centre label)
//    - Track info + gradient progress bar + transport controls on the RIGHT
//    - Record spins when playing; freezes when paused
//    - Cyan glow ramps up while playing
//
//  Reuses NowPlayingEntry / NowPlayingProvider from PeacePlayerWidget.swift
//  so state wiring is identical to the existing medium widget.
//

import WidgetKit
import SwiftUI
import UIKit


// MARK: - Background
// Container background lives in modifier so the system draws it
// edge-to-edge and we don't double-paint a rounded card.

private struct VinylWidgetBg: ViewModifier {
    let artworkImage: UIImage?

    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) { bg }
        } else {
            content.background(bg)
        }
    }

    @ViewBuilder
    private var bg: some View {
        ZStack {
            // Deep navy → black gradient — matches the cyberBackground theme
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.085),
                    .black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Very subtle blurred artwork underlay
            if let img = artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 36)
                    .opacity(0.12)
                    .clipped()
            }
            // Faint cyan radial glow upper-left corner
            RadialGradient(
                colors: [
                    WidgetTheme.cyberCyan.opacity(0.18),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 4,
                endRadius: 220
            )
        }
    }
}


// MARK: - Widget

@available(iOSApplicationExtension 17.0, *)
struct VinylNowPlayingWidget: Widget {
    let kind = "PeacePlayerVinylNowPlaying"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            VinylNowPlayingView(entry: entry)
                .modifier(VinylWidgetBg(artworkImage: entry.artworkImage))
        }
        .configurationDisplayName("Now Playing · Vinyl")
        .description("Spinning vinyl record with album art, progress, and controls.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}


// MARK: - Root view

struct VinylNowPlayingView: View {
    let entry: NowPlayingEntry

    var body: some View {
        // TimelineView drives the spin animation at 30fps while the
        // widget is on-screen. While paused, the timeline still ticks
        // but spin = 0, so battery drain is minimal.
        TimelineView(.periodic(from: entry.date, by: 1.0 / 30.0)) { context in
            let elapsed = context.date.timeIntervalSince(entry.date)
            let spin: Double = entry.snapshot.isPlaying
                ? (elapsed * 24).truncatingRemainder(dividingBy: 360)
                : 0

            Group {
                if entry.snapshot.hasContent {
                    PlayingContent(entry: entry, spin: spin)
                } else {
                    IdleContent()
                }
            }
        }
    }
}


// MARK: - Playing state

private struct PlayingContent: View {
    let entry: NowPlayingEntry
    let spin: Double

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // ── Vinyl record on the LEFT ──
            VinylRecordView(
                artwork: entry.artworkImage,
                size: 96,
                baseRotation: -6,
                spin: spin,
                isPlaying: entry.snapshot.isPlaying
            )

            // ── Right column: track info + progress + controls ──
            VStack(alignment: .leading, spacing: 0) {
                trackInfo
                Spacer(minLength: 6)
                progressBar
                Spacer(minLength: 8)
                controlsRow
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: track info

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.snapshot.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)

            Text(entry.snapshot.artist)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    // MARK: progress bar (cyan → magenta gradient)

    private var progressBar: some View {
        Capsule()
            .fill(WidgetTheme.subtleSurface)
            .frame(maxWidth: .infinity)
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    let w = max(6, geo.size.width * CGFloat(entry.snapshot.progress))
                    ZStack(alignment: .trailing) {
                        Capsule()
                            .fill(LinearGradient(
                                colors: [WidgetTheme.cyberCyan, WidgetTheme.cyberMagenta],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: w, height: 3)
                        Circle()
                            .fill(WidgetTheme.cyberCyan)
                            .frame(width: 6, height: 6)
                            .shadow(color: WidgetTheme.cyberCyan.opacity(0.9), radius: 3)
                    }
                }
                .frame(height: 3)
            }
    }

    // MARK: transport controls

    @ViewBuilder
    private var controlsRow: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            HStack(spacing: 14) {
                Button(intent: WidgetSkipPreviousIntent()) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 26, height: 28)
                }
                .buttonStyle(.plain)

                if entry.snapshot.isPlaying {
                    Button(intent: WidgetPlayPauseIntent()) {
                        playPauseCircle(isPlaying: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    Link(destination: URL(string: "peaceplayer://resume")!) {
                        playPauseCircle(isPlaying: false)
                    }
                }

                Button(intent: WidgetSkipNextIntent()) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 26, height: 28)
                }
                .buttonStyle(.plain)
            }
        } else {
            // iOS 16 fallback (no interaction)
            HStack(spacing: 14) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(width: 26, height: 28)
                playPauseCircle(isPlaying: entry.snapshot.isPlaying)
                Image(systemName: "forward.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.3))
                    .frame(width: 26, height: 28)
            }
        }
    }

    private func playPauseCircle(isPlaying: Bool) -> some View {
        ZStack {
            Circle()
                .fill(WidgetTheme.cyberCyan.opacity(0.18))
                .frame(width: 32, height: 32)
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(WidgetTheme.cyberCyan)
        }
    }
}


// MARK: - Idle state (nothing playing)

private struct IdleContent: View {
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VinylRecordView(artwork: nil, size: 96, baseRotation: -6, spin: 0, isPlaying: false)
                .opacity(0.55)

            VStack(alignment: .leading, spacing: 8) {
                Text("NOTHING PLAYING")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))

                Text("Open PeacePlayer to start listening")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)

                Link(destination: URL(string: "peaceplayer://resume")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 10))
                        Text("OPEN PEACEPLAYER")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(WidgetTheme.cyberCyan)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(WidgetTheme.cyberCyan.opacity(0.12))
                    .overlay(Capsule().strokeBorder(WidgetTheme.cyberCyan.opacity(0.5), lineWidth: 0.5))
                    .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}


// MARK: - Previews (for Xcode preview, no-op in build)

@available(iOSApplicationExtension 17.0, *)
struct VinylNowPlayingWidget_Previews: PreviewProvider {
    static let playing = NowPlayingEntry(
        date: .now,
        snapshot: NowPlayingSnapshot(
            title: "Neon Echoes",
            artist: "Synth Theory",
            artworkURLString: "",
            isPlaying: true,
            progress: 0.6
        ),
        artworkImage: nil
    )

    static let paused = NowPlayingEntry(
        date: .now,
        snapshot: NowPlayingSnapshot(
            title: "Midnight Run",
            artist: "Skyra",
            artworkURLString: "",
            isPlaying: false,
            progress: 0.42
        ),
        artworkImage: nil
    )

    static var previews: some View {
        Group {
            VinylNowPlayingView(entry: playing)
                .modifier(VinylWidgetBg(artworkImage: playing.artworkImage))
                .previewContext(WidgetPreviewContext(family: .systemMedium))

            VinylNowPlayingView(entry: paused)
                .modifier(VinylWidgetBg(artworkImage: paused.artworkImage))
                .previewContext(WidgetPreviewContext(family: .systemMedium))

            IdleContent()
                .modifier(VinylWidgetBg(artworkImage: nil))
                .previewContext(WidgetPreviewContext(family: .systemMedium))
        }
    }
}
