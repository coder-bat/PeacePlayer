# The Deck design system

Status: 2026-11-21. The Turntable Home, the Library and Search tabs, the
queue sheet, the mini player, the tab bar and the full player (portrait)
are built on it, as are Playlist detail, Downloads and History.
Everything else is still in the old style.

Code: `ios/YTAudioPlayer/DesignSystem/DeckKit.swift` (components),
`TurntableTokens.swift` (materials), `Theme.swift` (signal colours,
`Spacing`, `CornerRadius`).
Specimen: `ios/.review/snapshots/deck-design-system.png`, rendered by
`TurntableSnapshotTests.testRenderDesignSystemSpecimen`.

## 1. The idea

**The app is a hi-fi, not a dashboard.** A screen is a room with
furniture in it. Things are made of something, sit somewhere, are lit
from one side, and move as if they had weight.

Four rules follow from that, and they settle most design questions:

1. **Materials, not fills.** Every surface is one of six materials
   (§2). If a view needs a background and none of them fits, the view
   is probably a different kind of thing than you think it is.
2. **One lamp.** The key light is warm and comes from the upper left.
   Highlights are on top and left edges, shadows fall down and right.
   Never light something from below or centre it in a glow.
3. **Light is information.** The only saturated colour on a screen is
   a lamp, and a lamp is lit because something is on (§3). No neon
   borders, no glowing titles, no gradient text.
4. **Content is the picture.** Album art is the one place full colour
   belongs. Hardware frames it and stays quiet.

What this replaces: the "cyber" look — black background, cyan strokes
on everything, monospaced bold titles, glass circles. The signal
colours survive; their job narrows from decoration to status.

## 2. Materials

| Material | Token | Used for |
|---|---|---|
| Room | `TurntableTokens.room`, `DeckRoom` | The wall behind every screen. |
| Walnut | `.deckPlinth()`, `DeckLedge` | Furniture: the plinth, shelf edges, a sheet's body. |
| Anodised black | `.deckPanel()` | Panels that hold controls; selector housings. |
| Machined aluminium | `DeckMachinedMetal`, `DeckMetalButton` | Things you press or turn. |
| Cream card + brass | `DeckLabelCard`, `DeckButton(.card)` | Names and the one main action. |
| Vinyl | `TurntableTokens.vinyl` | Records only. |

A **well** (`.deckWell()`) is not a material but a cut: a channel
routed into whatever is behind it. Things lie *in* a well — the
queue's records, a search field's text, a progress track.

Depth has three levels and no more: recessed (wells, panels), flush
(the room, rows of text), and standing proud (buttons, sleeves, cards).
Something that stands proud casts a shadow down and right.

## 3. Signal colours

| Signal | Token | Means |
|---|---|---|
| Cyan | `DeckSignal.live` | Now playing, selected, "this one". |
| Magenta | `DeckSignal.discover` | New to the user: Dig, recommendations. |
| Yellow | `DeckSignal.attention` | Waiting on the user: review, confirm. |
| Amber | `DeckSignal.power` | Plain status: on, loading, saved. |

A lamp has three states (`DeckLampState`): **idle** (dark), **lit**
(steady: the thing is on), **working** (pulsing: the deck is busy).
Destructive actions get no colour of their own; they get a
confirmation.

Text is cream (`TurntableTokens.cream`) at 100% / 55% / 40% for
primary / secondary / placeholder. Small print — durations, counts —
is brass.

## 4. Type

Two voices (`DeckType`):

- **Print** — what is written on paper. System face. `screenTitle`
  26 bold, `title` 15 semibold, `subtitle` 13, `body` 15.
- **Engraving** — what is cut into hardware. Monospaced, upper-case,
  tracked. `engraved` 9.5 bold, `smallPrint` 10.5 medium, `button`
  13 bold.

Titles and names are print. Legends, counters, tabs and button
captions are engraving. A screen title is never monospaced and never
glows.

## 5. Controls

Pick the control by what it does, not by what fits:

| The thing… | Control | Component |
|---|---|---|
| does something when pressed | metal push button, symbol engraved, lamp ring | `DeckMetalButton` |
| does something and needs words | key (black) or, once per screen, card (cream) | `DeckButton` |
| has two positions | lever in a slot | `CueLeverView` (generalise when a second one is needed) |
| is one of several | selector: chips in a panel, lamp on the chosen one | `DeckChip` in `.deckPanel()` |
| is a position along something | an arm or a needle you drag by its head | `TonearmView` |
| is a list item | a sleeve (grid) or a row (list) | `SleeveView`, `DeckTrackRow` |

Rules:

- Touch targets are 44pt or more, whatever the drawn size.
- Icon-only controls are allowed only as `DeckMetalButton`, and always
  carry an accessibility label and hint.
- One `.card` button per screen. It is the brightest thing in the
  room; two of them cancel out.
- A hold shows more and commits nothing until a visible countdown
  finishes (the sleeve peek). No hidden long-press actions.

## 6. Motion and touch

`DeckMotion`: `press` for a control under a finger, `move` for a part
changing position, `settle` for something arriving or leaving, `pulse`
for a working lamp. Things arrive from somewhere (a record is flicked
into the tray, a card rises from its sleeve); nothing fades in from
nowhere. One overshoot at most.

Haptics: `selectionChanged` when a control detents or picks up,
`medium` when playback changes, `success` / `error` when a request
comes back. Nothing vibrates for decoration.

With Reduce Motion on, parts change state without travelling and lamps
light steadily instead of pulsing.

## 7. Screen anatomy

```
DeckRoom                      the wall, the lamp
  title (print, cream)        plain text on the wall — no bar
  selector panel              if the screen has sections
  content                     rows flush on the wall, or sleeves on ledges
  DeckLedge                   closes a group and names it
  tab bar                     floats; leave 104pt under the last row
```

Sheets are a walnut plinth rising from the bottom, not a grey card.

## 8. Rolling it out

One screen per change, each behind the existing `ff_turntable_home`
flag until the last one lands, so the app is never half-and-half for
someone with the flag off. Suggested order — most seen first, and
each one proves a part the next ones reuse:

1. **Library** (Liked / Downloaded / Playlists). **Done 2026-11-21.**
   Proves `DeckRoom`, the selector, `DeckTrackRow`, `DeckLedge`, the
   card button, the well as a text field. Not yet moved: the
   select-mode DONE / DELETE buttons, the storage-info sheet, and the
   swipe actions' colours.
2. **Search.** **Done 2026-11-21.** It also searches the user's
   library (`LibrarySearch`); the Library tab has no search field of
   its own. Proves the well as a live text field (lit while focused),
   a ledge as a list's header, and lamps for row state (cyan playing,
   amber pulsing while downloading). Not yet moved: the two sheets it
   opens (add to playlist, playlist preview).
3. **Queue sheet** and **mini player.** **Done 2026-11-21.** The
   sheet's head is a walnut board with the name in print and its
   actions as keys; the mini player is an anodised unit with the
   playing record, a progress ring and metal transport buttons
   (`MiniRecord`). The tab bar beside it is the same anodised unit:
   a three-position selector with a lamp under the chosen tab, and
   the collapsed player is one metal button. Not yet moved: the
   unused full-width mini player variant.
4. **Full player.** **Done 2026-11-22 (portrait).** Not restyled:
   rebuilt (`FullPlayer.deckCaseContent`, `DeckPlayerParts.swift`). It
   is THE SAME DECK AS HOME, in the same place, with a case of
   controls hinged on its front edge that swings open under it — so
   opening the player moves nothing but the case. The case holds the
   title, a backlit seek dial with the waveform and a needle, metal
   transport buttons and four switches with lamps. Volume, the
   deck/video/scope selector and the lesser-used actions are in a
   drawer. (A first version, a sleeve with the record sliding out,
   was replaced the same week.) Not yet moved: landscape, and every
   sheet the player opens.
5. **Playlist detail, Liked songs, History.** **Done 2026-11-21.**
   Reuse of 1. `PlaylistDetailView` has a sleeve, the name in print, a
   cream Play card and a Shuffle key, a "Tracks" ledge, and rows that
   are `DeckTrackRow` (amber lamp while loading or downloading, brass
   sparkle for a memory); its rename sheet has a well for the name.
   Liked songs needed no work: under the flag it is Library's Liked
   mode, and `LikedSongsContent` is only reached from the legacy Home.
   History is a sheet of the Downloads screen, so the two moved
   together (`DownloadQueueView`, `HistoryView`): readouts on
   anodised panels with lamps (amber working, yellow for failures),
   a ledge per queue state, a progress well that fills amber. The
   Share item in the playlist menu did nothing and was left out.
   `RecentlyPlayedView` is unreferenced dead code; delete it at step
   10. Not yet moved: the rename sheet is a flat board, not a walnut
   plinth, and History's per-row options still use a system
   confirmation dialog.
6. **Radio** (stations, podcasts, audiobooks). Adds a tuner dial for
   genres.
7. **Settings.** Rows with levers for toggles; needs the lever
   generalised out of `CueLeverView`.
8. **Sheets and one-offs:** create playlist, Smart Library review,
   cleanup, sleep timer, equaliser, Time Vault, Anti-Algorithm stats.
9. **Outside the app:** widgets, Live Activity, share cards. These
   compile `SharedCyberColors` and cannot use textures; they get the
   palette and type only.
10. Retire the flag, the legacy Home, and the unused parts of
    `Theme` (`NeonCard`, `NeonGlow`, `NeonTextField`).

How a screen is moved without breaking the flag-off app: it reads
`FeatureFlags.shared.turntableHome`, keeps each old drawing as a
`legacy…` twin of the new one, and sets `\.deckStyle` in the
environment so shared components (the playlist cards, for one) pick
the matching drawing. `LibraryView.swift` is the worked example.

Per screen: replace the background with `DeckRoom`, swap controls by
the table in §5, move every colour that is not a lamp to cream or
brass, then render a snapshot and compare it with the specimen.

## 9. Not decided yet

- A text field's error state (resting and focused exist).
- Toggles and sliders (the lever and the needle exist only as the
  deck's own parts).
- Light mode: the room is dark by design; nothing here has a light
  counterpart.
- Dynamic Type: the deck is drawn at a fixed design size and scaled.
  List screens must honour text size, so `DeckType` needs scaled
  variants before step 1 ships.
