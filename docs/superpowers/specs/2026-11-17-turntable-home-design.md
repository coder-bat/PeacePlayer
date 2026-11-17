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
│  ● ● ●   NIGHT   [33⅓]   ▮ ▮ ▮  │
├─────────────────────────────────┤
│                                 │
│           ╱ TONEEARM  ───────● │  2 cue lever
│          ╱                      │  3
│      ( PLATTER )                │  4
│         ◉ label                 │
│                                 │
│         ○ ○ ○   queue stack     │
│  [A1][A2][A3][A4]  sleeve crate │  5
│  ▬▬▬▬▬ rail                     │
│  Midnight Signal      ▁▃▅▂▇▃    │  7 VU
└─────────────────────────────────┘
```

### 4.1 Deck fascia (1)
- Replaces `headerSection`. Brushed-metal strip, rounded, dark walnut gradient.
- Three indicator lamps on the left (amber / cyan / magenta) — decorative state
  echoes; amber = playing, cyan = connected, magenta = queue has content.
- `NIGHT` greeting text (reuse `HomeViewModel.greeting`, already time-based).
- **RPM chip (6)** — `33⅓` / `45`, tappable. Maps to playback rate 1.0× / 1.25×
  via `PlayerState.setPlaybackRate(_:)`.
- Right side: the existing 5 `CyberIconChip` destinations (Time Capsule,
  Anti-Algorithm, Radio, Playlists, Settings), restyled as square deck buttons.
  **These must keep working** — same `HomeDestination` navigation, no new routes.

### 4.2 Cue lever (2)
- A vertical lever to the right of the platter.
- **Lift = pause, drop = play.** Calls `PlayerState.shared.togglePlayPause()`.
- Animation: lever rotates 14° on lift; the platter decelerates to a stop.
- Must be a ≥44×44pt hit target even though the visible lever is ~10×46pt.

### 4.3 Tonearm (3)
- Pivots from the upper right, arm reaching over the platter edge.
- **Drag to scrub.** Horizontal drag maps to `0…1` progress; a `DragGesture` with
  `@GestureState` drives the live angle, and the seek is committed on release
  (`PlayerState.seek(to:)`).
- **Haptic detent every 10%** — `HapticManager.selectionChanged()`, not `.light()`.
  The audit flagged ~80 haptics in `FullPlayer` alone; keep this one sharp and
  distinct, and use `.light()` nowhere else.
- Angle range: ~19° (start) to ~52° (end of side).

### 4.4 Platter (4)
- Concentric groove rings, magenta label, cyan spindle light at the centre.
- **Label artwork = current track's album art** via the existing `CachedAsyncImage`.
- **Rotation = playback.** `progress` drives rotation so the record turns exactly
  once per track; when paused it holds still; when idle it is blank.
- Tap the spindle → toggle 33/45.
- Long-press the platter → open the queue stack (existing `showQueue` / `DownloadQueueView`).

### 4.5 Sleeve crate (5)
- Horizontal row of album-art sleeves (64pt) for favourite-artist suggestions.
- **Drag a sleeve up onto the platter to play it.** This is the primary
  "browse → play" gesture and replaces the "FOR YOU" track list.
- Tapping a sleeve plays it directly (accessibility fallback for the drag).
- Drag threshold uses `DragGesture` with a translation check — no long-press needed.

### 4.6 Queue stack
- Three mini discs under the platter, coloured by the magenta / cyan / amber palette.
- Shows queue depth. Long-press on the platter reveals it; tapping a disc jumps to it.
- Hidden entirely when the queue is empty.

### 4.7 Now-playing strip + VU meter (7)
- Title + artist in the existing `Typography.playerTitle` / `playerArtist` tokens.
- VU meter = live amplitude bars, reusing `NeuralFreqVisualizer`'s colour ramp
  and bar logic.
- **This strip replaces `MiniPlayer` on Home.** If `MiniPlayer` stays, the two
  would show the same track twice — see §7 Open Question 2.

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
  amberLamp   #F0A92B   active state, RPM chip, cue lever head
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

TAP SPINDLE:        SPINNING ⇄ 45 RPM (rate 1.0 ↔ 1.25)
LONG-PRESS PLATTER: → QUEUE STACK overlay
```

Rotation is a pure function of `PlayerState.progress`; there is no independent
animation clock, so pausing or seeking is always visually consistent with audio.
This is the single most important correctness property of the design.

## 7. Open questions (need your call before implementation)

1. **Does `MiniPlayer` survive?** The now-playing strip (4.7) and `MiniPlayer` would
   show the same track twice. Options: (a) strip replaces `MiniPlayer` on Home,
   (b) strip shows only VU + queue depth, no title. *Recommendation: (a).*
2. **What happens to the existing Home sections** — "FOR YOU" favorite artists,
   Smart Library card, cleanup banner, "On this day"? They cannot all fit on a
   deck. Options: (a) keep Smart Library + cleanup as sheets behind fascia
   indicators, (b) drop them from Home entirely (Library already owns most of
   this), (c) move "On this day" into the sleeve crate as a special sleeve.
   *Recommendation: (a) for the two actionable cards, (c) for "On this day".*
3. **Scope of the first build.** Full swap of Home vs. a flag-gated variant
   (`ff_turntable_home`, same pattern as the existing `ff_on_this_day` flag).
   *Recommendation: flag-gated, so it ships behind Settings → Labs and the
   current Home stays the fallback.*

## 8. Implementation shape

New files under `ios/YTAudioPlayer/`:

```
DesignSystem/TurntableTokens.swift
Views/Turntable/TurntableHomeView.swift      root, replaces HomeView body
Views/Turntable/DeckFasciaView.swift         lamps, greeting, RPM chip, nav chips
Views/Turntable/PlatterView.swift            grooves, label, spindle, rotation
Views/Turntable/TonearmView.swift            drag gesture, detents, angle
Views/Turntable/CueLeverView.swift           play/pause
Views/Turntable/SleeveCrateView.swift        sleeves, drag-to-platter
Views/Turntable/QueueStackView.swift         mini discs
Views/Turntable/LevelMeterRow.swift          VU bars
```

`HomeView` keeps its `NavigationStack`, `HomeDestination` enum, and notification
handling (`.startSongRadio`, `.openRadioView`); only the body swaps. That keeps
every existing route reachable and avoids nested-`NavigationStack` crashes that
the codebase has already hit twice.

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

## 11. Reference

Visual spec: `docs/concepts/turntable-home-design.html` (animated, annotated).
Concept board (all 4 directions): `../../analysis/home-ui-concepts.html`.
