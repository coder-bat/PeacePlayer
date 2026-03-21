# Code Cleanup Implementation Plan

## Overview
Comprehensive cleanup of YTAudioSystem iOS project to remove dead code, fix duplicates, and improve state management.

## Implementation Order

### Phase 1: High Priority (Dead Code Removal)

#### Task 1.1: Delete Unused Files
- **Files to delete**:
  - `Sources/PlaybackQueueManager.swift` (629 lines, completely unused)
  - `Sources/Entities/CDPlaybackQueue.swift` (only used by PlaybackQueueManager)
  - `YTAudioPlayer/Views/PlayerView.swift` (replaced by FullPlayer.swift)

#### Task 1.2: Clean AudioPlayerManager.swift
- **Keep**: CrossfadeManager, ShareCardGenerator, QRCodeGenerator
- **Remove**: AudioPlayerManager class, PerformanceMonitor class, BatteryOptimizer class
- **Remove**: Empty extension methods (setPrefetchEnabled, setAggressiveCaching)
- **Action**: Split into separate files or just remove dead classes

#### Task 1.3: Fix Crossfade
- **Issue**: nextPlayer not prepared in time
- **Solution**: Start preparing next track earlier (at track start, not at 5s from end)
- **Test**: Enable crossfade in Audio Settings, play tracks, verify smooth transition

### Phase 2: Medium Priority (State Consolidation)

#### Task 2.1: Fix @StateObject Pattern
- **File**: `FullPlayer.swift:16`
- **Change**: `@StateObject private var playerState = PlayerState.shared` → `@ObservedObject private var playerState = PlayerState.shared`

#### Task 2.2: Remove Dead QueueRestorer UI (or Enable It)
- **Decision**: Either remove QueueRestorePrompt entirely OR add it to YTAudioPlayerApp.swift
- **Current**: QueueRestorer class exists but prompt never shown

#### Task 2.3: Fix Dashed Border No-op
- **File**: `HomeView.swift:620-624`
- **Options**: Implement proper dashed border or remove the modifier

### Phase 3: Low Priority (Code Organization)

#### Task 3.1: Split AudioPlayerManager.swift
- Create separate files:
  - `CrossfadeManager.swift`
  - `ShareCardGenerator.swift`
  - `QRCodeGenerator.swift`

#### Task 3.2: Document Remaining Duplicates
- UserDefaults vs Core Data split is intentional for now (migration complete but dual-storage for safety)
- Document why TrackStore and DataManager still use UserDefaults

## Testing Checklist

After each phase:
1. Build app in Xcode
2. Deploy to bat-phone
3. Test basic playback
4. Test queue management
5. Test crossfade (after Phase 1)

## Success Criteria

- App builds without warnings
- No duplicate file references in project.pbxproj
- Crossfade works smoothly when enabled
- All existing features continue to work
- Reduced binary size
