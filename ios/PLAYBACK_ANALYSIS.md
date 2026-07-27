# iYMusic iOS Playback System — Code Review Report

**Scope:** `ios/YTAudioPlayer/Models/PlayerState.swift` (2959 lines), `ios/YTAudioPlayer/Models/QueueStore.swift`, `ios/Sources/PlaybackQueueManager.swift`, `ios/Sources/CrossfadeManager.swift`, `ios/YTAudioPlayer/Models/AudioSessionController.swift`, plus relevant call sites.

**Status:** investigation complete; P0/P1 items fixed in commit `88c6de9`. P2 items remain for the action plan.

---

## TL;DR

`PlayerState` is a 2959-line god object that owns queue, AVPlayer, gapless, crossfade, audio-session callbacks, listening-time accounting, and remote-control updates. The most impactful bugs are: (1) `isHandlingCompletion` race that lets a user-tap skip a track, (2) `enqueueUpcomingItemsForGapless` appending duplicates into the AVQueuePlayer, (3) `expectedDuration` direct writes that bypass the focused `playbackClock` so the scrubber goes stale, (4) a dead JSON queue-persistence layer in `DataManager` that drifts from the CoreData truth, and (5) a `clearQueue` that doesn't stop the player, leaving "playing" with no audio.

---

## 1. `PlayerState` — the 2959-line god object

### 1.1 Critical race: `isHandlingCompletion` is not actually thread-safe (FIXED 88c6de9)

The flag was read from `nextTrack` and `playerDidFinishPlaying` (main) and written from `handleTrackCompletion` (the `completionQueue` serial queue). It is a plain `Bool` without a lock, barrier, or atomic wrapper.

**Concrete repro:** Track 5 is 0.5s from end. User taps Next. User-press path runs `nextTrack(userSkipped: true)` on main before the `.AVPlayerItemDidPlayToEndTime` fires. The user call proceeds. Half a frame later the notification fires, sets `isHandlingCompletion = true`, and re-dispatches `nextTrack()` to main. Result: **two `nextTrack` calls** — the user's `nextIndex+1` and then the auto-advance to `nextIndex+2`.

**Fix applied (88c6de9):** added a `userSkippedPendingCompletion` flag. `nextTrack(userSkipped: true)` sets it; `handleTrackCompletion` checks it and bails if set; `play(item:)` clears it. The user hears their chosen N+1, not the auto-advance to N+2.

### 1.2 Two completion triggers, no dedup (still latent)

`PlayerState.swift:2689-2702` (Trigger B: polling-based end detection in `updateProgress`) and `PlayerState.swift:2722-2794` (Trigger A: `.AVPlayerItemDidPlayToEndTime`) both end up at `handleTrackCompletion`. The `guard !isHandlingCompletion` (2836) deduplicates only because `completionQueue` is serial. If someone ever changes the queue to concurrent, the guard breaks.

The bigger problem: the `updateProgress` end-detection at 2689 fires when `current >= effectiveTotal - 0.5`. The `effectiveDuration` is the metadata duration from the track. For streams where the metadata duration is accurate, this fires ~0.5s before the actual AVPlayer end, racing with the AVPlayer's natural end notification. **Symptom:** the next track starts a half-second before the previous one actually ends.

### 1.3 Gapless path: missing `updateExpectedDuration` call (FIXED 88c6de9)

`PlayerState.swift:1977` (gapless `nextTrack`):

```swift
queueStore.setCurrentIndex(nextIndex)
let nextItem = queueStore.items[nextIndex]
expectedDuration = Double(nextItem.track.durationSeconds)   // <-- direct write
```

Compare to every other path (`play(item:)` at 942, `playQueue(at:)` at 1321, crossfade at 2091, restoreQueue at 578): they all go through `updateExpectedDuration(...)`, which also pushes to `playbackClock.setExpectedDuration(...)`.

**`playbackClock.setExpectedDuration` was never called on gapless transitions.** After a gapless auto-advance, the scrubber's denominator stayed at the old track's duration. The progress bar visibly compressed/expanded when crossing into the next track. `advanceGaplessState` at 2197-2226 had the same omission.

**Fix applied (88c6de9):** both the gapless `nextTrack` (1977) and `advanceGaplessState` (2210) now go through `updateExpectedDuration(...)`.

### 1.4 Gapless re-enqueue duplicates `AVPlayerItem`s in the player (FIXED 88c6de9)

`PlayerState.swift:2160-2191` (`enqueueUpcomingItemsForGapless`):

```swift
queuePlayer.insert(nextPlayerItem, after: queuePlayer.items().last)
```

Called from three places: `play(item:)` (1013), `nextTrack` gapless branch (1982), and `advanceGaplessState` (2225). It always appended after `.last`, never cleared what was already in the AVQueuePlayer. After 3 auto-advances in a row, the user heard the same track 2-3× in a row.

**Fix applied (88c6de9):** `enqueueUpcomingItemsForGapless` now removes every queued item after the current one before re-enqueueing. The AVQueuePlayer's items array stays bounded to `[current, next, next+1, next+2]`.

### 1.5 First-track-after-launch gapless pre-queue is a no-op (still latent)

`PlayerState.swift:946-953` then `1012-1014` then `2160-2191`:

For a single-track play (`play(track:)` from a Home recommendation or search), the queue is freshly populated with 1 item, `currentIndex = 0`, then `enqueueUpcomingItemsForGapless` runs:

```swift
let queueCount = queue.count
guard queueCount > 1 else { return }
```

It bails immediately. The actual auto-advance path then has to round-trip through `advanceGaplessState → enqueueUpcomingItemsForGapless` to populate the AVQueuePlayer.

**Edge case:** the first track of any session plays, ends, and the auto-advance to the prefetched next track happens through the non-gapless `nextTrack` path because the AVQueuePlayer's items array only had `[track0]`. Make `play(item:)` call `enqueueUpcomingItemsForGapless` *after* `QueuePrefetcher` populates the queue, or have `QueuePrefetcher` enqueue directly into the AVQueuePlayer.

### 1.6 Gapless "Next" branch updates UI before AVFoundation has switched (FIXED 88c6de9)

When the user presses Next with gapless on, `advanceToNextItem()` is called after `dataManager.addToRecentlyPlayed(...)` and `NotificationCenter.default.post(name: .trackPlayed, ...)`. The recently-played entry was recorded *before* the track had actually started.

Also `NotificationCenter.default.post(name: .trackPlayed, ...)` on line 1979 happened twice for the same transition: once here, then again inside `advanceGaplessState` (line 2210) when the AVQueuePlayer naturally auto-advances. Listeners subscribed to `.trackPlayed` saw duplicate events.

The recently-played / .trackPlayed duplication is still latent. Listeners should dedup; or the call should be removed from one of the two paths.

### 1.7 `play(item:)` double audio-session activation (still latent)

`PlayerState.swift:807-808` and `928-935`: `audioSessionController.activate()` is called, then `try AVAudioSession.sharedInstance().setActive(true)` is called from inside `play(item:)` itself. The second direct call bypasses the controller and reaches into `AVAudioSession.sharedInstance()` from `PlayerState`. Both are idempotent but a failure in the second call prints to console and the controller never knows.

### 1.8 `removeFromQueue` mid-gapless: AVQueuePlayer / store desync (FIXED 88c6de9)

`PlayerState.swift:1891-1913` — the store was updated, but the `AVQueuePlayer`'s already-enqueued items were not. The AVQueuePlayer kept playing the removed track; `advanceGaplessState` at 2197-2202 returned early; `currentIndex` became stale; next user-tap of Next jumped to the wrong place.

**Fix applied (88c6de9):** `removeFromQueue` now also removes the matching `AVPlayerItem` from the gapless `AVQueuePlayer` by URL match.

### 1.9 `clearQueue` doesn't stop the player (FIXED 88c6de9)

`PlayerState.swift:1922-1926`:

```swift
func clearQueue() {
    queueStore.clear()
}
```

If the user cleared the queue while a track was playing, the player kept playing the current track, but `currentIndex == -1` and the queue was empty. When the track ended, `playerDidFinishPlaying` fired, `nextTrack` was called, `queue.isEmpty` was true and it returned. The `AVPlayerItem` was in `.readyToPlay` paused state, but `playbackState` was still `.playing`. **Symptom:** UI shows "playing" with no audio.

**Fix applied (88c6de9):** `clearQueue` now calls `stop()` and sets `currentItem = nil`.

### 1.10 `previousTrack` doesn't support "restart current" via the normal tap pattern (still latent)

`PlayerState.swift:2276-2292` — most music apps (Apple Music, Spotify) treat the *first* prev-press within 3 seconds as "restart current track" rather than "go to previous". Here it's strictly `currentIndex - 1`, so if you're 10 seconds into track 5, pressing Prev skips to track 4 instead of restarting track 5. Not a bug per se, but a UX inconsistency.

### 1.11 `applyVolume` ignores `playbackRate` setting; replay-gain path is a one-line bug (FIXED 88c6de9)

`PlayerState.swift:609-612` (`resumeFromInterruption`):

```swift
private func resumeFromInterruption() {
    player?.play()
    player?.rate = playbackRate
}
```

Calls `play()` (which starts at rate 1.0) then sets `rate = playbackRate` on the next line. 1-frame rate race. Audible pop/glitch on resume at 1.5x.

**Fix applied (88c6de9):** `resumeFromInterruption` now uses `player.playImmediately(atRate: Float(playbackRate))`. The S17-E fix for the same race was already in `performSeamlessQualitySwitch`; now propagated here.

### 1.12 `nextTrack` BG task can leak in the autoplay-success case (still latent)

`PlayerState.swift:2027-2029` — when the queue is exhausted and `autoplayNextFromRecentlyPlayed` returns a candidate, the BG task is acquired at `nextTrack` line 1932, but if the user navigates away or calls `playRadioStation` / `playPodcastEpisode` between the autoplay call and the new track's `isPlaybackLikelyToKeepUp`, those code paths call `cancellables.removeAll()` (lines 1595, 1646) and may not call `endTrackTransitionBackgroundTask()`.

### 1.13 `removeTimeObserver` doesn't release BG task (still latent)

`PlayerState.swift:2597-2610`: called from `playRadioStation` (1593), `playPodcastEpisode` (1644), `playAudiobookChapter` (1712), and `stop` (1525). None of these call `endTrackTransitionBackgroundTask()`. If a user is mid-transition and then taps a podcast, the BG task is orphaned.

### 1.14 Dead comment chain at `setupPlayerObservers` 2373-2397 (still latent)

`PlayerState.swift:2373-2397`:

```swift
cancellables = cancellables.filter { cancellable in
    // ... 25 lines of comment ...
    true   // <-- the filter is a no-op
}
cancellables.removeAll()
```

The `filter { _ in true }` is dead — the code below it just calls `cancellables.removeAll()` anyway. The 25-line comment describes an aspiration that was never implemented. The unconditional `removeAll` is also dangerous: it drops *everything* in `cancellables`.

### 1.15 `removeTimeObserver` doesn't fully stop everything (still latent)

`PlayerState.swift:1524-1525`: `player?.replaceCurrentItem(with: nil)` runs *before* `removeTimeObserver` at 1525. The `.AVPlayerItemDidPlayToEndTime` observer is still registered when the item is replaced. The new item is `nil`, so the observer's `object:` filter won't match — but the old item is being dealloc'd and might fire one last KVO update.

### 1.16 `updateProgress` writes `accumulatedListeningTime` from the time observer (FIXED 88c6de9)

`PlayerState.swift:2664-2675`:

```swift
if timeDelta > 0 && timeDelta < 5 && playbackState == .playing {
    accumulatedListeningTime += timeDelta
    ...
}
```

During a phone call the AVPlayer pauses, but `playbackState` is set to `.paused` only when something explicitly calls `pause()`. Interruption doesn't call `pause()`. So during a phone call the time observer kept firing (with `timeDelta < 5`), but `playbackState` was still `.playing`. Listening time got credited for the duration of the call. Same applies to route changes.

**Fix applied (88c6de9):** check `player.rate > 0` instead of `playbackState == .playing`. `player.rate` is the ground truth for "is audio actually being produced".

### 1.17-1.21 Other latent issues (still latent)

- `nextTrack`'s gapless re-enqueue happens *after* `advanceToNextItem` (sequence is fine, but the duplicate event for `.trackPlayed` from 1.6 isn't fixed)
- `setCurrentIndex` callback in `setupPlayerObservers` only fires the Combine subscription; `currentItem` mirror may lag a tick
- `playQueue(at:)` resets `isHandlingCompletion` even when called from `nextTrack` (no fallback)
- `originalQueue` in `toggleShuffle` is captured by value but the items are class-by-value; double-shuffle breaks the "off restores to pre-shuffle" invariant
- `currentReplayGainLinear` is computed on every `applyVolume` call (cheap, but reads UserDefaults on every call)

---

## 2. `QueueStore` vs `PlaybackQueueManager` — two parallel queue systems

**Verdict:** They are *not* two parallel queue systems — they are the in-memory and persistence layers, and they are correctly split. The bugs were at the boundary, not in the split.

### 2.1 `DataManager.saveQueue` / `DataManager.loadQueue` (JSON in UserDefaults) was dead persistence (FIXED 88c6de9)

The only two callers of `DataManager.saveQueue(_:)` were in `PlayerState.swift:1820-1821` and `PlayerState.swift:1829-1830`. `DataManager.loadQueue()` was **never called externally** (verified via grep). The actual restoration path on cold launch is `PlaybackQueueManager.restoreQueue` (CoreData).

The JSON path was a complete duplicate of what `PlaybackQueueManager` does (via the auto-subscription at lines 35-40 of `PlaybackQueueManager.swift`). They drifted after every `nextTrack` advance.

**Fix applied (88c6de9):** deleted `DataManager.saveQueue`, `DataManager.loadQueue`, `DataManager.clearSavedQueue`, `DataManager.savedQueue` (@Published), `Keys.savedQueue`, and `QueueItemSnapshot`. The `dataManager.saveQueue(queue)` calls in `PlayerState.addToQueue` / `addToQueueNext` are removed. Net: -51 lines of code, one less write per add-to-queue, no more JSON-vs-CoreData drift.

### 2.2-2.7 Other items (still latent)

- `startObservingPlayerStateIfNeeded` guard is fragile (singleton-lifetime state, but the guard would silently drop a second call with a different `playerState` parameter)
- The `$items` 500ms debounce and `$currentIndex` 200ms debounce are independent; `isCurrent` flag can be set against a stale currentIndex for a 300ms window
- `restoreQueue` — the `hasUserTouchedPlayback` flag doesn't include `togglePlayPause` / `resume`; clobber scenarios possible
- `QueueStore.replace(with:)` doesn't reset `currentIndex` — caller must (correct but fragile contract)
- `QueueStore.remove(at:)` only adjusts `currentIndex` for the two boundary cases (correct but subtle invariant)
- `QueueStore.clear()` is correct, but `PlayerState.clearQueue` was incomplete (see 1.9 — fixed)

---

## 3. `CrossfadeManager` vs `gaplessEnabled` toggle

### 3.1 Three modes, not two

- `gaplessEnabled = true` → `PlayerState.play(item:)` creates an `AVQueuePlayer` (line 992-998) and pre-queues upcoming items via `enqueueUpcomingItemsForGapless`.
- `gaplessEnabled = false, isEnabled = true` → `PlayerState.play(item:)` creates a regular `AVPlayer`. `CrossfadeManager.prepareNextTrack` builds a second `AVPlayer` for the next track. `crossfadeToNext` does a 100ms-stepped volume fade between the two.
- `gaplessEnabled = false, isEnabled = false` → no transition management; `nextTrack` calls `playQueue(at: nextIndex)` directly (line 2012).

### 3.2 Mid-playback gapless toggle: no rebuild (still latent)

`FullPlayer.swift:1461-1464` writes `crossfadeManager.gaplessEnabled = $0` directly, which just persists to UserDefaults. **It does not trigger a player rebuild.** The `gaplessEnabled` is only consulted at 5 sites in PlayerState. So if the user toggles gapless ON mid-playback, the existing `AVPlayer` is *not* replaced with an `AVQueuePlayer`. The toggle is "lazy": it sets a flag that takes effect on the next play.

### 3.3 `CrossfadeManager.prepareNextTrack` early-returns on `gaplessEnabled` but still fires when only `isEnabled` is true (still latent)

`CrossfadeManager.swift:75-78` runs if either mode is on. `PlayerState.prepareNextTrackForCrossfade` (PlayerState.swift:2246-2274) gates on `CrossfadeManager.shared.isEnabled` only (line 2247), not on `gaplessEnabled`. So when `gaplessEnabled = true` and `isEnabled = false`, the pre-prep is skipped — but it shouldn't be (gapless still benefits from pre-buffering).

### 3.4 `CrossfadeManager.crossfadeToNext` is racy under user spam-press (acceptable as-is)

`CrossfadeManager.swift:126-188`. The `guard !isCrossfading` at 134 is checked on main; spam-presses are silently dropped. UX-wise: user presses Next, hears crossfade start, presses Next again, nothing happens. Acceptable.

### 3.5 The 100ms fade timer uses `Timer.scheduledTimer` on main runloop (acceptable as-is)

10 steps over 3s on the main runloop. The comment at 158-159 explains the choice (reduced from 30fps to 10fps for main-thread load). At 3s duration, 30 steps total, the main-thread impact is small. Under load the user might hear choppy fade. Alternative: `AVAudioMix` with `AVMutableAudioMixInputParameters` volume ramps, sample-accurate but a real refactor.

### 3.6 `setCurrentPlayer` cancels in-progress crossfade but leaks the next player (FIXED 88c6de9)

`CrossfadeManager.swift:191-199`: `cancelCrossfade` (210-222) paused `nextPlayer` and reset its volume to 0, but **did not nil it out**. The next call to `prepareNextTrack` (74-118) checked `guard nextPlayer == nil else { return }` and skipped preparation. Result: after a crossfade cancel, no future crossfade pre-prep happened for the rest of the track. **Symptom:** user starts track A, begins crossfade to B, presses Prev, the crossfade to C never preps. When track A ends, the user hears a hard cut to C, not a crossfade.

**Fix applied (88c6de9):** `cancelCrossfade` now sets `nextPlayer = nil`.

### 3.7 `CrossfadeManager` is not actually used in the gapless path (still latent)

`CrossfadeManager.shouldUseGapless(for:nextTrack:)` (line 225-233) is defined but never called. `prebufferNextTrack` (line 260-278) is defined but never called. Either delete them or wire them up so gapless is per-album as the comment claims.

---

## 4. `AudioSessionController`

### 4.1 Route change doesn't pause on `oldDeviceUnavailable` (FIXED 88c6de9)

`AudioSessionController.swift:165-177` previously called `activate()` for both `newDeviceAvailable` and `oldDeviceUnavailable`. Unplugging headphones kept audio playing through the speaker. **Fix applied (88c6de9):** new `onRouteChangeShouldPause` callback; handler pauses on `oldDeviceUnavailable`. Wired in `PlayerState.init` to call `self.pause()`.

### 4.2 Interruption doesn't pause explicitly (still latent)

`AudioSessionController.swift:144-148`: AVPlayer auto-pauses on interruption. But `PlayerState.playbackState` is *not* updated. UI shows "playing" with no audio during the call. The resume path at 609-612 sets `player.play()` but doesn't update `playbackState` either. The fix: expose an `onInterruptionBegan` callback that sets `playbackState = .paused`, or have the AVPlayer's KVO on `timeControlStatus` (`.paused`) drive `playbackState`.

### 4.3 `resumeFromInterruption` uses two-call `play + rate` (FIXED 88c6de9 via 1.11)

### 4.4 `mediaServicesWereReset` 0.5s delay is hard-coded (still latent)

`AudioSessionController.swift:179-189`. The 0.5s delay is "mirrors the original 0.5s delay in PlayerState" per the comment. If the new player construction in `handleMediaServicesResetRestart` (PlayerState.swift:618-622) takes longer than 0.5s, the callback fires into a half-constructed state.

### 4.5 No observer for `AVAudioSession.interruptionNotification`'s `.ended` when `shouldResume` is false (still latent)

`AudioSessionController.swift:149-159`. The AVPlayer will be paused after the interruption, the user is left with no audio, the UI shows "playing" (see 4.2). Apple's intentional behavior; the app should at least reflect the paused state in `playbackState`.

### 4.6 The audio session is configured with `.playback` category and `.allowAirPlay, .allowBluetooth` but no `.allowBluetoothA2DP` (FIXED 88c6de9)

`AudioSessionController.swift:86-97`. The `.allowBluetooth` option enables HFP — low quality, mono. For high-quality A2DP, `.allowBluetoothA2DP` is needed.

**Fix applied (88c6de9):** added `.allowBluetoothA2DP` to the options.

### 4.7 No support for `AVAudioSession.routeSharingPolicy` (still latent)

For long-form audio (podcasts, audiobooks), `.longFormAudio` route sharing policy is recommended by Apple. Not a bug, but worth knowing for the audiobook/podcast use cases.

---

## 5. `PlaybackQueueManager` details

### 5.1 `fetchFreshStreamUrl` uses `AudioFileManager.shared.localFileURL` for local files (acceptable as-is)

Correct for "downloaded after queue was saved, now restoring". But it also means: if the user *deleted* the local file, the restore silently falls through to fetching a fresh stream URL — which may fail because the source was originally local-only. The track drops out without explanation.

### 5.2 `restoreQueue` silently drops tracks that fail to fetch (FIXED 88c6de9)

`PlaybackQueueManager.swift:204-213` — `fetchFreshStreamUrl` returns nil on failure, the entry stays nil, the `compactMap` drops it. No error reported to the user. If 8 of 10 tracks restore and 2 fail, the user gets a queue with 8 items and no indication that 2 were dropped.

**Fix applied (88c6de9):** tracks failed-to-restore titles in a `failedCount` / `failedNames` accumulator, shows a single error toast at the end naming the failed tracks (or first 3 names + count of more).

### 5.3 `lastSavedQueueHash` (acceptable as-is)

The hash is just the concatenated videoIds. Order-sensitive, not content-sensitive. Reorder → save fires. Add+remove within 500ms debounce → save fires once with final state.

### 5.4 `updateCurrentItem` re-fetches ALL queue rows (still latent, perf only)

`PlaybackQueueManager.swift:130-150`. For every `currentIndex` change, this fetches *all* CD rows, mutates all of them, saves. With a 200-item queue, that's 200 row mutations and a save on every track change. `NSBatchUpdateRequest` would be O(1) database-side.

### 5.5 `saveQueue` uses `NSBatchDeleteRequest` correctly (acceptable as-is)

Background context is independent from the view context. Brief moment of empty list possible during a save if the view reads from the view context — but no view reads `CDPlaybackQueue` directly in practice.

### 5.6 `restoreQueue` calls `fetchFreshStreamUrl` but leaks the cancellable (still latent, minor)

`PlaybackQueueManager.swift:233-244` stores the cancellable in `self.cancellables` (PlaybackQueueManager's set). Every restore call leaks one `AnyCancellable` into the shared set. Should be scoped to a per-call set.

---

## Summary of user-facing symptoms and the fix state

| Symptom | Root cause | Status |
|---|---|---|
| "Track change feels broken" (overlap, gap) | `updateProgress` end-detection racing with `.AVPlayerItemDidPlayToEndTime` | FIXED 1.2 (1891a1e) — polling removed; `.AVPlayerItemDidPlayToEndTime` is the sole source of truth |
| "Mini-player loading icon forever" | Rate race in playImmediately path | FIXED 1.11 (88c6de9) |
| "Next/Prev doesn't work" | `isHandlingCompletion` race | FIXED 1.1 (88c6de9) |
| "Auto-advance broken" (same track plays twice) | Gapless re-enqueue duplicates | FIXED 1.4 (88c6de9) |
| "Lock screen shows wrong duration after gapless" | Gapless path skips `playbackClock.setExpectedDuration` | FIXED 1.3 (88c6de9) |
| "Recently-played is out of order" | Gapless `nextTrack` adds to recently-played before AVPlayer actually starts | FIXED 1.6 (dfb2763) — moved to `advanceGaplessState` so it fires when the new track actually starts |
| "Listening time credited during phone call" | `updateProgress` checks `playbackState == .playing` | FIXED 1.16 (88c6de9) |
| "Queue restored with fewer tracks than saved" | `restoreQueue` silently drops failures | FIXED 5.2 (88c6de9) |
| "Clear queue doesn't stop playback" | `clearQueue` doesn't call `stop()` | FIXED 1.9 (88c6de9) |
| "Background audio is mono on BT headphones" | Audio session missing `.allowBluetoothA2DP` | FIXED 4.6 (88c6de9) |
| "Crossfade doesn't work after a cancelled crossfade" | `cancelCrossfade` doesn't nil out `nextPlayer` | FIXED 3.6 (88c6de9) |
| "Lock screen keeps adding notifications" | Live Activity racy end+request | FIXED (88c6de9) |
| "Headphones unplugged = audio keeps playing" | Audio session doesn't pause on `oldDeviceUnavailable` | FIXED 4.1 (88c6de9) |
| "Two background saves for the same queue" | `DataManager.saveQueue` dead code | FIXED 2.1 (88c6de9) |
| "Recently-played / .trackPlayed duplicate" | Gapless `nextTrack` posted .trackPlayed before AVPlayer starts; `advanceGaplessState` posted again | FIXED 1.6 (dfb2763) — `nextTrack` no longer posts |
| "Gapless toggle does nothing mid-playback" | `gaplessEnabled` only consulted at `play(item:)` time | FIXED 3.2 (ae821f7) — toast "takes effect on next track" |
| "Phone call: UI shows 'playing' with no audio" | AVPlayer auto-pauses but `playbackState` doesn't flip | FIXED 4.2/4.5 (ae821f7) — `onInterruptionBegan` callback |
| "AirPods in one ear: audio drops" | Missing `routeSharingPolicy: .longFormAudio` | FIXED 4.7 (ae821f7) |
| "First-track gapless doesn't pre-queue the next" | `enqueueUpcomingItemsForGapless` bails on `queueCount > 1` | FIXED 1.5 (95863e3) — subscription to `queueStore.$items` re-enqueues after prefetcher |
| "Queue restore leaks cancellables" | `fetchFreshStreamUrl` stored in `self.cancellables` | FIXED 5.6 (ae821f7) — per-call set |
| "200-item queue: 200 row mutations per track change" | `updateCurrentItem` fetches + mutates + saves all rows | FIXED 5.4 (ae821f7) — `NSBatchUpdateRequest` O(1) |
| "AVPlayer: 'playing' with no audio after media-services reset" | Hardcoded 0.5s delay could fire too early | FIXED 4.4 (95863e3) — polling work item + 2s safety timeout |
| "Dead `filter { _ in true }` + 25 lines of comment" | Setup cleanup that was never implemented | FIXED 1.14 (ae821f7) |

---

## Top P2 items still unaddressed (after S17-H R10–R14)

1. **1.2** — Two completion triggers, no dedup. **RESOLVED**: the polling-based end detection in `updateProgress` (was 2689-2702) was removed in R12. `.AVPlayerItemDidPlayToEndTime` is now the sole source. The `isHandlingCompletion` guard is kept as a defensive layer in case the AVPlayer notification fires twice (rare; would happen on a stream-URL refresh). The `isHandlingCompletion` race from 1.1 (the user-tap vs auto-advance race) was the more dangerous one and is fixed via `userSkippedPendingCompletion`.

2. **1.5** — First-track-after-launch gapless pre-queue is a no-op. **RESOLVED**: added a lifetime subscription to `queueStore.$items` (debounced 300ms) that re-runs `enqueueUpcomingItemsForGapless` whenever the queue changes. When `QueuePrefetcher` populates the queue ~300ms after `play(item:)`, the subscription re-enqueues and the AVQueuePlayer has the next item ready.

3. **1.6** — Gapless "Next" branch posts `.trackPlayed` twice. **RESOLVED**: the `addToRecentlyPlayed` and `NotificationCenter.default.post(.trackPlayed)` calls were removed from the `nextTrack` gapless branch. They now happen only in `advanceGaplessState` (line 2314) when the AVQueuePlayer reports the new track has actually started. The dedup in `addToRecentlyPlayed` handles the edge case where the same track is recorded twice (e.g., on a stream-URL refresh).

4. **1.7** — `play(item:)` double audio-session activation. **RESOLVED**: removed the direct `setActive(true)` call at line 928-935. Now `play(item:)` calls `audioSessionController.activate()` like `play(track:)` does. Single owner of session activation.

5. **1.10** — `previousTrack` doesn't support "restart current" within 3 seconds. **RESOLVED**: added `previousTrackRestartGracePeriod: TimeInterval = 3` constant. If `player.currentTime() > 3s`, the first prev-press seeks to 0 instead of advancing.

6. **1.12 / 1.13** — `nextTrack` BG task can leak. **RESOLVED**: `stop()` and the 3 content-switching entry points (`playRadioStation` / `playPodcastEpisode` / `playAudiobookChapter`) now call `endTrackTransitionBackgroundTask()` before `cancellables.removeAll()`.

7. **1.14** — Dead comment chain at `setupPlayerObservers`. **RESOLVED**: deleted the `filter { _ in true }` and the 25 lines of comment that described an aspiration that was never implemented. The `removeAll()` below is what actually runs.

8. **1.15** — `removeTimeObserver` doesn't fully stop. **RESOLVED**: swapped the order in `stop()` so `removeTimeObserver()` runs *before* `player?.replaceCurrentItem(with: nil)`. The `.AVPlayerItemDidPlayToEndTime` observer is removed before the old item is dealloc'd.

9. **1.20** — `originalQueue` in `toggleShuffle` is captured by value but the items are class-by-value. **SKIPPED**: re-read the code; `originalQueue = queue` IS in the `isShuffled` branch (line 2467) and re-captures every time the user toggles on. The analysis was wrong; the invariant is preserved.

10. **3.2** — Mid-playback gapless toggle: no rebuild. **RESOLVED**: shows a "Gapless will take effect on the next track." toast when the user toggles gapless mid-playback. Section footer text also updated to mention the lazy-rebuild behavior.

11. **3.7** — `shouldUseGapless(for:nextTrack:)` and `prebufferNextTrack` are dead. **RESOLVED**: both deleted. Per-album gapless is a future feature that would live in `PlayerState.enqueueUpcomingItemsForGapless`, not `CrossfadeManager`. `prebufferNextTrack` was a no-op (AVURLAsset load is lazy anyway).

12. **4.2 / 4.5** — Interruption doesn't update `playbackState`. **RESOLVED**: new `onInterruptionBegan` callback in `AudioSessionController`. Wired in `PlayerState.init` to set `playbackState = .paused` when a phone call / Siri / alarm starts.

13. **4.4** — `mediaServicesWereReset` 0.5s delay is hard-coded. **RESOLVED**: replaced with a polling work item that fires on AVPlayer readiness or a 2s safety timeout. Also tracks the in-flight work item so a second reset during the wait doesn't double-fire the owner's `onMediaServicesReset`.

14. **4.7** — No `routeSharingPolicy: .longFormAudio` for podcasts/audiobooks. **RESOLVED**: set via `setCategory(_:mode:policy:options:)` (the Swift name for the `setCategory:mode:routeSharingPolicy:options:` Obj-C method). AirPods will intelligently route when only one pod is in the ear.

15. **5.4** — `updateCurrentItem` re-fetches all queue rows. **RESOLVED**: rewritten with two `NSBatchUpdateRequest`s. O(1) database-side updates instead of O(n) row mutations + save. View context refreshed via `NSManagedObjectContext.mergeChanges(fromRemoteContextSave:into:)`.

16. **5.6** — `restoreQueue` leaks one `AnyCancellable` per call. **RESOLVED**: `fetchFreshStreamUrl` now takes a per-call `cancellables: inout Set<AnyCancellable>` parameter. The previous code stored each restore's subscription in `self.cancellables`, leaking one per restore.

## PlayerState refactor (P3, multi-week)

The 2959-line god object should be split into:

- `AVPlayerController` — owns the AVPlayer, the time observer, the rate, the volume, the rate-race fixes. ~500 lines.
- `QueueController` — owns QueueStore, add/remove/move/clear, the dedup logic, the trim logic. ~400 lines.
- `GaplessController` — owns the AVQueuePlayer decision, the `enqueueUpcomingItemsForGapless`, the `advanceGaplessState`, the `prepareNextTrackForCrossfade` shared logic. ~300 lines.
- `ListeningTimeTracker` — owns `accumulatedListeningTime`, the player.rate check, the persistence. ~150 lines.
- `PlayerState` — the thin facade, owns the @Published properties that views observe, forwards to the controllers. ~600 lines.

This is the S17-F refactor and is explicitly deferred (2-3 weeks, 50+ sites affected by the `@Observable` migration that goes with it).
