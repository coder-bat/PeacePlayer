//
//  NowPlayingFullWidget.swift
//  PeacePlayerWidget
//
//  Full-featured systemMedium ("4×2") Now Playing widget.
//  Background lives in .containerBackground so the system handles
//  content margins — the view itself is pure transparent content.
//

import WidgetKit
import SwiftUI
import UIKit


// MARK: - Background modifier
// Puts WidgetTheme.cyberBg + blurred artwork into containerBackground so the system
// draws it edge-to-edge *outside* the content margins — eliminating the
// "inner card" that appears when the view draws its own background.

private struct FullWidgetBg: ViewModifier {
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
            WidgetTheme.cyberBg
            if let img = artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 28)
                    .opacity(0.14)
                    .clipped()
            }
        }
    }
}

// MARK: - Widget declaration
// Reuses NowPlayingEntry / NowPlayingProvider from PeacePlayerWidget.swift

@available(iOSApplicationExtension 17.0, *)
struct NowPlayingFullWidget: Widget {
    let kind = "PeacePlayerNowPlayingFull"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingFullView(entry: entry)
                .modifier(FullWidgetBg(artworkImage: entry.artworkImage))
        }
        .configurationDisplayName("Now Playing (Full)")
        .description("Current track, next up, progress and volume controls.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Root view
// No background — it's in FullWidgetBg.containerBackground.
// The system now presents this view at the *content area* size (after its
// own margins), so .frame(maxWidth/maxHeight: .infinity) + Spacers work.

struct NowPlayingFullView: View {
    let entry: NowPlayingEntry

    var body: some View {
        if entry.snapshot.hasContent {
            PlayingContent(entry: entry)
        } else {
            IdleContent()
        }
    }
}

// MARK: - Playing state

private struct PlayingContent: View {
    let entry: NowPlayingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            trackRow
            Spacer(minLength: 4)
            progressBar
            Spacer(minLength: 6)
            controlsRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // Expand to fill the content area the system gives us.
        // Because the view has no background, the system's content-margin
        // geometry is the true size — Spacers distribute the remainder.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // ── Track info ────────────────────────────────────────────

    private var trackRow: some View {
        HStack(alignment: .center, spacing: 10) {
            artworkThumb

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.snapshot.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(entry.snapshot.artist)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)

                if entry.snapshot.hasNextTrack {
                    HStack(spacing: 4) {
                        Text("NEXT")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(WidgetTheme.cyberCyan.opacity(0.7))
                        Text("·")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.3))
                        Text(entry.snapshot.nextTitle)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                } else {
                    Text("END OF QUEUE")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.2))
                }
            }

            Spacer(minLength: 0)

            Link(destination: URL(string: "peaceplayer://queue")!) {
                VStack(spacing: 2) {
                    Image(systemName: "list.bullet.below.rectangle")
                        .font(.system(size: 14))
                        .foregroundColor(WidgetTheme.cyberCyan.opacity(0.85))
                    Text("QUEUE")
                        .font(.system(size: 6, weight: .bold, design: .monospaced))
                        .foregroundColor(WidgetTheme.cyberCyan.opacity(0.6))
                }
            }
        }
    }

    private var artworkThumb: some View {
        Group {
            if let img = entry.artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                WidgetTheme.cyberSurface.overlay(
                    Image(systemName: "waveform")
                        .font(.system(size: 18))
                        .foregroundColor(WidgetTheme.cyberCyan.opacity(0.65))
                )
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(WidgetTheme.cyberCyan.opacity(0.25), lineWidth: 0.5)
        )
    }

    // ── Progress bar ──────────────────────────────────────────
    // GeometryReader lives inside .overlay so it reads the Capsule's
    // rendered width without disrupting the VStack's layout pass.

    private var progressBar: some View {
        Capsule()
            .fill(Color.white.opacity(0.1))
            .frame(maxWidth: .infinity)
            .frame(height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    let w = max(8, geo.size.width * CGFloat(entry.snapshot.progress))
                    ZStack(alignment: .trailing) {
                        Capsule()
                            .fill(LinearGradient(
                                colors: [WidgetTheme.cyberCyan, WidgetTheme.cyberMagenta],
                                startPoint: .leading, endPoint: .trailing
                            ))
                            .frame(width: w, height: 3)
                        Circle()
                            .fill(WidgetTheme.cyberCyan)
                            .frame(width: 7, height: 7)
                            .shadow(color: WidgetTheme.cyberCyan.opacity(0.9), radius: 4)
                    }
                }
                .frame(height: 3)
            }
    }

    // ── Controls row ──────────────────────────────────────────

    private var controlsRow: some View {
        HStack(alignment: .center, spacing: 0) {
            transportControls
            Spacer(minLength: 8)
            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 0.5, height: 20)
            Spacer(minLength: 8)
            volumeControls
        }
    }

    @ViewBuilder
    private var transportControls: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            HStack(spacing: 6) {
                Button(intent: WidgetSeekBackwardIntent()) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: 28, height: 32)
                }
                .buttonStyle(.plain)

                Button(intent: WidgetSkipPreviousIntent()) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 26, height: 32)
                }
                .buttonStyle(.plain)

                // Pause: run as background intent (no app open).
                // Play: open the app via URL so resumePlayback() can reload
                // the track if needed (handles killed/suspended app state).
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
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.9))
                        .frame(width: 26, height: 32)
                }
                .buttonStyle(.plain)

                Button(intent: WidgetSeekForwardIntent()) {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(width: 28, height: 32)
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "gobackward.15").font(.system(size: 14)).foregroundColor(.white.opacity(0.3)).frame(width: 28, height: 32)
                Image(systemName: "backward.fill").font(.system(size: 15)).foregroundColor(.white.opacity(0.4)).frame(width: 26, height: 32)
                ZStack {
                    Circle().fill(WidgetTheme.cyberCyan.opacity(0.15)).frame(width: 34, height: 34)
                    Image(systemName: entry.snapshot.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(WidgetTheme.cyberCyan)
                }
                Image(systemName: "forward.fill").font(.system(size: 15)).foregroundColor(.white.opacity(0.4)).frame(width: 26, height: 32)
                Image(systemName: "goforward.15").font(.system(size: 14)).foregroundColor(.white.opacity(0.3)).frame(width: 28, height: 32)
            }
        }
    }

    @ViewBuilder
    private var volumeControls: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            HStack(spacing: 5) {
                Button(intent: WidgetVolumeDownIntent()) {
                    Image(systemName: "speaker.wave.1.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 22, height: 32)
                }
                .buttonStyle(.plain)

                vuBar

                Button(intent: WidgetVolumeUpIntent()) {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 22, height: 32)
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.1.fill").font(.system(size: 12)).foregroundColor(.white.opacity(0.3)).frame(width: 22, height: 32)
                vuBar
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 12)).foregroundColor(.white.opacity(0.3)).frame(width: 22, height: 32)
            }
        }
    }

    private var vuBar: some View {
        let total  = 8
        let filled = max(0, min(total, Int((entry.snapshot.currentVolume * Float(total)).rounded())))
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<total, id: \.self) { i in
                vuSegment(index: i, filled: filled, total: total)
            }
        }
        .frame(width: 46, height: 16)
    }

    private func playPauseCircle(isPlaying: Bool) -> some View {
        ZStack {
            Circle()
                .fill(WidgetTheme.cyberCyan.opacity(0.18))
                .frame(width: 34, height: 34)
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(WidgetTheme.cyberCyan)
        }
    }

    @ViewBuilder
    private func vuSegment(index i: Int, filled: Int, total: Int) -> some View {
        let on = i < filled
        let bar = RoundedRectangle(cornerRadius: 1.5)
            .fill(on ? WidgetTheme.cyberCyan.opacity(0.5 + Double(i) * 0.045) : Color.white.opacity(0.1))
            .frame(width: 4, height: CGFloat(on ? 7 + i : 5))
        if #available(iOSApplicationExtension 17.0, *) {
            let intent: WidgetSetVolumeIntent = {
                var it = WidgetSetVolumeIntent()
                it.level = Double(i + 1) / Double(total)
                return it
            }()
            Button(intent: intent) { bar }
                .buttonStyle(.plain)
        } else {
            bar
        }
    }
}

// MARK: - Idle state

private struct IdleContent: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach([12, 20, 28, 20, 14, 22, 26], id: \.self) { h in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(WidgetTheme.cyberCyan.opacity(0.3))
                        .frame(width: 4, height: CGFloat(h))
                }
            }
            Text("NOTHING PLAYING")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))

            Link(destination: URL(string: "peaceplayer://resume")!) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 10))
                    Text("OPEN PEACEPLAYER").font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundColor(WidgetTheme.cyberCyan)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(WidgetTheme.cyberCyan.opacity(0.12))
                .overlay(Capsule().strokeBorder(WidgetTheme.cyberCyan.opacity(0.5), lineWidth: 0.5))
                .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
