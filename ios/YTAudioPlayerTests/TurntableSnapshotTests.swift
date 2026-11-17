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
    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat) throws -> Data {
        let renderer = ImageRenderer(content:
            view
                .frame(width: width, height: height)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2

        guard let image = renderer.uiImage else {
            XCTFail("ImageRenderer produced no image")
            throw NSError(domain: "TurntableSnapshot", code: 1)
        }
        guard let data = image.pngData() else {
            XCTFail("Could not encode PNG")
            throw NSError(domain: "TurntableSnapshot", code: 2)
        }
        return data
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
        try data.write(to: url)
        print("SNAPSHOT_WRITTEN \(url.path)")
        return url
    }

    // MARK: - Deck components

    /// The whole deck, assembled with fixed inputs so the render is
    /// deterministic. Mirrors TurntableHomeView's composition.
    @MainActor
    func testRenderFullDeck() throws {
        let deck = VStack(spacing: 0) {
            deckFascia

            deckPlatter
                .padding(.vertical, 10)

            QueueStackView(queue: [], currentIndex: 0, onSelect: { _ in })
                .padding(.horizontal, 18)

            deckCrate
                .padding(.horizontal, 14)
                .padding(.top, 12)

            Spacer(minLength: 8)

            deckNowPlaying
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }
        .background(deckPlinth)
        .frame(width: 402, height: 874)

        let data = try render(deck, width: 402, height: 874)
        let url = try write(data, named: "turntable-deck.png")
        XCTAssertGreaterThan(data.count, 10_000, "Deck render looks empty")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// The deck's parts stacked with no spacer between them, so a
    /// render taller than the screen shows every part. If the crate or
    /// the now-playing strip is invisible here, it is invisible in the
    /// app too.
    ///
    /// Note: `ImageRenderer` does not draw a ScrollView's contents, so
    /// the crate's sleeves are missing from every render. That is a
    /// limitation of the renderer, not of the crate.
    @MainActor
    func testRenderDeckParts() throws {
        let deck = VStack(spacing: 0) {
            deckFascia

            deckPlatter
                .padding(.vertical, 10)

            QueueStackView(queue: [], currentIndex: 0, onSelect: { _ in })
                .padding(.horizontal, 18)

            deckCrate
                .padding(.horizontal, 14)
                .padding(.top, 12)

            deckNowPlaying
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .background(deckPlinth)
        .frame(width: 402, height: 900)

        let data = try render(deck, width: 402, height: 900)
        try write(data, named: "turntable-deck-parts.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The platter alone, large, so the groove texture and the label
    /// can be judged at full size.
    @MainActor
    func testRenderPlatterDetail() throws {
        let platter = ZStack {
            TurntableTokens.walnut.opacity(0.5)
            PlatterView(
                artworkURL: nil,
                isPlaying: true,
                progress: 0.0,
                reduceMotion: false,
                onTapSpindle: {},
                onLongPress: {}
            )
            .frame(width: 320, height: 320)
        }
        let data = try render(platter, width: 360, height: 360)
        try write(data, named: "turntable-platter.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The tonearm alone, large, so the pivot and headshell geometry
    /// can be judged.
    @MainActor
    func testRenderTonearmDetail() throws {
        let arm = ZStack {
            Color.black
            Image(TurntableTexture.vinylGrooves)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 276, height: 276)
                .clipShape(Circle())
                .opacity(0.55)
            TonearmView(
                progress: 0.35,
                isScrubbing: false,
                onScrub: { _ in },
                onScrubEnded: { _ in }
            )
            .frame(width: 320, height: 320)
        }
        let data = try render(arm, width: 340, height: 340)
        try write(data, named: "turntable-tonearm.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    // MARK: - Pieces

    @MainActor
    private var deckPlinth: some View {
        ZStack {
            // The texture is pinned in an overlay so its natural size
            // cannot leak into the deck's layout — that bug once made
            // the whole deck 1024pt wide and pushed every control off
            // screen.
            Color.clear
                .overlay(
                    Image(TurntableTexture.walnut)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(0.22)
                )
            LinearGradient(
                colors: [Color.black.opacity(0.72), Color.black.opacity(0.45), Color.black.opacity(0.88)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [TurntableTokens.keyLight.opacity(0.10), .clear],
                center: UnitPoint(x: 0.18, y: 0.05),
                startRadius: 0, endRadius: 420
            )
        }
    }

    @MainActor
    private var deckFascia: some View {
        DeckFasciaView(
            profile: AnyView(
                HStack(spacing: 8) {
                    Circle()
                        .fill(Theme.cyberCyan.opacity(0.18))
                        .frame(width: 30, height: 30)
                        .overlay(
                            Circle().stroke(Theme.cyberCyan.opacity(0.4), lineWidth: 1)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text("NIGHT")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(TurntableTokens.aluminium.opacity(0.6))
                        Text("ALEX")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(TurntableTokens.cream)
                    }
                }
            ),
            isPlaying: true,
            isConnected: true,
            rpmLabel: "33⅓",
            hasSmartLibraryCandidates: true,
            hasPendingCleanup: true,
            onToggleRPM: {},
            onSmartLibrary: {},
            onCleanup: {}
        ) {
            HStack(spacing: 6) {
                ForEach(["hourglass", "dice.fill", "antenna.radiowaves.left.and.right", "music.note.list", "gearshape.fill"], id: \.self) { icon in
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.cyberCyan)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.35))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Theme.cyberCyan.opacity(0.35), lineWidth: 1)
                                )
                        )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    @MainActor
    private var deckPlatter: some View {
        ZStack {
            PlatterView(
                artworkURL: nil,
                isPlaying: true,
                progress: 0.42,
                reduceMotion: false,
                onTapSpindle: {},
                onLongPress: {}
            )
            .frame(width: 320, height: 320)

            TonearmView(
                progress: 0.42,
                isScrubbing: false,
                onScrub: { _ in },
                onScrubEnded: { _ in }
            )
            .frame(width: 320, height: 320)

            CueLeverView(isPlaying: true, onToggle: {})
                .offset(x: 132, y: -76)
        }
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private var deckCrate: some View {
        SleeveCrateView(
            sleeves: [
                Self.makeTrack(id: "a", title: "Alpha", artist: "One"),
                Self.makeTrack(id: "b", title: "Beta", artist: "Two"),
                Self.makeTrack(id: "c", title: "Gamma", artist: "Three"),
                Self.makeTrack(id: "d", title: "Delta", artist: "Four")
            ],
            onPlay: { _ in },
            onQueue: { _ in }
        )
    }

    @MainActor
    private var deckNowPlaying: some View {
        let track = Self.makeTrack(id: "deck-track", title: "Midnight Signal", artist: "Night FM")
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(Typography.playerTitle)
                    .foregroundColor(TurntableTokens.cream)
                Text(track.artists.first ?? "")
                    .font(Typography.playerArtist)
                    .foregroundColor(TurntableTokens.aluminium.opacity(0.75))
            }
            Spacer(minLength: 8)
            LevelMeterRow(
                levels: (0..<32).map { Float(0.15 + 0.6 * abs(sin(Double($0) / 4))) },
                accent: Theme.cyberCyan
            )
            .frame(width: 110, height: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(TurntableTokens.aluminium.opacity(0.18), lineWidth: 1)
                )
        )
    }

    // MARK: - Helpers

    private static func makeTrack(id: String, title: String, artist: String) -> Track {
        Track(videoId: id,
             title: title,
             artists: [artist],
             album: "Album",
             durationSeconds: 240,
             thumbnails: [],
             isExplicit: false,
             videoType: "MUSIC_VIDEO_TYPE_ATV")
    }
}
