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
│  NIGHT ALEX        ▮ ▮ ▮ ▮ ▮    │  ← 5 links, top right
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
- Replaces `headerSection`. Brushed-metal strip, rounded, dark walnut gradient.
- **One row.** The profile chip (owned by `HomeView`, so the avatar picker stays
  there) on the left; the existing 5 `CyberIconChip` destinations (Time Capsule,
  Anti-Algorithm, Radio, Playlists, Settings) in the **top-right corner**, restyled
  as square deck buttons.
- **Revision (2026-11-18):** the RPM chip and the three indicator lamps were
  removed — the record itself is the instrument, and a row of status dots above it
  was chrome. The five links moved up into row 1, where the old Home put its nav
  icons.
- Each nav chip is a 30pt graphic inside a **44×44pt** touch target.
- The two actionable lamps (Smart Library, scheduled cleanup) keep a full 44×44pt
  touch target and appear on a second row **only** when there is something to act
  on, so the strip normally stays a single row.
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
- The record is 288pt against a 320pt platter (0.9×), so a thin ring of green felt
  shows around it.
- **Artwork = current track's album art** via the existing `CachedAsyncImage`.
- **Rotation = playback.** `progress` drives rotation so the record turns exactly
  once per track; when paused it holds still; when idle it is blank.
- **Track change flips the face in 3D** (revision 2026-11-18): the outgoing
  artwork rotates away around the vertical axis while the incoming artwork rotates
  in. The flip is keyed on the **track**, not the artwork URL — two consecutive
  tracks can share a cover and the record still has to flip.
- Tap the platter → open the full player (`PlayerState.showFullPlayer = true`).
- Long-press the platter → open the queue stack (existing `showQueue` / `DownloadQueueView`).

### 4.5 Sleeve crate (5)
- **Three rows** of album-art sleeves (64pt, five across) for favourite-artist
  suggestions (revision 2026-11-18: a single row read as a shelf, not a crate).
- The rows live in one vertical scroll, so the deck stays one screen tall: three
  rows at a time, and you flip down through the rest the way you would work
  through a bin of records.
- The grid is centred — each sleeve is centred in its cell.
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
LONG-PRESS PLATTER: → QUEUE STACK overlay
TRACK CHANGE:       → 3D FACE FLIP (new artwork rotates in)
```

Rotation is a pure function of `PlayerState.progress`; there is no independent
animation clock, so pausing or seeking is always visually consistent with audio.
This is the single most important correctness property of the design.

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

## 11. Reference

Visual spec: `docs/concepts/turntable-home-design.html` (animated, annotated).
Concept board (all 4 directions): `../../analysis/home-ui-concepts.html`.
