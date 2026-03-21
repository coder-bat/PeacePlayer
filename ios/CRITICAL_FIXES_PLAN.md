# Critical Fixes Implementation Plan

## Fix 1: Download Manager Integration (URGENT)

### Current Problem
`SearchViewModel` bypasses `DownloadManager` completely:

```swift
// Current (WRONG):
APIService.shared.downloadTrack(track)  // Direct API call

// Should be:
DownloadManager.shared.download(track)   // Through manager
```

### Implementation Steps

1. **Update SearchViewModel.downloadTrack():**
```swift
func downloadTrack(_ track: Track) {
    guard !isDownloaded(track) else {
        alertMessage = "Already downloaded!"
        showAlert = true
        return
    }
    
    // Use DownloadManager instead of APIService directly
    DownloadManager.shared.download(track)
    
    // Show initial feedback
    alertMessage = "Added to download queue"
    showAlert = true
}
```

2. **Add DownloadManager Observer to SearchView:**
```swift
@StateObject private var downloadManager = DownloadManager.shared

// In body, show download progress
```

3. **Update Download Badge:**
- Make `DownloadManager` properly update badge count
- Connect to tab bar badge

---

## Fix 2: Data Persistence (URGENT)

### Implementation: CoreData Integration

1. **Create CoreData Model:**
```
RecentTrack
- videoId: String
- title: String
- artist: String
- artworkURL: String?
- playedAt: Date
- playCount: Int
- duration: Int

ListeningStats
- totalPlays: Int
- totalListeningTime: Double
- lastUpdated: Date

PlaybackState
- currentTrackId: String?
- queue: [String] (video IDs)
- currentIndex: Int
- progress: Double
- timestamp: Date
```

2. **Create PersistenceManager:**
```swift
class PersistenceManager {
    static let shared = PersistenceManager()
    
    // Save recently played
    func saveRecentTrack(_ track: Track)
    
    // Load recently played
    func loadRecentTracks() -> [Track]
    
    // Update stats
    func recordPlay(duration: Double)
    
    // Save/restore queue
    func saveQueueState(_ playerState: PlayerState)
    func restoreQueueState() -> QueueState?
}
```

3. **Auto-save on app background:**
```swift
// In SceneDelegate or App
defaults.notificationCenter.addObserver(
    forName: UIApplication.didEnterBackgroundNotification
) { _ in
    PersistenceManager.shared.saveQueueState(PlayerState.shared)
}
```

---

## Fix 3: Recently Played Tracking (URGENT)

### Current Issue
`HomeView` shows `lastPlayedTrack` but it's never set.

### Fix

1. **Add tracking to PlayerState:**
```swift
func play(item: QueueItem) {
    // ... existing code ...
    
    // Track recently played
    PersistenceManager.shared.saveRecentTrack(item.track)
    
    // Post notification
    NotificationCenter.default.post(
        name: .trackDidStartPlaying,
        object: item.track
    )
}

extension Notification.Name {
    static let trackDidStartPlaying = Notification.Name("trackDidStartPlaying")
}
```

2. **Listen in HomeViewModel:**
```swift
init() {
    NotificationCenter.default.publisher(for: .trackDidStartPlaying)
        .sink { [weak self] notification in
            if let track = notification.object as? Track {
                self?.addToRecentlyPlayed(track)
            }
        }
        .store(in: &cancellables)
}

private func addToRecentlyPlayed(_ track: Track) {
    recentlyPlayed.removeAll { $0.videoId == track.videoId }
    recentlyPlayed.insert(track, at: 0)
    recentlyPlayed = Array(recentlyPlayed.prefix(20))
    lastPlayedTrack = track
}
```

---

## Fix 4: Fix "Currently Playing" Detection

### Problem
Using title matching is fragile.

### Solution

1. **Use videoId matching:**
```swift
// In LibraryViewModel
func isCurrentlyPlaying(_ track: LocalTrack) -> Bool {
    guard let currentItem = PlayerState.shared.currentItem else { return false }
    // Match by comparing titles since local tracks don't have videoId
    return track.parsedTitle == currentItem.track.title
}

// Better: Store videoId in LocalTrack
// Update backend to include video_id in filename or metadata
```

2. **Alternative: Add playing state to LibraryViewModel:**
```swift
@Published var currentlyPlayingId: String?

init() {
    // Observe player state
    PlayerState.shared.$currentItem
        .map { $0?.track.videoId }
        .assign(to: &$currentlyPlayingId)
}
```

---

## Fix 5: Mini Player Swipe Visual Feedback

### Implementation

1. **Add swipe indicator overlay:**
```swift
struct MiniPlayer: View {
    @State private var dragOffset: CGFloat = 0
    @State private var swipeDirection: SwipeDirection?
    
    enum SwipeDirection {
        case left, right, none
    }
    
    var body: some View {
        HStack { /* ... */ }
        .overlay(
            // Swipe indicators
            HStack {
                if dragOffset > 30 {
                    Image(systemName: "backward.fill")
                        .foregroundColor(.accentColor)
                        .padding(.leading)
                }
                Spacer()
                if dragOffset < -30 {
                    Image(systemName: "forward.fill")
                        .foregroundColor(.accentColor)
                        .padding(.trailing)
                }
            }
            .opacity(abs(dragOffset) / 50)
        )
    }
}
```

---

## Fix 6: Image Caching

### Implementation

1. **Add URLCache configuration:**
```swift
// In App init
let cache = URLCache(
    memoryCapacity: 50 * 1024 * 1024,    // 50MB
    diskCapacity: 100 * 1024 * 1024,     // 100MB
    diskPath: "image_cache"
)
URLCache.shared = cache
```

2. **Create CachedAsyncImage:**
```swift
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    
    var body: some View {
        AsyncImage(url: url) { phase in
            // Handle cache properly
        }
    }
}
```

---

## Fix 7: Error Handling System

### Implementation

1. **Create ErrorManager:**
```swift
class ErrorManager: ObservableObject {
    static let shared = ErrorManager()
    
    @Published var currentError: AppError?
    @Published var showError = false
    
    func show(_ error: AppError) {
        currentError = error
        showError = true
    }
}

enum AppError {
    case network(retry: () -> Void)
    case playback(retry: () -> Void, skip: () -> Void)
    case download(retry: () -> Void)
    case server
}
```

2. **Global error view:**
```swift
// In ContentView
.overlay(
    ErrorToast(error: errorManager.currentError)
        .animation(.spring(), value: errorManager.showError)
)
```

---

## Implementation Priority & Estimates

| Fix | Priority | Estimated Time | Impact |
|-----|----------|----------------|--------|
| Download Manager Integration | 🔴 Critical | 2 hours | High |
| Data Persistence (CoreData) | 🔴 Critical | 6 hours | Very High |
| Recently Played Tracking | 🔴 Critical | 2 hours | Medium |
| Playing State Detection | 🔴 Critical | 1 hour | Medium |
| Mini Player Visual Feedback | 🟡 High | 2 hours | Medium |
| Image Caching | 🟡 High | 3 hours | High |
| Error Handling System | 🟡 High | 4 hours | High |

**Total Critical Fix Time: ~20 hours**

---

## Testing Checklist After Fixes

- [ ] Download shows in queue immediately
- [ ] Download badge updates correctly
- [ ] Recently played persists after app close
- [ ] Queue restores after app kill
- [ ] Currently playing shows in both search and library
- [ ] Mini player swipe shows visual feedback
- [ ] Images don't reload on scroll
- [ ] Errors show with proper retry actions
