//
//  TurntableWidget.swift
//  PeacePlayerWidget
//
//  2x2 home-screen widget: the Turntable Home's deck, full size. Plinth,
//  platter, record with the album art as its label, and the tonearm.
//
//  WidgetKit cannot run a continuous animation, so "playing" is shown
//  the way a photograph of a playing deck would show it: the stylus is
//  down in the groove, the arm sits at the track's progress, the
//  pilot lamp is lit, and the record's sheen is at a different angle
//  on each refresh. Paused: the arm is lifted clear and the lamp is off.
//  Nothing loaded: the arm is parked in its rest.
//
//  Tap anywhere opens the full player (peaceplayer://player).
//

import WidgetKit
import SwiftUI
import UIKit

@available(iOSApplicationExtension 17.0, *)
struct TurntableWidget: Widget {
    let kind = "PeacePlayerTurntable"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            TurntableWidgetView(entry: entry)
                .widgetURL(URL(string: "peaceplayer://player"))
                .containerBackground(for: .widget) { DeckWidget.plinth }
        }
        .configurationDisplayName("Turntable")
        .description("The deck: record, platter and tonearm. Tap to open the player.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct TurntableWidgetView: View {
    let entry: NowPlayingEntry

    private var pose: DeckWidgetTonearm.Pose {
        guard entry.snapshot.hasContent else { return .parked }
        return entry.snapshot.isPlaying ? .playing : .lifted
    }

    /// Sheen angle: advances with the refresh time while playing.
    private var sheen: Double {
        guard entry.snapshot.isPlaying else { return 20 }
        return (entry.date.timeIntervalSinceReferenceDate * 24)
            .truncatingRemainder(dividingBy: 360)
    }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                // Platter: anodised strobe band, felt mat, record.
                Circle()
                    .fill(DeckWidget.anodised)
                    .frame(width: s * 0.94, height: s * 0.94)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.6), radius: 5, y: 3)
                    .position(x: s * 0.5, y: s * 0.5)

                DeckWidgetRecord(
                    artwork: entry.snapshot.hasContent ? entry.artworkImage : nil,
                    size: s * 0.88,
                    angle: sheen
                )
                .position(x: s * 0.5, y: s * 0.5)

                DeckWidgetLamp(isLit: entry.snapshot.isPlaying, size: 7)
                    .position(x: s * 0.09, y: s * 0.91)

                DeckWidgetTonearm(pose: pose, progress: entry.snapshot.progress, size: s)
            }
            .frame(width: s, height: s)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
