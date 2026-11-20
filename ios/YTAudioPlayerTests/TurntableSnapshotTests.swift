//
//  TurntableSnapshotTests.swift
//  YTAudioPlayerTests
//
//  Renders the Turntable deck offscreen and writes PNGs, so the
//  layout can be inspected without a backend.
//
//  Why this exists: the app's entry point gates the whole UI behind
//  Apple sign-in, so on a fresh simulator the Turntable Home is
//  unreachable without a running backend. That makes it very easy to
//  ship a deck that compiles, passes every unit test, and still looks
//  wrong.
//
//  The PNGs are written into the app container's tmp directory; the
//  host-side path is printed in the test log.
//
//  These are NOT golden-image comparisons - the golden image would be
//  brittle across OS versions and would fail on every OS upgrade.
//  This test's job is to PRODUCE the image so a human (or an agent)
//  can look at it, and to fail loudly if the view cannot be rendered
//  at all (a crash, a missing asset, a layout that expands to
//  infinity).
//

import XCTest
import SwiftUI
@testable import PeacePlayer

final class TurntableSnapshotTests: XCTestCase {

    /// Renders `view` at the given size and returns the PNG data.
    ///
    /// `ImageRenderer` is main-actor isolated, so this runs on the main
    /// actor — the render must happen where UIKit drawing is allowed.
    @MainActor
    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, scale: CGFloat = 2) throws -> Data {
        // The artwork loads asynchronously through ImageCache, and the
        // offscreen renderer draws whatever is in the cache at the
        // moment it runs. So: render once to start the loads, let the
        // main queue drain, then render for real.
        _ = makeImage(view, width: width, height: height, scale: scale)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        guard let image = makeImage(view, width: width, height: height, scale: scale) else {
            XCTFail("ImageRenderer produced no image")
            throw NSError(domain: "TurntableSnapshot", code: 1)
        }
        guard let data = image.pngData() else {
            XCTFail("Could not encode PNG")
            throw NSError(domain: "TurntableSnapshot", code: 2)
        }
        return data
    }

    @MainActor
    private func makeImage<V: View>(_ view: V, width: CGFloat, height: CGFloat, scale: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content:
            view
                .frame(width: width, height: height)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = scale
        return renderer.uiImage
    }

    @discardableResult
    private func write(_ data: Data, named name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
        try data.write(to: url)
        print("SNAPSHOT_WRITTEN \(url.path)")
        return url
    }

    // MARK: - The whole Home

    /// The whole Home, assembled with fixed inputs so the render is
    /// deterministic. Mirrors TurntableHomeView's composition.
    ///
    /// `ImageRenderer` does not draw a ScrollView's contents, so the
    /// tray and the shelves are rendered through their scroll-free
    /// halves (`QueueDiscRow`, `CrateShelves`) — which is exactly what
    /// the user sees before scrolling.
    @MainActor
    func testRenderFullDeck() throws {
        let home = VStack(spacing: 0) {
            // The status bar's share of the screen.
            Color.clear.frame(height: 59)

            // Nothing pending, so no row of indicators: the deck
            // starts at the top (revision 2026-11-20).
            Color.clear.frame(height: 10)

            deck(.playing)
                .padding(.top, 2)

            NowPlayingCaption(title: "Feeling Good", artist: "Nina Simone")
                .padding(.top, 12)

            deckQueue
                .padding(.top, 8)

            CrateShelves(
                shelves: Self.shelves,
                nowPlayingID: "shelf-0-1",
                onPlay: { _ in },
                onQueue: { _ in }
            )
            .padding(.top, 32)

            Spacer(minLength: 0)
        }
        .frame(width: 402, height: 874)
        .background(DeckRoomBackground(artworkURL: Self.makeArtworkFile(index: 2)))
        .clipped()

        let data = try render(home, width: 402, height: 874)
        let url = try write(data, named: "turntable-deck.png")
        XCTAssertGreaterThan(data.count, 10_000, "Deck render looks empty")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - The deck, state by state

    /// The deck on its own, at three times scale, so the platter, the
    /// arm and the lever can be judged at the pixel.
    @MainActor
    func testRenderDeckPlaying() throws {
        let data = try render(deckOnRoom(.playing), width: 402, height: 420, scale: 3)
        try write(data, named: "turntable-deck-playing.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// Paused: the lever is up and the arm has lifted off the groove.
    @MainActor
    func testRenderDeckPaused() throws {
        let data = try render(deckOnRoom(.paused), width: 402, height: 420)
        try write(data, named: "turntable-deck-paused.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// Nothing loaded: the idle record, and the arm parked in its rest.
    @MainActor
    func testRenderDeckIdle() throws {
        let data = try render(deckOnRoom(.idle), width: 402, height: 420)
        try write(data, named: "turntable-deck-idle.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// Fetching a track: the lamp on the platter's edge is lit.
    @MainActor
    func testRenderDeckLoading() throws {
        let data = try render(deckOnRoom(.loading), width: 402, height: 420)
        try write(data, named: "turntable-deck-loading.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The end of a side: the stylus is at the label.
    @MainActor
    func testRenderDeckAtEndOfTrack() throws {
        let data = try render(deckOnRoom(.ending), width: 402, height: 420)
        try write(data, named: "turntable-deck-ending.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    // MARK: - Tray and shelves

    /// The tray of queued records.
    @MainActor
    func testRenderQueueTray() throws {
        let tray = deckQueue
            .padding(.vertical, 16)
            .frame(width: 402)
            .background(TurntableTokens.room)
        let data = try render(tray, width: 402, height: 100, scale: 3)
        try write(data, named: "turntable-queue.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The line that names what is playing, over the tray.
    @MainActor
    func testRenderNowPlayingCaption() throws {
        let view = VStack(spacing: 8) {
            NowPlayingCaption(title: "Feeling Good", artist: "Nina Simone")
            deckQueue
        }
        .padding(.vertical, 14)
        .frame(width: 402)
        .background(TurntableTokens.room)
        let data = try render(view, width: 402, height: 124, scale: 3)
        try write(data, named: "turntable-now-playing.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// A sleeve held up for a closer look.
    @MainActor
    func testRenderHeldSleeve() throws {
        // The first shelf stands albums; the second one stands records.
        let track = Self.shelves[1].tracks[0]
        let card = HStack(spacing: 24) {
            SleevePeekCard(track: track, stage: .looking)
            SleevePeekCard(track: track, stage: .queued)
        }
        .padding(30)
        .background(TurntableTokens.room)
        let data = try render(
            card,
            width: SleevePeekCard.size.width * 2 + 84,
            height: SleevePeekCard.size.height + 60,
            scale: 3
        )
        try write(data, named: "turntable-sleeve-held.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The keys along the front of the plinth, in each lamp state.
    @MainActor
    func testRenderDeckKeys() throws {
        let view = VStack(spacing: 14) {
            HStack(spacing: 30) {
                DeckKeysView()
                DeckKeysView(states: [.dig: .lit, .radio: .lit, .review: .lit])
                DeckKeyButton(key: .setup) {}
            }
        }
        .padding(18)
        .frame(width: 402)
        .deckPlinth(cornerRadius: 0)
        let data = try render(view, width: 402, height: 130, scale: 3)
        try write(data, named: "turntable-keys.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The tray mid-deal: records spinning on a wave, the channel lit.
    @MainActor
    func testRenderTrayBeingDealt() throws {
        let items = (0..<6).map { index in
            QueueItem(
                track: Self.makeTrack(id: "q-\(index)", title: "Q\(index)", artist: "Artist", artIndex: index + 1),
                streamUrl: "https://example.com/\(index)",
                source: .stream,
                contentSource: .youtube
            )
        }
        let tray = VStack(spacing: 8) {
            NowPlayingCaption(title: "Feeling Good", artist: "Nina Simone", notice: TurntableHomeModel.diggingNotice)
            QueueDiscRow(items: items, currentIndex: 1, dealPhase: 0.4, onSelect: { _ in })
                .padding(.horizontal, 22)
                .frame(maxWidth: .infinity, minHeight: QueueTray.height, alignment: .leading)
                .clipShape(Capsule())
                .padding(.horizontal, QueueTray.margin)
                .background(QueueTray(isLit: true))
        }
        .padding(.vertical, 14)
        .frame(width: 402)
        .background(TurntableTokens.room)
        let data = try render(tray, width: 402, height: 124, scale: 3)
        try write(data, named: "turntable-queue-dealing.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The design system's parts on one sheet.
    @MainActor
    func testRenderDesignSystemSpecimen() throws {
        let sheet = VStack(alignment: .leading, spacing: 22) {
            Text("Library").font(DeckType.screenTitle).foregroundColor(TurntableTokens.cream)

            HStack(spacing: 4) {
                DeckChip(title: "Liked", count: 42, isSelected: true) {}
                DeckChip(title: "Downloaded", count: 118, isSelected: false) {}
                DeckChip(title: "Playlists", count: 6, isSelected: false) {}
            }
            .padding(4)
            .deckPanel()

            VStack(spacing: 0) {
                DeckTrackRow(
                    title: "Feeling Good", subtitle: "Nina Simone",
                    artworkURL: Self.makeArtworkFile(index: 2), smallPrint: "2:54", isPlaying: true
                )
                DeckTrackRow(
                    title: "Maria También", subtitle: "Khruangbin",
                    artworkURL: Self.makeArtworkFile(index: 5), smallPrint: "3:09"
                )
                DeckLedge(title: "Recently played", count: 24).padding(.top, 6)
            }

            HStack(spacing: 12) {
                DeckButton(title: "Play all", symbol: "play.fill", kind: .card) {}
                DeckButton(title: "Shuffle", symbol: "shuffle") {}
            }

            HStack(spacing: 18) {
                DeckMetalButton(symbol: "dice.fill", accent: DeckSignal.discover, state: .lit) {}
                DeckMetalButton(symbol: "heart.fill", accent: DeckSignal.live) {}
                DeckMetalButton(symbol: "arrow.down", accent: DeckSignal.power, state: .lit, size: 30) {}
                Spacer()
                HStack(spacing: 10) {
                    DeckLamp(color: DeckSignal.live)
                    DeckLamp(color: DeckSignal.discover)
                    DeckLamp(color: DeckSignal.attention)
                    DeckLamp(color: DeckSignal.power)
                    DeckLamp(state: .idle)
                }
            }
            .padding(14)
            .deckPlinth(cornerRadius: CornerRadius.lg)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(TurntableTokens.aluminium.opacity(0.7))
                Text("Find music").font(DeckType.body).foregroundColor(TurntableTokens.cream.opacity(0.4))
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 46)
            .deckWell(Capsule())
        }
        .padding(20)
        .frame(width: 402, alignment: .leading)
        .background(DeckRoom())
        let data = try render(sheet, width: 402, height: 522, scale: 3)
        try write(data, named: "deck-design-system.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The Library's grid and list, drawn the Deck way.
    @MainActor
    func testRenderLibraryDeckStyle() throws {
        func item(_ index: Int, _ title: String, _ artist: String) -> DownloadedTrackItem {
            let track = Self.makeTrack(id: "lib-\(index)", title: title, artist: artist, artIndex: index)
            return DownloadedTrackItem(
                id: "lib-\(index)", videoId: "lib-\(index)", title: title, artist: artist, album: "",
                durationSeconds: 174 + index * 23, fileSize: 4_200_000, fileSizeFormatted: "4.2 MB",
                downloadedAt: Date(), localPath: "", thumbnailURL: track.artworkURL, track: track
            )
        }
        let items = [
            item(2, "Feeling Good", "Nina Simone"), item(5, "Maria También", "Khruangbin"),
            item(7, "Blue in Green", "Miles Davis"), item(9, "Pink + White", "Frank Ocean")
        ]
        let sheet = VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, track in
                    GridTrackCell(
                        track: track, isSelected: index == 3, isEditing: false, isPlaying: index == 0,
                        memoryPreview: nil, mode: .downloaded, deck: true,
                        onTap: {}, onPlay: {}, onPlayNext: {}, onAddToQueue: {}, onDelete: {}
                    )
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, track in
                    DeckTrackRow(
                        title: track.title, subtitle: track.artist, artworkURL: track.thumbnailURL,
                        smallPrint: DeckFormat.runtime(track.durationSeconds), isPlaying: index == 0
                    )
                    Rectangle().fill(TurntableTokens.cream.opacity(0.08)).frame(height: 0.5)
                }
            }
        }
        .padding(16)
        .frame(width: 402, alignment: .leading)
        .background(DeckRoom())
        let data = try render(sheet, width: 402, height: 720, scale: 2)
        try write(data, named: "library-deck.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// A playlist's track rows (playing, downloaded, loading, with a
    /// memory) and the rename board.
    @MainActor
    func testRenderPlaylistDetailDeckStyle() throws {
        let flag = FeatureFlags.shared.turntableHome
        FeatureFlags.shared.turntableHome = true
        defer { FeatureFlags.shared.turntableHome = flag }

        func row(_ index: Int, _ title: String, _ artist: String,
                 playing: Bool = false, loading: Bool = false,
                 downloaded: Bool = false, memory: Bool = false) -> some View {
            CyberpunkTrackRow(
                track: Self.makeTrack(id: "pl-\(index)", title: title, artist: artist, artIndex: index),
                index: index + 1, isPlaying: playing, isEditing: false, deck: true,
                isLoading: loading, downloadTask: nil, isDownloaded: downloaded, hasMemory: memory,
                onPlay: {}, onDownload: {}, onAddToQueue: {}, onPlayNext: {},
                onAddToPlaylist: {}, onEditMemory: {}, onDelete: {}
            )
        }
        let sheet = VStack(spacing: 0) {
            DeckLedge(title: "Tracks", count: 4).padding(.bottom, 10)
            row(2, "Feeling Good", "Nina Simone", playing: true)
            row(5, "Maria También", "Khruangbin", downloaded: true)
            row(7, "Blue in Green", "Miles Davis", loading: true)
            row(9, "Pink + White", "Frank Ocean", memory: true)
            RenamePlaylistSheet(currentName: "Late night drives", onRename: { _ in })
                .frame(height: 260)
                .padding(.top, 30)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .frame(width: 402)
        .background(DeckRoom())
        let data = try render(sheet, width: 402, height: 640, scale: 2)
        try write(data, named: "playlist-detail-deck.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The Downloads screen's parts and History's readouts.
    @MainActor
    func testRenderDownloadsDeckStyle() throws {
        let flag = FeatureFlags.shared.turntableHome
        FeatureFlags.shared.turntableHome = true
        defer { FeatureFlags.shared.turntableHome = flag }

        var active = DownloadTask(track: Self.makeTrack(id: "dl-1", title: "Feeling Good", artist: "Nina Simone", artIndex: 2))
        active.progress = 0.62
        active.status = .downloading
        var done = DownloadTask(track: Self.makeTrack(id: "dl-2", title: "Maria También", artist: "Khruangbin", artIndex: 5))
        done.status = .completed
        done.completionTime = Date().addingTimeInterval(-600)
        var failed = DownloadTask(track: Self.makeTrack(id: "dl-3", title: "Blue in Green", artist: "Miles Davis", artIndex: 7))
        failed.status = .failed("Network")
        failed.completionTime = Date().addingTimeInterval(-3_600)

        let sheet = VStack(alignment: .leading, spacing: 18) {
            Text("Downloads").font(DeckType.screenTitle).foregroundColor(TurntableTokens.cream)
            HStack(spacing: 12) {
                StatBadge(icon: "arrow.down.circle.fill", value: "1", label: "Active", lamp: .working, lampColor: DeckSignal.power)
                StatBadge(icon: "internaldrive.fill", value: "24", label: "Saved", lamp: .idle, lampColor: DeckSignal.power)
                StatBadge(icon: "xmark.circle.fill", value: "1", label: "Failed", lamp: .lit, lampColor: DeckSignal.attention)
            }
            HStack(spacing: 12) {
                StatCard(value: "312", label: "Total Plays", icon: "play.fill")
                StatCard(value: "18h 40m", label: "Listening Time", icon: "clock.fill")
            }
            SectionHeader(title: "Downloading", icon: "arrow.down.circle", count: 1)
            ActiveDownloadCard(task: active)
            SectionHeader(title: "Completed", icon: "checkmark.circle", count: 2)
            CompletedDownloadCard(task: done)
            CompletedDownloadCard(task: failed)
            SectionHeader(title: "Downloaded files", icon: "internaldrive", count: 0)
            EmptyStateCard(icon: "internaldrive", title: "No Saved Downloads", subtitle: "Downloaded tracks appear here")
        }
        .environment(\.deckStyle, true)
        .padding(16)
        .frame(width: 402, alignment: .leading)
        .background(DeckRoom())
        let data = try render(sheet, width: 402, height: 900, scale: 2)
        try write(data, named: "downloads-deck.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The playlist sheets' parts: picker rows, preview rows, states.
    @MainActor
    func testRenderPlaylistSheetsDeckStyle() throws {
        let flag = FeatureFlags.shared.turntableHome
        FeatureFlags.shared.turntableHome = true
        defer { FeatureFlags.shared.turntableHome = flag }

        let track = Self.makeTrack(id: "sh-1", title: "Feeling Good", artist: "Nina Simone", artIndex: 2)
        let drives = Playlist(name: "Late night drives", trackIds: ["a", "b", "c"])
        let focus = Playlist(name: "Focus", trackIds: ["a"])

        let sheet = VStack(alignment: .leading, spacing: 0) {
            DeckLedge(title: "All playlists", count: 2).padding(.bottom, 6)
            PlaylistRow(playlist: drives, track: track, isAdded: true, onTap: {})
            PlaylistRow(playlist: focus, track: track, isAdded: false, onTap: {})
            DeckLedge(title: "Tracks", count: 2).padding(.top, 24).padding(.bottom, 6)
            TrackListRow(index: 1, track: track, onPlay: {}, onAddToQueue: {}, onPlayNext: {}, onAddToPlaylist: {}, onDownload: {})
            TrackListRow(index: 2, track: Self.makeTrack(id: "sh-2", title: "Maria También", artist: "Khruangbin", artIndex: 5),
                         onPlay: {}, onAddToQueue: {}, onPlayNext: {}, onAddToPlaylist: {}, onDownload: {})
            HStack(spacing: 30) {
                PlaylistLoadingView().frame(height: 90)
                PlaylistErrorView(message: "Failed to load playlist", onRetry: {}).frame(height: 160)
            }
            .padding(.top, 20)
        }
        .environment(\.deckStyle, true)
        .padding(16)
        .frame(width: 402, alignment: .leading)
        .background(DeckRoom())
        let data = try render(sheet, width: 402, height: 640, scale: 2)
        try write(data, named: "playlist-sheets-deck.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// Radio's selectors, shelf cards, rows, and the detail rows.
    @MainActor
    func testRenderRadioDeckStyle() throws {
        let flag = FeatureFlags.shared.turntableHome
        FeatureFlags.shared.turntableHome = true
        defer { FeatureFlags.shared.turntableHome = flag }

        func art(_ index: Int) -> String { Self.makeArtworkFile(index: index)?.absoluteString ?? "" }
        let station = RadioStation(stationuuid: "s1", name: "FIP Radio", urlResolved: "", favicon: art(2),
                                   country: "France", tags: "eclectic", codec: "AAC", bitrate: 128, clickcount: 1, votes: 1)
        let show = PodcastShow(collectionId: 1, collectionName: "Song Exploder", artistName: "Hrishikesh Hirway",
                               artworkUrl600: art(5), feedUrl: "", genres: ["Music"], trackCount: 300, releaseDate: "")
        let book = Audiobook(id: "b1", title: "Pride and Prejudice", description: "", authors: ["Jane Austen"],
                             language: "English", totalTime: "11:52:00", totalTimeSecs: 42_720, numSections: 61,
                             rssUrl: "", coverUrl: art(7), urlLibrivox: "")
        let episode = PodcastEpisode(guid: "e1", title: "Khruangbin — Maria También",
                                     description: "How a Thai-funk trio built a slow groove.",
                                     audioUrl: "", durationSeconds: 1_860, pubDate: "", artworkUrl: art(9))
        let chapter = AudiobookChapter(guid: "c1", title: "Chapter 1", chapterNumber: 1, audioUrl: "", durationSeconds: 640)

        let sheet = VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    DeckChip(title: "Stations", isSelected: true) {}
                    DeckChip(title: "Podcasts", isSelected: false) {}
                    DeckChip(title: "Audiobooks", isSelected: false) {}
                }.padding(5)
            }
            .deckPanel()
            DeckLedge(title: "Top stations", count: 3)
            HStack(alignment: .top, spacing: 14) {
                RadioStationCard(station: station) {}
                PodcastCard(show: show) {}
                AudiobookCard(book: book) {}
            }
            RadioStationRow(station: station) {}
            PodcastRow(show: show) {}
            AudiobookRow(book: book) {}
            DeckLedge(title: "Episodes", count: 1)
            PodcastEpisodeRow(episode: episode) {}
            AudiobookChapterRow(chapter: chapter, bookId: "b1") {}
        }
        .environment(\.deckStyle, true)
        .padding(16)
        .frame(width: 402, alignment: .leading)
        .background(DeckRoom())
        let data = try render(sheet, width: 402, height: 900, scale: 2)
        try write(data, named: "radio-deck.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// Settings' lever, off and on, in the rows it lives in, with a
    /// section ledge and the favourite-artist chips.
    @MainActor
    func testRenderSettingsLeversDeckStyle() throws {
        func row(_ title: String, _ detail: String, _ icon: String, on: Bool) -> some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(TurntableTokens.aluminium.opacity(0.85))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundColor(TurntableTokens.cream)
                    Text(detail).font(.caption).foregroundColor(TurntableTokens.cream.opacity(0.55))
                }
                Spacer(minLength: 8)
                DeckLever(isOn: on)
            }
            .frame(minHeight: 44)
            .overlay(alignment: .bottom) {
                Rectangle().fill(TurntableTokens.cream.opacity(0.08)).frame(height: 1)
            }
        }
        let sheet = VStack(alignment: .leading, spacing: 10) {
            DeckLedge(title: "Labs").padding(.bottom, 6)
            row("On This Day", "Show tracks you played on this day", "calendar", on: false)
            row("Daily Recap", "Remind you of your last track", "clock.arrow.circlepath", on: true)
            row("Turntable Home", "Replace the home screen with a record deck", "record.circle", on: true)
            DeckLedge(title: "Favorite artists", count: 3).padding(.top, 18).padding(.bottom, 6)
            HStack(spacing: 8) {
                FavoriteArtistChip(artist: "Khruangbin", onRemove: {})
                FavoriteArtistChip(artist: "Nina Simone", onRemove: {})
            }
        }
        .environment(\.deckStyle, true)
        .padding(16)
        .frame(width: 402, alignment: .leading)
        .background(DeckRoom())
        let data = try render(sheet, width: 402, height: 420, scale: 2)
        try write(data, named: "settings-levers-deck.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The mini player's record at three points in a side, and loading.
    @MainActor
    func testRenderMiniRecord() throws {
        let row = HStack(spacing: 18) {
            MiniRecord(artworkURL: Self.makeArtworkFile(index: 2), progress: 0.05)
            MiniRecord(artworkURL: Self.makeArtworkFile(index: 5), progress: 0.5)
            MiniRecord(artworkURL: Self.makeArtworkFile(index: 7), progress: 0.95)
            MiniRecord(artworkURL: nil, isLoading: true)
        }
        .padding(16)
        .deckPanel()
        .padding(20)
        .background(TurntableTokens.room)
        let data = try render(row, width: 300, height: 110, scale: 3)
        try write(data, named: "mini-record.png")
        XCTAssertGreaterThan(data.count, 5_000)
    }

    /// The full player's seek dial and on-air strip.
    @MainActor
    func testRenderPlayerDial() throws {
        let clock = PlaybackClock()
        _ = clock.tick(currentSeconds: 78, totalSeconds: 217, effectiveDuration: 217)
        let peaks: [Float] = (0..<400).map { index in
            let x = Double(index)
            let slow: Double = 0.3 * sin(x / 9)
            let fast: Double = 0.25 * sin(x / 2.3)
            return Float(0.35 + slow + fast)
        }
        let view = VStack(spacing: 16) {
            DeckSeekDial(clock: clock, peaks: peaks) { _ in }
            DeckSeekDial(clock: clock, peaks: nil) { _ in }
            DeckOnAirStrip()
        }
        .padding(14)
        .deckPanel(cornerRadius: 16)
        .padding(16)
        .background(DeckRoom())
        let data = try render(view, width: 402, height: 300, scale: 3)
        try write(data, named: "player-dial.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The shelves on their own, at three times scale.
    @MainActor
    func testRenderCrateGrid() throws {
        let shelves = CrateShelves(
            shelves: Self.shelves,
            nowPlayingID: "shelf-0-1",
            onPlay: { _ in },
            onQueue: { _ in }
        )
        .padding(.vertical, 18)
        .frame(width: 402)
        .background(TurntableTokens.room)

        let data = try render(shelves, width: 402, height: 370, scale: 3)
        try write(data, named: "turntable-crate.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The shelves before anything has loaded.
    @MainActor
    func testRenderEmptyShelves() throws {
        let shelves = CrateShelves(shelves: [], onPlay: { _ in }, onQueue: { _ in })
            .padding(.vertical, 18)
            .frame(width: 402)
            .background(TurntableTokens.room)
        let data = try render(shelves, width: 402, height: 230)
        try write(data, named: "turntable-crate-empty.png")
        XCTAssertGreaterThan(data.count, 5_000)
    }

    // MARK: - Pieces

    private enum DeckState {
        case playing, paused, idle, loading, ending
    }

    @MainActor
    private func deck(_ state: DeckState) -> some View {
        let loaded = state != .idle
        return TurntableDeckView(
            artworkURL: loaded ? Self.makeArtworkFile(index: 2) : nil,
            trackIdentity: loaded ? "deck-track" : "",
            isLoaded: loaded,
            isPlaying: state == .playing || state == .ending,
            isLoading: state == .loading,
            progress: state == .ending ? 1.0 : (state == .loading ? 0 : 0.42),
            duration: 244,
            reduceMotion: false,
            keyStates: state == .loading ? [.dig: .working] : (state == .playing ? [.dig: .lit, .review: .lit] : [:])
        )
    }

    @MainActor
    private func deckOnRoom(_ state: DeckState) -> some View {
        deck(state)
            .frame(width: 402, height: 420)
            .background(
                DeckRoomBackground(
                    artworkURL: state == .idle ? nil : Self.makeArtworkFile(index: 2)
                )
                .frame(height: 874, alignment: .top)
                .frame(height: 420, alignment: .top)
            )
            .clipped()
    }

    /// The tray of queued picture discs.
    @MainActor
    private var deckQueue: some View {
        QueueDiscRow(
            items: (0..<6).map { index in
                QueueItem(
                    track: Self.makeTrack(id: "q-\(index)", title: "Q\(index)", artist: "Artist", artIndex: index + 1),
                    streamUrl: "https://example.com/\(index)",
                    source: .stream,
                    contentSource: .youtube
                )
            },
            currentIndex: 1,
            onSelect: { _ in }
        )
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, minHeight: QueueTray.height, alignment: .leading)
        .clipShape(Capsule())
        .padding(.horizontal, QueueTray.margin)
        .background(QueueTray())
    }

    /// Three shelves: one artist standing albums, one artist standing
    /// records, and the recently-played shelf.
    @MainActor
    private static var shelves: [CrateShelfModel] {
        let titles = ["Nina Simone", "Khruangbin", TurntableHomeModel.recentShelfTitle]
        return titles.enumerated().map { shelfIndex, title in
            if shelfIndex == 0 {
                // The Selected Artists shelf stands albums, not records.
                return CrateShelfModel(
                    id: "shelf-\(shelfIndex)",
                    title: title,
                    albums: (0..<5).map { column in
                        makeAlbum(
                            id: "shelf-\(shelfIndex)-\(column)",
                            title: ["Pastel Blues", "Nina Simone", "Silk & Smoke", "Baltimore", "Fodder on My Wings"][column],
                            year: ["1965", "1967", "1968", "1972", "1974"][column],
                            artist: title,
                            artIndex: shelfIndex * 5 + column
                        )
                    }
                )
            }
            return CrateShelfModel(
                id: "shelf-\(shelfIndex)",
                title: title,
                tracks: (0..<(shelfIndex == 1 ? 4 : 5)).map { column in
                    makeTrack(
                        id: "shelf-\(shelfIndex)-\(column)",
                        title: "Track \(column)",
                        artist: title,
                        artIndex: shelfIndex * 5 + column
                    )
                }
            )
        }
    }

    // MARK: - Helpers

    @MainActor
    private static func makeTrack(id: String, title: String, artist: String, artIndex: Int = 0) -> Track {
        var thumbnails: [Thumbnail] = []
        if let url = makeArtworkFile(index: artIndex) {
            thumbnails = [Thumbnail(url: url, width: 600, height: 600)]
        }
        return Track(videoId: id,
             title: title,
             artists: [artist],
             album: "Album",
             durationSeconds: 240,
             thumbnails: thumbnails,
             isExplicit: false,
             videoType: "MUSIC_VIDEO_TYPE_ATV")
    }

    @MainActor
    private static func makeAlbum(id: String, title: String, year: String, artist: String, artIndex: Int) -> Album {
        var thumbnails: [Thumbnail] = []
        if let url = makeArtworkFile(index: artIndex) {
            thumbnails = [Thumbnail(url: url, width: 600, height: 600)]
        }
        return Album(browseId: "MPREb_test_\(id)",
                     title: title,
                     artists: [artist],
                     year: year,
                     type: "Album",
                     trackCount: 10,
                     thumbnails: thumbnails,
                     thumbnailSmall: thumbnails.first,
                     thumbnailLarge: thumbnails.first)
    }

    /// Writes a deterministic cover image to the tmp directory and
    /// returns its file URL.
    ///
    /// `ImageCache` reads file:// URLs directly (URLSession cannot),
    /// which is what lets these renders show real artwork on the
    /// record and on the shelves.
    ///
    /// The covers are deliberately varied — a two-colour ground, a
    /// large off-centre shape, a band of "type" — because a flat
    /// swatch says nothing about how a real sleeve will sit under the
    /// grooves and the sheen.
    private static func makeArtworkFile(index: Int) -> URL? {
        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        let hue = CGFloat((index * 37) % 100) / 100.0
        let image = renderer.image { context in
            let cg = context.cgContext
            let ground = [
                UIColor(hue: hue, saturation: 0.58, brightness: 0.86, alpha: 1).cgColor,
                UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1),
                        saturation: 0.72, brightness: 0.42, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: ground, locations: [0, 1]) {
                cg.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }

            UIColor(hue: (hue + 0.5).truncatingRemainder(dividingBy: 1),
                    saturation: 0.55, brightness: 0.95, alpha: 0.9).setFill()
            switch index % 3 {
            case 0:
                cg.fillEllipse(in: CGRect(x: 250, y: 60, width: 420, height: 420))
            case 1:
                cg.fill(CGRect(x: 70, y: 70, width: 240, height: 360))
            default:
                cg.move(to: CGPoint(x: 80, y: 520))
                cg.addLine(to: CGPoint(x: 330, y: 90))
                cg.addLine(to: CGPoint(x: 560, y: 520))
                cg.closePath()
                cg.fillPath()
            }

            UIColor.black.withAlphaComponent(0.78).setFill()
            cg.fill(CGRect(x: 50, y: 470, width: 300, height: 34))
            cg.fill(CGRect(x: 50, y: 520, width: 180, height: 18))
        }

        guard let data = image.pngData() else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("turntable-cover-\(index).png")
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        return url
    }
}
