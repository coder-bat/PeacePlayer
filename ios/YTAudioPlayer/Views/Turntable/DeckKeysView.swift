//
//  DeckKeysView.swift
//  YTAudioPlayer
//
//  The deck's push buttons.
//
//  The plinth's four corners each hold one thing (revision
//  2026-11-22): setup back-left, the arm's pivot back-right, the cue
//  lever front-left, and a cluster of three keys front-right. The
//  keys are the things that used to be icons floating over the deck:
//
//    dig     re-deals the queue with records from just outside what
//            the user normally plays (the Anti-Algorithm engine)
//    radio   opens the tuner — stations, podcasts, audiobooks
//    review  opens what is waiting on the user: the Smart Library's
//            auto-download review, or a scheduled cleanup
//    setup   opens Settings
//
//  Each is a machined aluminium button set straight into the walnut,
//  the same metal as the 45 adapter and the arm's hardware
//  (`DeckMetalButton`). There are no captions: the symbol is engraved
//  in the face, and the ring round the button is its lamp — dark at
//  rest, lit while what it starts is on, pulsing while the deck works.
//

import SwiftUI

/// One button on the front of the deck.
enum DeckKey: String, CaseIterable, Identifiable {
    case dig
    case radio
    case review
    case setup

    var id: String { rawValue }

    /// The symbol engraved in the button's face.
    var symbol: String {
        switch self {
        case .dig: return "dice.fill"
        case .radio: return "antenna.radiowaves.left.and.right"
        case .review: return "wand.and.stars"
        case .setup: return "gearshape.fill"
        }
    }

    /// The colour the ring lights in. See `DeckSignal`.
    var accent: Color {
        switch self {
        case .dig: return DeckSignal.discover
        case .radio: return DeckSignal.live
        case .review: return DeckSignal.attention
        case .setup: return DeckSignal.power
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .dig: return "Dig for something new"
        case .radio: return "Radio"
        case .review: return "Review"
        case .setup: return "Settings"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .dig: return "Replaces the queue with songs just outside what you usually play"
        case .radio: return "Opens stations, podcasts and audiobooks"
        case .review: return "Opens auto-downloads and cleanups waiting for your review"
        case .setup: return "Opens settings"
        }
    }
}

/// What a button's ring is doing. The Deck design system's lamp
/// states, under the name the deck's own code uses.
typealias DeckKeyState = DeckLampState

/// The three buttons in the plinth's front-right corner, set out as
/// a triangle that sits into the corner:
///
///            ◎        dig
///        ◎   ◎        radio · review
///
/// The fourth key, setup, is not here: it has the back-left corner to
/// itself (revision 2026-11-22), where the 45 adapter used to sit.
struct DeckKeysView: View {
    /// The keys in the cluster, and where each sits: (column, row),
    /// counted from the top-left of a 2×2 grid.
    static let cluster: [(key: DeckKey, column: Int, row: Int)] = [
        (.dig, 1, 0),
        (.radio, 0, 1),
        (.review, 1, 1)
    ]

    /// A button's cap.
    static let buttonDiameter: CGFloat = 36
    /// Centre to centre, across and down.
    static let pitch: CGFloat = 46
    /// The cluster's design size on the plinth.
    static let size = CGSize(width: pitch + 44, height: pitch + 44)

    /// A key's centre inside the cluster's box.
    static func centre(column: Int, row: Int) -> CGPoint {
        CGPoint(x: 22 + CGFloat(column) * pitch, y: 22 + CGFloat(row) * pitch)
    }

    var states: [DeckKey: DeckKeyState] = [:]
    var onPress: (DeckKey) -> Void = { _ in }

    var body: some View {
        ZStack {
            ForEach(Self.cluster, id: \.key) { entry in
                DeckKeyButton(key: entry.key, state: states[entry.key] ?? .idle) {
                    onPress(entry.key)
                }
                .position(Self.centre(column: entry.column, row: entry.row))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

/// One of the deck's keys, as a metal push button.
struct DeckKeyButton: View {
    let key: DeckKey
    var state: DeckKeyState = .idle
    var action: () -> Void

    var body: some View {
        DeckMetalButton(
            symbol: key.symbol,
            accent: key.accent,
            state: state,
            size: DeckKeysView.buttonDiameter,
            action: action
        )
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityHint(key.accessibilityHint)
        .accessibilityValue(state == .working ? "Working" : (state == .lit ? "On" : ""))
        .accessibilityIdentifier("deck.key.\(key.rawValue)")
    }
}
