//
//  SleeveCrateView.swift
//  Views/Turntable
//
//  The shelves under the deck. Records stand face-out on walnut
//  ledges, the way a record shop shows the ones it wants you to see.
//
//  One shelf per favourite artist, in the user's own order, and one
//  for what was played recently. Each ledge carries a card in a brass
//  holder that says whose records they are — so a cover is never just
//  a cover, it is "another one by her".
//
//  A ledge is drawn as a solid thing: a top you can see a little of,
//  a front edge that catches the key light, and a shadow underneath.
//  The sleeves stand ON it and cast onto it. Every sleeve leans a
//  degree or so its own way, has its record showing at the opening,
//  and lifts out toward you when you touch it.
//
//  Hold a sleeve and it comes right up to you: the cover at a size
//  you can read, with what it is and how long it runs. Let go and it
//  drops back onto the shelf. Keep holding and a ring on the card
//  closes; when it does, the record goes in the queue. A tap still
//  plays it.
//
//  The shelves scroll as a unit under the deck; a shelf with more
//  records than fit across scrolls sideways on its own.
//

import SwiftUI

// MARK: - Model

/// One ledge and the records standing on it.
///
/// A ledge holds either records or albums: the shelves under the
/// turntable stand one album per favourite artist and the songs that
/// were played recently.
struct CrateShelfModel: Identifiable, Equatable {
    /// Stable across renders: the shelf's title.
    let id: String
    /// What the card on the ledge says.
    let title: String
    /// The records standing on it.
    var tracks: [Track] = []
    /// The albums standing on it. When this is not empty the ledge
    /// stands albums and `tracks` is empty.
    var albums: [Album] = []

    /// True when this ledge stands albums rather than records.
    var standsAlbums: Bool { !albums.isEmpty }
}

/// The sleeve being held up for a closer look, and where on the
/// shelves it stands.
struct SleevePeek: Equatable {
    /// How far a hold has got.
    enum Stage: Equatable {
        /// Picked up, being looked at.
        case looking
        /// Still held: counting down to adding it to the queue.
        case arming
        /// Held to the end. It is in the queue.
        case queued
    }

    let track: Track
    /// The sleeve's frame in the shelves' own coordinate space.
    let frame: CGRect
    var stage: Stage = .looking

    /// The name of that coordinate space.
    static let space = "crate.shelves"

    /// How long a sleeve is looked at before the countdown starts.
    /// Long enough to read the card and let go without queueing.
    static let lookTime: Double = 1.0
    /// How long the countdown runs.
    static let armTime: Double = 1.1
}

// MARK: - Geometry

/// The shelves' dimensions.
///
/// Split out as pure geometry so the layout can be asserted in a
/// test without rendering anything.
enum CrateGrid {
    /// One sleeve's edge length, on a screen wide enough for it.
    static let sleeveSize: CGFloat = 60
    /// How far the ledge stands in from each edge of the screen.
    static let margin: CGFloat = 12
    /// Gap between sleeves along a shelf.
    static let spacing: CGFloat = 10
    /// How many sleeves fit across the deck.
    static let columnCount: Int = 5
    /// How many shelves the deck shows at once.
    static let visibleRows: Int = 3
    /// How much of the ledge's top is visible behind its front edge.
    static let ledgeDepth: CGFloat = 6
    /// The height of the ledge's front edge. Tall enough for the card.
    static let ledgeFace: CGFloat = 15
    /// How far the sleeves stand in from the ledge's lip.
    static let standIn: CGFloat = 2
    /// Gap between one ledge and the tops of the sleeves below it.
    static let rowSpacing: CGFloat = 30
    /// Inset of the first sleeve from the ledge's end.
    static let inset: CGFloat = 14
    /// The height of the label above an album's cover: its name and
    /// its year, the way a record shop labels each sleeve.
    static let albumCaptionHeight: CGFloat = 20

    /// The height of one shelf: the sleeves and the ledge under them.
    ///
    /// A shelf of albums is taller by the label above each cover.
    static func rowHeight(sleeveSize: CGFloat = sleeveSize, captionHeight: CGFloat = 0) -> CGFloat {
        sleeveSize + captionHeight + ledgeDepth - standIn + ledgeFace
    }

    /// The sleeve size that puts exactly `columnCount` sleeves on a
    /// ledge, for a screen of the given width.
    ///
    /// 60pt where there is room. On a narrow phone the sleeves shrink
    /// rather than the fifth one hanging off the end of the shelf.
    static func sleeveSize(forWidth width: CGFloat) -> CGFloat {
        let ledge = width - margin * 2
        let room = ledge - inset * 2 - CGFloat(columnCount - 1) * spacing
        return max(44, min(sleeveSize, (room / CGFloat(columnCount)).rounded(.down)))
    }

    /// The width a full shelf of sleeves needs, edge of screen to edge
    /// of screen.
    static func fullWidth(sleeveSize: CGFloat = sleeveSize) -> CGFloat {
        CGFloat(columnCount) * sleeveSize + CGFloat(columnCount - 1) * spacing + inset * 2 + margin * 2
    }

    /// How far a sleeve leans, in degrees. Derived from the track, so
    /// a record leans the same way every time the shelf is drawn.
    static func lean(for videoId: String) -> Double {
        let sum = videoId.unicodeScalars.reduce(0) { ($0 &+ Int($1.value) &* 31) % 9973 }
        return (Double(sum % 25) / 24.0 - 0.5) * 2.4
    }
}

// MARK: - Shelves

struct SleeveCrateView: View {
    let shelves: [CrateShelfModel]
    /// The track on the platter. Its sleeve stands empty.
    var nowPlayingID: String?
    /// Room left under the last shelf, for the tab bar floating over
    /// the bottom of the deck.
    var bottomInset: CGFloat = 0
    var onPlay: (Track) -> Void
    var onQueue: (Track) -> Void
    /// An album on a ledge was touched: play it, or put it in the
    /// queue.
    var onPlayAlbum: (Album) -> Void = { _ in }
    var onQueueAlbum: (Album) -> Void = { _ in }

    /// The sleeve a finger is holding, if one is.
    @State private var peek: SleevePeek?

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                CrateShelves(
                    shelves: shelves,
                    nowPlayingID: nowPlayingID,
                    sleeveSize: CrateGrid.sleeveSize(forWidth: geo.size.width),
                    scrollsSideways: true,
                    onPlay: onPlay,
                    onQueue: onQueue,
                    onPlayAlbum: onPlayAlbum,
                    onQueueAlbum: onQueueAlbum,
                    onPeek: { peek = $0 }
                )
                .padding(.top, 10)
                .padding(.bottom, bottomInset)
            }
        }
        // Shelves slide out from under the tray above and fade into
        // the floor below, instead of being cut by a hard edge.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.045),
                    .init(color: .black, location: 0.80),
                    .init(color: .black.opacity(0.25), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .coordinateSpace(name: SleevePeek.space)
        // The held sleeve is drawn over the shelves — and over the
        // tray and the deck above them, which is where there is room
        // for it. It is outside the mask and both scroll views, so
        // nothing clips it.
        .overlay {
            GeometryReader { geo in
                if let peek {
                    SleevePeekCard(track: peek.track, stage: peek.stage)
                        .position(SleevePeekCard.centre(over: peek.frame, in: geo.size.width))
                        .transition(
                            .scale(scale: 0.3, anchor: SleevePeekCard.anchor(over: peek.frame, in: geo.size.width))
                                .combined(with: .opacity)
                        )
                        .id(peek.track.videoId)
                }
            }
            .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: peek)
        // A sleeve that scrolls away, or a shelf that is taken down,
        // must not leave its card hanging.
        .onChange(of: shelves) { _, _ in peek = nil }
        .onDisappear { peek = nil }
    }
}

/// The ledges themselves, without the vertical scroll view.
///
/// Split out so the shelves can be rendered on their own — the
/// offscreen renderer does not draw a scroll view's contents.
struct CrateShelves: View {
    let shelves: [CrateShelfModel]
    var nowPlayingID: String?
    var sleeveSize: CGFloat = CrateGrid.sleeveSize
    /// Off for offscreen renders, for the same reason.
    var scrollsSideways: Bool = false
    var onPlay: (Track) -> Void
    var onQueue: (Track) -> Void
    var onPlayAlbum: (Album) -> Void = { _ in }
    var onQueueAlbum: (Album) -> Void = { _ in }
    /// A sleeve was picked up (or, with nil, put back).
    var onPeek: (SleevePeek?) -> Void = { _ in }

    var body: some View {
        VStack(spacing: CrateGrid.rowSpacing) {
            if shelves.isEmpty {
                // Nothing to show yet: bare shelves, so the room is
                // still furnished while the suggestions load.
                ForEach(0..<2, id: \.self) { index in
                    CrateShelf(
                        shelf: CrateShelfModel(id: "empty-\(index)", title: "", tracks: []),
                        sleeveSize: sleeveSize,
                        grain: index,
                        onPlay: onPlay,
                        onQueue: onQueue
                    )
                }
            } else {
                ForEach(Array(shelves.enumerated()), id: \.element.id) { index, shelf in
                    CrateShelf(
                        shelf: shelf,
                        nowPlayingID: nowPlayingID,
                        sleeveSize: sleeveSize,
                        grain: index,
                        scrollsSideways: scrollsSideways,
                        onPlay: onPlay,
                        onQueue: onQueue,
                        onPlayAlbum: onPlayAlbum,
                        onQueueAlbum: onQueueAlbum,
                        onPeek: onPeek
                    )
                    .transition(.opacity.combined(with: .offset(y: 10)))
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: shelves.map(\.id))
    }
}

// MARK: - One shelf

/// A ledge and the sleeves standing on it.
struct CrateShelf: View {
    let shelf: CrateShelfModel
    var nowPlayingID: String?
    var sleeveSize: CGFloat = CrateGrid.sleeveSize
    /// Which stretch of the walnut this ledge is cut from, so no two
    /// ledges show the same grain.
    var grain: Int = 0
    var scrollsSideways: Bool = false
    var onPlay: (Track) -> Void
    var onQueue: (Track) -> Void
    var onPlayAlbum: (Album) -> Void = { _ in }
    var onQueueAlbum: (Album) -> Void = { _ in }
    var onPeek: (SleevePeek?) -> Void = { _ in }

    /// How tall this ledge is: an album shelf carries a label above
    /// every cover, a record shelf does not.
    private var rowHeight: CGFloat {
        CrateGrid.rowHeight(
            sleeveSize: sleeveSize,
            captionHeight: shelf.standsAlbums ? CrateGrid.albumCaptionHeight : 0
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ShelfLedge(title: shelf.title, grain: grain)

            sleeves
                .padding(.bottom, CrateGrid.ledgeFace + CrateGrid.ledgeDepth - CrateGrid.standIn)
        }
        .frame(height: rowHeight)
        .padding(.horizontal, CrateGrid.margin)
    }

    @ViewBuilder
    private var sleeves: some View {
        if shelf.standsAlbums {
            albumRow
                .padding(.horizontal, CrateGrid.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if scrollsSideways && shelf.tracks.count > CrateGrid.columnCount {
            ScrollView(.horizontal, showsIndicators: false) {
                sleeveRow
                    .padding(.horizontal, CrateGrid.inset)
                    // Room for a sleeve to lift and lean without being
                    // clipped by the scroll view.
                    .padding(.top, 12)
            }
            .padding(.top, -12)
        } else {
            sleeveRow
                .padding(.horizontal, CrateGrid.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sleeveRow: some View {
        HStack(alignment: .bottom, spacing: CrateGrid.spacing) {
            ForEach(shelf.tracks) { track in
                SleeveCell(
                    track: track,
                    size: sleeveSize,
                    isOnDeck: track.videoId == nowPlayingID,
                    onPlay: onPlay,
                    onQueue: onQueue,
                    onPeek: onPeek
                )
            }
        }
    }

    /// The albums standing on this ledge.
    private var albumRow: some View {
        HStack(alignment: .bottom, spacing: CrateGrid.spacing) {
            ForEach(shelf.albums) { album in
                AlbumCell(
                    album: album,
                    size: sleeveSize,
                    onPlay: onPlayAlbum,
                    onQueue: onQueueAlbum
                )
            }
        }
    }
}

// MARK: - One sleeve on a shelf

/// A sleeve and what touching it does: a tap plays it, a hold picks
/// it up for a closer look until the finger lifts.
private struct SleeveCell: View {
    let track: Track
    let size: CGFloat
    let isOnDeck: Bool
    var onPlay: (Track) -> Void
    var onQueue: (Track) -> Void
    var onPeek: (SleevePeek?) -> Void

    /// How long a finger rests on a sleeve before it is picked up.
    /// (The scroll view holds a touch back for a moment before the
    /// button sees it, so the wait a finger feels is a little longer.)
    static let holdDelay: Double = 0.22

    /// How far the hold has got; nil when the sleeve is on its shelf.
    @State private var stage: SleevePeek.Stage?

    /// Walks the hold through its stages while the sleeve is pressed.
    @State private var holdTimer: Task<Void, Never>?

    /// The touch that is ending was a hold, so the button's own
    /// touch-up must not also play the record.
    @State private var swallowTap = false

    private static func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return !Task.isCancelled
    }

    /// The hold is read off the button's own pressed state rather than
    /// a gesture of its own. A long-press gesture attached to a sleeve
    /// competes with the scroll views the sleeve sits in — a swipe
    /// that starts on a cover stops scrolling the shelves and plays
    /// the record instead. A button already knows how to give a touch
    /// up to a scroll, and says so by un-pressing.
    ///
    /// Hold: the sleeve comes up for a look. Keep holding: a ring on
    /// the card fills, and when it closes the record goes in the
    /// queue. Letting go at any point puts the sleeve back.
    private func pressChanged(_ pressed: Bool) {
        holdTimer?.cancel()
        holdTimer = nil
        if pressed {
            holdTimer = Task { @MainActor in
                guard await Self.pause(Self.holdDelay) else { return }
                stage = .looking
                guard await Self.pause(SleevePeek.lookTime) else { return }
                stage = .arming
                guard await Self.pause(SleevePeek.armTime) else { return }
                stage = .queued
                HapticManager.success()
                onQueue(track)
            }
        } else if stage != nil {
            stage = nil
        }
    }

    var body: some View {
        Button {
            if swallowTap || stage != nil {
                swallowTap = false
                return
            }
            onPlay(track)
        } label: {
            SleeveView(track: track, size: size, isOnDeck: isOnDeck)
        }
        .buttonStyle(
            SleeveButtonStyle(
                lean: CrateGrid.lean(for: track.videoId),
                isHeld: stage != nil,
                onPressChanged: pressChanged
            )
        )
        .onDisappear {
            holdTimer?.cancel()
            if stage != nil { stage = nil }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: stage) { was, now in
                        if let now {
                            if was == nil {
                                swallowTap = true
                                HapticManager.selectionChanged()
                            }
                            onPeek(
                                SleevePeek(
                                    track: track,
                                    frame: proxy.frame(in: .named(SleevePeek.space)),
                                    stage: now
                                )
                            )
                        } else {
                            onPeek(nil)
                            // If the finger lifted off the sleeve the
                            // button never fires, and the flag must not
                            // eat the next tap.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                swallowTap = false
                            }
                        }
                    }
            }
        )
        .accessibilityLabel("\(track.title) by \(track.artists.first ?? "unknown artist")")
        .accessibilityValue(isOnDeck ? "On the deck" : "")
        .accessibilityHint("Double tap to play. Hold to look closer; keep holding to add to the queue")
        .accessibilityAction(named: "Add to queue") { onQueue(track) }
        // Identifier so the UI test can find and tap a specific
        // sleeve on the device.
        .accessibilityIdentifier("crate.sleeve.\(track.videoId)")
    }
}

// MARK: - One album on a shelf

/// An album standing on a ledge, and what touching it does: a tap
/// plays it, a hold puts it in the queue.
private struct AlbumCell: View {
    let album: Album
    let size: CGFloat
    var onPlay: (Album) -> Void
    var onQueue: (Album) -> Void

    /// How long a finger rests on an album before the hold begins.
    static let holdDelay: Double = 0.22
    /// How long the hold runs before the album goes in the queue.
    static let holdTime: Double = 0.9

    /// The album is being held.
    @State private var isHeld = false
    @State private var holdTimer: Task<Void, Never>?
    /// The hold ended in a queue, so the button's own touch-up must
    /// not also play the album.
    @State private var swallowTap = false

    private static func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return !Task.isCancelled
    }

    var body: some View {
        Button {
            if swallowTap {
                swallowTap = false
                return
            }
            onPlay(album)
        } label: {
            AlbumCard(album: album, size: size)
        }
        .buttonStyle(
            SleeveButtonStyle(
                lean: 0,
                isHeld: isHeld,
                onPressChanged: pressChanged
            )
        )
        .onDisappear {
            holdTimer?.cancel()
            isHeld = false
        }
        .accessibilityLabel("Album \(album.title) by \(album.artists.first ?? "unknown artist")")
        .accessibilityValue(album.year)
        .accessibilityHint("Double tap to play the album. Hold to add it to the queue")
        .accessibilityAction(named: "Add to queue") { onQueue(album) }
        .accessibilityIdentifier("crate.album.\(album.browseId)")
    }

    /// The hold is read off the button's own pressed state rather than
    /// a gesture of its own — the same reasoning as a sleeve: a
    /// long-press gesture on a card competes with the scroll views
    /// the card sits in.
    private func pressChanged(_ pressed: Bool) {
        holdTimer?.cancel()
        holdTimer = nil
        if pressed {
            holdTimer = Task { @MainActor in
                guard await Self.pause(Self.holdDelay) else { return }
                isHeld = true
                HapticManager.selectionChanged()
                guard await Self.pause(Self.holdTime) else { return }
                swallowTap = true
                onQueue(album)
                HapticManager.success()
            }
        } else {
            isHeld = false
        }
    }
}

/// The album itself: a label above the cover, the way a record shop
/// labels each sleeve it wants you to look at.
struct AlbumCard: View {
    let album: Album
    var size: CGFloat = CrateGrid.sleeveSize

    private static let corner: CGFloat = 2.5

    var body: some View {
        VStack(spacing: 2) {
            caption
            cover
        }
        .frame(width: size)
    }

    /// The album's name and its year.
    private var caption: some View {
        VStack(spacing: 0) {
            Text(album.title)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
            if !album.year.isEmpty {
                Text(album.year)
                    .font(.system(size: 7.5, weight: .light))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(height: CrateGrid.albumCaptionHeight)
        .frame(maxWidth: .infinity)
    }

    private var cover: some View {
        CachedAsyncImage(url: album.artworkURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                LinearGradient(
                    colors: [TurntableTokens.aluminium.opacity(0.25), TurntableTokens.walnut.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "square.stack")
                    .font(.system(size: 15, weight: .light))
                    .foregroundColor(TurntableTokens.aluminium.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner))
        // The shrink-wrap: a band of the room's light across the cover.
        .overlay(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.22), location: 0),
                    .init(color: .white.opacity(0.04), location: 0.34),
                    .init(color: .clear, location: 0.36),
                    .init(color: .black.opacity(0.22), location: 1)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: Self.corner))
        )
        // The card's cut edge: lit on top and on the left.
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner)
                .strokeBorder(
                    LinearGradient(
                        colors: [TurntableTokens.cream.opacity(0.55), .clear, .black.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 4, x: 2, y: 2)
    }
}

// MARK: - Ledge

/// The shelf itself.
struct ShelfLedge: View {
    let title: String
    var grain: Int = 0

    /// Which strip of the walnut photograph the front edge is cut
    /// from.
    private var grainStrip: CGRect {
        CGRect(x: 0, y: [0.10, 0.44, 0.76, 0.28, 0.62][grain % 5], width: 1, height: 0.06)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The top of the ledge, seen from a little above: a strip
            // of lit wood running back to the wall.
            LinearGradient(
                colors: [
                    Color.black.opacity(0.55),
                    TurntableTokens.walnut,
                    Color(red: 0.42, green: 0.30, blue: 0.21)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: CrateGrid.ledgeDepth)
            .padding(.horizontal, 3)

            // The front edge.
            //
            // Painted from a strip of the photograph rather than laid
            // over as an image: a fill-scaled image is as tall as it is
            // wide, and although it is clipped to the ledge it still
            // takes touches over its whole square — which put every
            // ledge on top of the sleeves of the shelf above it.
            Rectangle()
                .fill(ImagePaint(image: Image(TurntableTexture.walnut), sourceRect: grainStrip, scale: 0.5))
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.05), .black.opacity(0.48)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: CrateGrid.ledgeFace)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 1.5, bottomLeadingRadius: 3,
                        bottomTrailingRadius: 3, topTrailingRadius: 1.5
                    )
                )
                // The lip, where the key light lands.
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(TurntableTokens.keyLight.opacity(0.42))
                        .frame(height: 1)
                        .padding(.horizontal, 1.5)
                }
                .overlay(alignment: .leading) {
                    if !title.isEmpty {
                        DeckLabelCard(text: title)
                            .padding(.leading, CrateGrid.inset)
                    }
                }
                // What the ledge throws onto the wall below it.
                .shadow(color: .black.opacity(0.7), radius: 7, y: 7)
        }
        // The ledge is furniture. A touch on it belongs to nobody.
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.isEmpty ? "Empty shelf" : title)
        .accessibilityAddTraits(title.isEmpty ? [] : .isHeader)
    }
}

// MARK: - Sleeve

struct SleeveView: View {
    let track: Track
    var size: CGFloat = CrateGrid.sleeveSize
    /// This sleeve's record is the one on the platter.
    var isOnDeck: Bool = false

    private static let corner: CGFloat = 2.5

    var body: some View {
        ZStack {
            // The record, showing at the sleeve's opening. Not there
            // when it is on the deck — the sleeve is standing empty.
            if !isOnDeck {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(white: 0.20), TurntableTokens.vinyl],
                            center: .center,
                            startRadius: size / 3,
                            endRadius: size / 2
                        )
                    )
                    .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.7))
                    .frame(width: size - 5, height: size - 5)
                    .offset(x: 6.5)
            }

            cover
        }
        .frame(width: size, height: size)
        // Where the sleeve's foot meets the ledge.
        .background(alignment: .bottom) {
            Ellipse()
                .fill(.black.opacity(0.7))
                .frame(width: size * 0.98, height: 7)
                .blur(radius: 3)
                .offset(x: 2, y: 3)
        }
    }

    private var cover: some View {
        CachedAsyncImage(url: track.artworkURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                LinearGradient(
                    colors: [TurntableTokens.aluminium.opacity(0.25), TurntableTokens.walnut.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.system(size: 15, weight: .light))
                    .foregroundColor(TurntableTokens.aluminium.opacity(0.6))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Self.corner))
        // The shrink-wrap: a band of the room's light across the cover.
        .overlay(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.22), location: 0),
                    .init(color: .white.opacity(0.04), location: 0.34),
                    .init(color: .clear, location: 0.36),
                    .init(color: .black.opacity(0.22), location: 1)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: Self.corner))
        )
        // The card's cut edge: lit on top and on the left.
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner)
                .strokeBorder(
                    LinearGradient(
                        colors: [TurntableTokens.cream.opacity(0.55), .clear, .black.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .overlay(alignment: .bottomTrailing) {
            if isOnDeck {
                onDeckBadge
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 4, x: 2, y: 2)
    }

    /// Marks the sleeve whose record is playing.
    private var onDeckBadge: some View {
        Image(systemName: "waveform")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.black)
            .frame(width: 16, height: 16)
            .background(Circle().fill(Theme.cyberCyan))
            .shadow(color: Theme.cyberCyan.opacity(0.7), radius: 4)
            .padding(3)
    }
}

/// Touching a sleeve draws it up and toward you, the way you tip a
/// record out of a row to look at it. Holding it keeps it there.
private struct SleeveButtonStyle: ButtonStyle {
    let lean: Double
    var isHeld: Bool = false
    /// The finger went down on the sleeve, or came off it.
    var onPressChanged: (Bool) -> Void = { _ in }

    func makeBody(configuration: Configuration) -> some View {
        let lifted = configuration.isPressed || isHeld
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in onPressChanged(pressed) }
            .rotationEffect(.degrees(lifted ? 0 : lean), anchor: .bottom)
            .scaleEffect(lifted ? 1.07 : 1, anchor: .bottom)
            .offset(y: lifted ? -7 : 0)
            .animation(.spring(response: 0.26, dampingFraction: 0.62), value: lifted)
    }
}

// MARK: - Peek

/// The sleeve held up for a closer look: the cover at a size you can
/// read, the title, who it is by, the album and how long it runs.
///
/// Drawn above the sleeve it came from, because the finger holding
/// that sleeve is in the way of anything drawn on it.
struct SleevePeekCard: View {
    let track: Track
    var stage: SleevePeek.Stage = .looking

    static let coverSize: CGFloat = 140
    static let padding: CGFloat = 11
    static let textHeight: CGFloat = 62
    /// The strip at the foot that says how to queue the record.
    static let footHeight: CGFloat = 26
    static let size = CGSize(
        width: coverSize + padding * 2,
        height: coverSize + padding * 2 + textHeight + footHeight
    )
    /// Clear air between the card's foot and the sleeve's top.
    static let gap: CGFloat = 14
    /// How close the card may come to the screen's edge.
    static let edge: CGFloat = 10

    /// Where the card's centre goes: over the sleeve, kept on screen.
    static func centre(over sleeve: CGRect, in width: CGFloat) -> CGPoint {
        let half = size.width / 2
        let x = min(max(sleeve.midX, edge + half), max(edge + half, width - edge - half))
        return CGPoint(x: x, y: sleeve.minY - gap - size.height / 2)
    }

    /// The point on the card nearest the sleeve, as a unit point: the
    /// card grows out of there and shrinks back into it.
    static func anchor(over sleeve: CGRect, in width: CGFloat) -> UnitPoint {
        let centre = centre(over: sleeve, in: width)
        let x = (sleeve.midX - (centre.x - size.width / 2)) / size.width
        return UnitPoint(x: min(1, max(0, x)), y: 1)
    }

    /// "3:42". Nothing when the length is not known.
    static func runtime(_ seconds: Int) -> String? {
        DeckFormat.runtime(seconds)
    }

    /// The small print: album and running time, whichever are known.
    static func smallPrint(for track: Track) -> String {
        var parts: [String] = []
        let album = track.album.trimmingCharacters(in: .whitespaces)
        if !album.isEmpty, album.caseInsensitiveCompare(track.title) != .orderedSame {
            parts.append(album)
        }
        if let runtime = runtime(track.durationSeconds) {
            parts.append(runtime)
        }
        return parts.joined(separator: "  ·  ")
    }

    /// What the foot of the card says at each stage of the hold.
    static func footText(for stage: SleevePeek.Stage) -> String {
        switch stage {
        case .looking, .arming: return "Keep holding to queue"
        case .queued: return "Added to queue"
        }
    }

    /// The countdown: a ring that closes while the sleeve is held, and
    /// a tick once the record is in the queue.
    private var foot: some View {
        let done = stage == .queued
        return HStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(TurntableTokens.cream.opacity(0.18), lineWidth: 1.6)
                Circle()
                    .trim(from: 0, to: stage == .looking ? 0 : 1)
                    .stroke(Theme.cyberCyan, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(
                        stage == .arming ? .linear(duration: SleevePeek.armTime) : .easeOut(duration: 0.15),
                        value: stage
                    )
                Image(systemName: done ? "checkmark" : "plus")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundColor(done ? Theme.cyberCyan : TurntableTokens.cream.opacity(0.55))
            }
            .frame(width: 15, height: 15)

            Text(Self.footText(for: stage))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(done ? Theme.cyberCyan : TurntableTokens.cream.opacity(0.5))
                .lineLimit(1)
        }
        .frame(width: Self.coverSize, height: Self.footHeight, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TurntableTokens.cream.opacity(0.10))
                .frame(height: 0.6)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            CachedAsyncImage(url: track.artworkURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    TurntableTokens.walnut
                    Image(systemName: "music.note")
                        .font(.system(size: 34, weight: .light))
                        .foregroundColor(TurntableTokens.aluminium.opacity(0.6))
                }
            }
            .frame(width: Self.coverSize, height: Self.coverSize)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.8)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(TurntableTokens.cream)
                Text(track.artists.joined(separator: ", "))
                    .font(.system(size: 12))
                    .foregroundColor(TurntableTokens.cream.opacity(0.62))
                let small = Self.smallPrint(for: track)
                if !small.isEmpty {
                    Text(small)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(TurntableTokens.brass)
                        .padding(.top, 2)
                }
            }
            .lineLimit(1)
            .frame(width: Self.coverSize, height: Self.textHeight, alignment: .leading)

            foot
        }
        .padding(.horizontal, Self.padding)
        .padding(.top, Self.padding)
        .padding(.bottom, Self.padding)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            shape
                .fill(TurntableTokens.room)
                .overlay(
                    shape.fill(
                        LinearGradient(
                            colors: [.white.opacity(0.09), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                )
        )
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [TurntableTokens.keyLight.opacity(0.45), .white.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.75), radius: 22, y: 14)
        .accessibilityHidden(true)
    }
}
