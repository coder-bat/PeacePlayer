# Critical Fixes Implementation Plan

## Overview
Implementing 8 critical fixes to make the app production-ready.

## Implementation Order

### Phase 1: Foundation (Fixes 1-3) - Core functionality
### Phase 2: UX Polish (Fixes 4-6) - User experience
### Phase 3: Testing (Fixes 7-8) - Verification

---

## Fix 1: Download Manager Integration

### Problem
SearchView bypasses DownloadManager, using APIService directly.

### Solution
1. Add download progress observation to SearchView
2. Update SearchResultRow to show download state
3. Connect DownloadManager to UI

### Implementation
```swift
// Add to SearchResultRow:
- downloadProgress: Double?
- downloadStatus: DownloadStatus?
- Show progress indicator during download
- Update when complete
```

---

## Fix 2: CoreData Persistence

### Problem
All data lost on app close.

### Solution
1. Create CoreData model
2. Add PersistenceManager
3. Auto-save on background
4. Restore on launch

### Data Model
```
RecentTrack: videoId, title, artist, artworkURL, playedAt, playCount
ListeningStats: totalPlays, totalTime, lastUpdated
PlaybackState: currentTrackId, queue, progress, timestamp
```

---

## Fix 3: Recently Played Tracking

### Problem
HomeView shows lastPlayedTrack but it's never set.

### Solution
1. Add NotificationCenter events when track plays
2. Listen in HomeViewModel
3. Persist to CoreData

---

## Fix 4: Playing State Detection

### Problem
Title matching is fragile.

### Solution
1. Add currentlyPlayingId to LibraryViewModel
2. Observe PlayerState changes
3. Match by videoId

---

## Fix 5: Image Caching

### Problem
Images reload every time, no caching.

### Solution
1. Configure URLCache
2. Create CachedAsyncImage component
3. Replace all AsyncImage usages

---

## Fix 6: Error Handling

### Problem
Inconsistent error display.

### Solution
1. Create ErrorManager singleton
2. Add global ErrorToast view
3. Standardize error types

---

## Fix 7: Mini Player Feedback

### Problem
Swipe gestures have no visual feedback.

### Solution
1. Add swipe indicators
2. Show track skip preview
3. Haptic feedback during swipe

---

## Fix 8: Testing

### Problem
No way to verify fixes.

### Solution
1. Create test checklist
2. Verify each fix
3. Document results
