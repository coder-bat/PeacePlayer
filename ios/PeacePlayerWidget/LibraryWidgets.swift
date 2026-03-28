//
//  LibraryWidgets.swift
//  PeacePlayerWidget
//
//  Shuffle Favorites and Playlists widgets.
//  Both read LibrarySnapshot from the shared App Group.
//  Sizes: ShuffleFavorites (small, medium), Playlists (medium, large)
//

import WidgetKit
import SwiftUI


// MARK: - Shared Entry & Provider

struct LibraryEntry: TimelineEntry {
    let date: Date
    let library: LibrarySnapshot
}

struct LibraryProvider: TimelineProvider {

    func placeholder(in context: Context) -> LibraryEntry {
        LibraryEntry(
            date: .now,
            library: LibrarySnapshot(
                likedTrackCount: 42,
                playlists: [
                    WidgetPlaylist(id: "1", name: "Chill Vibes",   trackCount: 12),
                    WidgetPlaylist(id: "2", name: "Night Drive",   trackCount: 8),
                    WidgetPlaylist(id: "3", name: "Cyber Dreams",  trackCount: 20),
                    WidgetPlaylist(id: "4", name: "Morning Light", trackCount: 15),
                    WidgetPlaylist(id: "5", name: "Deep Focus",    trackCount: 30),
                    WidgetPlaylist(id: "6", name: "Workout Mix",   trackCount: 25),
                ]
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LibraryEntry) -> Void) {
        completion(LibraryEntry(date: .now, library: SharedNowPlayingState.readLibrary()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LibraryEntry>) -> Void) {
        let entry = LibraryEntry(date: .now, library: SharedNowPlayingState.readLibrary())
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Shuffle Favorites Widget
// ─────────────────────────────────────────────────────────────

struct ShuffleFavoritesWidget: Widget {
    let kind = "PeacePlayerShuffleFavorites"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LibraryProvider()) { entry in
            ShuffleFavoritesWidgetView(entry: entry)
                .widgetContainerBackground()
        }
        .configurationDisplayName("Shuffle Favorites")
        .description("Instantly shuffle your liked tracks.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ShuffleFavoritesWidgetView: View {
    let entry: LibraryEntry
    @Environment(\.widgetFamily) private var family

    private var shuffleURL: URL { URL(string: "peaceplayer://shuffle-favorites")! }

    var body: some View {
        ZStack {
            WidgetTheme.cyberBg

            // Radial magenta glow
            RadialGradient(
                colors: [WidgetTheme.cyberMagenta.opacity(0.22), Color.clear],
                center: .center,
                startRadius: 0,
                endRadius: 90
            )
            .blendMode(.screen)

            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [WidgetTheme.cyberMagenta.opacity(0.5), WidgetTheme.cyberCyan.opacity(0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            if family == .systemMedium {
                mediumContent
            } else {
                smallContent
            }
        }
        .widgetURL(shuffleURL)
    }

    // MARK: Small

    private var smallContent: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(WidgetTheme.cyberMagenta.opacity(0.15))
                    .frame(width: 54, height: 54)
                Circle()
                    .strokeBorder(WidgetTheme.cyberMagenta.opacity(0.3), lineWidth: 1)
                    .frame(width: 54, height: 54)
                Image(systemName: "shuffle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(WidgetTheme.cyberMagenta)
            }

            VStack(spacing: 2) {
                Text("\(entry.library.likedTrackCount)")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text("LIKED")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
            }

            Text("SHUFFLE")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(WidgetTheme.cyberMagenta)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(WidgetTheme.cyberMagenta.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(12)
    }

    // MARK: Medium

    private var mediumContent: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(WidgetTheme.cyberMagenta.opacity(0.15))
                    .frame(width: 72, height: 72)
                Circle()
                    .strokeBorder(WidgetTheme.cyberMagenta.opacity(0.3), lineWidth: 1)
                    .frame(width: 72, height: 72)
                Image(systemName: "shuffle")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(WidgetTheme.cyberMagenta)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("SHUFFLE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(WidgetTheme.cyberMagenta)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(entry.library.likedTrackCount)")
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("tracks")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }

                Text("FAVORITES")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 9))
                        .foregroundColor(WidgetTheme.cyberMagenta)
                    Text("TAP TO SHUFFLE ALL")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(WidgetTheme.cyberMagenta.opacity(0.8))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Playlists Widget
// ─────────────────────────────────────────────────────────────

struct PlaylistsWidget: Widget {
    let kind = "PeacePlayerPlaylists"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LibraryProvider()) { entry in
            PlaylistsWidgetView(entry: entry)
                .widgetContainerBackground()
        }
        .configurationDisplayName("Playlists")
        .description("Quickly launch any playlist.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct PlaylistsWidgetView: View {
    let entry: LibraryEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ZStack {
            WidgetTheme.cyberBg

            VStack(spacing: 0) {
                widgetHeader
                divider

                if family == .systemLarge {
                    largeContent
                } else {
                    mediumContent
                }
            }
        }
    }

    // MARK: Shared Header

    private var widgetHeader: some View {
        HStack {
            Image(systemName: "music.note.list")
                .font(.system(size: 11))
                .foregroundColor(WidgetTheme.cyberCyan)
            Text("PLAYLISTS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(WidgetTheme.cyberCyan)
            Spacer()
            Text("\(entry.library.playlists.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(WidgetTheme.cyberCyan.opacity(0.2))
            .frame(height: 0.5)
            .padding(.horizontal, 14)
    }

    // MARK: Medium (3 playlists)

    private var mediumContent: some View {
        Group {
            let rows = Array(entry.library.playlists.prefix(3))
            if rows.isEmpty {
                Spacer()
                Text("No playlists yet")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, pl in
                    Link(destination: URL(string: "peaceplayer://playlist?id=\(pl.id)")!) {
                        PlaylistRow(playlist: pl, showDivider: idx < rows.count - 1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Large (shuffle row + 6 playlists)

    private var largeContent: some View {
        Group {
            // Shuffle Favorites shortcut row
            Link(destination: URL(string: "peaceplayer://shuffle-favorites")!) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(WidgetTheme.cyberMagenta.opacity(0.18))
                            .frame(width: 34, height: 34)
                        Image(systemName: "shuffle")
                            .font(.system(size: 14))
                            .foregroundColor(WidgetTheme.cyberMagenta)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Shuffle Favorites")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text("\(entry.library.likedTrackCount) liked tracks")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)
                .padding(.horizontal, 14)

            let rows = Array(entry.library.playlists.prefix(5))
            if rows.isEmpty {
                Spacer()
                Text("No playlists yet")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, pl in
                    Link(destination: URL(string: "peaceplayer://playlist?id=\(pl.id)")!) {
                        PlaylistRow(playlist: pl, showDivider: idx < rows.count - 1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Shared Playlist Row

private struct PlaylistRow: View {
    let playlist: WidgetPlaylist
    let showDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(
                            LinearGradient(
                                colors: [WidgetTheme.cyberCyan.opacity(0.22), WidgetTheme.cyberMagenta.opacity(0.14)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    Image(systemName: "music.note")
                        .font(.system(size: 12))
                        .foregroundColor(WidgetTheme.cyberCyan)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("\(playlist.trackCount) tracks")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }

                Spacer()

                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundColor(WidgetTheme.cyberCyan.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if showDivider {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 0.5)
                    .padding(.horizontal, 14)
            }
        }
    }
}
