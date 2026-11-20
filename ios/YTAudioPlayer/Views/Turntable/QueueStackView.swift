//
//  QueueStackView.swift
//  YTAudioPlayer
//
//  The queue, drawn as records laid out in a tray under the deck.
//
//  Each one is a miniature of the record on the platter: the track's
//  art printed across black vinyl, grooves, the same wedge of light.
//  The record that is playing stands a little proud of the tray with a
//  cyan ring; the ones already played sink back and fade.
//
//  The tray shows a WINDOW of the queue, not its first twelve items:
//  it starts one record before the current one and follows it, so
//  "what is on, and what is next" is always on screen however long the
//  queue is. When there is more queue than tray, the last slot is a
//  counter that opens the full queue.
//
//  The tray can be browsed (revision 2026-11-22). One record is always
//  in FOCUS: it sits in the middle of the tray, a little larger than
//  the rest, and the line above the tray names it. At rest the focus
//  is the record that is playing. Swipe the tray and the focus moves
//  to whichever record comes to the middle — the music does not
//  change; tap a record to play it. Five seconds after the last
//  touch the tray swings back to the record that is playing.
//
//  When the deck's DIG key is pressed the tray is being re-dealt: the
//  records in it spin and ride a wave while the new ones are found, a
//  light runs along the channel, and the new records are flicked in
//  one at a time as they arrive.
//

import SwiftUI

// MARK: - Window

enum QueueShelf {
    /// How many records the tray lays out.
    static let capacity = 12

    /// The slice of the queue the tray shows.
    ///
    /// One played record stays in view (it is how you step back), the
    /// current one follows it, and the rest of the tray is what comes
    /// next. Near the end of the queue the window slides back so the
    /// tray stays full.
    static func window(count: Int, currentIndex: Int, capacity: Int = capacity) -> Range<Int> {
        guard count > 0, capacity > 0 else { return 0..<0 }
        let current = max(0, min(count - 1, currentIndex))
        let end = min(count, max(0, current - 1) + capacity)
        let start = max(0, end - capacity)
        return start..<end
    }
}

// MARK: - Caption

/// What is on the platter, in words: the title, then who it is by.
///
/// One line, sitting between the deck and the tray so it reads as the
/// label for both — the record that is turning above it and the one
/// ringed in cyan below. The line keeps its height when nothing is
/// loaded, so the tray does not jump when a record goes on.
struct NowPlayingCaption: View {
    let title: String?
    var artist: String?
    /// Something the deck has to say that is not the track: "digging",
    /// or why a dig came back empty. Shown in place of the track while
    /// it is set.
    var notice: String?
    /// The symbol and colour of the button the notice came from.
    var noticeSymbol: String = "dice.fill"
    var noticeColor: Color = DeckSignal.discover
    /// Set while the tray is being browsed: the line is naming the
    /// record in focus, not the one that is playing. Shown in place of
    /// the playing mark — "7/20".
    var browsing: String?

    static let height: CGFloat = 20

    var body: some View {
        HStack(spacing: 7) {
            if let notice {
                Image(systemName: noticeSymbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(noticeColor)
                    .accessibilityHidden(true)

                Text(notice)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(noticeColor.opacity(0.92))
            } else if let title {
                if let browsing {
                    Text(browsing)
                        .font(DeckType.smallPrint)
                        .foregroundColor(TurntableTokens.brass)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(Theme.cyberCyan)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(TurntableTokens.cream)
                    .layoutPriority(1)

                if let artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 13))
                        .foregroundColor(TurntableTokens.cream.opacity(0.55))
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .padding(.horizontal, 26)
        .id(notice ?? title ?? "")
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.35), value: title)
        .animation(.easeInOut(duration: 0.25), value: notice)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notice ?? title.map { (browsing == nil ? "Now playing: " : "In the queue: ") + "\($0)" + (artist.map { ", by \($0)" } ?? "") } ?? "Nothing playing")
        .accessibilityIdentifier("turntable.nowPlaying")
    }
}

// MARK: - Tray

struct QueueStackView: View {
    let queue: [QueueItem]
    let currentIndex: Int
    var onSelect: (Int) -> Void
    /// Opens the full queue. Offered when the tray cannot show it all.
    var onShowAll: (() -> Void)?
    /// The queue is being re-dealt.
    var isDealing: Bool = false
    /// The record in focus changed: its place in the queue, or nil
    /// when the focus is back on the one that is playing.
    var onBrowse: (Int?) -> Void = { _ in }

    /// How long the tray stays where it was left before it swings
    /// back to the record that is playing.
    static let browseTimeout: Double = 5

    /// The record in the middle of the tray.
    @State private var focusID: String?
    @State private var resetTask: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the current deal began: the riffle's clock starts there.
    @State private var dealStart = Date()

    private var window: Range<Int> {
        QueueShelf.window(count: queue.count, currentIndex: currentIndex)
    }

    /// The record that is playing. Watched as well as the index: a
    /// queue that is replaced can keep the index and change the record.
    private var currentID: String? {
        queue.indices.contains(currentIndex) ? queue[currentIndex].id : nil
    }

    var body: some View {
        Group {
            if !queue.isEmpty || isDealing {
                GeometryReader { geo in
                    ScrollView(.horizontal, showsIndicators: false) {
                        TimelineView(.animation(paused: !isDealing || reduceMotion)) { timeline in
                            let phase = isDealing && !reduceMotion
                                ? timeline.date.timeIntervalSince(dealStart)
                                : nil
                            HStack(spacing: QueueDiscRow.spacing) {
                                if queue.isEmpty {
                                    QueueGhostRow(phase: phase)
                                } else {
                                    QueueDiscRow(
                                        items: Array(queue[window]),
                                        currentIndex: currentIndex,
                                        firstIndex: window.lowerBound,
                                        focusedID: focusID ?? currentID,
                                        dealPhase: phase,
                                        onSelect: onSelect
                                    )
                                }

                                if queue.count > window.upperBound, let onShowAll {
                                    moreButton(count: queue.count - window.upperBound, action: onShowAll)
                                }
                            }
                            .frame(height: QueueTray.height)
                            .opacity(isDealing && reduceMotion ? 0.45 : 1)
                        }
                    }
                    // The record in focus is the one in the middle, so
                    // the first and last records need room to get there.
                    .contentMargins(
                        .horizontal,
                        max(0, (geo.size.width - QueueDisc.diameter) / 2),
                        for: .scrollContent
                    )
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $focusID, anchor: .center)
                }
                .frame(height: QueueTray.height)
                .onAppear { focusID = currentID }
                .onChange(of: currentID) { _, id in refocus(on: id) }
                .onChange(of: focusID) { _, id in focusChanged(to: id) }
                .onDisappear { resetTask?.cancel() }
                // Records slide out from under the tray's ends rather
                // than being cut off by them.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.09),
                            .init(color: .black, location: 0.91),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay { if isDealing && !reduceMotion { DealSweep(start: dealStart) } }
                // The records lie IN the channel. The scroll view is
                // exactly the channel's shape, so nothing — a record,
                // its shadow, the current one's glow — shows outside
                // the pill.
                .clipShape(Capsule())
                .padding(.horizontal, QueueTray.margin)
                .background(QueueTray(isLit: isDealing))
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .allowsHitTesting(!isDealing)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: queue.isEmpty)
        .animation(.easeInOut(duration: 0.3), value: isDealing)
        .onChange(of: isDealing) { _, dealing in
            if dealing { dealStart = Date() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(isDealing ? "Finding new songs" : "")
    }

    /// The song changed (or the queue did): the tray follows it, and
    /// any browsing is over.
    private func refocus(on id: String?) {
        resetTask?.cancel()
        // Deferred by a turn of the run loop: the tray's window moves
        // in the same update that changes the record, and a scroll
        // asked for before the new row is laid out goes nowhere.
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.86)) {
                focusID = id
            }
        }
    }

    /// A record came to the middle of the tray.
    private func focusChanged(to id: String?) {
        resetTask?.cancel()
        guard let id, id != currentID, let index = queue.firstIndex(where: { $0.id == id }) else {
            onBrowse(nil)
            return
        }
        HapticManager.selectionChanged()
        onBrowse(index)
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.browseTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.86)) {
                focusID = currentID
            }
        }
    }

    private func moreButton(count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("+\(count)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(TurntableTokens.cream.opacity(0.8))
                .frame(width: QueueDisc.diameter, height: QueueDisc.diameter)
                .background(
                    Circle()
                        .fill(.black.opacity(0.4))
                        .overlay(
                            Circle().strokeBorder(
                                TurntableTokens.aluminium.opacity(0.3),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                            )
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressDownStyle())
        .accessibilityLabel("\(count) more in queue")
        .accessibilityHint("Opens the queue")
    }
}

// MARK: - Tray

/// The channel the records lie in: routed into the sideboard, darker
/// than the wood round it, with the far edge in shadow and the near
/// edge catching the light.
struct QueueTray: View {
    static let height: CGFloat = 68
    /// How far the channel stands in from each edge of the screen.
    static let margin: CGFloat = 12

    /// The channel's edge glows while the queue is being re-dealt.
    var isLit: Bool = false

    var body: some View {
        // The channel is the design system's well (`DeckWell`).
        DeckWell(shape: Capsule(), lit: isLit ? DeckKey.dig.accent : nil)
            .padding(.horizontal, Self.margin)
            .frame(height: Self.height)
    }
}

// MARK: - Queue row

/// The discs themselves, without the scroll view.
///
/// Split out so the tray can be rendered on its own — the offscreen
/// renderer does not draw a scroll view's contents.
struct QueueDiscRow: View {
    static let spacing: CGFloat = 12

    let items: [QueueItem]
    let currentIndex: Int
    /// The queue index of `items.first`. The row shows a window of the
    /// queue, and a tap has to name the record's place in the whole.
    var firstIndex: Int = 0
    /// The record in focus — in the middle of the tray, drawn larger.
    /// Nil means the one that is playing.
    var focusedID: String?
    /// Seconds into a re-deal, or nil when the tray is at rest.
    var dealPhase: Double?
    var onSelect: (Int) -> Void

    /// A record being dealt: flicked in from above the tray's far end.
    private static let deal = AnyTransition.asymmetric(
        insertion: .offset(x: 54, y: -38)
            .combined(with: .scale(scale: 0.3))
            .combined(with: .opacity),
        removal: .scale(scale: 0.35).combined(with: .opacity)
    )

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                let index = firstIndex + offset
                Button {
                    HapticManager.selectionChanged()
                    onSelect(index)
                } label: {
                    QueueDisc(
                        item: item,
                        state: index == currentIndex ? .current : (index < currentIndex ? .played : .upcoming),
                        isFocused: focusedID.map { $0 == item.id } ?? (index == currentIndex)
                    )
                }
                .buttonStyle(PressDownStyle())
                .modifier(Riffle(phase: dealPhase, slot: offset))
                .id(item.id)
                .transition(Self.deal)
                .contextMenu {
                    Section(item.track.title) {
                        Button {
                            onSelect(index)
                        } label: {
                            Label("Play now", systemImage: "play.fill")
                        }
                    }
                }
                .accessibilityLabel("\(item.track.title) by \(item.track.artists.first ?? "unknown artist")")
                .accessibilityValue(index == currentIndex ? "Now playing" : (index < currentIndex ? "Played" : "In queue"))
            }
        }
        // The row's own children are what the tray snaps to.
        .scrollTargetLayout()
        .animation(.spring(response: 0.4, dampingFraction: 0.74), value: currentIndex)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: focusedID)
        .animation(.spring(response: 0.46, dampingFraction: 0.68), value: items.map(\.id))
    }
}

// MARK: - Re-deal

/// What a record does while the tray is being re-dealt: it spins,
/// and rides a wave that runs along the tray.
struct Riffle: ViewModifier {
    /// Seconds into the deal, or nil at rest.
    let phase: Double?
    /// The record's place in the tray. Each one is a beat behind the
    /// one before it.
    let slot: Int

    /// Degrees a record has turned, `phase` seconds in.
    static func spin(phase: Double, slot: Int) -> Double {
        phase * 400 + Double(slot) * 47
    }

    /// How far a record has risen, in points.
    static func lift(phase: Double, slot: Int) -> Double {
        sin(phase * 7 - Double(slot) * 0.85) * 4.5
    }

    func body(content: Content) -> some View {
        if let phase {
            content
                .rotationEffect(.degrees(Self.spin(phase: phase, slot: slot)))
                .scaleEffect(0.9)
                .offset(y: Self.lift(phase: phase, slot: slot))
        } else {
            content
        }
    }
}

/// Blank records, shown riffling when there is no queue to shuffle
/// yet — the first deal into an empty tray.
struct QueueGhostRow: View {
    let phase: Double?

    var body: some View {
        HStack(spacing: QueueDiscRow.spacing) {
            ForEach(0..<6, id: \.self) { slot in
                Circle()
                    .fill(TurntableTokens.vinyl)
                    .overlay(
                        Circle()
                            .strokeBorder(.white.opacity(0.10), lineWidth: 0.6)
                            .padding(9)
                    )
                    .overlay(
                        AngularGradient(
                            colors: [.clear, .white.opacity(0.22), .clear, .clear, .white.opacity(0.12), .clear],
                            center: .center
                        )
                        .clipShape(Circle())
                    )
                    .overlay(Circle().fill(DeckKey.dig.accent.opacity(0.75)).frame(width: 13, height: 13))
                    .overlay(Circle().fill(TurntableTokens.room).frame(width: 4, height: 4))
                    .overlay(Circle().strokeBorder(TurntableTokens.aluminium.opacity(0.28), lineWidth: 0.8))
                    .frame(width: QueueDisc.diameter, height: QueueDisc.diameter)
                    .modifier(Riffle(phase: phase, slot: slot))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The light that runs along the channel while it is re-dealt.
private struct DealSweep: View {
    let start: Date

    /// Seconds for one pass.
    static let period: Double = 1.15

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSince(start)
                let travel = (t.truncatingRemainder(dividingBy: Self.period)) / Self.period
                let band = geo.size.width * 0.34
                LinearGradient(
                    colors: [.clear, DeckKey.dig.accent.opacity(0.34), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: band)
                .offset(x: -band + (geo.size.width + band) * travel)
                .blendMode(.plusLighter)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Queue disc

/// One queued track, drawn as a small picture disc.
struct QueueDisc: View {
    enum State { case played, current, upcoming }

    let item: QueueItem
    let state: State
    /// In the middle of the tray: drawn larger, with the lit cyan ring.
    /// The glow follows the focus (revision 2026-11-22 c).
    var isFocused: Bool = false

    static let diameter: CGFloat = 50
    /// How much larger the record in focus is drawn.
    static let focusScale: CGFloat = 1.2

    private var isCurrent: Bool { state == .current }

    var body: some View {
        ZStack {
            // Vinyl body.
            Circle()
                .fill(TurntableTokens.vinyl)

            // The album art, printed across the disc. It stops short
            // of the edge, the way a pressing's lead-in does.
            artwork
                .frame(width: Self.diameter - 7, height: Self.diameter - 7)
                .clipShape(Circle())
                .colorMultiply(Color(white: 0.88))

            grooves

            // The same wedge of light the big record throws.
            AngularGradient(
                stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: .clear, location: 0.07),
                    .init(color: .white.opacity(0.14), location: 0.125),
                    .init(color: .clear, location: 0.18),
                    .init(color: .clear, location: 0.55),
                    .init(color: .white.opacity(0.28), location: 0.625),
                    .init(color: .clear, location: 0.70),
                    .init(color: .clear, location: 1.00)
                ],
                center: .center
            )
            .blendMode(.plusLighter)
            .clipShape(Circle())

            // Spindle hole.
            Circle()
                .fill(TurntableTokens.room)
                .frame(width: 6, height: 6)
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.6))

            // Edge bead, and the current record's cyan ring.
            Circle()
                .strokeBorder(
                    // The lit ring is on the record in FOCUS. The one
                    // that is playing keeps a thin unlit ring while the
                    // focus is elsewhere, so it can still be found.
                    isFocused
                        ? Theme.cyberCyan
                        : (isCurrent ? Theme.cyberCyan.opacity(0.45) : TurntableTokens.aluminium.opacity(0.28)),
                    lineWidth: isFocused ? 1.5 : 0.8
                )
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .saturation(state == .played && !isFocused ? 0.45 : 1)
        .opacity(state == .played && !isFocused ? 0.55 : 1)
        .scaleEffect(isFocused ? Self.focusScale : (state == .played ? 0.9 : 1))
        .shadow(color: isFocused ? Theme.cyberCyan.opacity(0.45) : .clear, radius: 5)
        .shadow(
            color: .black.opacity(isFocused ? 0.75 : 0.55),
            radius: isFocused ? 7 : 3.5,
            x: 1.5,
            y: isFocused ? 6 : 3
        )
        .zIndex(isFocused ? 1 : 0)
        .contentShape(Circle())
    }

    private var grooves: some View {
        ZStack {
            ForEach([0.86, 0.70, 0.52], id: \.self) { fraction in
                Circle()
                    .strokeBorder(.black.opacity(0.28), lineWidth: 0.8)
                    .frame(width: Self.diameter * fraction, height: Self.diameter * fraction)
                Circle()
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
                    .frame(width: Self.diameter * fraction - 2, height: Self.diameter * fraction - 2)
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = item.track.artworkURL {
            CachedAsyncImage(url: url) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle().fill(TurntableTokens.vinyl)
            }
        } else {
            // No artwork: the source colour still identifies the
            // track, as a blank record label does.
            Circle()
                .fill(item.contentSource.tintColor.opacity(0.85))
        }
    }
}

// MARK: - Press style

/// A record gives slightly when it is touched.
struct PressDownStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
