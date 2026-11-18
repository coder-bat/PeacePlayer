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
        // The artwork loads asynchronously through ImageCache, and the
        // offscreen renderer draws whatever is in the cache at the
        // moment it runs. So: render once to start the loads, let the
        // main queue drain, then render for real.
        _ = makeImage(view, width: width, height: height)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        guard let image = makeImage(view, width: width, height: height) else {
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
    private func makeImage<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content:
            view
                .frame(width: width, height: height)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2
        return renderer.uiImage
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

            deckQueue
                .padding(.horizontal, 18)

            deckCrateVisible
                .padding(.horizontal, 14)
                .padding(.top, 12)

            Spacer(minLength: 8)
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
    /// the queue shelf is invisible here, it is invisible in the app
    /// too.
    ///
    /// Note: `ImageRenderer` does not draw a ScrollView's contents, so
    /// the crate's sleeves are missing from any render that uses the
    /// scrolling `SleeveCrateView`. That is a limitation of the
    /// renderer, not of the crate — `testRenderCrateGrid` renders the
    /// grid itself.
    @MainActor
    func testRenderDeckParts() throws {
        let deck = VStack(spacing: 0) {
            deckFascia

            deckPlatter
                .padding(.vertical, 10)

            deckQueue
                .padding(.horizontal, 18)

            deckCrateVisible
                .padding(.horizontal, 14)
                .padding(.top, 12)
        }
        .background(deckPlinth)
        .frame(width: 402, height: 900)

        let data = try render(deck, width: 402, height: 900)
        try write(data, named: "turntable-deck-parts.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The platter alone, large, with real cover art, so the picture
    /// disc can be judged at full size.
    @MainActor
    func testRenderPlatterDetail() throws {
        let platter = ZStack {
            TurntableTokens.walnut.opacity(0.5)
            PlatterView(
                artworkURL: Self.makeArtworkFile(index: 0),
                trackIdentity: "art-0",
                isPlaying: true,
                progress: 0.0,
                reduceMotion: false,
                progressAt: nil,
                onTapPlatter: {},
                onLongPress: {}
            )
            .frame(width: 320, height: 320)
        }
        let data = try render(platter, width: 360, height: 360)
        try write(data, named: "turntable-platter.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The blank record — the fallback when a track has no artwork.
    @MainActor
    func testRenderBlankPlatter() throws {
        let platter = ZStack {
            TurntableTokens.walnut.opacity(0.5)
            PlatterView(
                artworkURL: nil,
                trackIdentity: "",
                isPlaying: false,
                progress: 0.0,
                reduceMotion: false,
                progressAt: nil,
                onTapPlatter: {},
                onLongPress: {}
            )
            .frame(width: 320, height: 320)
        }
        let data = try render(platter, width: 360, height: 360)
        try write(data, named: "turntable-platter-blank.png")
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
                progressAt: nil,
                onScrub: { _ in },
                onScrubEnded: { _ in }
            )
            .frame(width: 320, height: 320)
        }
        let data = try render(arm, width: 340, height: 340)
        try write(data, named: "turntable-tonearm.png")
        XCTAssertGreaterThan(data.count, 10_000)
    }

    /// The crate's grid on its own. `ImageRenderer` cannot draw scroll
    /// content, so this renders the grid directly — which is exactly
    /// what the user sees in the crate's first three rows.
    @MainActor
    func testRenderCrateGrid() throws {
        let crate = VStack(alignment: .leading, spacing: 8) {
            CrateShelf(
                sleeves: (0..<18).map {
                    Self.makeTrack(id: "crate-\($0)", title: "Track \($0)", artist: "Artist", artIndex: $0)
                },
                onPlay: { _ in },
                onQueue: { _ in }
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .background(deckPlinth)
        .frame(width: 402, height: 260)

        let data = try render(crate, width: 402, height: 260)
        try write(data, named: "turntable-crate.png")
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
        DeckFasciaView {
            HStack(spacing: 6) {
                ForEach(["hourglass", "dice.fill", "antenna.radiowaves.left.and.right", "music.note.list"], id: \.self) { icon in
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
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
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                // The two actionable indicators, in the row, left of
                // Settings.
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.cyberYellow)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.35))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Theme.cyberYellow.opacity(0.35), lineWidth: 1)
                            )
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(TurntableTokens.aluminium)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.35))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(TurntableTokens.aluminium.opacity(0.35), lineWidth: 1)
                            )
                    )
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    @MainActor
    private var deckPlatter: some View {
        ZStack {
            PlatterView(
                artworkURL: Self.makeArtworkFile(index: 2),
                trackIdentity: "deck-track",
                isPlaying: true,
                progress: 0.42,
                reduceMotion: false,
                progressAt: nil,
                onTapPlatter: {},
                onLongPress: {}
            )
            .frame(width: 320, height: 320)

            TonearmView(
                progress: 0.42,
                isScrubbing: false,
                progressAt: nil,
                onScrub: { _ in },
                onScrubEnded: { _ in }
            )
            .frame(width: 320, height: 320)

            CueLeverView(isPlaying: true, onToggle: {})
                .offset(x: -132, y: -76)
        }
        .frame(maxWidth: .infinity)
    }

    /// The shelf of queued picture discs.
    @MainActor
    private var deckQueue: some View {
        QueueDiscRow(
            items: (0..<6).map { index in
                QueueItem(
                    track: Self.makeTrack(id: "q-\(index)", title: "Q\(index)", artist: "Artist", artIndex: index),
                    streamUrl: "https://example.com/\(index)",
                    source: .stream,
                    contentSource: .youtube
                )
            },
            currentIndex: 1,
            onSelect: { _ in }
        )
    }

    /// The crate as the user sees it: the first three rows of the grid
    /// (the scrolling crate itself cannot be drawn by the offscreen
    /// renderer).
    @MainActor
    private var deckCrateVisible: some View {
        CrateShelf(
            sleeves: (0..<12).map {
                Self.makeTrack(id: "crate-\($0)", title: "Track \($0)", artist: "Artist", artIndex: $0)
            },
            onPlay: { _ in },
            onQueue: { _ in }
        )
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

    /// Writes a deterministic cover image to the tmp directory and
    /// returns its file URL.
    ///
    /// `ImageCache` reads file:// URLs directly (URLSession cannot),
    /// which is what lets these renders show real artwork on the
    /// record and in the crate.
    private static func makeArtworkFile(index: Int) -> URL? {
        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cg = context.cgContext
            UIColor(hue: CGFloat(index % 6) / 6.0,
                   saturation: 0.62,
                   brightness: 0.82,
                   alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))

            UIColor.white.withAlphaComponent(0.16).setFill()
            for band in 0..<7 {
                cg.fill(CGRect(x: CGFloat(band) * 96 - 80, y: 0, width: 38, height: size.height))
            }

            UIColor.black.withAlphaComponent(0.32).setFill()
            cg.fillEllipse(in: CGRect(x: 130, y: 130, width: 340, height: 340))

            UIColor.white.withAlphaComponent(0.92).setFill()
            cg.fillEllipse(in: CGRect(x: 285, y: 285, width: 30, height: 30))
        }

        guard let data = image.pngData() else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("turntable-art-\(index).png")
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        return url
    }
}
