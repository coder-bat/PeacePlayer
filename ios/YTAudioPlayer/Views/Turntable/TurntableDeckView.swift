//
//  TurntableDeckView.swift
//  YTAudioPlayer
//
//  The deck as one object: a walnut plinth with everything that is
//  bolted to it.
//
//  Laid out the way a real deck is, seen from above:
//
//    ┌──────────────────────────────────┐
//    │ (⚙)                       ◉──┐   │  setup · arm pivot
//    │        ╭───────────╮         │   │
//    │      ╱               ╲       │   │
//    │     │     RECORD      │      │   │  the arm runs down the
//    │     │        ·        │     ╱    │  right-hand side
//    │      ╲               ╱    ▰      │
//    │        ╰───────────╯          ◎  │  cue lever front-left,
//    │ ▯                          ◎  ◎  │  three keys front-right
//    └──────────────────────────────────┘
//
//  Each corner holds one thing (revision 2026-11-22).
//
//  The platter is set left of centre so the arm has the right-hand
//  margin to itself, and the corners the platter leaves empty are
//  where the controls live. Nothing overlaps the record except the
//  headshell — the artwork is the point of the deck.
//
//  The keys are the things that used to be icons floating over the
//  deck. See DeckKeysView.
//
//  The view is drawn at a fixed design size (`size`) and scaled by
//  its parent to fit the screen, so every part keeps its proportion
//  to every other.
//

import SwiftUI

struct TurntableDeckView: View {
    /// The plinth's design size.
    static let size = CGSize(width: 366, height: 384)

    /// Back-left: the setup button, where the 45 adapter used to sit.
    static let setupCentre = CGPoint(x: 37, y: 39)
    /// Front-left: the cue lever.
    static let leverCentre = CGPoint(x: 33, y: 336)
    /// Front-right: the cluster of three keys.
    static let keysCentre = CGPoint(x: 313, y: 331)

    /// The platter's centre on the plinth.
    static let platterCentre = CGPoint(
        x: 22 + PlatterView.diameter / 2,
        y: 18 + PlatterView.diameter / 2
    )

    let artworkURL: URL?
    let trackIdentity: String
    /// A record is on the platter.
    let isLoaded: Bool
    let isPlaying: Bool
    var isLoading: Bool = false
    let progress: Double
    var duration: Double = 0
    let reduceMotion: Bool
    /// Playback position sampled at display rate.
    var progressAt: ((Date) -> Double)?
    var onTapPlatter: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onScrubEnded: (Double) -> Void = { _ in }
    var onToggle: () -> Void = {}
    /// What each key on the front panel is doing.
    var keyStates: [DeckKey: DeckKeyState] = [:]
    var onKey: (DeckKey) -> Void = { _ in }

    /// The record on the platter. It lags `trackIdentity` during a
    /// change, while the arm gets out of the way.
    @State private var platterIdentity: String = ""
    @State private var platterArtwork: URL?
    /// False for the first frame, before the state above has been set
    /// from the track. The deck draws the track itself until then, so
    /// it never shows an empty platter for a frame — which matters
    /// when the full player puts this deck over Home's identical one.
    @State private var hasAppeared = false
    /// A record change is under way: the arm is up and parked.
    @State private var isChanging = false
    @State private var changeToken = 0

    /// The record change, in seconds from the moment the track changes.
    /// A change takes about a second to buffer, so the deck has that
    /// long: the arm lifts and swings clear, the record is lifted off
    /// and the new one set down, and the arm comes back.
    enum RecordChange {
        /// The arm has swung clear; the old record starts to lift.
        static let swapAt: Double = 0.30
        /// The new record is down; the arm starts back.
        static let armBackAt: Double = 0.92
    }

    var body: some View {
        ZStack {
            plinth

            DeckKeyButton(key: .setup, state: keyStates[.setup] ?? .idle) {
                onKey(.setup)
            }
            .position(Self.setupCentre)

            // The well the platter turns in: a hairline of shadow
            // between the platter and the wood.
            Circle()
                .fill(.black.opacity(0.55))
                .frame(width: PlatterView.diameter + 7, height: PlatterView.diameter + 7)
                .blur(radius: 2)
                .position(Self.platterCentre)

            PlatterView(
                artworkURL: hasAppeared ? platterArtwork : artworkURL,
                trackIdentity: hasAppeared ? platterIdentity : trackIdentity,
                isPlaying: isPlaying,
                isLoading: isLoading,
                progress: progress,
                duration: duration,
                reduceMotion: reduceMotion,
                progressAt: progressAt,
                onTapPlatter: onTapPlatter,
                onLongPress: onLongPress
            )
            .frame(width: PlatterView.diameter, height: PlatterView.diameter)
            .position(Self.platterCentre)

            TonearmView(
                progress: progress,
                isLoaded: isLoaded && !isChanging,
                isLifted: !isPlaying || isChanging,
                duration: duration,
                progressAt: progressAt,
                onScrubEnded: onScrubEnded
            )
            .frame(width: PlatterView.diameter, height: PlatterView.diameter)
            .position(Self.platterCentre)

            // The start/stop lever has the front-LEFT corner, the way
            // it does on a Technics — the arm owns the right-hand side.
            CueLeverView(
                isPlaying: isPlaying,
                isLoading: isLoading,
                onToggle: onToggle
            )
            .position(Self.leverCentre)

            DeckKeysView(states: keyStates, onPress: onKey)
                .position(Self.keysCentre)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear {
            platterIdentity = trackIdentity
            platterArtwork = artworkURL
            hasAppeared = true
        }
        .onChange(of: trackIdentity) { old, new in
            changeRecord(from: old, to: new)
        }
        // Artwork that arrives late for the record already down.
        .onChange(of: artworkURL) { _, url in
            if !isChanging, platterIdentity == trackIdentity { platterArtwork = url }
        }
    }

    /// One record to the next: arm up and clear, record off, record
    /// on, arm back. Putting the first record on an empty platter, or
    /// taking the last one off, needs no clearing — the arm is parked.
    private func changeRecord(from old: String, to new: String) {
        changeToken += 1
        let token = changeToken
        guard !old.isEmpty, !new.isEmpty, !reduceMotion else {
            isChanging = false
            platterIdentity = new
            platterArtwork = artworkURL
            return
        }
        isChanging = true
        DispatchQueue.main.asyncAfter(deadline: .now() + RecordChange.swapAt) {
            guard changeToken == token else { return }
            platterArtwork = artworkURL
            platterIdentity = trackIdentity
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + RecordChange.armBackAt) {
            guard changeToken == token else { return }
            isChanging = false
        }
    }

    // MARK: - Plinth

    /// Walnut veneer under satin lacquer.
    ///
    /// The texture sits inside an overlay on purpose. A resizable
    /// image with `.aspectRatio(contentMode: .fill)` reports its
    /// natural size as its ideal size, and in a ZStack that ideal size
    /// wins: the container grows to the texture's 1024pt width and
    /// everything laid out on the deck is pushed off screen. An
    /// overlay pins the texture to the plinth's own bounds.
    private var plinth: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        return shape
            .fill(TurntableTokens.walnut)
            .overlay(
                Image(TurntableTexture.walnut)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .colorMultiply(Color(red: 0.80, green: 0.74, blue: 0.70))
                    .allowsHitTesting(false)
            )
            // The lacquer: lit at the corner under the lamp, falling
            // away to the corner nearest you.
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: TurntableTokens.keyLight.opacity(0.20), location: 0),
                        .init(color: .clear, location: 0.38),
                        .init(color: .black.opacity(0.42), location: 1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(shape)
            // The edge is eased, so it catches a line of light along
            // the top and left and goes dark along the bottom.
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            TurntableTokens.keyLight.opacity(0.55),
                            TurntableTokens.keyLight.opacity(0.08),
                            .black.opacity(0.65)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.4
                )
            )
            .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
            .shadow(color: .black.opacity(0.75), radius: 26, y: 18)
            .frame(width: Self.size.width, height: Self.size.height)
    }
}
