# Turntable Home — Design Spec

**Date:** 2026-11-17
**Status:** Awaiting approval
**Direction:** 01 — Turntable (from the 4-direction concept board)
**Scope:** iOS app (`YAudioSystem/ios/YTAudioPlayer`), Home tab only

---

## 1. Problem

Home is currently a vertical scroll of cards: profile chip + 5 nav chips, "FOR YOU"
favorite artists, an optional "On this day" section, a Smart Library card, a cleanup
banner, and the existing `MiniPlayer` floating above the tab bar. Recent commits
(`6c7cf3b feat(ios): slim the home page, Library owns Play All / Shuffle`) deliberately
stripped Home down — so the page is short, but it is still a *list*.

The app's identity is strong elsewhere: `NeuralFreqVisualizer`, `TimeCapsuleRevealView`,
`OrbitalMenu`, `CyberPlayingBars` all have a distinct point of view. Home does not.
Home is where the app opens, and it reads as the most generic screen in the build.

**Goal:** make Home feel like hardware — specifically, a record player — so that the
first thing the user sees has the same craft as the best screens in the app.

## 2. The core idea

**The record is the home screen.**

Instead of scrolling past cards, the user looks at a platter. Whatever is playing *is*
the record on the platter. The progress bar is gone; rotation carries it. The
tonearm is the scrub control. Sleeves on the shelf below are the library. Lifting
the cue lever pauses; dropping it plays.

One metaphor, applied consistently, rather than one metaphor per section.

## 3. Why this works for this app

| Asset in the codebase | Becomes |
|---|---|
| `PlayerState.progress` (0→1) | platter rotation + tonearm angle |
| `PlayerState.playbackState` | spin / idle / paused state |
| `PlayerState.currentItem` | record label artwork, title, artist |
| `PlayerState.togglePlayPause()` | cue lever lift / drop |
| `PlayerState.seek(to:)` | tonearm scrub release |
| `NeuralFreqVisualizer` amplitude maths | VU meter row |
| `FavoriteArtistsManager` / `HomeViewModel.artistSuggestions` | sleeve crate |
| `QueueItem` list | queue stack (3 mini discs) |
| `CyberIconChip` set | fascia deck chips |

Nothing in the concept is speculative — every interactive element maps to an API
that already exists in `PlayerState`.

## 4. Screen anatomy

```
┌─────────────────────────────────┐
│ FASCIA                          │  1
│        ▮ ▮ ▮ ▮ ▮                │  ← 5 links, centred
├─────────────────────────────────┤
│ ● cue lever                      │  2
│            ╱ TONEEARM ────────● │
│           ╱                     │  3
│      ( PICTURE DISC )           │  4
│         ◉ spindle               │
│                                 │
│           ▁▃▅▂▇▃ VU strip      │  7
│         ◎ ◎ ◎ ◎  queue shelf   │
│  CRATE                           │  5
│  [A1][A2][A3][A4][A5]           │
│  [A6][A7][A8][A9][A10]          │
│  [A11][A12][A13][A14][A15]     │
│  ▬▬▬▬▬ rail                     │
└─────────────────────────────────┘
```

### 4.1 Deck fascia (1)
- Replaces `headerSection`. **No background at all** (revision 2026-11-18): no frosted
  material, no border, no shadow. The strip is a row of icons floating over the deck.
- **One row, centred.** The existing 5 `CyberIconChip` destinations (Time Capsule,
  Anti-Algorithm, Radio, Playlists, Settings) restyled as square deck buttons, with
  the two actionable indicators **as icons in the same row**, just left of Settings:
  `wand.and.stars` (amber, Smart Library review) and `trash.circle` (magenta,
  scheduled cleanup). Both appear only when there is something to act on.
- **The etched PEACEPLAYER wordmark is gone** (revision 2026-11-18).
- **The profile chip is gone** (revision 2026-11-18). The deck is a record player,
  not an account screen: the avatar, display name and sign-out sheet moved to
  **Settings**, where tapping the email row opens it. The legacy Home keeps its
  own profile chip.
- **Revision (2026-11-18):** the RPM chip and the three indicator lamps were
  removed — the record itself is the instrument, and a row of status dots above it
  was chrome. The five links moved up into row 1, where the old Home put its nav
  icons.
- **Revision (2026-11-18):** the output meter strip under the platter was
  removed, the crate's **CRATE** caption was removed, the crate's rows got more
  air between them (`rowSpacing` 10 → 20), and an idle platter now wears
  **PeacePlayer's own record art** (`Turntable/idle_art`) instead of a blank
  black disc.
- Each nav chip is a 30pt graphic inside a **44×44pt** touch target.
- The two actionable indicators are **icons in the row** now (revision 2026-11-18),
  each with the same 44×44pt touch target, and appear **only** when there is
  something to act on.
- **These must keep working** — same `HomeDestination` navigation, no new routes.

### 4.2 Cue lever (2)
- A vertical lever to the **left** of the platter. (Revision 2026-11-18: the arm
  moved to the back-right, so the lever took the left — the same arrangement as
  a Technics SL-1200.)
- **Lift = pause, drop = play.** Calls `PlayerState.shared.togglePlayPause()`.
- Animation: lever rotates 14° on lift; the platter decelerates to a stop.
- Must be a ≥44×44pt hit target even though the visible lever is ~10×46pt.

### 4.3 Tonearm (3)
- Pivots from the deck's back-**right** corner and reaches across the record, with
  the headshell travelling down the record's left-hand side. (Revision 2026-11-18:
  the pivot moved from the back-left to the back-right after a reference review —
  every real turntable mounts the arm on the right and the start/stop lever on the
  left, and an arm on the left is the single most common tell of a fake deck.)
- The arm is a rigid tube: the stylus rides a **circular arc about the pivot**, not a
  straight line, exactly as on a real deck. The angles (171.2° at rest → 142.9° at
  the end, measured from the +x axis) are calibrated so the stylus starts on the
  outer groove and finishes at the edge of the paper label; `TurntableGeometryTests`
  asserts both.
- **Drag to scrub.** The drag angle about the pivot maps to `0…1` progress; the seek is
  committed on release (`PlayerState.seek(to:)`).
- **Haptic detent every 10%** — `HapticManager.selectionChanged()`, not `.light()`.
  The audit flagged ~80 haptics in `FullPlayer` alone; keep this one sharp and
  distinct, and use `.light()` nowhere else.

### 4.4 Platter (4)
- Built outside in: machined aluminium **rim** (with 24 amber **strobe dots**) →
  **felt mat** → the **record** → the lit cyan **spindle**.
- **The record is a picture disc** (revision 2026-11-18): the album art fills the
  whole 12", the way a custom-printed record does, instead of sitting as a small
  circle on a cream label. Groove arcs, an edge vignette and a specular sheen are
  laid OVER the artwork so it still reads as pressed vinyl rather than a photo
  pasted on a circle. With no artwork the face falls back to black vinyl with the
  cream **"PEACEPLAYER"** label.
- The **sheen does not rotate with the record** — the highlight belongs to the
  room, so the record turns under a fixed light.
- The record is 270pt against a 300pt platter (0.9×), so a thin ring of green felt
  shows around it.
- **Artwork = current track's album art** via the existing `CachedAsyncImage`.
- **Rotation = playback.** `progress` drives rotation so the record turns exactly
  once per track; when paused it holds still; when idle it is blank.
- **The rotation is sampled at display rate** (revision 2026-11-18). The player's
  clock ticks at 1Hz, which made the record move in visible one-degree jumps —
  "short bursts". The platter and the tonearm now read the clock through a
  `TimelineView` at 30fps and project the clock's value forward by the
  wall-clock time since its last tick. It is still a pure function of the
  player's own position in the track.
- **Track change flips the face in 3D** (revision 2026-11-18): the outgoing
  artwork rotates away around the vertical axis while the incoming artwork rotates
  in. The flip is keyed on the **track**, not the artwork URL — two consecutive
  tracks can share a cover and the record still has to flip.
- Tap the platter → open the full player (`PlayerState.showFullPlayer = true`).
- Long-press the platter → open the queue stack (existing `showQueue` / `DownloadQueueView`).

### 4.5 Sleeve crate (5)
- **Three rows** of album-art sleeves (56pt, five across) for favourite-artist
  suggestions (revision 2026-11-18: a single row read as a shelf, not a crate).
- **Every row stands on its own rail** — the walnut slat a row of records rests
  on. A single rail under the whole crate read as a stand waiting for rows that
  never came.
- The rows live in one vertical scroll, so the deck stays one screen tall: three
  rows at a time, and you flip down through the rest the way you would work
  through a bin of records.
- Rows are centred, so a short last row sits in the middle of the crate rather
  than hanging off the left.
- The crate's contents are the suggestions **plus the queue and the
  recently-played shelf** — the suggestions alone rarely fill three rows, and a
  half-empty crate made the deck look broken.
- Tapping a sleeve plays it; long-press offers "Add to queue".

### 4.6 Queue shelf
- A horizontal shelf of up to **12 mini picture discs** under the platter
  (revision 2026-11-18: was three plain discs; each is now a small record with the
  track's album art printed across it, and the shelf holds twelve).
- The current track's disc is ringed in cyan and sits slightly larger; the others
  are dim vinyl.
- Tapping a disc jumps to it. Hidden entirely when the queue is empty.

### 4.7 VU meter (7)
- A slim peak-meter strip recessed into the plinth under the platter, reusing
  `AudioVisualizerEngine`'s bands and `LevelMeterRow`'s bar logic.
- **The now-playing strip was removed** (revision 2026-11-18) — it was a second
  copy of what the record and the arm already say, and the user asked for the
  bottom row of Home to go. The deck's now-playing surfaces are now: the artwork
  on the record, the arm's position, and tap-the-platter → full player.
- `MiniPlayer` is still hidden on Home (§7.1) — the deck replaced the strip's
  role, so the global `BottomBar` must not also show it there.

### 4.8 Revision 2026-11-19 — the deck as an object

This revision supersedes the layout details in §4.2–§4.6 where they differ.

- **Plinth.** The deck is one walnut plinth (`TurntableDeckView`, 366×336 design
  size, scaled to fit). The platter sits left of centre; the corners hold the 45
  adapter (back-left), the arm pivot (back-right) and the cue lever (front-left).
- **Tonearm geometry is a real deck's.** Pivot off the platter at the back-right,
  arm 13pt longer than pivot-to-spindle (overhang), so the arm runs down the
  right-hand side and the stylus plays the front-right quadrant: 103.7° at the
  lead-in → 129.1° at the label. The headshell is cranked 24° so the cartridge lies
  along the groove. The arm no longer crosses the artwork.
- **Three arm positions:** parked in its rest (nothing loaded), lifted (loaded, not
  playing), needle down (playing). The cue lever lifts and drops the arm.
- **Only the headshell takes a drag.** The arm's touch area used to cover the whole
  platter, so a tap on the record seeked instead of opening the player. The drag is
  relative (the arm never jumps to the finger) and shows the time under the needle.
- **The record turns once every 8 seconds of audio**, not once per track. Still a
  function of playback position (`PlatterGeometry.rotation(forProgress:duration:)`);
  the drawn angle eases toward it (`PlatterGeometry.follow`) so clock ticks, seeks
  and pauses never show as a jump. The strobe band turns with the platter; grooves
  and light stay still.
- **Loading is visible:** an amber lamp runs round the platter edge and the pilot
  lamp pulses while a track is fetched or buffering.
- **Queue tray.** A window of the queue that follows the current record
  (`QueueShelf.window`), auto-scrolled, with a `+N` slot that opens the full queue.
- **Shelves.** One ledge per favourite artist (the user's order) plus "Recently
  played", each with a card naming it (`TurntableHomeModel.shelves`). The queue no
  longer tops up the shelves. Sleeves shrink on narrow phones so five always fit.
- **The room** picks up the playing record's colours behind the deck.

## 5. Visual language

New tokens live in a dedicated file so the existing cyberpunk palette is not
mutated — the widgets extension also consumes `SharedCyberColors`, and Home must
not break them.

```
TurntableTokens
  walnut      #3B2A1E   deck body, rails
  aluminium   #C9C6BE   tonearm, pivot, deck buttons
  cream       #F3EDE0   label card, sleeve text
  felt        #2F4034   sleeve edge, crate interior
  amberLamp   #F0A92B   active state, strobe dots, cue lever head
```

Rule: **warm hardware tones carry the surface, cyan and magenta stay the only
neon.** Existing `Theme.cyberCyan` / `cyberMagenta` / `cyberYellow` remain the
signal colours so the player, the widgets, and Home still agree.

Typography: keep `Typography.sectionHeader` / `playerTitle` / `playerArtist`.
Add nothing new to `Typography` — the deck reuses the monospaced section header
for its labels, which is already the app's voice.

## 6. State machine

```
IDLE ──play──▶ SPINNING ──pause──▶ PAUSED
  ▲               │                    │
  │            scrub                  │ resume
  │               ▼                    │
  └─────────── SCRUB ──────────────────┘

TAP PLATTER:        → FULL PLAYER
CRATE / QUEUE TAP:  → TRACK CHANGE (3D face flip)
LONG-PRESS PLATTER: → QUEUE STACK overlay
TRACK CHANGE:       → 3D FACE FLIP (new artwork rotates in)
```

Rotation is a pure function of `PlayerState.progress`; there is no independent
animation clock, so pausing or seeking is always visually consistent with audio.
This is the single most important correctness property of the design.

### 4.9 Revision 2026-11-19 (b) — after the first run on the phone

Asked for after trying the deck with real music:

- **Tray.** The records are clipped to the channel's own shape, so
  nothing shows outside the pill. The tray follows the song: the
  current record is brought back to the leading third whenever the
  track changes, including after the tray has been scrolled by hand.
- **Now-playing line.** One line between the deck and the tray —
  title, then artist. This reverses the earlier "no now-playing strip"
  decision, at the user's request; it is a caption, not a control.
- **Spacing.** More air between the tray and the first shelf, and
  between one shelf and the next (`CrateGrid.rowSpacing` 16 → 30).
- **Liked songs.** A last shelf of the user's liked songs (up to ten).
  It is exempt from the one-shelf-per-track rule: liked songs are the
  ones played most, and thinning the shelf by "recently played" would
  leave it bare. Not put up when nothing is liked.
- **Hold to look.** Holding a sleeve raises a card above it — cover,
  title, artist, album, running time — and letting go puts it back. A
  tap still plays. This replaces the system context menu. "Add to
  queue" is reached by keeping the hold: after a second a ring on the
  card closes over a further 1.1s, and when it does the record is
  queued (also a VoiceOver action). The hold is read off the button's pressed state:
  a long-press gesture on the sleeve stopped the shelves scrolling.

### 4.10 Revision 2026-11-20 — the icons become keys

The row of icons over the deck is gone. Asked for by the user.

- **Front panel.** The plinth is 56pt taller (366×392) and carries a
  black anodised panel along its front edge with three keys: DIG,
  RADIO, SETUP (`DeckKeysView`). Each has a pilot lamp and a legend
  that lights: dark at rest, lit while what it starts is running,
  pulsing while the deck is working. The removed icon row gives the
  height back, so the tray and shelves sit where they did.
- **DIG** replaces the Anti-Algorithm icon and its screen's "Start
  Exploring" step. One press re-deals the queue: the records in the
  tray spin on a wave and a light runs along the channel while the
  engine looks; the queue is then REPLACED (it used to be appended
  to) and the new records are flicked into the tray as their streams
  resolve. The playing record is kept as the queue's first item until
  the first new one starts. Pressing again deals again. With no
  listening history, or when nothing comes back, the caption line says
  so. The lamp stays lit only while a dealt record is playing. The
  old Anti-Algorithm screen (stats, End) is still reachable from the
  full player.
- **RADIO** and **SETUP** push the existing Radio and Settings screens
  onto Home's NavigationStack. RADIO is lit while a live station plays.
- **Time Vault** has no entry point on the turntable Home any more.
- **Playlists** moved to the Library tab as a third section beside
  Liked and Downloaded (`PlaylistsContent`, shared with the old
  screen). The section picker now sits above Library's empty state, so
  an empty Downloaded list no longer hides the other sections.
- The Smart Library and cleanup indicators are the only things left
  above the deck, and the row is drawn only when one is pending.

### 4.11 Revision 2026-11-21 — metal buttons, review, design system

- The three captioned keys and their black panel are replaced by four
  round machined-aluminium push buttons set straight into the walnut
  (`DeckMetalButton`), with no captions: dig (magenta ring), radio
  (cyan), review (yellow), setup (amber). The ring is the lamp.
- **Review** takes over the last icon above the deck. It opens the
  Smart Library auto-download review, or the scheduled cleanup if that
  is all that is waiting; its ring is lit while either is pending.
  With nothing pending the caption line says so. `DeckFasciaView` is
  deleted; nothing floats over the deck any more.
- The deck's look is written up as a design system for the rest of
  the app: `docs/design/deck-design-system.md`, with its components in
  `DesignSystem/DeckKit.swift`. The tray's channel and the shelf cards
  now use those components.

### 4.12 Revision 2026-11-22 — one thing in each corner

Asked for by the user. The plinth's four corners each hold one thing:

- **Back-left:** the setup (Settings) button, replacing the 45
  adapter, which did nothing.
- **Back-right:** the arm's pivot, as before.
- **Front-left:** the cue lever, moved down into the corner.
- **Front-right:** dig, radio and review as a triangle sitting into
  the corner (dig above review, radio to their left).

The row of four buttons along the front is gone and the plinth is 8pt
shorter (366×384).

### 4.13 Revision 2026-11-22 (b) — rest, record change, browsing

- **Arm rest.** The rest post stood on the pivot-to-stylus line, which
  the S-shaped tube does not follow, so a parked arm hung beside it.
  The post is now placed from the tube's own curve
  (`TonearmGeometry.restOffset`).
- **Record change.** Changing song is choreographed over the second it
  takes to buffer: the arm lifts and swings clear (0–0.3s), the old
  record is lifted off and the new one set down (0.3–0.9s), the arm
  comes back (from 0.92s). The in-place 3D flip is gone. Putting the
  first record on, or taking the last off, skips it. Reduce Motion
  swaps at once.
- **Browsing the tray.** One record is in focus: in the middle of the
  tray, 1.2× the size, named by the caption. At rest that is the one
  playing. Swiping moves the focus (the tray snaps record by record)
  without changing the music; the caption shows the focused record
  with its place in the queue ("7/20") instead of the playing mark.
  Tap plays. Five seconds after the last swipe, or when the song
  changes, the tray swings back. The cyan ring always marks the record
  that is playing.

### 4.14 Revision 2026-11-22 (c) — glow follows focus; the case

- The tray's lit cyan ring and glow are on the record in FOCUS, and
  move with it while browsing. The record that is playing keeps a
  thin unlit ring so it can still be found.
- Tapping the record opens the full player as this deck with its case
  open: the deck does not move, the case of controls swings down
  under it. Tapping the record again, the latch, or a pull down shuts
  it. Keys pressed on the deck there shut the case and are handed to
  Home (`.deckKeyPressed`).

## 7. Resolved decisions (2026-11-17, Vergil)

All three open questions were answered during design review.

### 7.1 MiniPlayer — the strip replaces it on Home

**Decision:** the deck's now-playing strip replaces `MiniPlayer` while the user is on
the Home tab. `MiniPlayer` is unchanged on every other tab.

**Implementation note (non-obvious):** `MiniPlayer` is **not** inside `HomeView`.
It is rendered by `ContentView`'s global `BottomBar`, which sits in a
`.safeAreaInset(edge: .bottom)` on the `TabView` and therefore appears on every
tab (`ContentView.swift:83-95`, `BottomBar` at `ContentView.swift:374`).
Hiding it on Home therefore has to be done at that level, not in `HomeView`:

- `BottomBar` gains a `hidesMiniPlayer: Bool` parameter.
- `ContentView` passes `hidesMiniPlayer: selectedTab == 0 && turntableHomeEnabled`.
- The flag is read through an `ObservableObject` so flipping it in Settings → Labs
  takes effect without a relaunch (see §7.3).

`BottomBar` must then centre the tab pill when the mini player is hidden — it
already has that branch for the "nothing playing" case, so the work is to reuse it.

`MiniPlayer` also owns the swipe-to-collapse gesture and the full-player expansion.
On Home the deck replaces that role: tapping the **platter** opens the full player
(`PlayerState.showFullPlayer = true`), and the deck's own transport controls
(tonearm, cue lever) replace the mini player's buttons.

### 7.2 Existing Home sections — actionable cards become fascia indicators

**Decision:**

| Existing section | New home |
|---|---|
| `SmartLibraryCard` | fascia indicator lamp (amber when candidates pending) → opens the existing `SmartLibraryReviewSheet` |
| `CleanupScheduledBanner` | fascia indicator lamp (magenta when a cleanup is scheduled) → opens the existing `CleanupReviewSheet` |
| "On this day" (`OnThisDaySection`) | a special sleeve in the crate, pinned first, visually distinct (cream sleeve with the date) |
| "FOR YOU" favorite artists | the sleeve crate itself — the sleeves *are* the suggestions |

The two actionable cards were previously the most important decision surfaces on
Home ("the user sees the actionable surface first"). They cannot be cards on a
deck, so they become **lamps on the fascia**: small, always visible, and they light
up only when they need attention. This preserves the "actionable first" property
without spending screen space.

`SmartLibraryCard` and `CleanupScheduledBanner` already self-hide when their
manager state is nil, so the lamps can reuse the exact same state check and stay
in sync automatically — no new plumbing.

### 7.3 Scope — flag-gated behind Settings → Labs

**Decision:** ship as `ff_turntable_home`, default **OFF**, with a toggle in
Settings → Labs. The current Home remains the fallback.

**Implementation note:** `SettingsView` already has a `Labs` section and a private
`LabsToggle` row component (`SettingsView.swift:502-548`, `1303+`). The new
toggle is one more `LabsToggle` entry — no new settings infrastructure.

The flag must be **reactive**, not read once at launch. `ff_on_this_day` is read
inline at render time (`HomeView.swift:89`), which works because it is checked on
every body evaluation; the turntable flag must work the same way, but the switch
also needs to hide `MiniPlayer` in `ContentView`, which does not re-render on
`UserDefaults` changes. So:

- Add a small `FeatureFlags: ObservableObject` in `DesignSystem/` that publishes
  `@Published var turntableHome: Bool` backed by `UserDefaults`.
- `SettingsView`'s `LabsToggle` for this key writes through to it (the existing
  `LabsToggle` has an `onChange` hook for exactly this — see the `ff_daily_recap`
  entry, which uses it to reset the notifier's state).
- Both `HomeView` and `ContentView` observe it.

This avoids the bug where the user toggles the flag in Settings, returns to Home,
and the deck has not appeared (or `MiniPlayer` is still showing) because the flag
was cached in a `@State` initialiser.

Default OFF also means the current Home's behaviour is byte-for-byte unchanged for
existing users until they opt in — which is the safe default for a full visual
replacement of the app's entry screen.

## 8. Implementation shape

New files under `ios/YTAudioPlayer/`:

```
DesignSystem/TurntableTokens.swift
DesignSystem/FeatureFlags.swift             reactive flag store (ff_turntable_home)
Views/Turntable/TurntableHomeView.swift      root, replaces HomeView body
Views/Turntable/DeckFasciaView.swift         lamps, greeting, RPM chip, nav chips
Views/Turntable/PlatterView.swift            grooves, label, spindle, rotation
Views/Turntable/TonearmView.swift            drag gesture, detents, angle
Views/Turntable/CueLeverView.swift           play/pause
Views/Turntable/SleeveCrateView.swift        sleeves, drag-to-platter
Views/Turntable/QueueStackView.swift         mini discs
Views/Turntable/LevelMeterRow.swift          VU bars
```

Files modified (not created):

```
Views/HomeView.swift         body branches on the flag; keeps NavigationStack,
                             HomeDestination, notification handling
Views/ContentView.swift      BottomBar gains hidesMiniPlayer
Views/SettingsView.swift     one more LabsToggle for ff_turntable_home
```

`HomeView` keeps its `NavigationStack`, `HomeDestination` enum, and notification
handling (`.startSongRadio`, `.openRadioView`); only the body swaps. That keeps
every existing route reachable and avoids nested-`NavigationStack` crashes that
the codebase has already hit twice.

**Ordering constraint:** the deck's bottom edge must clear the `BottomBar`'s
`rowHeight` (60pt) + the tab pill. The current `HomeView` already reserves
`.padding(.bottom, 100)` for this; the turntable layout must reserve the same.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Rotation janks against the audio clock | Drive angle from `progress` only; no `CADisplayLink`, no independent timer |
| Drag-to-platter conflicts with scroll | Sleeve drag uses a directional threshold; the shelf sits outside the vertical scroll container |
| Haptic flood (audit finding) | One `selectionChanged()` per 10% detent; nothing else |
| Off-palette colour creep | All new colours in `TurntableTokens`; no raw `.red` / `.orange` / `.systemGray` |
| Dynamic Type overflow on the fascia | Fascia labels use `Typography.sectionHeader` (Dynamic Type aware); the deck chips are fixed-size, labels truncate |

## 10. Acceptance criteria

1. Rotating platter visibly tracks audio progress, and stops within one frame of pause.
2. Tonearm drag scrubs audio within 100 ms of release.
3. Cue lever lifts and drops correctly, including when audio is interrupted.
4. Every existing `HomeDestination` remains reachable from the fascia.
5. No new raw system colours; every colour resolves to `TurntableTokens` or `Theme`.
6. Dark-mode only, matches the rest of the app.
7. All new touch targets ≥ 44×44pt.
8. `prefers-reduced-motion` respected: platter rotation replaced by a static label,
   no decorative animation.
9. With `ff_turntable_home` OFF, the current Home renders exactly as it does today,
   and `MiniPlayer` is present in the `BottomBar`.
10. With the flag ON and `selectedTab == 0`, `MiniPlayer` is hidden and exactly one
    now-playing surface (the deck strip) is visible.
11. Toggling the flag in Settings → Labs takes effect on returning to Home without
    an app relaunch.
12. `SmartLibraryCard` and `CleanupScheduledBanner` state changes light their
    corresponding fascia lamp within one render cycle.
13. **Tapping a crate record must never block the main thread.** The audio tap's
    track lookup is async (`loadTracks(withMediaType:)`); the synchronous
    `AVAsset.tracks(withMediaType:)` froze the app long enough for iOS to
    watchdog-kill it (2026-11-18).
14. **The deck follows playback started elsewhere.** The record and the shelf of
    upcoming discs update when the queue changes in another tab, a shortcut or a
    notification — the deck observes the queue store, not just `PlayerState`.
15. **Every cover loads.** The image cache delivers the downloaded artwork to the
    view that asked for it; covers do not sit on their placeholder.

## 11. Reference

Visual spec: `docs/concepts/turntable-home-design.html` (animated, annotated).
Concept board (all 4 directions): `../../analysis/home-ui-concepts.html`.
