//
//  DeckKit.swift
//  YTAudioPlayer
//
//  The Deck design system: the Turntable Home's look, made into parts
//  any screen can use.
//
//  The idea in one line: THE APP IS A HI-FI, NOT A DASHBOARD. A screen
//  is a room with furniture in it — walnut, black anodised metal,
//  machined aluminium, cream card, brass — lit by one warm lamp from
//  the upper left. Light is information: the only saturated colour on
//  a screen is a lamp, and a lamp is lit because something is on.
//
//  The guide, with the rules and the rollout order for the rest of the
//  app, is docs/design/deck-design-system.md. This file is the code
//  half of it:
//
//    DeckType        type styles
//    DeckMotion      springs
//    DeckSignal      what each lamp colour means
//    DeckLampState   idle / lit / working
//    DeckLamp        a pilot lamp
//    DeckMetalButton a machined aluminium push button with a lamp ring
//    .deckPlinth()   walnut surface
//    .deckPanel()    black anodised panel, let into a surface
//    .deckWell()     a recessed channel (the queue tray)
//    DeckRoom        the room a screen stands in
//    DeckLabelCard   cream card in a brass holder
//    DeckLedge       a walnut shelf edge, used as a section header
//    DeckButton      the text button: card (primary) or key (secondary)
//    DeckChip        one position of a selector switch
//    DeckTrackRow    a track in a list: sleeve, title, small print
//    DeckMetalCap    the metal button's drawing, as a label
//    .deckCover()    artwork as a sleeve
//    \.deckStyle     "this screen has been moved over" (rollout only)
//
//  Colours stay where they were: materials in `TurntableTokens`,
//  signal colours in `Theme`. Spacing and radii are the app's existing
//  `Spacing` and `CornerRadius`.
//

import SwiftUI

// MARK: - Type

/// Two voices. PRINT is what is written on paper — titles, names —
/// and is set in the system face. ENGRAVING is what is cut into the
/// hardware — legends, counters, small print — and is monospaced,
/// upper-case and tracked.
enum DeckType {
    /// A screen's name.
    static let screenTitle = Font.system(size: 26, weight: .bold)
    /// A track or playlist title in a list, a card's headline.
    static let title = Font.system(size: 15, weight: .semibold)
    /// The line under a title: artist, description.
    static let subtitle = Font.system(size: 13)
    /// Running text.
    static let body = Font.system(size: 15)

    /// A legend cut into a panel or printed on a label card.
    static let engraved = Font.system(size: 9.5, weight: .bold, design: .monospaced)
    /// Durations, counts, file sizes.
    static let smallPrint = Font.system(size: 10.5, weight: .medium, design: .monospaced)
    /// A button's caption.
    static let button = Font.system(size: 13, weight: .bold, design: .monospaced)

    /// Letter-spacing for engraved text.
    static let engravedTracking: CGFloat = 1.4
}

// MARK: - Motion

/// Things on the deck have mass. Nothing fades in from nowhere and
/// nothing bounces more than once.
enum DeckMotion {
    /// A control under a finger: quick, a little give.
    static let press = Animation.spring(response: 0.2, dampingFraction: 0.7)
    /// A part moving to a new position: a lever, a selector.
    static let move = Animation.spring(response: 0.3, dampingFraction: 0.72)
    /// Something arriving or leaving: a card, a shelf, a record.
    static let settle = Animation.spring(response: 0.46, dampingFraction: 0.8)
    /// A lamp pulsing while the deck works.
    static let pulse = Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true)
}

// MARK: - Signal

/// What a lamp's colour means. A colour is never decoration: if two
/// things on a screen glow the same colour they are the same kind of
/// thing.
enum DeckSignal {
    /// Now playing, selected, "this one".
    static let live = Theme.cyberCyan
    /// Discovery: something new, something the user has not heard.
    static let discover = Theme.cyberMagenta
    /// Waiting on the user: review, confirm, a countdown.
    static let attention = Theme.cyberYellow
    /// Power and plain status: on, loading, saved.
    static let power = TurntableTokens.amberLamp
}

/// What a lamp is doing.
enum DeckLampState: Equatable {
    /// Dark.
    case idle
    /// Lit steadily: the thing is on.
    case lit
    /// Pulsing: the deck is working on it.
    case working
}

/// Turns a `DeckLampState` into a brightness, 0...1, and runs the
/// pulse. Shared by everything that has a lamp.
private struct LampLevel: ViewModifier {
    let state: DeckLampState
    @Binding var level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onAppear { apply() }
            .onChange(of: state) { _, _ in apply() }
    }

    private func apply() {
        switch state {
        case .idle:
            withAnimation(.easeOut(duration: 0.2)) { level = 0 }
        case .lit:
            withAnimation(.easeOut(duration: 0.2)) { level = 1 }
        case .working:
            guard !reduceMotion else { level = 1; return }
            level = 0.25
            withAnimation(DeckMotion.pulse) { level = 1 }
        }
    }
}

// MARK: - Lamp

/// A pilot lamp: a small lens that is dark, lit, or pulsing.
struct DeckLamp: View {
    var color: Color = DeckSignal.power
    var state: DeckLampState = .lit
    var size: CGFloat = 5

    @State private var level: Double = 0

    var body: some View {
        Circle()
            .fill(state == .idle ? Color.black.opacity(0.7) : color.opacity(0.2 + 0.8 * level))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.65), lineWidth: 0.6))
            .overlay(
                Circle()
                    .fill(.white.opacity(0.08 + 0.45 * level))
                    .frame(width: size * 0.34, height: size * 0.34)
                    .offset(x: -size * 0.16, y: -size * 0.16)
            )
            .shadow(color: color.opacity(0.9 * level), radius: size * 0.8)
            .modifier(LampLevel(state: state, level: $level))
            .accessibilityHidden(true)
    }
}

// MARK: - Metal

/// Machined aluminium, as a fill for round parts: the light breaks
/// into wedges round the centre, the way it does on a lathe-turned
/// face.
struct DeckMachinedMetal: View {
    /// Darker for a part in shadow or under a finger.
    var dim: Double = 0

    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    colors: [
                        Color(white: 0.60), Color(white: 0.94), Color(white: 0.46),
                        Color(white: 0.82), Color(white: 0.40), Color(white: 0.96),
                        Color(white: 0.60)
                    ],
                    center: .center
                )
            )
            .colorMultiply(TurntableTokens.aluminium)
            .brightness(-dim)
    }
}

/// A round aluminium push button with a lamp ring round it.
///
/// The deck's own control for an action that has no position: you
/// press it and something happens. (A thing with two positions is a
/// lever; a choice between several is a selector.) There is no caption
/// — the symbol is engraved in the face, and the ring says whether
/// what it starts is running.
struct DeckMetalButton: View {
    let symbol: String
    var accent: Color = DeckSignal.power
    var state: DeckLampState = .idle
    /// The cap's diameter. The touch target is never less than 44pt.
    var size: CGFloat = 36
    var action: () -> Void

    @State private var level: Double = 0

    var body: some View {
        Button(action: action) {
            // The label is only the touch target; the style draws the
            // button, because it needs to know when it is pressed.
            Color.clear
                .frame(width: max(44, size + 8), height: max(44, size + 8))
                .contentShape(Circle())
        }
        .buttonStyle(Cap(symbol: symbol, accent: accent, size: size, isOn: state != .idle, level: level))
        .modifier(LampLevel(state: state, level: $level))
    }

    private struct Cap: ButtonStyle {
        let symbol: String
        let accent: Color
        let size: CGFloat
        let isOn: Bool
        let level: Double

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(
                    DeckMetalCap(
                        symbol: symbol, accent: accent, size: size,
                        isOn: isOn, level: level, pressed: configuration.isPressed
                    )
                )
                .animation(DeckMotion.press, value: configuration.isPressed)
        }
    }
}

/// The drawing of a metal push button, without the button: the cap,
/// the hole it sits in and its lamp ring. `DeckMetalButton` is this
/// plus a touch target; use the cap on its own as the label of
/// something that is already a control, such as a `Menu`.
struct DeckMetalCap: View {
    let symbol: String
    var accent: Color = DeckSignal.power
    var size: CGFloat = 36
    var isOn: Bool = false
    /// The lamp's brightness, 0...1.
    var level: Double = 1
    var pressed: Bool = false

    var body: some View {
        ZStack {
            // The hole the button sits in.
            Circle()
                .fill(.black.opacity(0.7))
                .frame(width: size + 7, height: size + 7)
                .blur(radius: 1.6)

            // The lamp ring: a dark groove that lights.
            Circle()
                .fill(Color(white: 0.05))
                .frame(width: size + 6, height: size + 6)
            Circle()
                .strokeBorder(
                    isOn ? accent.opacity(0.3 + 0.7 * level) : Color.white.opacity(0.07),
                    lineWidth: 2.2
                )
                .frame(width: size + 5, height: size + 5)
                .shadow(color: accent.opacity(isOn ? 0.95 * level : 0), radius: 5)
                .shadow(color: accent.opacity(isOn ? 0.5 * level : 0), radius: 11)

            ZStack {
                DeckMachinedMetal(dim: pressed ? 0.10 : 0)
                    .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 0.7))
                    // The lamp's colour spills onto the rim.
                    .overlay(Circle().strokeBorder(accent.opacity(isOn ? 0.35 * level : 0), lineWidth: 1.2))

                // The face is dished: a step in from the rim.
                Circle()
                    .strokeBorder(.black.opacity(0.24), lineWidth: 0.8)
                    .padding(size * 0.11)
                Circle()
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                    .padding(size * 0.11 + 0.9)

                // The symbol, engraved: dark, with the cut's lower
                // edge catching the light.
                Image(systemName: symbol)
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundColor(Color(white: 0.13).opacity(0.86))
                    .shadow(color: .white.opacity(0.6), radius: 0, y: 0.7)
            }
            .frame(width: size, height: size)
            .scaleEffect(pressed ? 0.95 : 1)
            .shadow(color: .black.opacity(pressed ? 0.3 : 0.7), radius: pressed ? 1 : 2.5, x: 1, y: pressed ? 1 : 2.5)
        }
        .frame(width: size + 7, height: size + 7)
    }
}

/// A control gives a little under the finger. For buttons whose label
/// is already drawn as a Deck part.
struct DeckPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(DeckMotion.press, value: configuration.isPressed)
    }
}

// MARK: - Rollout

private struct DeckStyleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the screen this view is in has been moved onto the
    /// Deck design system. Shared components that are drawn two ways
    /// during the rollout read it; a screen sets it at its root. It
    /// goes away, with the old drawings, when the rollout is done.
    var deckStyle: Bool {
        get { self[DeckStyleKey.self] }
        set { self[DeckStyleKey.self] = newValue }
    }
}

/// How the Deck writes numbers.
enum DeckFormat {
    /// "3:42", "1:02:05". Nil when the length is not known.
    static func runtime(_ seconds: Int) -> String? {
        guard seconds > 0 else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// "1 track", "24 tracks".
    static func tracks(_ count: Int) -> String {
        "\(count) track\(count == 1 ? "" : "s")"
    }
}

/// A record's sleeve as a square cover: the cut card edge lit from
/// the upper left, a shadow down and right. The Deck's way of showing
/// artwork anywhere it is not on the platter.
struct DeckCover: ViewModifier {
    var cornerRadius: CGFloat = 3

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        content
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [TurntableTokens.cream.opacity(0.5), .clear, .black.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
            )
            .shadow(color: .black.opacity(0.55), radius: 5, x: 2, y: 3)
    }
}

extension View {
    func deckCover(cornerRadius: CGFloat = 3) -> some View {
        modifier(DeckCover(cornerRadius: cornerRadius))
    }
}

// MARK: - Surfaces

extension View {
    /// A walnut surface: veneer under satin lacquer, lit from the
    /// upper left. The plinth, a sheet's body, a card that is
    /// furniture rather than paper.
    func deckPlinth(cornerRadius: CGFloat = CornerRadius.xl) -> some View {
        modifier(DeckPlinthSurface(cornerRadius: cornerRadius))
    }

    /// A black anodised panel let into the surface behind it. Groups
    /// controls; holds anything that is "the hardware's own" rather
    /// than content.
    func deckPanel(cornerRadius: CGFloat = CornerRadius.md) -> some View {
        modifier(DeckPanelSurface(cornerRadius: cornerRadius))
    }

    /// A channel routed into the surface, darker than what is round
    /// it. Things lie IN a well: the queue's records, a search field's
    /// text, a progress track.
    func deckWell<S: InsettableShape>(_ shape: S, lit: Color? = nil) -> some View {
        background(DeckWell(shape: shape, lit: lit))
    }
}

private struct DeckPlinthSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                shape
                    .fill(TurntableTokens.walnut)
                    // Painted, not laid over as an image: a fill-scaled
                    // image takes touches over its whole natural size.
                    .overlay(
                        shape
                            .fill(ImagePaint(image: Image(TurntableTexture.walnut), scale: 0.5))
                            .opacity(0.9)
                    )
                    .overlay(
                        shape.fill(
                            LinearGradient(
                                stops: [
                                    .init(color: TurntableTokens.keyLight.opacity(0.16), location: 0),
                                    .init(color: .clear, location: 0.4),
                                    .init(color: .black.opacity(0.42), location: 1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
                    .overlay(
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [
                                    TurntableTokens.keyLight.opacity(0.5),
                                    TurntableTokens.keyLight.opacity(0.08),
                                    .black.opacity(0.65)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                    )
                    .shadow(color: .black.opacity(0.6), radius: 14, y: 9)
                    .allowsHitTesting(false)
            )
    }
}

private struct DeckPanelSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                shape
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.16), TurntableTokens.anodised],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.30), .white.opacity(0.03), .black.opacity(0.6)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                    )
                    .shadow(color: .black.opacity(0.5), radius: 4, x: 1.5, y: 3)
                    .allowsHitTesting(false)
            )
    }
}

/// The recessed channel behind `.deckWell(_:)`.
struct DeckWell<S: InsettableShape>: View {
    let shape: S
    /// The colour the channel's edge glows, when it is doing something.
    var lit: Color?

    var body: some View {
        shape
            .fill(TurntableTokens.walnut.opacity(0.55))
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [.black.opacity(0.78), .black.opacity(0.36)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            // The shadow the top edge throws into the channel.
            .overlay(
                shape
                    .strokeBorder(.black.opacity(0.8), lineWidth: 5)
                    .blur(radius: 4)
                    .offset(y: 2.5)
                    .mask(shape)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.black.opacity(0.7), .white.opacity(0.03), TurntableTokens.keyLight.opacity(0.22)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .overlay(
                shape
                    .strokeBorder((lit ?? .clear).opacity(lit == nil ? 0 : 0.55), lineWidth: 1)
                    .shadow(color: (lit ?? .clear).opacity(lit == nil ? 0 : 0.6), radius: 6)
            )
            .allowsHitTesting(false)
    }
}

/// The room a screen stands in: a warm near-black wall and the lamp
/// up and to the left. Every Deck screen has this behind it, so going
/// from one to the next is walking round one room.
struct DeckRoom: View {
    var body: some View {
        ZStack {
            TurntableTokens.room
            RadialGradient(
                colors: [TurntableTokens.keyLight.opacity(0.11), .clear],
                center: UnitPoint(x: 0.12, y: 0.04),
                startRadius: 0,
                endRadius: 460
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Label card

/// A cream card in a brass holder: how the hardware names things. A
/// shelf's artist, a section, a tag.
struct DeckLabelCard: View {
    let text: String
    var maxWidth: CGFloat = 190

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 7.5, weight: .bold, design: .monospaced))
            .tracking(1.1)
            .foregroundColor(TurntableTokens.walnut)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 10.5)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        LinearGradient(
                            colors: [TurntableTokens.cream, TurntableTokens.cream.opacity(0.82)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 1.5)
                    .strokeBorder(
                        LinearGradient(
                            colors: [TurntableTokens.brass, TurntableTokens.brass.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
    }
}

/// A walnut shelf edge with a label card on it: the Deck's section
/// header. Content above it stands on it; content below hangs under
/// it. An optional trailing count is engraved at the far end.
struct DeckLedge: View {
    let title: String
    var count: Int?

    var body: some View {
        Rectangle()
            .fill(ImagePaint(image: Image(TurntableTexture.walnut), sourceRect: CGRect(x: 0, y: 0.44, width: 1, height: 0.06), scale: 0.5))
            .overlay(
                LinearGradient(
                    colors: [.black.opacity(0.05), .black.opacity(0.48)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: 15)
            .clipShape(RoundedRectangle(cornerRadius: 2.5))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(TurntableTokens.keyLight.opacity(0.42))
                    .frame(height: 1)
                    .padding(.horizontal, 1.5)
            }
            .overlay(alignment: .leading) {
                DeckLabelCard(text: title).padding(.leading, 14)
            }
            .overlay(alignment: .trailing) {
                if let count {
                    Text("\(count)")
                        .font(DeckType.engraved)
                        .foregroundColor(TurntableTokens.cream.opacity(0.55))
                        .padding(.trailing, 14)
                }
            }
            .shadow(color: .black.opacity(0.7), radius: 7, y: 7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Buttons

/// The Deck's text button.
///
/// `.card` is the one main action on a screen: cream stock with a
/// brass edge, like the label on a record — it is the brightest thing
/// in the room, so there is only ever one. `.key` is everything else:
/// a black key with an engraved caption.
struct DeckButton: View {
    enum Kind { case card, key }

    let title: String
    var symbol: String?
    var kind: Kind = .key
    /// Stretch to the width on offer, for two buttons sharing a row.
    var fillsWidth: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                }
                Text(title.uppercased())
                    .font(DeckType.button)
                    .tracking(1.0)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .frame(minWidth: 44, maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)
        }
        .buttonStyle(Style(kind: kind))
    }

    private struct Style: ButtonStyle {
        let kind: Kind

        func makeBody(configuration: Configuration) -> some View {
            let pressed = configuration.isPressed
            let shape = RoundedRectangle(cornerRadius: CornerRadius.smd, style: .continuous)
            configuration.label
                .foregroundColor(kind == .card ? TurntableTokens.walnut : TurntableTokens.cream.opacity(0.9))
                .background(
                    shape
                        .fill(
                            kind == .card
                                ? LinearGradient(
                                    colors: [TurntableTokens.cream, TurntableTokens.cream.opacity(0.80)],
                                    startPoint: .top, endPoint: .bottom
                                )
                                : LinearGradient(
                                    colors: pressed
                                        ? [Color(white: 0.07), Color(white: 0.11)]
                                        : [Color(white: 0.21), Color(white: 0.10)],
                                    startPoint: .top, endPoint: .bottom
                                )
                        )
                        .overlay(
                            shape.strokeBorder(
                                kind == .card
                                    ? LinearGradient(
                                        colors: [TurntableTokens.brass, TurntableTokens.brass.opacity(0.5)],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                    : LinearGradient(
                                        colors: [.white.opacity(pressed ? 0.05 : 0.30), .white.opacity(0.03), .black.opacity(0.7)],
                                        startPoint: .top, endPoint: .bottom
                                    ),
                                lineWidth: kind == .card ? 1.4 : 1
                            )
                        )
                        .brightness(kind == .card && pressed ? -0.08 : 0)
                        .shadow(color: .black.opacity(pressed ? 0.25 : 0.6), radius: pressed ? 1 : 4, y: pressed ? 1 : 3)
                )
                .offset(y: pressed ? 1.2 : 0)
                .animation(DeckMotion.press, value: pressed)
        }
    }
}

/// One position of a selector: a set of these in a `.deckPanel()` is
/// the Deck's segmented control. The selected one has its lamp lit;
/// the rest are dark.
struct DeckChip: View {
    let title: String
    var count: Int?
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                DeckLamp(color: DeckSignal.live, state: isSelected ? .lit : .idle, size: 4.5)
                Text(title.uppercased())
                    .font(DeckType.engraved)
                    .tracking(DeckType.engravedTracking)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(DeckType.engraved)
                        .opacity(0.55)
                }
            }
            .foregroundColor(isSelected ? DeckSignal.live : TurntableTokens.aluminium.opacity(0.7))
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous)
                    .fill(Color.white.opacity(isSelected ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(DeckMotion.move, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Track row

/// A track in a list: its sleeve, its title and artist in print, and
/// its small print engraved at the far end. The row that is playing
/// has the live lamp and a cyan title — the same cyan as the ring
/// round the current record in the tray.
struct DeckTrackRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    var artworkURL: URL?
    var smallPrint: String?
    var isPlaying: Bool = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    TurntableTokens.walnut
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(TurntableTokens.aluminium.opacity(0.6))
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 2.5))
            .overlay(
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(
                        LinearGradient(
                            colors: [TurntableTokens.cream.opacity(0.5), .clear, .black.opacity(0.4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: .black.opacity(0.5), radius: 3, x: 1.5, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DeckType.title)
                    .foregroundColor(isPlaying ? DeckSignal.live : TurntableTokens.cream)
                Text(subtitle)
                    .font(DeckType.subtitle)
                    .foregroundColor(TurntableTokens.cream.opacity(0.55))
            }
            .lineLimit(1)

            Spacer(minLength: 8)

            if isPlaying {
                DeckLamp(color: DeckSignal.live, state: .lit)
            }
            if let smallPrint {
                Text(smallPrint)
                    .font(DeckType.smallPrint)
                    .foregroundColor(TurntableTokens.brass)
            }
            accessory()
        }
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}

extension DeckTrackRow where Accessory == EmptyView {
    init(title: String, subtitle: String, artworkURL: URL? = nil, smallPrint: String? = nil, isPlaying: Bool = false) {
        self.init(
            title: title, subtitle: subtitle, artworkURL: artworkURL,
            smallPrint: smallPrint, isPlaying: isPlaying, accessory: { EmptyView() }
        )
    }
}

// MARK: - Lever

/// A two-position lever in a slot: the Deck's switch. The knurled
/// aluminium head sits at the left end for off and the right end for
/// on, and the pilot lamp beside it is lit while it is on.
///
/// This is `CueLeverView`'s idea (a thing with two positions is a
/// lever) turned on its side and made generic. It draws only; the
/// toggle that owns it (`DeckLeverToggleStyle`) supplies the touch.
struct DeckLever: View {
    let isOn: Bool
    var lamp: Color = DeckSignal.power

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the head travels either side of the slot's centre.
    private static let travel: CGFloat = 11

    var body: some View {
        HStack(spacing: 9) {
            DeckLamp(color: lamp, state: isOn ? .lit : .idle, size: 5)

            ZStack {
                Capsule()
                    .fill(.black.opacity(0.85))
                    .frame(width: 44, height: 17)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 0.6))

                head
                    .offset(x: isOn ? Self.travel : -Self.travel)
            }
            .frame(width: 48, height: 26)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.62), value: isOn)
    }

    /// The lever's head: a knurled aluminium barrel, ridges across it.
    private var head: some View {
        RoundedRectangle(cornerRadius: 3.5)
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Color(white: 0.42), location: 0),
                        .init(color: Color(white: 0.98), location: 0.3),
                        .init(color: Color(white: 0.72), location: 0.55),
                        .init(color: Color(white: 0.30), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .colorMultiply(TurntableTokens.aluminium)
            .frame(width: 17, height: 21)
            .overlay(
                VStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { _ in
                        Rectangle().fill(.black.opacity(0.22)).frame(width: 11, height: 0.8)
                    }
                }
            )
            .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(.black.opacity(0.5), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.65), radius: 3, x: 1.5, y: isOn ? 2 : 3)
    }
}

/// A `Toggle` drawn as a lever: its label on the left, the lever at
/// the far end. Use it with `.toggleStyle(DeckLeverToggleStyle())`;
/// set on a `List` it reaches every toggle in it.
struct DeckLeverToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            DeckLever(isOn: configuration.isOn)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            HapticManager.selectionChanged()
            configuration.isOn.toggle()
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
