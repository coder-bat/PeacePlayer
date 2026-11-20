//
//  TurntableHomeModelTests.swift
//  YTAudioPlayerTests
//
//  What goes on the shelves under the deck, and what the tray of
//  queued records shows.
//
//  The shelves matter because they are the Home screen's only browse
//  surface: a track standing on two shelves would show the same
//  record twice, an artist whose suggestions failed to load must not
//  leave an empty ledge behind, and the order must not change between
//  renders or the shelves would reshuffle under the user's finger.
//

import XCTest
import SwiftUI
@testable import PeacePlayer

final class TurntableHomeModelTests: XCTestCase {

    // MARK: - Shelves

    func testEachFavouriteArtistGetsAShelf() {
        let shelves = TurntableHomeModel.shelves(
            albums: ["One": [makeAlbum(id: "a")], "Two": [makeAlbum(id: "b")]],
            artistOrder: ["One", "Two"],
            recent: []
        )
        XCTAssertEqual(shelves.map(\.title), ["One", "Two"])
        XCTAssertEqual(shelves.map { $0.albums.map(\.browseId) }, [["a"], ["b"]])
    }

    func testShelvesFollowTheUsersOrderNotTheAlphabet() {
        let shelves = TurntableHomeModel.shelves(
            albums: ["Apple": [makeAlbum(id: "a")], "Zebra": [makeAlbum(id: "z")]],
            artistOrder: ["Zebra", "Apple"],
            recent: []
        )
        XCTAssertEqual(shelves.map(\.title), ["Zebra", "Apple"])
    }

    func testAnArtistTheOrderDoesNotKnowStillGetsAShelf() {
        // Suggestions can arrive for an artist the favourites list has
        // since dropped. They follow the ranked ones, alphabetically.
        let shelves = TurntableHomeModel.shelves(
            albums: [
                "Ranked": [makeAlbum(id: "r")],
                "Mystery": [makeAlbum(id: "m")],
                "Another": [makeAlbum(id: "n")]
            ],
            artistOrder: ["Ranked"],
            recent: []
        )
        XCTAssertEqual(shelves.map(\.title), ["Ranked", "Another", "Mystery"])
    }

    func testShelvesAreDeterministicAcrossCalls() {
        // The shelves must not reshuffle on every Home render.
        let albums = ["Zebra": [makeAlbum(id: "z")], "Apple": [makeAlbum(id: "a")]]
        let first = TurntableHomeModel.shelves(albums: albums, artistOrder: [], recent: [])
        let second = TurntableHomeModel.shelves(albums: albums, artistOrder: [], recent: [])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.title), ["Apple", "Zebra"])
    }

    func testAnAlbumStandsOnOneShelfOnly() {
        let shared = makeAlbum(id: "same")
        let shelves = TurntableHomeModel.shelves(
            albums: ["One": [shared, makeAlbum(id: "a")], "Two": [shared, makeAlbum(id: "b")]],
            artistOrder: ["One", "Two"],
            recent: [makeRecent(id: "r")]
        )
        let all = shelves.flatMap { $0.albums.map(\.browseId) }
        XCTAssertEqual(all.count, Set(all).count, "The same album is standing on two shelves")
        // Two artist shelves; the recently-played shelf stands records.
        XCTAssertEqual(shelves.map { $0.albums.map(\.browseId) }, [["same", "a"], ["b"], []])
    }

    func testAShelfWithNothingLeftOnItIsNotPutUp() {
        // Every one of the second artist's albums is already on the
        // first artist's shelf, and one artist has none at all.
        let album = makeAlbum(id: "only")
        let shelves = TurntableHomeModel.shelves(
            albums: ["One": [album], "Two": [album], "Three": []],
            artistOrder: ["One", "Two", "Three"],
            recent: []
        )
        XCTAssertEqual(shelves.map(\.title), ["One"])
    }

    func testAnArtistShelfHoldsOneRowOfAlbums() {
        let many = (0..<12).map { makeAlbum(id: "a\($0)") }
        let shelves = TurntableHomeModel.shelves(
            albums: ["Artist": many],
            artistOrder: ["Artist"],
            recent: []
        )
        XCTAssertEqual(shelves.first?.albums.count, CrateGrid.columnCount)
    }

    func testAnArtistShelfStandsAlbumsAndTheRecentShelfStandsRecords() {
        let shelves = TurntableHomeModel.shelves(
            albums: ["Artist": [makeAlbum(id: "s")]],
            artistOrder: ["Artist"],
            recent: [makeRecent(id: "r")]
        )
        XCTAssertTrue(shelves.first?.standsAlbums == true)
        XCTAssertEqual(shelves.first?.tracks, [])
        XCTAssertEqual(shelves.last?.standsAlbums, false)
        XCTAssertEqual(shelves.last?.albums, [])
        XCTAssertEqual(shelves.last?.tracks.map(\.videoId), ["r"])
    }

    func testRecentlyPlayedIsTheLastShelf() {
        let shelves = TurntableHomeModel.shelves(
            albums: ["Artist": [makeAlbum(id: "s")]],
            artistOrder: ["Artist"],
            recent: [makeRecent(id: "r1"), makeRecent(id: "r2")]
        )
        XCTAssertEqual(shelves.last?.title, TurntableHomeModel.recentShelfTitle)
        XCTAssertEqual(shelves.last?.tracks.map(\.videoId), ["r1", "r2"])
    }

    func testRecentlyPlayedAloneStillFurnishesTheRoom() {
        // A user with no favourite artists still has a shelf.
        let shelves = TurntableHomeModel.shelves(
            albums: [:],
            artistOrder: [],
            recent: [makeRecent(id: "r1")]
        )
        XCTAssertEqual(shelves.count, 1)
        XCTAssertEqual(shelves.first?.tracks.map(\.videoId), ["r1"])
    }

    // MARK: - Deck keys

    func testEveryKeyIsDarkOnAQuietDeck() {
        let states = TurntableHomeModel.keyStates(
            isDigging: false, dugTrackIDs: [], nowPlayingID: "a", isRadioPlaying: false
        )
        XCTAssertTrue(states.isEmpty)
    }

    func testTheDigKeyPulsesWhileTheEngineLooks() {
        let states = TurntableHomeModel.keyStates(
            isDigging: true, dugTrackIDs: ["a"], nowPlayingID: "a", isRadioPlaying: false
        )
        XCTAssertEqual(states[.dig], .working)
    }

    func testTheDigKeyIsLitOnlyWhileADugRecordPlays() {
        // The engine's session stays open until the app quits; the
        // lamp must not.
        let on = TurntableHomeModel.keyStates(
            isDigging: false, dugTrackIDs: ["a", "b"], nowPlayingID: "b", isRadioPlaying: false
        )
        XCTAssertEqual(on[.dig], .lit)
        let off = TurntableHomeModel.keyStates(
            isDigging: false, dugTrackIDs: ["a", "b"], nowPlayingID: "z", isRadioPlaying: false
        )
        XCTAssertNil(off[.dig])
        let idle = TurntableHomeModel.keyStates(
            isDigging: false, dugTrackIDs: ["a"], nowPlayingID: nil, isRadioPlaying: false
        )
        XCTAssertNil(idle[.dig])
    }

    func testTheRadioKeyIsLitWhileAStationPlays() {
        let states = TurntableHomeModel.keyStates(
            isDigging: false, dugTrackIDs: [], nowPlayingID: nil, isRadioPlaying: true
        )
        XCTAssertEqual(states, [.radio: .lit])
    }

    func testTheReviewButtonIsLitWhileSomethingWaits() {
        let waiting = TurntableHomeModel.keyStates(
            isDigging: false, dugTrackIDs: [], nowPlayingID: nil, isRadioPlaying: false, hasPendingReview: true
        )
        XCTAssertEqual(waiting, [.review: .lit])
    }

    func testEachCornerOfThePlinthHoldsOneThing() {
        let size = TurntableDeckView.size
        // Setup back-left, lever front-left, keys front-right. (The
        // arm's pivot has the back-right.)
        XCTAssertLessThan(TurntableDeckView.setupCentre.x, size.width / 4)
        XCTAssertLessThan(TurntableDeckView.setupCentre.y, size.height / 4)
        XCTAssertLessThan(TurntableDeckView.leverCentre.x, size.width / 4)
        XCTAssertGreaterThan(TurntableDeckView.leverCentre.y, size.height * 3 / 4)
        XCTAssertGreaterThan(TurntableDeckView.keysCentre.x, size.width * 3 / 4)
        XCTAssertGreaterThan(TurntableDeckView.keysCentre.y, size.height * 3 / 4)
    }

    /// Every button's centre on the plinth.
    private var buttonCentres: [CGPoint] {
        let origin = CGPoint(
            x: TurntableDeckView.keysCentre.x - DeckKeysView.size.width / 2,
            y: TurntableDeckView.keysCentre.y - DeckKeysView.size.height / 2
        )
        let cluster = DeckKeysView.cluster.map { entry -> CGPoint in
            let local = DeckKeysView.centre(column: entry.column, row: entry.row)
            return CGPoint(x: origin.x + local.x, y: origin.y + local.y)
        }
        return cluster + [TurntableDeckView.setupCentre]
    }

    func testEveryButtonIsOnThePlinthAndClearOfThePlatter() {
        let plinth = CGRect(origin: .zero, size: TurntableDeckView.size)
        // The cap, its lamp ring and the hole it sits in.
        let reach = DeckKeysView.buttonDiameter / 2 + 4
        for centre in buttonCentres {
            XCTAssertTrue(plinth.insetBy(dx: reach + 3, dy: reach + 3).contains(centre), "\(centre)")
            let dx = centre.x - TurntableDeckView.platterCentre.x
            let dy = centre.y - TurntableDeckView.platterCentre.y
            XCTAssertGreaterThan(
                (dx * dx + dy * dy).squareRoot(), PlatterView.diameter / 2 + reach + 4, "\(centre)"
            )
        }
    }

    func testTheLeverIsOnThePlinthAndClearOfThePlatter() {
        let lever = CGRect(
            x: TurntableDeckView.leverCentre.x - 18, y: TurntableDeckView.leverCentre.y - 36, width: 36, height: 72
        )
        XCTAssertTrue(CGRect(origin: .zero, size: TurntableDeckView.size).insetBy(dx: 6, dy: 6).contains(lever))
        for corner in [CGPoint(x: lever.maxX, y: lever.minY), CGPoint(x: lever.maxX, y: lever.maxY)] {
            let dx = corner.x - TurntableDeckView.platterCentre.x
            let dy = corner.y - TurntableDeckView.platterCentre.y
            XCTAssertGreaterThan((dx * dx + dy * dy).squareRoot(), PlatterView.diameter / 2 + 6)
        }
    }

    func testTheKeysAreAComfortableTouchTargetAndDoNotCrowd() {
        // Caps never touch, and the cluster is the three keys that are
        // not setup.
        XCTAssertGreaterThan(DeckKeysView.pitch, DeckKeysView.buttonDiameter + 6)
        XCTAssertEqual(Set(DeckKeysView.cluster.map(\.key)), [.dig, .radio, .review])
        // No captions, so the symbols have to tell them apart.
        XCTAssertEqual(Set(DeckKey.allCases.map(\.symbol)).count, DeckKey.allCases.count)
        XCTAssertEqual(Set(DeckKey.allCases.map(\.accessibilityLabel)).count, DeckKey.allCases.count)
    }

    // MARK: - Design system

    func testRunningTimesAndCountsReadTheSameEverywhere() {
        XCTAssertEqual(DeckFormat.runtime(222), "3:42")
        XCTAssertEqual(DeckFormat.runtime(3725), "1:02:05")
        XCTAssertNil(DeckFormat.runtime(0))
        XCTAssertEqual(DeckFormat.tracks(1), "1 track")
        XCTAssertEqual(DeckFormat.tracks(24), "24 tracks")
        XCTAssertEqual(DeckFormat.tracks(0), "0 tracks")
    }

    func testAScreenIsLegacyUnlessItSaysOtherwise() {
        // Shared components are drawn the old way by default, so a
        // screen that has not been moved over cannot pick up the Deck
        // style by accident.
        XCTAssertFalse(EnvironmentValues().deckStyle)
    }

    // MARK: - Library search

    private func song(_ id: String, _ title: String, _ artist: String, album: String = "") -> Track {
        Track(videoId: id, title: title, artists: [artist], album: album, durationSeconds: 200,
              thumbnails: [], isExplicit: false, videoType: "MUSIC_VIDEO_TYPE_ATV")
    }

    func testLibrarySearchFindsByTitleArtistAndAlbum() {
        let tracks = [
            song("a", "Feeling Good", "Nina Simone"),
            song("b", "Sinnerman", "Nina Simone", album: "Pastel Blues"),
            song("c", "Maria También", "Khruangbin")
        ]
        let byTitle = LibrarySearch.results(for: "feel", downloaded: tracks, liked: [], playlists: [])
        XCTAssertEqual(byTitle.tracks.map(\.videoId), ["a"])
        let byArtist = LibrarySearch.results(for: "nina", downloaded: tracks, liked: [], playlists: [])
        XCTAssertEqual(Set(byArtist.tracks.map(\.videoId)), ["a", "b"])
        let byAlbum = LibrarySearch.results(for: "pastel", downloaded: tracks, liked: [], playlists: [])
        XCTAssertEqual(byAlbum.tracks.map(\.videoId), ["b"])
    }

    func testLibrarySearchIgnoresCaseAndAccents() {
        let tracks = [song("c", "Maria También", "Khruangbin")]
        XCTAssertEqual(
            LibrarySearch.results(for: "TAMBIEN", downloaded: tracks, liked: [], playlists: []).tracks.count, 1
        )
    }

    func testLibrarySearchMatchesWordsAcrossTitleAndArtist() {
        let tracks = [song("a", "Feeling Good", "Nina Simone"), song("d", "Good Days", "SZA")]
        let found = LibrarySearch.results(for: "nina good", downloaded: tracks, liked: [], playlists: [])
        XCTAssertEqual(found.tracks.map(\.videoId), ["a"])
    }

    func testATitleMatchOutranksAnArtistMatch() {
        let tracks = [song("x", "Unrelated", "Blue Note Trio"), song("y", "Blue in Green", "Miles Davis")]
        let found = LibrarySearch.results(for: "blue", downloaded: tracks, liked: [], playlists: [])
        XCTAssertEqual(found.tracks.map(\.videoId), ["y", "x"])
    }

    func testASongThatIsLikedAndDownloadedAppearsOnce() {
        let track = song("a", "Feeling Good", "Nina Simone")
        let liked = song("l", "Good Days", "SZA")
        let found = LibrarySearch.results(for: "good", downloaded: [track], liked: [track, liked], playlists: [])
        XCTAssertEqual(found.tracks.map(\.videoId).sorted(), ["a", "l"])
        XCTAssertEqual(found.downloadedIDs, ["a"])
    }

    func testLibrarySearchFindsTheUsersOwnPlaylistsButNotSmartOnes() {
        let own = Playlist(name: "Sunday Morning")
        var smart = Playlist(name: "Sunday Smart")
        smart.isSmart = true
        let found = LibrarySearch.results(for: "sunday", downloaded: [], liked: [], playlists: [own, smart])
        XCTAssertEqual(found.playlists.map(\.name), ["Sunday Morning"])
        XCTAssertEqual(found.count, 1)
    }

    func testAnEmptyQueryFindsNothing() {
        let tracks = [song("a", "Feeling Good", "Nina Simone")]
        XCTAssertTrue(LibrarySearch.results(for: "   ", downloaded: tracks, liked: [], playlists: []).isEmpty)
        XCTAssertTrue(LibrarySearch.results(for: "zzz", downloaded: tracks, liked: [], playlists: []).isEmpty)
    }

    // MARK: - Full player

    func testTheCaseCarriesTheVolumeOnlyWhereThereIsRoom() {
        // The home-indicator inset is walnut, not room for controls.
        XCTAssertFalse(DeckCaseLayout.isRoomy(height: DeckCaseLayout.minimumHeight, bottomInset: 0))
        XCTAssertFalse(DeckCaseLayout.isRoomy(height: 400, bottomInset: 34))
        XCTAssertTrue(DeckCaseLayout.isRoomy(height: 440, bottomInset: 34))
        XCTAssertGreaterThan(DeckCaseLayout.roomyHeight, DeckCaseLayout.minimumHeight + 44)
    }

    func testTheDialMapsATouchToAPlaceInTheTrack() {
        XCTAssertEqual(DeckDial.progress(atX: 0, width: 300), 0)
        XCTAssertEqual(DeckDial.progress(atX: 150, width: 300), 0.5)
        XCTAssertEqual(DeckDial.progress(atX: 400, width: 300), 1)
        XCTAssertEqual(DeckDial.progress(atX: -20, width: 300), 0)
        XCTAssertEqual(DeckDial.progress(atX: 10, width: 0), 0)
    }

    func testTheDialsWaveformIsResampledAndNormalised() {
        let peaks = (0..<1000).map { Float($0 % 100) / 200 }
        let bars = DeckDial.bars(from: peaks)
        XCTAssertEqual(bars.count, DeckDial.barCount)
        XCTAssertEqual(bars.max() ?? 0, 1, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(bars.min() ?? 0, 0.08)
        XCTAssertTrue(DeckDial.bars(from: []).isEmpty)
        // Silence still draws a line rather than nothing.
        XCTAssertEqual(Set(DeckDial.bars(from: [0, 0, 0, 0], count: 4)), [0.08])
    }

    func testTheDialReadsTimesTheWayTheRestOfTheDeckDoes() {
        XCTAssertEqual(DeckDial.time(78), "1:18")
        XCTAssertEqual(DeckDial.time(0), "0:00")
        XCTAssertEqual(DeckDial.time(.nan), "0:00")
        XCTAssertEqual(DeckDial.time(-4), "0:00")
    }

    // MARK: - Browsing the tray

    func testTheCaptionMarksWhichRecordIsBeingBrowsed() {
        XCTAssertEqual(TurntableHomeModel.browsingMark(index: 6, count: 20), "7/20")
        XCTAssertEqual(TurntableHomeModel.browsingMark(index: 0, count: 1), "1/1")
    }

    func testNothingBrowsedMeansNoMark() {
        XCTAssertNil(TurntableHomeModel.browsingMark(index: nil, count: 20))
        // A queue that shrank under a browsed record.
        XCTAssertNil(TurntableHomeModel.browsingMark(index: 20, count: 20))
        XCTAssertNil(TurntableHomeModel.browsingMark(index: -1, count: 20))
    }

    func testTheFocusedRecordIsLargerAndFitsTheTray() {
        XCTAssertGreaterThan(QueueDisc.focusScale, 1.1)
        XCTAssertLessThanOrEqual(QueueDisc.diameter * QueueDisc.focusScale, QueueTray.height - 4)
        XCTAssertEqual(QueueStackView.browseTimeout, 5)
    }

    // MARK: - Re-deal

    func testRecordsInTheTrayRiffleOutOfStep() {
        XCTAssertNotEqual(Riffle.lift(phase: 0.4, slot: 0), Riffle.lift(phase: 0.4, slot: 1))
        for slot in 0..<12 {
            for step in 0..<40 {
                // Never far enough to leave the channel.
                XCTAssertLessThanOrEqual(abs(Riffle.lift(phase: Double(step) * 0.07, slot: slot)), 5)
            }
        }
        XCTAssertGreaterThan(Riffle.spin(phase: 1, slot: 0), Riffle.spin(phase: 0.5, slot: 0))
    }

    // MARK: - Shelves

    func testThereIsNoLikedShelf() {
        let shelves = TurntableHomeModel.shelves(
            albums: ["Artist": [makeAlbum(id: "s")]],
            artistOrder: ["Artist"],
            recent: [makeRecent(id: "r1")]
        )
        XCTAssertEqual(shelves.map(\.id), ["artist-Artist", "recent"])
    }

    // MARK: - Held sleeve

    func testTheHeldSleevesCardSitsAboveIt() {
        let sleeve = CGRect(x: 170, y: 300, width: 60, height: 60)
        let centre = SleevePeekCard.centre(over: sleeve, in: 402)
        XCTAssertEqual(centre.x, sleeve.midX, accuracy: 0.01)
        // Clear of the sleeve, and so of the finger holding it.
        XCTAssertLessThan(centre.y + SleevePeekCard.size.height / 2, sleeve.minY)
    }

    func testTheCardStaysOnScreenForSleevesAtEitherEnd() {
        for width in [320.0, 375.0, 402.0, 430.0] as [CGFloat] {
            for x in [12.0, width - 72] as [CGFloat] {
                let sleeve = CGRect(x: x, y: 200, width: 60, height: 60)
                let centre = SleevePeekCard.centre(over: sleeve, in: width)
                XCTAssertGreaterThanOrEqual(centre.x - SleevePeekCard.size.width / 2, SleevePeekCard.edge - 0.01)
                XCTAssertLessThanOrEqual(centre.x + SleevePeekCard.size.width / 2, width - SleevePeekCard.edge + 0.01)
                // It still grows out of the sleeve it belongs to.
                let anchor = SleevePeekCard.anchor(over: sleeve, in: width)
                XCTAssertTrue((0...1).contains(anchor.x))
                XCTAssertEqual(anchor.y, 1)
            }
        }
    }

    func testThereIsTimeToReadTheCardBeforeItQueues() {
        // Looking must not queue by accident: a second to read, then a
        // visible countdown of at least another.
        XCTAssertGreaterThanOrEqual(SleevePeek.lookTime, 1.0)
        XCTAssertGreaterThanOrEqual(SleevePeek.armTime, 1.0)
        XCTAssertLessThanOrEqual(SleevePeek.lookTime + SleevePeek.armTime, 2.5)
    }

    func testTheCardSaysWhatHoldingWillDo() {
        XCTAssertEqual(SleevePeekCard.footText(for: .looking), SleevePeekCard.footText(for: .arming))
        XCTAssertNotEqual(SleevePeekCard.footText(for: .arming), SleevePeekCard.footText(for: .queued))
    }

    func testRunningTimeReadsTheWayASleeveNotesIt() {
        XCTAssertEqual(SleevePeekCard.runtime(222), "3:42")
        XCTAssertEqual(SleevePeekCard.runtime(59), "0:59")
        XCTAssertEqual(SleevePeekCard.runtime(3725), "1:02:05")
        XCTAssertNil(SleevePeekCard.runtime(0))
    }

    func testShelvesStandFurtherApartThanASleeveLifts() {
        // A lifted sleeve rises 7pt and grows 7%; it must not reach
        // the ledge above.
        XCTAssertGreaterThanOrEqual(CrateGrid.rowSpacing, 28)
    }

    func testTheRecentShelfIsCapped() {
        let recents = (0..<40).map { makeRecent(id: "r\($0)") }
        let shelves = TurntableHomeModel.shelves(albums: [:], artistOrder: [], recent: recents)
        XCTAssertEqual(shelves.first?.tracks.count, CrateGrid.columnCount * 2)
    }

    func testNothingToShowMeansNoShelves() {
        XCTAssertTrue(TurntableHomeModel.shelves(albums: [:], artistOrder: [], recent: []).isEmpty)
    }

    func testShelfIdentityIsStable() {
        // SwiftUI diffs the shelves by id; an id that changed between
        // renders would rebuild every sleeve and drop its artwork.
        let albums = ["Artist": [makeAlbum(id: "a")]]
        let first = TurntableHomeModel.shelves(albums: albums, artistOrder: ["Artist"], recent: [])
        let second = TurntableHomeModel.shelves(albums: albums, artistOrder: ["Artist"], recent: [])
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    // MARK: - Shelf geometry

    func testAShelfIsFiveSleevesAcrossAndTheDeckShowsThree() {
        XCTAssertEqual(CrateGrid.columnCount, 5)
        XCTAssertEqual(CrateGrid.visibleRows, 3)
    }

    func testFiveSleevesFitTheLedgeOnEveryPhone() {
        // 375 is the narrowest phone the app runs on; 440 the widest.
        // At full size five sleeves need 368pt, so on a 375pt screen
        // the fifth used to hang off the end of the ledge.
        for width in stride(from: CGFloat(375), through: 440, by: 1) {
            let size = CrateGrid.sleeveSize(forWidth: width)
            XCTAssertLessThanOrEqual(CrateGrid.fullWidth(sleeveSize: size), width,
                                     "Five sleeves overflow a \(Int(width))pt screen")
        }
    }

    func testSleevesAreFullSizeWhereThereIsRoom() {
        XCTAssertEqual(CrateGrid.sleeveSize(forWidth: 402), CrateGrid.sleeveSize)
        XCTAssertEqual(CrateGrid.sleeveSize(forWidth: 430), CrateGrid.sleeveSize)
        XCTAssertLessThan(CrateGrid.sleeveSize(forWidth: 375), CrateGrid.sleeveSize)
    }

    func testASleeveIsAlwaysAComfortableTouchTarget() {
        for width in [320, 375, 393, 402, 430, 440] as [CGFloat] {
            XCTAssertGreaterThanOrEqual(CrateGrid.sleeveSize(forWidth: width), 44)
        }
    }

    func testEverySleeveLeansTheSameWayEveryTime() {
        XCTAssertEqual(CrateGrid.lean(for: "abc123"), CrateGrid.lean(for: "abc123"))
    }

    func testNoSleeveLeansFarEnoughToLookFallen() {
        for id in ["a", "dQw4w9WgXcQ", "zzzzzzzzzzz", "", "shelf-0-1", "🎵"] {
            XCTAssertLessThanOrEqual(abs(CrateGrid.lean(for: id)), 1.2001, "\(id) leans too far")
        }
    }

    // MARK: - Queue tray

    func testTheTrayStartsOneRecordBeforeTheCurrentOne() {
        // One played record stays in view: it is how you step back.
        XCTAssertEqual(QueueShelf.window(count: 40, currentIndex: 20, capacity: 12), 19..<31)
    }

    func testTheTrayStartsAtTheFrontOfAFreshQueue() {
        XCTAssertEqual(QueueShelf.window(count: 40, currentIndex: 0, capacity: 12), 0..<12)
    }

    func testTheTrayShowsAShortQueueWhole() {
        XCTAssertEqual(QueueShelf.window(count: 5, currentIndex: 3, capacity: 12), 0..<5)
    }

    func testTheTrayStaysFullAtTheEndOfTheQueue() {
        // On the last record the window slides back rather than
        // showing two records and ten empty slots.
        XCTAssertEqual(QueueShelf.window(count: 40, currentIndex: 39, capacity: 12), 28..<40)
    }

    func testTheCurrentRecordIsAlwaysInTheTray() {
        // The old tray showed the first twelve items of the queue, so
        // from the thirteenth track on the playing record was not in
        // it at all.
        for count in 1...45 {
            for current in 0..<count {
                let window = QueueShelf.window(count: count, currentIndex: current)
                XCTAssertTrue(window.contains(current),
                              "Record \(current) of \(count) is playing but not in the tray")
                XCTAssertLessThanOrEqual(window.count, QueueShelf.capacity)
            }
        }
    }

    func testTheTraySurvivesAnIndexOutsideTheQueue() {
        // Nothing playing yet (-1), or an index left over from a queue
        // that has since been trimmed.
        XCTAssertEqual(QueueShelf.window(count: 5, currentIndex: -1, capacity: 12), 0..<5)
        XCTAssertEqual(QueueShelf.window(count: 5, currentIndex: 99, capacity: 3), 2..<5)
        XCTAssertTrue(QueueShelf.window(count: 0, currentIndex: 0).isEmpty)
    }

    // MARK: - Helpers

    private func makeTrack(id: String) -> Track {
        Track(videoId: id,
             title: "Title \(id)",
             artists: ["Artist"],
             album: "Album",
             durationSeconds: 180,
             thumbnails: [],
             isExplicit: false,
             videoType: "MUSIC_VIDEO_TYPE_ATV")
    }

    private func makeAlbum(id: String) -> Album {
        Album(browseId: id,
              title: "Album \(id)",
              artists: ["Artist"],
              year: "1997",
              type: "Album",
              trackCount: 12,
              thumbnails: [],
              thumbnailSmall: nil,
              thumbnailLarge: nil)
    }

    // MARK: - The backend's contract

    func testAnAlbumFromTheBackendDecodes() {
        // The exact shape the backend answers with — a contract test, so
        // a change on either side shows up here rather than as an empty
        // shelf on the device.
        let json = """
        {
          "browseId": "MPREb_yXhSI4FCUo6",
          "title": "OK Computer",
          "artists": ["Radiohead"],
          "year": "1997",
          "type": "Album",
          "trackCount": 12,
          "thumbnails": [{"url": "https://example.com/w544.jpg", "width": 544, "height": 544}],
          "thumbnailSmall": {"url": "https://example.com/w120.jpg", "width": 120, "height": 120},
          "thumbnailLarge": {"url": "https://example.com/w544.jpg", "width": 544, "height": 544}
        }
        """.data(using: .utf8)!

        let album = try? JSONDecoder().decode(Album.self, from: json)
        XCTAssertEqual(album?.browseId, "MPREb_yXhSI4FCUo6")
        XCTAssertEqual(album?.title, "OK Computer")
        XCTAssertEqual(album?.artists, ["Radiohead"])
        XCTAssertEqual(album?.year, "1997")
        XCTAssertEqual(album?.type, "Album")
        XCTAssertEqual(album?.trackCount, 12)
        XCTAssertEqual(album?.artworkURL?.absoluteString, "https://example.com/w120.jpg")
        XCTAssertEqual(album?.fullArtworkURL?.absoluteString, "https://example.com/w544.jpg")
    }

    func testAnAlbumWithoutTheOptionalFieldsStillDecodes() {
        // A backend that has not learned about the year yet must not
        // empty the shelf.
        let json = """
        {"browseId": "MPREb_x", "title": "Untitled", "artists": [], "thumbnails": []}
        """.data(using: .utf8)!

        let album = try? JSONDecoder().decode(Album.self, from: json)
        XCTAssertEqual(album?.browseId, "MPREb_x")
        XCTAssertEqual(album?.year, "")
        XCTAssertEqual(album?.type, "Album")
        XCTAssertEqual(album?.trackCount, 0)
        XCTAssertNil(album?.artworkURL)
    }

    private func makeRecent(id: String) -> RecentTrack {
        RecentTrack(videoId: id, title: "Recent \(id)", artists: ["Artist"],
                    album: "Album", durationSeconds: 100, thumbnails: [],
                    isExplicit: false, videoType: "MUSIC_VIDEO_TYPE_ATV",
                    playedAt: Date(), playbackProgress: 0)
    }
}
