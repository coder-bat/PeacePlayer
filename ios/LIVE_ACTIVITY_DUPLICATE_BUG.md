# Live Activity duplicate-notification bug — root cause & fix

**Status:** investigation complete, fix proposed
**Reporter:** "when tracks are playing, live activity keeps adding new notifications instead of replacing current live notification from app"
**Files involved:** `ios/Sources/LiveActivityManager.swift`, `ios/YTAudioPlayer/Models/PlayerState.swift`, `ios/Sources/NowPlayingService.swift`, `ios/YTAudioPlayer/Views/HomeView.swift`, `ios/YTAudioPlayer/Views/SearchView.swift`, `ios/YTAudioPlayer/Views/Playlists/PlaylistDetailView.swift`

---

## TL;DR

`LiveActivityManager` calls `Activity.request(...)` **once per emission of `PlayerState.$currentItem`**, but `PlayerState.$currentItem` is published **3-4 times for every single track change** in the codebase, and `LiveActivityManager` has no guard against "same track, just transitioning through a loading placeholder". On top of that, the end-then-restart path is racy: when two `$currentItem` emissions land in quick succession, both see the same `existing` activity and both call `Activity.request(...)` for the new one, leaking two activities to the lock screen per real track change.

**The fix is in `LiveActivityManager`** — not in `NowPlayingService` and not in `PlayerState`. It needs two changes:

1. Compare the *new* attributes against the *existing* activity's attributes and **only end+restart when the track actually changes** (skip restart when the same track is re-asserted, e.g. loadingItem → realItem).
2. Serialize the end-then-restart lifecycle through a single `Task` chain so concurrent `$currentItem` emissions cannot both observe the same `existing` activity and call `Activity.request(...)` twice.

A second, smaller fix in the call sites: don't set `PlayerState.currentItem = loadingItem` (the `streamUrl == ""` placeholder). It's the trigger that wedges an extra `Activity.request` between every queue advance and every track restart. The `playbackState = .loading` already conveys the loading state to the UI without polluting `currentItem`.

---

## 1. Audit of every `Activity.request` / `end` / `update` site

I grepped the entire iOS target for the three call sites. There is exactly one of each, all inside `LiveActivityManager.swift`:

| API | Location |
|-----|----------|
| `Activity.request(...)` | `ios/Sources/LiveActivityManager.swift:110` |
| `Activity.update(...)` | `ios/Sources/LiveActivityManager.swift:138` |
| `Activity.end(...)`   | `ios/Sources/LiveActivityManager.swift:90` (track change) and `:148` (`endActivity()`) |

`NowPlayingService` writes only to `MPNowPlayingInfoCenter.default().nowPlayingInfo` and `SharedNowPlayingState.update(...)` — it does **not** touch `ActivityKit`. So hypothesis #5 (both services pushing to lock screen → duplicates) is wrong. There is no second source of "now playing" notifications from `NowPlayingService`.

`UNUserNotificationCenter` is used by `AdaptiveWalkDJManager` (`Sources/AdaptiveWalkDJManager.swift:254-263`) and `TimeCapsuleManager` (`Sources/TimeCapsuleManager.swift:334-340`). Both are unrelated to playback — Walk DJ posts a "song suggestion" notification with a 30-min cooldown (`suggestionCooldown`, `:66`), and Time Capsule posts calendar reminders. Neither fires per-track, so they are not the duplicate source either.

`LiveActivityManager.shared` is touched in exactly one place outside itself: `WalkDJAppDelegate.swift:39`, which only triggers init. So there is exactly one `Activity` lifecycle owner in the app.

**Conclusion:** the duplicate activity is entirely created inside `LiveActivityManager`, and the root cause is the `Activity.request` call at line 110 firing more often than once per real track change.

---

## 2. The trigger: `PlayerState.$currentItem` publishes 3-4× per track change

`LiveActivityManager.init` wires three subscriptions (`LiveActivityManager.swift:30-55`):

```swift
PlayerState.shared.$currentItem
    .removeDuplicates { $0?.track.videoId == $1?.track.videoId }   // ← trigger for create/destroy
    .sink { [weak self] _ in
        self?.refreshActivityForCurrentTrack()
    }
```

So the question is: how many times does `$currentItem` fire for one user-visible track change?

The `removeDuplicates` predicate is `true` ⇒ **drop the new value**. So a `loadingItem → realItem` transition with the same `videoId` is *correctly dropped*. But two things conspire to break that:

### 2a. The `loadingItem` pattern in three Views

`HomeView.playTrack(_:seekToProgress:)` (`ios/YTAudioPlayer/Views/HomeView.swift:1299-1305`):

```swift
let loadingItem = QueueItem(
    track: track,
    streamUrl: "",       // ← empty stream URL
    source: .stream
)
PlayerState.shared.currentItem = loadingItem        // ← fires $currentItem (publishes videoId X)
PlayerState.shared.playbackState = .loading

StreamURLCache.shared.getStreamUrl(videoId: track.videoId)
    .sink(receiveValue: { streamInfo in
        let item = QueueItem(
            track: track,
            streamUrl: streamInfo.streamUrl,
            source: .stream
        )
        PlayerState.shared.play(item: item)         // ← eventually fires $currentItem again
```

Same pattern in `SearchView.swift:1083` and `PlaylistDetailView.swift:373`. The intent is to show a loading spinner in the UI immediately, before the HTTP stream URL resolves. The problem is that `currentItem` is the canonical source for "what is currently playing" — it feeds `MPNowPlayingInfoCenter`, the widgets, and the live activity. Setting it to a placeholder for the same `videoId` that is about to be set again is a category error: it counts as a "track change" because of the sequence below.

### 2b. `play(item:)` clears `currentItem` to `nil` first

`PlayerState.play(item:)` calls `stop()` before doing anything else, and `stop()` sets `currentItem = nil`:

`PlayerState.swift:1516-1544`:

```swift
func stop() {
    ...
    cancellables.removeAll()                  // line 1534 — drops *transient* observers
    player = nil
    currentItem = nil                        // line 1544 — fires $currentItem with nil
    playbackState = .idle
    ...
}
```

Then `play(item:)` sets `currentItem = item` at `PlayerState.swift:937`:

```swift
stop()                                       // → currentItem = nil → $currentItem fires
...
currentItem = item                           // → $currentItem fires again
playbackState = .loading
```

### 2c. The full sequence for one tap (e.g. user taps a row in `HomeView`)

1. `HomeView.playTrack` (line 1304): `currentItem = loadingItem` (videoId X)
   - `$currentItem` fires with `loadingItem` (videoId X)
   - `LiveActivityManager.refreshActivityForCurrentTrack` runs
   - `self.activity` is `nil` ⇒ **`Activity.request(...)` creates Activity #1** (the loading placeholder)
2. `play(item:)` runs (line 1324), which calls `stop()` (line 917) ⇒ `currentItem = nil`
   - `$currentItem` fires with `nil`
   - previous = `loadingItem` (videoId X), new = `nil` ⇒ `removeDuplicates` predicate `X == nil` is `false` ⇒ **NOT dropped** ⇒ fires
   - `refreshActivityForCurrentTrack`: `currentItem` is `nil` ⇒ `endActivity()` runs
   - `endActivity()` synchronously clears `self.activity = nil` and dispatches `Task { await activity #1.end(...) }`
3. `play(item:)` continues, sets `currentItem = realItem` (line 937) (videoId X)
   - previous = `nil`, new = `realItem` (videoId X) ⇒ predicate `nil == X` is `false` ⇒ **NOT dropped** ⇒ fires
   - `refreshActivityForCurrentTrack`: `self.activity` is `nil` ⇒ **`Activity.request(...)` creates Activity #2** (the real track)

**Per user tap, two `Activity.request` calls happen.** Activity #1 is ended (asynchronously, in a Task), Activity #2 becomes the new `self.activity`.

Same shape happens on every `playQueue(at:)`, every `playNext()`, every auto-advance, and every URL refresh — anywhere the code goes through `play(item:)`. The autoplay-next path is `playQueue(at:) → play(item:)`, and the gapless path bypasses `play(item:)` but still flips `$currentItem` once, which is the *correct* single-call case.

### 2d. Auto-advance (when the queue is playing without user input)

When `AVQueuePlayer` auto-advances, the chain is `setupPlayerObservers` → `isPlaybackLikelyToKeepUp` observer (in the new item) → `nextTrack()` → `playQueue(at: nextIndex)` → `setCurrentIndex` + `play(item:)`. So even without the user tapping, every track transition creates a loadingItem and a realItem. The same 2-`Activity.request` pattern happens per auto-advance. Over a 20-track queue, that's 20 transient duplicate activities.

That matches the user's "keeps adding" description.

---

## 3. The race condition that leaks activities

Even if the loadingItem pattern were removed, the end-then-restart path in `LiveActivityManager.refreshActivityForCurrentTrack` (lines 84-95) is racy:

```swift
if let existing = activity {
    // Track changed while activity was running. End the
    // old one and start a new one
    Task {
        await existing.end(nil, dismissalPolicy: .immediate)        // ← YIELDS
        self.startNewActivity(attributes: attributes, state: state) // ← runs after the await
    }
} else {
    startNewActivity(attributes: attributes, state: state)
}
```

`self.activity` is **not cleared before the await**. So while the Task is suspended on `await activity.end(...)`, a second `$currentItem` emission can see the same `existing` and schedule a parallel Task:

```
T0  refreshActivityForCurrentTrack() #1
    → existing = nil
    → startNewActivity(track A)  →  self.activity = Activity #A

T1  refreshActivityForCurrentTrack() #2  (different track B)
    → existing = Activity #A
    → Task #1 scheduled:  end(A); startNewActivity(track B)
    ← yields at `await existing.end(...)`

T2  refreshActivityForCurrentTrack() #3  (yet another track C, e.g. user is rapidly skipping)
    → existing = Activity #A     ← still #A! Task #1 hasn't resumed yet
    → Task #2 scheduled:  end(A); startNewActivity(track C)
    ← yields

T3  Task #1 resumes: end(A) was a no-op (or it ran), startNewActivity(B) → self.activity = #B

T4  Task #2 resumes: end(A) was a no-op (or it ran), startNewActivity(C) → self.activity = #C
```

Net result: **two** `Activity.request` calls ran, for #B and #C. The lock screen shows both #B and #C simultaneously (each with `dismissalPolicy: .immediate` only removes it once its own `end` call resolves, but the call sites don't track whether each Activity's end has been issued). On rapid skipping, N skipped tracks → N+1 simultaneously-visible activities.

The same race also matters without skipping: a `playbackState` or `progress` publisher firing right around a track change can interleave with the Task, but those use `updateActivityState` (which only calls `activity.update(...)`), so they don't *create* new activities. The race that matters is two `$currentItem` emissions within the end's await window.

---

## 4. The fix

The fix lives in `LiveActivityManager.swift`. `NowPlayingService` and `PlayerState` are correct as far as the live activity is concerned — they don't touch ActivityKit, and their `currentItem` publication pattern is what the rest of the app depends on (don't change it without thinking about the queue, mini-player, full-player, widgets, etc.).

### Fix A (required): in `LiveActivityManager`, compare attributes before end+restart, and serialize end+request

`ios/Sources/LiveActivityManager.swift`, replace `refreshActivityForCurrentTrack()` and the surrounding state with a single serialized `Task` chain that gates on "did the track actually change":

```swift
@available(iOS 16.2, *)
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<NowPlayingActivityAttributes>?
    private var cancellables = Set<AnyCancellable>()

    // Serializes activity lifecycle so concurrent $currentItem
    // emissions cannot both observe the same `existing` activity
    // and each fire their own Activity.request — which is the
    // root cause of the duplicate-notification bug.
    private var pendingLifecycle: Task<Void, Never>?

    private init() {
        if #available(iOS 16.2, *) {
            PlayerState.shared.$currentItem
                .removeDuplicates { $0?.track.videoId == $1?.track.videoId }
                .sink { [weak self] _ in
                    self?.refreshActivityForCurrentTrack()
                }
                .store(in: &cancellables)

            PlayerState.shared.$playbackState
                .sink { [weak self] _ in
                    self?.updateActivityState()
                }
                .store(in: &cancellables)

            PlayerState.shared.$progress
                .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] _ in
                    self?.updateActivityState()
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Public API

    private func refreshActivityForCurrentTrack() {
        guard #available(iOS 16.1, *) else { return }
        guard let item = PlayerState.shared.currentItem else {
            scheduleEnd()
            return
        }
        let track = item.track
        let newAttributes = NowPlayingActivityAttributes(
            trackTitle: track.title,
            trackArtist: track.displayArtist,
            trackAlbum: track.album,
            artworkURLString: track.artworkURL?.absoluteString
        )
        let newState = NowPlayingActivityAttributes.ContentState(
            isPlaying: PlayerState.shared.playbackState.isPlaying,
            currentTime: PlayerState.shared.progress,
            duration: Double(track.durationSeconds),
            updatedAt: Date()
        )

        // FIX-1: only end+restart when the track actually changed.
        // The previous code assumed `existing != nil` meant "track
        // changed", which is false during the loadingItem → realItem
        // transition (same videoId, just stream URL resolves) and
        // false during a `playbackState` change that happens to be
        // routed through this method. In both cases, end+request
        // creates a brand-new Activity visible on the lock screen
        // for no reason.
        if let existing = activity,
           existing.attributes.trackTitle  == newAttributes.trackTitle,
           existing.attributes.trackArtist == newAttributes.trackArtist,
           existing.attributes.artworkURLString == newAttributes.artworkURLString {
            // Same track — push state in place. Do NOT call
            // Activity.request. This is the change that makes the
            // loadingItem → realItem transition not leak an activity.
            updateActivityState()
            return
        }

        // FIX-2: chain the end+request through `pendingLifecycle` so
        // concurrent $currentItem emissions cannot both observe the
        // same `existing` and both call Activity.request for the new
        // track. The previous code's `Task { await ... }` did not
        // serialize against later refreshActivityForCurrentTrack
        // calls — the next emission would see the same `existing`
        // and schedule another Task, leaking two Activity.requests.
        let old = pendingLifecycle
        pendingLifecycle = Task { [weak self] in
            await old?.value
            guard let self else { return }
            await self.performEndAndStart(
                existing: self.activity,
                attributes: newAttributes,
                state: newState
            )
        }
    }

    private func performEndAndStart(
        existing: Activity<NowPlayingActivityAttributes>?,
        attributes: NowPlayingActivityAttributes,
        state: NowPlayingActivityAttributes.ContentState
    ) async {
        if let existing = existing {
            // Clear self.activity BEFORE awaiting end so concurrent
            // refreshActivityForCurrentTrack() calls don't see a
            // ghost "existing" that is already being torn down.
            self.activity = nil
            await existing.end(nil, dismissalPolicy: .immediate)
        }
        startNewActivity(attributes: attributes, state: state)
    }

    private func scheduleEnd() {
        let old = pendingLifecycle
        pendingLifecycle = Task { [weak self] in
            await old?.value
            guard let self else { return }
            await self.performEnd(existing: self.activity)
        }
    }

    private func performEnd(
        existing: Activity<NowPlayingActivityAttributes>?
    ) async {
        guard let existing = existing else { return }
        self.activity = nil
        await existing.end(nil, dismissalPolicy: .immediate)
    }

    private func startNewActivity(
        attributes: NowPlayingActivityAttributes,
        state: NowPlayingActivityAttributes.ContentState
    ) {
        guard #available(iOS 16.1, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }
        do {
            let content = ActivityContent(state: state, staleDate: nil)
            self.activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            print("⚠️ LiveActivityManager: failed to start activity: \(error)")
            self.activity = nil
        }
    }

    private func updateActivityState() {
        guard #available(iOS 16.1, *) else { return }
        guard let activity = activity,
              let item = PlayerState.shared.currentItem else {
            return
        }
        let state = NowPlayingActivityAttributes.ContentState(
            isPlaying: PlayerState.shared.playbackState.isPlaying,
            currentTime: PlayerState.shared.progress,
            duration: Double(item.track.durationSeconds),
            updatedAt: Date()
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// End any active activity. Called on stop, sign-out, or
    /// when playback ends naturally.
    func endActivity() {
        guard #available(iOS 16.1, *) else { return }
        let old = pendingLifecycle
        pendingLifecycle = Task { [weak self] in
            await old?.value
            guard let self else { return }
            await self.performEnd(existing: self.activity)
        }
    }
}
```

What this changes:

- **FIX-1** (line `existing.attributes.trackTitle == newAttributes.trackTitle`): the `loadingItem → realItem` transition now hits the early-return branch. The existing activity for the same track gets a `update(...)` push (in `updateActivityState`) instead of an end+request. **One `Activity.request` per real track change.**
- **FIX-2** (`pendingLifecycle` chain): if the user rapid-skips and three `$currentItem` emissions land before the first Task resumes, all three chain onto the same serialized Task. Each one waits for the previous to finish. The second and third emissions see `self.activity = nil` (because we cleared it before the await) and either schedule another end+request or just call `updateActivityState` if the track matches.

Note: `Activity<NowPlayingActivityAttributes>.attributes` is a stored property on the `Activity` instance, so reading it is safe on `@MainActor`. (In iOS 16.2+ the `Activity` properties are `@MainActor`-isolated; this class is already `@MainActor`.) If the deployment target were below 16.2, the `attributes` field isn't a stored property — but the file is already gated on `@available(iOS 16.2, *)` at the class level, so this is fine.

### Fix B (recommended, not strictly required): stop setting `currentItem = loadingItem` in the three call sites

This is the second-order cause. Even with Fix A in place, every track tap still produces one `Activity.request` for the loading placeholder, then one `update` for the real track. That's correct behavior (one activity per real track change), but the placeholder never needed to be `currentItem` in the first place — it exists only to show a loading spinner. The `playbackState = .loading` mutation on the next line already carries that signal to the UI.

Change in `ios/YTAudioPlayer/Views/HomeView.swift:1299-1305` (and the two mirror sites below):

```swift
// Before
let loadingItem = QueueItem(
    track: track,
    streamUrl: "",
    source: .stream
)
PlayerState.shared.currentItem = loadingItem
PlayerState.shared.playbackState = .loading

// After
PlayerState.shared.playbackState = .loading
```

- `ios/YTAudioPlayer/Views/SearchView.swift:1083` (same pattern, around `performPlayTrack`)
- `ios/YTAudioPlayer/Views/Playlists/PlaylistDetailView.swift:373`

**Caveat — verify the UI before deleting the `loadingItem`**: a few views read `currentItem` to decide what to display (e.g. `QueueView.swift:41`, `LibraryViewModel.swift:363`, `UnifiedLibraryViewModel.swift:429`). If any of them depends on the placeholder being there to render a loading row in the queue, you'll need to add a separate `@Published var isLoading: Bool` on `PlayerState` and have those views observe it. Quick check before deleting: `grep -n "currentItem" ios/YTAudioPlayer/Views/QueueView.swift` — if the view only reads `currentItem.track` for display, it's fine, because the real track arrives a few hundred ms later via `play(item:)`.

### Fix C (optional, defense-in-depth): make `removeDuplicates` use full attribute equality

`LiveActivityManager.swift:32`:

```swift
.removeDuplicates { $0?.track.videoId == $1?.track.videoId }
```

This is fine once Fix A is in place, because the new logic in `refreshActivityForCurrentTrack` also checks `existing.attributes`. But if you want a single line of defense at the publisher level, you could change the predicate to compare the full `NowPlayingActivityAttributes` value rather than just `videoId`. That would suppress the `loadingItem → realItem` emission entirely, so `refreshActivityForCurrentTrack` would only see one emission per real track change. **However**, since the loadingItem and the realItem have the same `track`, their `NowPlayingActivityAttributes` are *identical* — so the predicate would already suppress them *if there were no `nil` in between*. The `nil` from `stop()` is what breaks this. So Fix C alone is not enough; Fix A is the load-bearing change.

---

## 5. Why I'm not changing `NowPlayingService`

`NowPlayingService` writes to `MPNowPlayingInfoCenter.default().nowPlayingInfo` and `SharedNowPlayingState.update(...)` and triggers `WidgetSyncService.reloadAll()`. None of those are `ActivityKit` calls. Hypothesis #5 (both services pushing to the lock screen) is wrong — `MPNowPlayingInfoCenter` and the Live Activity are two separate lock-screen surfaces, and only the Live Activity is duplicating. The widget code (`NowPlayingFullWidget`, `NowPlayingLiveActivityWidget`) also doesn't call `Activity.request` — it only renders the `ActivityConfiguration<NowPlayingActivityAttributes>`, which is fed by the one `Activity` instance owned by `LiveActivityManager`. So the widget side is fine.

The artwork cache logic in `NowPlayingService` (lines 301-345) does NOT touch `Activity`. Confirmed.

---

## 6. Verification plan (post-fix)

1. **Unit-style trace**: with a `print` in `startNewActivity` and `performEndAndStart`, run a queue of 5 tracks and count `Activity.request` invocations. Should be exactly 5, plus 1 for the first play.
2. **Rapid-skip stress**: tap "next" 10 times in 2 seconds. The lock screen should show at most 1 (or 2 with brief overlap during the in-flight end) Live Activity, not 10.
3. **Cold launch + restoreQueue**: launch the app with a saved queue, verify one Live Activity appears for the current track (not one for each of the 50 restored items).
4. **Sign out / sign in cycle**: end the activity explicitly via the new `endActivity()` path, then sign back in, verify the new track creates exactly one new activity.

---

## Summary of changes

| File | Change | Required? |
|------|--------|-----------|
| `ios/Sources/LiveActivityManager.swift` | Add `pendingLifecycle` Task chain; compare attributes before end+restart; clear `self.activity` before the end await | **Required** |
| `ios/YTAudioPlayer/Views/HomeView.swift:1299-1304` | Drop the `currentItem = loadingItem` line, keep `playbackState = .loading` | Recommended |
| `ios/YTAudioPlayer/Views/SearchView.swift:1083` | Same | Recommended |
| `ios/YTAudioPlayer/Views/Playlists/PlaylistDetailView.swift:373` | Same | Recommended |

`NowPlayingService.swift`, `SharedNowPlayingState.swift`, `WidgetSyncService.swift`, `PeacePlayerShortcuts.swift`, the widget extension files, and `PlayerState.swift` itself are not changed. The duplicate originates and is fixed entirely inside `LiveActivityManager` (and optionally suppressed at the source by removing the `loadingItem` pattern).
