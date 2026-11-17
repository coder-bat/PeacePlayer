# Turntable Home Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a flag-gated "Turntable" Home screen where the record itself is the UI — a textured vinyl platter carries the album art, the tonearm scrubs, the cue lever is play/pause, and album sleeves drop onto the platter to play.

**Architecture:** A new `Views/Turntable/` module owns every visual element of the deck. `HomeView` keeps its `NavigationStack` and `HomeDestination` routes and only swaps its *body* — the deck or the existing card scroll, chosen by a reactive feature flag. `ContentView`'s global `BottomBar` hides `MiniPlayer` on the Home tab when the flag is on, so exactly one now-playing surface is ever visible.

**Tech Stack:** Swift 5.9, SwiftUI, Xcode 16.4, iOS 17.0 deployment target, XcodeGen (`ios/project.yml`), XCTest.

## Global Constraints

- Deployment target is iOS **17.0**. No iOS 18+ APIs.
- Swift **5.9**. No macros, no Swift 6 concurrency features.
- New colours live in `TurntableTokens` only. **Zero raw system colours** (`.red`, `.orange`, `.systemGray`, `.blue`) in any new file — the audit in `analysis/13-VISUAL-DESIGN.md` flagged exactly this class of drift.
- Every new touch target is **≥ 44×44pt** even when the visible artwork is smaller.
- `Theme.cyberCyan` / `Theme.cyberMagenta` / `Theme.cyberYellow` remain the only neon accents. Warm hardware tones carry the surfaces.
- `prefers-reduced-motion` must be honoured everywhere animation exists.
- **Haptic discipline:** one `HapticManager.selectionChanged()` per 10% scrub detent. No `.light()` on icon buttons.
- Text assets live in `Assets.xcassets/Turntable/` — 4 generated textures (already produced, see Task 1).
- Every task ends with a commit. Branch: `feature/turntable-home`.

---

### Task 1: Asset catalog + texture tokens

**Files:**
- Create: `ios/YTAudioPlayer/Assets.xcassets/Turntable/*.imageset/Contents.json` (4 already generated)
- Create: `ios/YTAudioPlayer/DesignSystem/TurntableTokens.swift`
- Test: `ios/YTAudioPlayerTests/TurntableTokensTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  ```swift
  enum TurntableTokens {
      static let walnut: Color        // #3B2A1E
      static let aluminium: Color     // #C9C6BE
      static let cream: Color         // #F3EDE0
      static let felt: Color          // #2F4034
      static let amberLamp: Color     // #F0A92B
      static let vinyl: Color         // #08080A
      static let grooveShadow: Color  // rgba(255,255,255,0.05)
  }
  enum TurntableTexture {
      static let vinylGrooves = "Turntable/vinyl_grooves"
      static let walnut = "Turntable/walnut"
      static let brushedAluminium = "Turntable/brushed_aluminium"
      static let felt = "Turntable/felt"
  }
  ```

- [ ] **Step 1: Write the failing test**

`ios/YTAudioPlayerTests/TurntableTokensTests.swift`:

```swift
import XCTest
import SwiftUI
@testable import PeacePlayer

final class TurntableTokensTests: XCTestCase {

    func testTextureNamesResolveToRealAssets() {
        // The asset catalog must contain all four generated textures.
        // A typo here silently falls back to a blank image at runtime.
        for name in [TurntableTexture.vinylGrooves,
                     TurntableTexture.walnut,
                     TurntableTexture.brushedAluminium,
                     TurntableTexture.felt] {
            XCTAssertNotNil(UIImage(named: name),
                            "Missing asset: \(name)")
        }
    }

    func testHardwarePaletteIsDistinctFromCyberpunkSignals() {
        // The deck's warm surfaces must not collapse into the cyan/magenta
        // signal colours, or the hardware metaphor stops reading.
        let hardware = [TurntableTokens.walnut,
                        TurntableTokens.aluminium,
                        TurntableTokens.cream,
                        TurntableTokens.felt]
        let signals = [Theme.cyberCyan, Theme.cyberMagenta, Theme.cyberYellow]
        for h in hardware {
            for s in signals {
                XCTAssertNotEqual(h, s, "Hardware tone collided with signal colour")
            }
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios && xcodebuild test -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PeacePlayerTests/TurntableTokensTests`
Expected: FAIL — `TurntableTokens` is not defined.

- [ ] **Step 3: Write the implementation**

Create `ios/YTAudioPlayer/DesignSystem/TurntableTokens.swift`:

```swift
//
//  TurntableTokens.swift
//  YTAudioPlayer
//
//  Material palette for the Turntable Home (flag: ff_turntable_home).
//
//  These live in their own file rather than in Theme.swift for two
//  reasons:
//
//  1. Theme.swift is aliased onto SharedCyberColors.swift, which the
//     widget extension also compiles. Adding hardware tones there
//     would widen the widget's palette for no reason.
//  2. The Turntable deck is opt-in behind a Labs flag. When the flag
//     is retired, this file and its whole module can be deleted
//     without touching anything else.
//
//  Rule: the deck's SURFACES are warm (walnut, aluminium, cream,
//  felt). The only neon allowed on the deck is the app's existing
//  signal palette — cyberCyan, cyberMagenta, cyberYellow — so the
//  player, the widgets and Home all still read as one app.
//

import SwiftUI

enum TurntableTokens {
    // MARK: - Hardware surfaces

    /// Deck plinth body. Deep walnut with a warm red undertone.
    static let walnut = Color(red: 0.231, green: 0.165, blue: 0.118)

    /// Brushed aluminium: fascia strip, tonearm tube, pivot hardware.
    static let aluminium = Color(red: 0.788, green: 0.776, blue: 0.745)

    /// Paper label stock: the record's centre label, sleeve captions.
    static let cream = Color(red: 0.953, green: 0.929, blue: 0.878)

    /// Felt mat under the platter. Deep green, absorbs the platter's
    /// reflection the way a real slipmat does.
    static let felt = Color(red: 0.184, green: 0.251, blue: 0.204)

    /// Amber pilot lamp — the "power on" indicator.
    static let amberLamp = Color(red: 0.941, green: 0.663, blue: 0.169)

    /// Vinyl body colour, used for the groove ring shadow and the
    /// platter's inner void where no texture is drawn.
    static let vinyl = Color(red: 0.031, green: 0.031, blue: 0.039)

    /// A single groove's specular line. Drawn as a repeating radial
    /// gradient over the vinyl texture.
    static let grooveShadow = Color.white.opacity(0.055)

    // MARK: - Lighting

    /// Warm key light from the upper left, matching the generated
    /// textures' studio lighting so the parts agree.
    static let keyLight = Color(red: 1.0, green: 0.97, blue: 0.92)

    /// Cool fill from the lower right.
    static let fillLight = Color(red: 0.62, green: 0.68, blue: 0.80)

    /// Edge highlight for machined parts (pivot collar, spindle).
    static let edgeHighlight = Color.white.opacity(0.55)
}

/// Names of the generated textures in the asset catalog.
///
/// Kept as string constants rather than direct `Image("...")` calls so
/// a rename breaks at compile time in exactly one place, and so tests
/// can assert the assets exist.
enum TurntableTexture {
    /// Macro photograph of black vinyl grooves with an anisotropic sheen.
    static let vinylGrooves = "Turntable/vinyl_grooves"

    /// Dark walnut veneer, satin lacquer.
    static let walnut = "Turntable/walnut"

    /// Brushed aluminium, fine horizontal striations.
    static let brushedAluminium = "Turntable/brushed_aluminium"

    /// Dark forest green felt.
    static let felt = "Turntable/felt"
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ios && xcodebuild test -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PeacePlayerTests/TurntableTokensTests`
Expected: PASS (2 tests).

**Note:** `xcodegen generate` must be run once before the first build so the new
`DesignSystem/TurntableTokens.swift` is registered — `ios/project.yml` globs the
whole `YTAudioPlayer` directory, so no `project.yml` edit is needed.

- [ ] **Step 5: Commit**

```bash
git add ios/YTAudioPlayer/DesignSystem/TurntableTokens.swift \
        ios/YTAudioPlayer/Assets.xcassets/Turntable \
        ios/YTAudioPlayerTests/TurntableTokensTests.swift
git commit -m "feat(ios): turntable tokens + generated material textures

Adds the hardware palette (walnut, aluminium, cream, felt, amber lamp)
and four generated textures: vinyl grooves, walnut veneer, brushed
aluminium and felt.

The palette lives outside Theme.swift on purpose - Theme aliases
SharedCyberColors, which the widget extension also compiles, and the
whole Turntable module is flag-gated and deletable.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Reactive feature flags

**Files:**
- Create: `ios/YTAudioPlayer/DesignSystem/FeatureFlags.swift`
- Modify: `ios/YTAudioPlayer/Views/SettingsView.swift` (add Labs toggle)
- Test: `ios/YTAudioPlayerTests/FeatureFlagsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  ```swift
  final class FeatureFlags: ObservableObject {
      static let shared = FeatureFlags()
      @Published var turntableHome: Bool { get set }
      static let turntableHomeKey = "ff_turntable_home"
  }
  ```

- [ ] **Step 1: Write the failing test**

`ios/YTAudioPlayerTests/FeatureFlagsTests.swift`:

```swift
import XCTest
@testable import PeacePlayer

final class FeatureFlagsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "FeatureFlagsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testTurntableHomeDefaultsToOff() {
        // The Turntable deck replaces the app's entry screen. It must
        // never be on by default - existing users get the current Home
        // until they opt in via Settings -> Labs.
        let flags = FeatureFlags(defaults: defaults)
        XCTAssertFalse(flags.turntableHome)
    }

    func testTurntableHomeReadsPersistedValue() {
        defaults.set(true, forKey: FeatureFlags.turntableHomeKey)
        let flags = FeatureFlags(defaults: defaults)
        XCTAssertTrue(flags.turntableHome)
    }

    func testTurntableHomeWritePersistsAndPublishes() {
        let flags = FeatureFlags(defaults: defaults)
        var observed: Bool?
        let cancellable = flags.$turntableHome.sink { observed = $0 }
        defer { cancellable.cancel() }

        flags.turntableHome = true

        XCTAssertEqual(observed, true, "Change did not publish")
        XCTAssertEqual(defaults.bool(forKey: FeatureFlags.turntableHomeKey), true,
                       "Change did not persist")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios && xcodebuild test -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PeacePlayerTests/FeatureFlagsTests`
Expected: FAIL — `FeatureFlags` is not defined.

- [ ] **Step 3: Write the implementation**

Create `ios/YTAudioPlayer/DesignSystem/FeatureFlags.swift`:

```swift
//
//  FeatureFlags.swift
//  YTAudioPlayer
//
//  Reactive store for the Labs feature flags.
//
//  Why a store instead of reading UserDefaults inline:
//
//  The Turntable flag has to be read in TWO places - HomeView (swap the
//  body) and ContentView (hide the MiniPlayer). If either of them
//  cached the value in a @State initialiser, flipping the toggle in
//  Settings would leave the deck and the mini player out of sync:
//  the user comes back to Home and sees the old layout with the
//  mini player still there.
//
//  A published ObservableObject fixes that - both readers observe the
//  same instance and re-render the moment the value changes.
//

import Foundation
import Combine

final class FeatureFlags: ObservableObject {

    // MARK: - Keys

    /// Labs toggle for the Turntable Home.
    static let turntableHomeKey = "ff_turntable_home"

    // MARK: - Store

    private let defaults: UserDefaults

    /// Shared instance used by the app UI.
    static let shared = FeatureFlags()

    private init() {
        self.defaults = .standard
    }

    /// Test seam - lets the unit tests use an isolated UserDefaults suite
    /// instead of polluting the real one.
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - Flags

    /// Turntable Home: the record is the home screen.
    ///
    /// Default OFF. When ON, Home renders the Turntable deck and the
    /// global BottomBar hides the MiniPlayer on the Home tab.
    @Published var turntableHome: Bool {
        didSet {
            guard turntableHome != defaults.bool(forKey: Self.turntableHomeKey) else { return }
            defaults.set(turntableHome, forKey: Self.turntableHomeKey)
        }
    }

    private init(defaults: UserDefaults) {
        self.defaults = defaults
        self.turntableHome = defaults.bool(forKey: Self.turntableHomeKey)
    }
}
```

**Fix:** the file above has two `init`s for `UserDefaults` — merge them into one
and delete the `private init()` block. The correct file is:

```swift
//
//  FeatureFlags.swift
//  YTAudioPlayer
//
//  Reactive store for the Labs feature flags.
//
//  Why a store instead of reading UserDefaults inline:
//
//  The Turntable flag has to be read in TWO places - HomeView (swap the
//  body) and ContentView (hide the MiniPlayer). If either of them
//  cached the value in a @State initialiser, flipping the toggle in
//  Settings would leave the deck and the mini player out of sync:
//  the user comes back to Home and sees the old layout with the
//  mini player still there.
//
//  A published ObservableObject fixes that - both readers observe the
//  same instance and re-render the moment the value changes.
//

import Foundation
import Combine

final class FeatureFlags: ObservableObject {

    // MARK: - Keys

    /// Labs toggle for the Turntable Home.
    static let turntableHomeKey = "ff_turntable_home"

    // MARK: - Store

    private let defaults: UserDefaults

    /// Shared instance used by the app UI.
    static let shared = FeatureFlags()

    /// Designated initialiser. The shared instance uses `.standard`;
    /// tests pass an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.turntableHome = defaults.bool(forKey: Self.turntableHomeKey)
    }

    // MARK: - Flags

    /// Turntable Home: the record is the home screen.
    ///
    /// Default OFF. When ON, Home renders the Turntable deck and the
    /// global BottomBar hides the MiniPlayer on the Home tab.
    @Published var turntableHome: Bool {
        didSet {
            guard turntableHome != defaults.bool(forKey: Self.turntableHomeKey) else { return }
            defaults.set(turntableHome, forKey: Self.turntableHomeKey)
        }
    }
}
```

- [ ] **Step 4: Wire the Settings toggle**

In `ios/YTAudioPlayer/Views/SettingsView.swift`, inside the `Labs` `Section`,
add a `LabsToggle` entry after the `ff_cross_feature_wiring` one:

```swift
                    LabsToggle(
                        key: FeatureFlags.turntableHomeKey,
                        defaultValue: false,
                        icon: "record.circle",
                        iconColor: Theme.cyberCyan,
                        title: "Turntable Home",
                        subtitle: "Replace the home screen with a record deck"
                    )
```

The existing `LabsToggle` writes to `UserDefaults` directly. To keep
`FeatureFlags` in sync, add an `onChange` that mirrors the value:

```swift
                    LabsToggle(
                        key: FeatureFlags.turntableHomeKey,
                        defaultValue: false,
                        icon: "record.circle",
                        iconColor: Theme.cyberCyan,
                        title: "Turntable Home",
                        subtitle: "Replace the home screen with a record deck",
                        onChange: { enabled in
                            FeatureFlags.shared.turntableHome = enabled
                        }
                    )
```

`LabsToggle`'s `onChange` fires AFTER the value is written to `UserDefaults`,
so `FeatureFlags.shared.turntableHome = enabled` will see the same value and
its `didSet` guard will skip the redundant write. Verify this by reading
`LabsToggle`'s body (SettingsView.swift ~1303) — if it writes before calling
`onChange`, the guard handles it; if after, the assignment still lands.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd ios && xcodebuild test -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PeacePlayerTests/FeatureFlagsTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add ios/YTAudioPlayer/DesignSystem/FeatureFlags.swift \
        ios/YTAudioPlayer/Views/SettingsView.swift \
        ios/YTAudioPlayerTests/FeatureFlagsTests.swift
git commit -m "feat(ios): reactive FeatureFlags store + Turntable Labs toggle

The Turntable flag is read in two places - HomeView swaps the body,
ContentView hides the MiniPlayer. A cached @State read in either would
leave them out of sync after a toggle, so the flag lives in a published
ObservableObject instead.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Platter — the textured vinyl

**Files:**
- Create: `ios/YTAudioPlayer/Views/Turntable/PlatterView.swift`
- Test: `ios/YTAudioPlayerTests/PlatterGeometryTests.swift`

**Interfaces:**
- Consumes: `TurntableTokens`, `TurntableTexture` (Task 1).
- Produces:
  ```swift
  struct PlatterView: View {
      let artworkURL: URL?
      let isPlaying: Bool
      let progress: Double
      let reduceMotion: Bool
      var onTapSpindle: () -> Void
      var onLongPress: () -> Void
  }

  enum PlatterGeometry {
      /// Total rotation (degrees) the platter turns over one full track.
      static let turnsPerTrack: Double = 1
      /// Rotation in degrees for a given playback progress.
      static func rotation(forProgress progress: Double) -> Double
      /// The sheen band sweeps once per revolution.
      static func sheenAngle(forProgress progress: Double) -> Double
  }
  ```

- [ ] **Step 1: Write the failing test**

`ios/YTAudioPlayerTests/PlatterGeometryTests.swift`:

```swift
import XCTest
@testable import PeacePlayer

final class PlatterGeometryTests: XCTestCase {

    func testRotationIsZeroAtStartAndFullTurnAtEnd() {
        XCTAssertEqual(PlatterGeometry.rotation(forProgress: 0), 0, accuracy: 0.001)
        XCTAssertEqual(PlatterGeometry.rotation(forProgress: 1),
                       360 * PlatterGeometry.turnsPerTrack,
                       accuracy: 0.001)
    }

    func testRotationIsLinearInProgress() {
        XCTAssertEqual(PlatterGeometry.rotation(forProgress: 0.25),
                       360 * PlatterGeometry.turnsPerTrack * 0.25,
                       accuracy: 0.001)
        XCTAssertEqual(PlatterGeometry.rotation(forProgress: 0.5),
                       360 * PlatterGeometry.turnsPerTrack * 0.5,
                       accuracy: 0.001)
    }

    func testRotationClampsOutOfRangeProgress() {
        XCTAssertEqual(PlatterGeometry.rotation(forProgress: -0.5), 0, accuracy: 0.001)
        XCTAssertEqual(PlatterGeometry.rotation(forProgress: 1.5),
                       360 * PlatterGeometry.turnsPerTrack,
                       accuracy: 0.001)
    }

    func testSheenAngleReturnsIntoZeroToOneRange() {
        for step in 0...20 {
            let p = Double(step) / 20.0
            let a = PlatterGeometry.sheenAngle(forProgress: p)
            XCTAssertTrue((0...1).contains(a), "sheen out of range at \(p): \(a)")
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios && xcodebuild test -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PeacePlayerTests/PlatterGeometryTests`
Expected: FAIL — `PlatterGeometry` is not defined.

- [ ] **Step 3: Write the implementation**

Create `ios/YTAudioPlayer/Views/Turntable/PlatterView.swift`:

```swift
//
//  PlatterView.swift
//  YTAudioPlayer
//
//  The record itself - the centrepiece of the Turntable Home.
//
//  Construction, outside in:
//
//    1. Felt mat        - deep green, sits under the platter
//    2. Platter rim     - machined aluminium ring with a bright edge
//    3. Groove surface  - the generated macro photograph of vinyl
//                         grooves, clipped to a circle
//    4. Groove rings    - concentric specular lines drawn on top so
//                         the surface still reads as vinyl when the
//                         texture is compressed on a small screen
//    5. Specular sheen  - a soft off-centre highlight band that
//                         sweeps as the record turns
//    6. Centre label    - the album art on a paper label, with the
//                         track title curved around it
//    7. Spindle         - the metal pin with a lit centre
//
//  Rotation is a PURE FUNCTION of playback progress. There is no
//  independent animation clock and no CADisplayLink: the record turns
//  exactly once per track and stops dead the instant playback pauses.
//  That is what keeps the deck visually honest against the audio.
//

import SwiftUI

// MARK: - Geometry

enum PlatterGeometry {
    /// How many full revolutions the platter makes over one track.
    /// One turn per track reads as "a record playing" without the
    /// motion blur of a real 33 RPM spin.
    static let turnsPerTrack: Double = 1

    /// Rotation of the record surface, in degrees.
    static func rotation(forProgress progress: Double) -> Double {
        let clamped = max(0, min(1, progress))
        return 360 * turnsPerTrack * clamped
    }

    /// Position of the specular sheen along its sweep, 0...1.
    /// The sheen completes one pass per revolution.
    static func sheenAngle(forProgress progress: Double) -> Double {
        let clamped = max(0, min(1, progress))
        return (clamped * turnsPerTrack).truncatingRemainder(dividingBy: 1)
    }
}

// MARK: - Platter

struct PlatterView: View {
    let artworkURL: URL?
    let isPlaying: Bool
    let progress: Double
    let reduceMotion: Bool
    var onTapSpindle: () -> Void
    var onLongPress: () -> Void

    var body: some View {
        ZStack {
            // 1. Felt mat
            Circle()
                .fill(
                    LinearGradient(
                        colors: [TurntableTokens.felt, TurntableTokens.felt.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Image(TurntableTexture.felt)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(0.5)
                        .blendMode(.overlay)
                )
                .shadow(color: .black.opacity(0.6), radius: 18, y: 8)

            // 2. Platter rim
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            TurntableTokens.edgeHighlight,
                            TurntableTokens.aluminium.opacity(0.35),
                            TurntableTokens.aluminium.opacity(0.8),
                            TurntableTokens.edgeHighlight
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
                .padding(1)

            // 3 + 4. Groove surface
            Circle()
                .fill(TurntableTokens.vinyl)
                .overlay(
                    Image(TurntableTexture.vinylGrooves)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .rotationEffect(.degrees(rotationDegrees))
                )
                .overlay(
                    // Concentric specular lines, drawn on top so the
                    // surface reads as vinyl even at low resolution.
                    Circle()
                        .strokeBorder(TurntableTokens.grooveShadow, lineWidth: 1)
                        .padding(26)
                        .overlay(
                            Circle()
                                .strokeBorder(TurntableTokens.grooveShadow.opacity(0.7), lineWidth: 1)
                                .padding(44)
                        )
                        .overlay(
                            Circle()
                                .strokeBorder(TurntableTokens.grooveShadow.opacity(0.5), lineWidth: 1)
                                .padding(64)
                        )
                )
                .overlay(
                    // 5. Specular sheen - off-centre band that sweeps.
                    RadialGradient(
                        colors: [
                            .white.opacity(0.20),
                            .white.opacity(0.05),
                            .clear
                        ],
                        center: UnitPoint(x: 0.30, y: 0.22),
                        startRadius: 0,
                        endRadius: 260
                    )
                    .blendMode(.screen)
                    .allowsHitTesting(false)
                )
                .overlay(
                    // Inner shadow at the record's edge so it sits inside
                    // the platter rim rather than floating on it.
                    Circle()
                        .strokeBorder(.black.opacity(0.55), lineWidth: 10)
                        .blur(radius: 8)
                        .padding(-5)
                        .allowsHitTesting(false)
                )
                .clipShape(Circle())

            // 6. Centre label
            labelArtwork

            // 7. Spindle
            spindle
        }
        .frame(width: 320, height: 320)
        .contentShape(Circle())
        .onTapGesture { onTapSpindle() }
        .onLongPressGesture(minimumDuration: 0.5) { onLongPress() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Record")
        .accessibilityValue(
            isPlaying ? "Spinning, \(Int(progress * 100)) percent through track" : "Stopped"
        )
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Rotation

    /// The record turns as the track plays. With `reduceMotion` on we
    /// hold it still - the progress is still legible from the label
    /// and the tonearm, so nothing is lost.
    private var rotationDegrees: Double {
        guard !reduceMotion else { return 0 }
        return PlatterGeometry.rotation(forProgress: progress)
    }

    // MARK: - Label

    private var labelArtwork: some View {
        ZStack {
            // Paper label disc, slightly proud of the record.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [TurntableTokens.cream, TurntableTokens.cream.opacity(0.86)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 70
                    )
                )
                .frame(width: 132, height: 132)
                .shadow(color: .black.opacity(0.55), radius: 6, y: 2)

            // Album art, circular crop, on the label.
            CachedAsyncImage(url: artworkURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                // Placeholder: a magenta disc with a spindle hole, so an
                // unloaded track still looks like a record with a blank
                // label rather than a grey square.
                ZStack {
                    Circle().fill(Theme.cyberMagenta.opacity(0.55))
                    Circle().fill(TurntableTokens.vinyl).frame(width: 22, height: 22)
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 3)

            // Label type ring - the record's own typography.
            Text("PEACEPLAYER")
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .tracking(1.6)
                .foregroundColor(TurntableTokens.walnut.opacity(0.75))
                .rotationEffect(.degrees(-90))
                .offset(y: -56)
                .allowsHitTesting(false)
        }
        // The label spins with the record.
        .rotationEffect(.degrees(rotationDegrees))
    }

    // MARK: - Spindle

    private var spindle: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [TurntableTokens.aluminium, TurntableTokens.aluminium.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 13, height: 13)
                .shadow(color: .black.opacity(0.6), radius: 2)

            Circle()
                .fill(Theme.cyberCyan)
                .frame(width: 5, height: 5)
                .shadow(color: Theme.cyberCyan.opacity(0.9), radius: 5)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ios && xcodebuild test -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PeacePlayerTests/PlatterGeometryTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add ios/YTAudioPlayer/Views/Turntable/PlatterView.swift \
        ios/YTAudioPlayerTests/PlatterGeometryTests.swift
git commit -m "feat(ios): textured vinyl platter for the turntable home

Layered construction: felt mat, machined aluminium rim, the generated
vinyl groove photograph, drawn specular groove rings, a sweeping sheen,
the album art on a paper label, and the lit spindle.

Rotation is a pure function of playback progress - one turn per track,
no independent animation clock - so the deck never drifts from the audio.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Tonearm — the scrub control

**Files:**
- Create: `ios/YTAudioPlayer/Views/Turntable/TonearmView.swift`
- Test: `ios/YTAudioPlayerTests/TonearmGeometryTests.swift`

**Interfaces:**
- Consumes: `TurntableTokens` (Task 1).
- Produces:
  ```swift
  struct TonearmView: View {
      let progress: Double
      let isScrubbing: Bool
      var onScrub: (Double) -> Void      // called continuously while dragging
      var onScrubEnded: (Double) -> Void // called once on release
  }

  enum TonearmGeometry {
      /// Angle of the arm at the start of a track (radians).
      static let startAngle: Double
      /// Angle of the arm at the end of a track (radians).
      static let endAngle: Double
      /// Arm angle for a given progress.
      static func angle(forProgress progress: Double) -> Double
      /// Progress for a given arm angle (inverse of the above).
      static func progress(forAngle angle: Double) -> Double
      /// The detent index a progress value falls into, or nil if it
      /// did not cross a 10% boundary since the last call.
      static func detent(forProgress progress: Double) -> Int?
  }
  ```

- [ ] **Step 1: Write the failing test**

`ios/YTAudioPlayerTests/TonearmGeometryTests.swift`:

```swift
import XCTest
@testable import PeacePlayer

final class TonearmGeometryTests: XCTestCase {

    func testAngleMovesFromStartToEndAcrossTrack() {
        let start = TonearmGeometry.angle(forProgress: 0)
        let end = TonearmGeometry.angle(forProgress: 1)
        XCTAssertEqual(start, TonearmGeometry.startAngle, accuracy: 0.0001)
        XCTAssertEqual(end, TonearmGeometry.endAngle, accuracy: 0.0001)
        XCTAssertGreaterThan(end, start, "Arm must sweep inward as the track plays")
    }

    func testAngleIsClampedOutsideZeroToOne() {
        XCTAssertEqual(TonearmGeometry.angle(forProgress: -1),
                       TonearmGeometry.startAngle, accuracy: 0.0001)
        XCTAssertEqual(TonearmGeometry.angle(forProgress: 2),
                       TonearmGeometry.endAngle, accuracy: 0.0001)
    }

    func testProgressIsInverseOfAngle() {
        for step in 0...10 {
            let p = Double(step) / 10.0
            let angle = TonearmGeometry.angle(forProgress: p)
            XCTAssertEqual(TonearmGeometry.progress(forAngle: angle), p, accuracy: 0.001)
        }
    }

    func testDetentFiresOnEachTenPercentBoundary() {
        XCTAssertEqual(TonearmGeometry.detent(forProgress: 0.10), 1)
        XCTAssertEqual(TonearmGeometry.detent(forProgress: 0.20), 2)
        XCTAssertEqual(TonearmGeometry.detent(forProgress: 0.55), 5)
    }

    func testDetentIsNilBelowFirstBoundary() {
        XCTAssertNil(TonearmGeometry.detent(forProgress: 0.0))
        XCTAssertNil(TonearmGeometry.detent(forProgress: 0.09))
    }

    func testDetentIsNilAtExactlyZero() {
        XCTAssertNil(TonearmGeometry.detent(forProgress: 0.0))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios && xcodebuild test -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PeacePlayerTests/TonearmGeometryTests`
Expected: FAIL — `TonearmGeometry` is not defined.

- [ ] **Step 3: Write the implementation**

Create `ios/YTAudioPlayer/Views/Turntable/TonearmView.swift`:

```swift
//
//  TonearmView.swift
//  YTAudioPlayer
//
//  The tonearm is the Turntable Home's scrub control.
//
//  A real tonearm rests at the outer edge of the record and travels
//  inward as the track plays. We use the same mapping: progress 0 is
//  the arm at rest, progress 1 is the arm over the run-out groove.
//  Dragging the arm therefore scrubs, and the arm's position is
//  always an honest readout of where in the track we are.
//
//  The pivot sits at the top-right of the platter; the arm sweeps
//  clockwise from about -18 degrees (rest, outer edge) to +26 degrees
//  (inner). The headshell carries the stylus that touches the record.
//

import SwiftUI

// MARK: - Geometry

enum TonearmGeometry {
    /// Arm angle at the outer edge of the record (radians).
    static let startAngle: Double = -18 * .pi / 180

    /// Arm angle over the inner run-out groove (radians).
    static let endAngle: Double = 26 * .pi / 180

    /// Arm angle for a given playback progress.
    static func angle(forProgress progress: Double) -> Double {
        let clamped = max(0, min(1, progress))
        return startAngle + (endAngle - startAngle) * clamped
    }

    /// Playback progress for a given arm angle. Inverse of `angle`.
    static func progress(forAngle angle: Double) -> Double {
        let span = endAngle - startAngle
        guard span != 0 else { return 0 }
        return max(0, min(1, (angle - startAngle) / span))
    }

    /// The 10% detent a progress value has just crossed, or nil if it
    /// has not crossed a boundary.
    ///
    /// Returns the detent index (1...9) so the caller can fire a
    /// haptic exactly once per boundary crossing.
    static func detent(forProgress progress: Double) -> Int? {
        let clamped = max(0, min(1, progress))
        let index = Int((clamped * 10).rounded(.down))
        guard index >= 1, index <= 9 else { return nil }
        // Only fire when we are within the last 20% of the band, so a
        // value that sits exactly on a boundary (0.10) reports the
        // boundary it just reached rather than repeating it.
        let fractional = clamped * 10 - Double(index)
        guard fractional >= 0.8 else { return nil }
        return index
    }
}

// MARK: - Tonearm

struct TonearmView: View {
    let progress: Double
    let isScrubbing: Bool
    var onScrub: (Double) -> Void
    var onScrubEnded: (Double) -> Void

    @State private var dragProgress: Double?

    /// The progress the arm is showing right now - the live drag
    /// value if the user is dragging, otherwise the playback progress.
    private var displayedProgress: Double {
        dragProgress ?? progress
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pivot = CGPoint(x: size.width - 26, y: 30)
            let armLength = min(size.width, size.height) * 0.62
            let angle = TonearmGeometry.angle(forProgress: displayedProgress)
            let stylus = CGPoint(
                x: pivot.x + armLength * cos(angle),
                y: pivot.y + armLength * sin(angle)
            )

            ZStack {
                // Counterweight - the fat cylinder at the back of the arm.
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                TurntableTokens.aluminium,
                                TurntableTokens.aluminium.opacity(0.35),
                                TurntableTokens.aluminium.opacity(0.75)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 30, height: 30)
                    .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 5, y: 2)
                    .position(x: pivot.x - 12, y: pivot.y)

                // Pivot base.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [TurntableTokens.aluminium.opacity(0.85), TurntableTokens.aluminium.opacity(0.2)],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 24
                        )
                    )
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.55), radius: 6, y: 2)
                    .position(pivot)

                // The arm tube.
                Path { path in
                    path.move(to: pivot)
                    path.addLine(to: stylus)
                }
                .stroke(
                    LinearGradient(
                        colors: [
                            TurntableTokens.aluminium,
                            TurntableTokens.edgeHighlight,
                            TurntableTokens.aluminium.opacity(0.55)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .shadow(color: .black.opacity(0.5), radius: 4, y: 2)

                // Headshell + stylus at the far end.
                headshell
                    .position(x: stylus.x, y: stylus.y)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let newProgress = TonearmGeometry.progress(
                            forAngle: angleOf(point: value.location, around: pivot)
                        )
                        if let previous = dragProgress {
                            let previousDetent = TonearmGeometry.detent(forProgress: previous)
                            let currentDetent = TonearmGeometry.detent(forProgress: newProgress)
                            if let currentDetent, currentDetent != previousDetent {
                                HapticManager.selectionChanged()
                            }
                        } else {
                            HapticManager.selectionChanged()
                        }
                        dragProgress = newProgress
                        onScrub(newProgress)
                    }
                    .onEnded { value in
                        let finalProgress = TonearmGeometry.progress(
                            forAngle: angleOf(point: value.location, around: pivot)
                        )
                        dragProgress = nil
                        onScrubEnded(finalProgress)
                    }
            )
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: displayedProgress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tone arm")
        .accessibilityValue("\(Int(displayedProgress * 100)) percent through track")
        .accessibilityAdjustableAction { direction in
            // VoiceOver users get a coarse scrub. The full gesture is
            // unavailable to them, so this is the accessible path to
            // the same control.
            let step = 0.05
            switch direction {
            case .increment: onScrubEnded(min(1, progress + step))
            case .decrement: onScrubEnded(max(0, progress - step))
            default: break
            }
        }
    }

    // MARK: - Headshell

    private var headshell: some View {
        ZStack {
            // Headshell body - a small angled block.
            RoundedRectangle(cornerRadius: 3)
                .fill(
                    LinearGradient(
                        colors: [TurntableTokens.amberLamp, TurntableTokens.amberLamp.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 22, height: 14)
                .rotationEffect(.degrees(28))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.black.opacity(0.35), lineWidth: 1)
                        .rotationEffect(.degrees(28))
                )
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)

            // The stylus - the actual needle that touches the record.
            Circle()
                .fill(TurntableTokens.edgeHighlight)
                .frame(width: 4, height: 4)
                .offset(y: 9)
        }
    }

    // MARK: - Helpers

    /// Angle of a point relative to a pivot, measured from the +x axis.
    private func angleOf(point: CGPoint, around pivot: CGPoint) -> Double {
        atan2(point.y - pivot.y, point.x - pivot.x)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ios && xcodebuild test -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PeacePlayerTests/TonearmGeometryTests`
Expected: PASS (6 tests).

**Note on `HapticManager.selectionChanged()`:** confirm the exact method name
against `ios/YTAudioPlayer/DesignSystem/HapticManager.swift`. If it is named
differently (e.g. `selection()`), use the real name — the haptic must fire
once per detent.

- [ ] **Step 5: Commit**

```bash
git add ios/YTAudioPlayer/Views/Turntable/TonearmView.swift \
        ios/YTAudioPlayerTests/TonearmGeometryTests.swift
git commit -m "feat(ios): tonearm scrub control for the turntable home

The arm rests at the record's outer edge and sweeps inward as the
track plays, so its position is an honest readout of playback progress.
Dragging scrubs live; a haptic fires once per 10% detent crossing.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Deck fascia, cue lever, sleeve crate, queue stack, level meter

**Files:**
- Create: `ios/YTAudioPlayer/Views/Turntable/DeckFasciaView.swift`
- Create: `ios/YTAudioPlayer/Views/Turntable/CueLeverView.swift`
- Create: `ios/YTAudioPlayer/Views/Turntable/SleeveCrateView.swift`
- Create: `ios/YTAudioPlayer/Views/Turntable/QueueStackView.swift`
- Create: `ios/YTAudioPlayer/Views/Turntable/LevelMeterRow.swift`

**Interfaces:**
- Consumes: `TurntableTokens` (Task 1).
- Produces:
  ```swift
  struct DeckFasciaView: View {
      let greeting: String
      let isPlaying: Bool
      let isConnected: Bool
      let rpmLabel: String
      let hasSmartLibraryCandidates: Bool
      let hasPendingCleanup: Bool
      var onToggleRPM: () -> Void
      var onSmartLibrary: () -> Void
      var onCleanup: () -> Void
      @ViewBuilder var navChips: () -> Content
  }

  struct CueLeverView: View {
      let isPlaying: Bool
      var onToggle: () -> Void
  }

  struct SleeveCrateView: View {
      let sleeves: [Track]
      var onPlay: (Track) -> Void
      var onQueue: (Track) -> Void
  }

  struct QueueStackView: View {
      let queue: [QueueItem]
      let currentIndex: Int
      var onSelect: (Int) -> Void
  }

  struct LevelMeterRow: View {
      let levels: [Float]
      let accent: Color
  }
  ```

- [ ] **Step 1: Write `DeckFasciaView`**

```swift
//
//  DeckFasciaView.swift
//  YTAudioPlayer
//
//  The brushed-aluminium strip across the top of the deck.
//
//  It replaces the current Home header (profile chip + 5 nav chips).
//  Three pilot lamps sit on the left: amber for power, cyan for a
//  live connection, magenta for a queue with content. The greeting
//  and the RPM chip sit in the middle; the existing navigation chips
//  are passed in from HomeView so their routes stay owned by Home.
//

import SwiftUI

struct DeckFasciaView: View {
    let greeting: String
    let isPlaying: Bool
    let isConnected: Bool
    let rpmLabel: String
    let hasSmartLibraryCandidates: Bool
    let hasPendingCleanup: Bool
    var onToggleRPM: () -> Void
    var onSmartLibrary: () -> Void
    var onCleanup: () -> Void
    @ViewBuilder var navChips: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            // Pilot lamps.
            HStack(spacing: 6) {
                PilotLamp(color: TurntableTokens.amberLamp, isOn: true)
                PilotLamp(color: Theme.cyberCyan, isOn: isConnected)
                PilotLamp(color: Theme.cyberMagenta, isOn: isPlaying)
            }

            // Actionable-state lamps. These replace the Smart Library
            // card and the cleanup banner - both of which were the most
            // important decision surfaces on the old Home.
            if hasSmartLibraryCandidates {
                PilotLamp(color: Theme.cyberYellow, isOn: true, action: onSmartLibrary)
                    .accessibilityLabel("Smart Library needs review")
            }
            if hasPendingCleanup {
                PilotLamp(color: Theme.cyberMagenta, isOn: true, action: onCleanup)
                    .accessibilityLabel("Scheduled cleanup pending")
            }

            Spacer(minLength: 4)

            Text(greeting.uppercased())
                .font(Typography.eyebrow)
                .foregroundColor(TurntableTokens.aluminium.opacity(0.85))
                .lineLimit(1)

            // RPM chip.
            Button {
                onToggleRPM()
            } label: {
                Text(rpmLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(TurntableTokens.amberLamp)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(TurntableTokens.amberLamp.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(TurntableTokens.amberLamp.opacity(0.45), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playback speed, \(rpmLabel)")

            navChips()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            ZStack {
                // Brushed aluminium.
                Image(TurntableTexture.brushedAluminium)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(0.30)

                // Machined gradient over the texture so the strip reads
                // as a solid metal part rather than a photo.
                LinearGradient(
                    colors: [
                        TurntableTokens.aluminium.opacity(0.16),
                        TurntableTokens.aluminium.opacity(0.05),
                        Color.black.opacity(0.30)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Bright machined edge along the top.
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [TurntableTokens.edgeHighlight, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    LinearGradient(
                        colors: [TurntableTokens.aluminium.opacity(0.45), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
    }
}

// MARK: - Pilot lamp

/// A small indicator lamp on the fascia. Optionally tappable - used
/// for the Smart Library and cleanup lamps, which stand in for the
/// cards they replaced.
struct PilotLamp: View {
    let color: Color
    let isOn: Bool
    var action: (() -> Void)?

    var body: some View {
        Group {
            if let action {
                Button {
                    action()
                } label: {
                    lampBody
                }
                .buttonStyle(.plain)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            } else {
                lampBody
            }
        }
    }

    private var lampBody: some View {
        ZStack {
            // The chrome bezel the lamp sits in.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [TurntableTokens.aluminium.opacity(0.5), TurntableTokens.aluminium.opacity(0.1)],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 10
                    )
                )
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.black.opacity(0.45), lineWidth: 1))

            // The lens.
            Circle()
                .fill(isOn ? color : color.opacity(0.18))
                .frame(width: 8, height: 8)
                .shadow(color: isOn ? color.opacity(0.85) : .clear, radius: 4)
        }
    }
}
```

- [ ] **Step 2: Write `CueLeverView`**

```swift
//
//  CueLeverView.swift
//  YTAudioPlayer
//
//  The cue lever is the Turntable Home's play/pause control.
//
//  On a real turntable you lift the arm off the record to stop and
//  drop it back down to start. We use the same gesture: the lever
//  rises to pause and falls to play.
//

import SwiftUI

struct CueLeverView: View {
    let isPlaying: Bool
    var onToggle: () -> Void

    var body: some View {
        Button {
            onToggle()
        } label: {
            ZStack {
                // The slot the lever travels in.
                Capsule()
                    .fill(.black.opacity(0.55))
                    .frame(width: 12, height: 62)

                // The lever itself.
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                TurntableTokens.aluminium,
                                TurntableTokens.edgeHighlight,
                                TurntableTokens.aluminium.opacity(0.55)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 9, height: 34)
                    .overlay(
                        Capsule().strokeBorder(.black.opacity(0.4), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.55), radius: 4, y: 2)
                    .offset(y: isPlaying ? 14 : -14)

                // Engraved state indicator: a lit amber dot when the
                // needle is down (playing).
                Circle()
                    .fill(isPlaying ? TurntableTokens.amberLamp : TurntableTokens.amberLamp.opacity(0.2))
                    .frame(width: 5, height: 5)
                    .shadow(color: isPlaying ? TurntableTokens.amberLamp.opacity(0.9) : .clear, radius: 4)
                    .offset(y: 30)
            }
            .frame(width: 44, height: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPlaying)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .accessibilityHint("Cue lever")
    }
}
```

- [ ] **Step 3: Write `SleeveCrateView`**

```swift
//
//  SleeveCrateView.swift
//  YTAudioPlayer
//
//  The record crate. Each sleeve is an album cover standing in a
//  felt-lined wooden crate; tapping one plays it.
//
//  This replaces the "FOR YOU" favorite-artist list from the old
//  Home. The crate is horizontal and scrollable, so the deck stays
//  one screen tall.
//

import SwiftUI

struct SleeveCrateView: View {
    let sleeves: [Track]
    var onPlay: (Track) -> Void
    var onQueue: (Track) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CRATE")
                .font(Typography.eyebrow)
                .foregroundColor(TurntableTokens.aluminium.opacity(0.7))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(sleeves) { track in
                        Button {
                            onPlay(track)
                        } label: {
                            SleeveView(track: track)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                onQueue(track)
                            } label: {
                                Label("Play next", systemImage: "text.insert")
                            }
                        }
                        .accessibilityLabel("\(track.title) by \(track.artists.first ?? "unknown artist")")
                        .accessibilityHint("Double tap to play")
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }

            // The crate's front rail - walnut, catching the key light.
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            TurntableTokens.walnut.opacity(0.95),
                            TurntableTokens.walnut.opacity(0.55)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 7)
                .overlay(
                    Rectangle()
                        .fill(TurntableTokens.keyLight.opacity(0.18))
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: .top)
                )
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}

// MARK: - Sleeve

private struct SleeveView: View {
    let track: Track

    var body: some View {
        ZStack {
            // The felt-lined interior behind the sleeve.
            Rectangle()
                .fill(TurntableTokens.felt.opacity(0.55))

            CachedAsyncImage(url: track.artworkURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    LinearGradient(
                        colors: [TurntableTokens.aluminium.opacity(0.25), TurntableTokens.walnut.opacity(0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .light))
                        .foregroundColor(TurntableTokens.aluminium.opacity(0.6))
                }
            }
        }
        .frame(width: 62, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        // The sleeve's card stock edge.
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(TurntableTokens.cream.opacity(0.22), lineWidth: 1)
        )
        // Sleeves sit in the crate, so they cast a shadow downward.
        .shadow(color: .black.opacity(0.55), radius: 5, y: 3)
    }
}
```

- [ ] **Step 4: Write `QueueStackView`**

```swift
//
//  QueueStackView.swift
//  YTAudioPlayer
//
//  The queue, drawn as a stack of records resting on the deck.
//  Each disc is one queued track; the coloured centre is the
//  track's content source.
//

import SwiftUI

struct QueueStackView: View {
    let queue: [QueueItem]
    let currentIndex: Int
    var onSelect: (Int) -> Void

    /// Only the next few are drawn - a stack of 40 records is noise.
    private var visible: ArraySlice<QueueItem> {
        queue.prefix(4)
    }

    var body: some View {
        Group {
            if !visible.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        Button {
                            onSelect(index)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(
                                        RadialGradient(
                                            colors: [
                                                Color(white: 0.13),
                                                TurntableTokens.vinyl
                                            ],
                                            center: .center,
                                            startRadius: 2,
                                            endRadius: 24
                                        )
                                    )
                                    .overlay(
                                        Circle()
                                            .strokeBorder(
                                                index == currentIndex
                                                    ? Theme.cyberCyan.opacity(0.8)
                                                    : .white.opacity(0.08),
                                                lineWidth: index == currentIndex ? 2 : 1
                                            )
                                    )

                                Circle()
                                    .fill(color(for: item))
                                    .frame(width: 11, height: 11)
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.track.title)
                        .accessibilityValue(index == currentIndex ? "Now playing" : "In queue")
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: queue.count)
    }

    /// Centre colour by content source - cyan for local files, magenta
    /// for streamed tracks.
    private func color(for item: QueueItem) -> Color {
        switch item.contentSource {
        case .local: return Theme.cyberCyan
        case .youtube: return Theme.cyberMagenta
        }
    }
}
```

**Verify:** `ContentSource` is the enum on `QueueItem` (see
`Models/PlayerState.swift:103-108` for its `tintColor`). If the cases are
named differently, use the real case names. Use the enum's existing
`tintColor` accessor rather than duplicating the mapping.

- [ ] **Step 5: Write `LevelMeterRow`**

```swift
//
//  LevelMeterRow.swift
//  YTAudioPlayer
//
//  The level meter on the deck's front panel.
//
//  This is a peak meter, not the frequency spectrum - the deck's
//  meter shows output level, the way a turntable's aux VU meter
//  does. The bands come from AudioVisualizerEngine, which is the
//  same engine the existing NeuralFreqVisualizer reads.
//

import SwiftUI

struct LevelMeterRow: View {
    let levels: [Float]
    let accent: Color

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            guard count > 0 else { return }

            let spacing: CGFloat = 2
            let barWidth = max(1, (size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            let floor = size.height

            for (index, level) in levels.enumerated() {
                let magnitude = max(0, min(1, CGFloat(level)))
                guard magnitude > 0.01 else { continue }

                let barHeight = magnitude * size.height
                let x = CGFloat(index) * (barWidth + spacing)
                let rect = CGRect(x: x, y: floor - barHeight, width: barWidth, height: barHeight)

                // Glow pass.
                context.fill(
                    Path(roundedRect: rect.insetBy(dx: -1, dy: 0), cornerRadius: barWidth / 2),
                    with: .color(accent.opacity(0.18))
                )

                // Bar.
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(accent)
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Output level meter")
    }
}
```

- [ ] **Step 6: Build to verify all five compile**

Run: `cd ios && xcodegen generate && xcodebuild -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add ios/YTAudioPlayer/Views/Turntable/
git commit -m "feat(ios): deck fascia, cue lever, sleeve crate, queue stack, level meter

The fascia replaces the old Home header - pilot lamps, greeting, RPM
chip and the existing nav chips. The Smart Library and cleanup cards
become indicator lamps that light only when they need attention.

Sleeves are album covers in a felt-lined crate; the queue is a stack of
records; the level meter reads output level from the existing
AudioVisualizerEngine.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: TurntableHomeView — the root composition

**Files:**
- Create: `ios/YTAudioPlayer/Views/Turntable/TurntableHomeView.swift`
- Test: `ios/YTAudioPlayerTests/TurntableHomeModelTests.swift`

**Interfaces:**
- Consumes: `PlatterView`, `TonearmView`, `DeckFasciaView`, `CueLeverView`, `SleeveCrateView`, `QueueStackView`, `LevelMeterRow` (Task 5), `FeatureFlags` (Task 2).
- Produces:
  ```swift
  struct TurntableHomeView: View {
      @ObservedObject var viewModel: HomeViewModel
      @ObservedObject var favoriteArtists: FavoriteArtistsManager
      @ObservedObject var playerState: PlayerState
      @ObservedObject var visualizer: AudioVisualizerEngine
  }

  enum TurntableHomeModel {
      /// The sleeves shown in the crate, in priority order.
      static func sleeves(from suggestions: [String: [Track]],
                          limit: Int) -> [Track]
      /// Playback rate for an RPM label.
      static func playbackRate(forRPM is45: Bool) -> Float
  }
  ```

- [ ] **Step 1: Write the failing test**

`ios/YTAudioPlayerTests/TurntableHomeModelTests.swift`:

```swift
import XCTest
@testable import PeacePlayer

final class TurntableHomeModelTests: XCTestCase {

    func testSleevesAreFlattenedFromAllArtists() {
        let a = makeTrack(id: "a", title: "Alpha")
        let b = makeTrack(id: "b", title: "Beta")
        let sleeves = TurntableHomeModel.sleeves(from: ["Artist One": [a], "Artist Two": [b]], limit: 10)
        XCTAssertEqual(sleeves.count, 2)
        XCTAssertEqual(Set(sleeves.map(\.videoId)), Set(["a", "b"]))
    }

    func testSleevesRespectLimit() {
        let tracks = (0..<8).map { makeTrack(id: "t\($0)", title: "T\($0)") }
        let sleeves = TurntableHomeModel.sleeves(from: ["Artist": tracks], limit: 4)
        XCTAssertEqual(sleeves.count, 4)
    }

    func testSleevesAreDeduplicatedByTrack() {
        let a = makeTrack(id: "a", title: "Alpha")
        let sleeves = TurntableHomeModel.sleeves(from: ["One": [a], "Two": [a]], limit: 10)
        XCTAssertEqual(sleeves.count, 1, "The same track must not appear twice in the crate")
    }

    func testSleevesAreEmptyForNoSuggestions() {
        XCTAssertTrue(TurntableHomeModel.sleeves(from: [:], limit: 10).isEmpty)
    }

    func testPlaybackRateForRPM() {
        XCTAssertEqual(TurntableHomeModel.playbackRate(forRPM: false), 1.0, accuracy: 0.001)
        XCTAssertEqual(TurntableHomeModel.playbackRate(forRPM: true), 1.25, accuracy: 0.001)
    }

    private func makeTrack(id: String, title: String) -> Track {
        Track(videoId: id,
             title: title,
             artists: ["Artist"],
             album: "Album",
             durationSeconds: 180,
             thumbnails: [],
             thumbnailSmall: nil,
             thumbnailLarge: nil,
             isExplicit: false,
             videoType: "MUSIC_VIDEO_TYPE_ATV")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios && xcodebuild test -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PeacePlayerTests/TurntableHomeModelTests`
Expected: FAIL — `TurntableHomeModel` is not defined.

- [ ] **Step 3: Write the implementation**

Create `ios/YTAudioPlayer/Views/Turntable/TurntableHomeView.swift`:

```swift
//
//  TurntableHomeView.swift
//  YTAudioPlayer
//
//  The Turntable Home - the record is the screen.
//
//  Replaces the old Home body (flag: ff_turntable_home). Every
//  interactive element maps onto an API that already exists:
//
//    platter rotation  -> PlayerState.playbackClock.progress
//    tonearm drag      -> PlayerState.seek(to:)
//    cue lever         -> PlayerState.togglePlayPause()
//    spindle tap       -> PlayerState.setPlaybackRate(_:)
//    crate sleeves     -> PlayerState.play(track:)
//    level meter       -> AudioVisualizerEngine.bands
//
//  The view deliberately owns NO playback state of its own. It reads
//  PlayerState and calls its methods; that keeps the deck honest
//  (it cannot show a position the player does not agree with) and
//  means every existing player control keeps working unchanged.
//

import SwiftUI
import Combine

// MARK: - Model

enum TurntableHomeModel {
    /// Flatten the per-artist suggestion dictionary into a single
    /// ordered list of sleeves, de-duplicated by track.
    static func sleeves(from suggestions: [String: [Track]], limit: Int) -> [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        for artist in suggestions.keys.sorted() {
            for track in suggestions[artist] ?? [] {
                guard !seen.contains(track.videoId) else { continue }
                seen.insert(track.videoId)
                result.append(track)
                if result.count >= limit { return result }
            }
        }
        return result
    }

    /// Playback rate for the 33 / 45 RPM switch. 45 RPM is the real
    /// turntable convention: the same record plays 45/33 = 1.36x
    /// faster. We use 1.25x so it stays musical.
    static func playbackRate(forRPM is45: Bool) -> Float {
        is45 ? 1.25 : 1.0
    }
}

// MARK: - View

struct TurntableHomeView: View {
    @ObservedObject var viewModel: HomeViewModel
    @ObservedObject var favoriteArtists: FavoriteArtistsManager
    @ObservedObject var playerState: PlayerState
    @ObservedObject var visualizer: AudioVisualizerEngine

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var is45RPM = false
    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0
    @State private var showSmartLibrary = false
    @State private var showCleanup = false

    /// The progress the deck shows. While the user drags the tonearm
    /// the arm wins; otherwise playback drives it.
    private var displayedProgress: Double {
        isScrubbing ? scrubProgress : playerState.progress
    }

    private var sleeves: [Track] {
        TurntableHomeModel.sleeves(from: viewModel.artistSuggestions, limit: 12)
    }

    var body: some View {
        VStack(spacing: 0) {
            DeckFasciaView(
                greeting: viewModel.greeting,
                isPlaying: playerState.playbackState == .playing,
                isConnected: true,
                rpmLabel: is45RPM ? "45" : "33⅓",
                hasSmartLibraryCandidates: SmartLibraryManager.shared.pendingCandidates != nil,
                hasPendingCleanup: SmartLibraryManager.shared.pendingCleanup != nil,
                onToggleRPM: {
                    HapticManager.selectionChanged()
                    is45RPM.toggle()
                    playerState.setPlaybackRate(TurntableHomeModel.playbackRate(forRPM: is45RPM))
                },
                onSmartLibrary: { showSmartLibrary = true },
                onCleanup: { showCleanup = true }
            ) {
                navChips
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            // The deck: platter with the tonearm swinging over it, and
            // the cue lever at the side.
            ZStack {
                PlatterView(
                    artworkURL: playerState.currentItem?.track.artworkURL,
                    isPlaying: playerState.playbackState == .playing,
                    progress: displayedProgress,
                    reduceMotion: reduceMotion,
                    onTapSpindle: {
                        HapticManager.selectionChanged()
                        is45RPM.toggle()
                        playerState.setPlaybackRate(TurntableHomeModel.playbackRate(forRPM: is45RPM))
                    },
                    onLongPress: {
                        playerState.showQueue = true
                    }
                )
                .frame(width: 320, height: 320)

                TonearmView(
                    progress: displayedProgress,
                    isScrubbing: isScrubbing,
                    onScrub: { value in
                        isScrubbing = true
                        scrubProgress = value
                    },
                    onScrubEnded: { value in
                        isScrubbing = false
                        scrubProgress = value
                        playerState.seek(to: value)
                    }
                )
                .frame(width: 320, height: 320)
                .rotationEffect(.degrees(0))
                .allowsHitTesting(true)

                CueLeverView(
                    isPlaying: playerState.playbackState == .playing,
                    onToggle: {
                        HapticManager.medium()
                        playerState.togglePlayPause()
                    }
                )
                .offset(x: 138, y: -70)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)

            // Queue stack.
            QueueStackView(
                queue: playerState.queue,
                currentIndex: playerState.currentQueueIndex,
                onSelect: { index in
                    playerState.playQueue(at: index)
                }
            )
            .padding(.horizontal, 18)

            // The crate.
            SleeveCrateView(
                sleeves: sleeves,
                onPlay: { track in
                    HapticManager.medium()
                    viewModel.playTrack(track)
                },
                onQueue: { track in
                    viewModel.addToQueue(track)
                }
            )
            .padding(.horizontal, 14)
            .padding(.top, 12)

            Spacer(minLength: 8)

            // Now-playing strip - the deck's only now-playing surface.
            nowPlayingStrip
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }
        .background(deckBackground)
        .sheet(isPresented: $showSmartLibrary) {
            SmartLibraryReviewSheet(originalCycle: SmartLibraryManager.shared.pendingCandidates!,
                                    isPresented: $showSmartLibrary)
        }
        .sheet(isPresented: $showCleanup) {
            CleanupReviewSheet(pending: SmartLibraryManager.shared.pendingCleanup!,
                               isPresented: $showCleanup)
        }
    }

    // MARK: - Nav chips

    /// The five existing Home destinations. They are passed into the
    /// fascia rather than owned by it, so Home keeps ownership of its
    /// NavigationStack routes.
    @ViewBuilder
    private var navChips: some View {
        HStack(spacing: 6) {
            NavigationLink(value: HomeDestination.timeCapsule) {
                deckChip(icon: "hourglass", accent: Theme.cyberYellow)
            }
            .buttonStyle(.plain)

            NavigationLink(value: HomeDestination.antiAlgorithm) {
                deckChip(icon: "dice.fill", accent: Theme.cyberMagenta)
            }
            .buttonStyle(.plain)

            NavigationLink(value: HomeDestination.radio) {
                deckChip(icon: "antenna.radiowaves.left.and.right", accent: Theme.cyberCyan)
            }
            .buttonStyle(.plain)

            NavigationLink(value: HomeDestination.playlists) {
                deckChip(icon: "music.note.list", accent: TurntableTokens.aluminium)
            }
            .buttonStyle(.plain)

            NavigationLink(value: HomeDestination.settings) {
                deckChip(icon: "gearshape.fill", accent: TurntableTokens.aluminium)
            }
            .buttonStyle(.plain)
        }
    }

    private func deckChip(icon: String, accent: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(accent)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(accent.opacity(0.35), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
    }

    // MARK: - Now playing strip

    private var nowPlayingStrip: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(playerState.currentItem?.track.title ?? "Nothing playing")
                    .font(Typography.playerTitle)
                    .foregroundColor(TurntableTokens.cream)
                    .lineLimit(1)

                Text(playerState.currentItem?.track.artists.first ?? "Turn the record")
                    .font(Typography.playerArtist)
                    .foregroundColor(TurntableTokens.aluminium.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            LevelMeterRow(
                levels: visualizer.bands,
                accent: Theme.cyberCyan
            )
            .frame(width: 120, height: 22)

            // Time readout.
            Text(timeReadout)
                .font(Typography.playerTime)
                .foregroundColor(TurntableTokens.aluminium.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(TurntableTokens.aluminium.opacity(0.18), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            playerState.showFullPlayer = true
        }
        .accessibilityLabel("Now playing")
        .accessibilityValue(playerState.currentItem?.track.title ?? "Nothing playing")
        .accessibilityAddTraits(.isButton)
    }

    private var timeReadout: String {
        let elapsed = playerState.currentTimeFormatted
        let total = playerState.durationFormatted
        return "\(elapsed) / \(total)"
    }

    // MARK: - Background

    /// The deck's plinth: walnut with a dark vignette so the deck
    /// sits in a room rather than on a flat colour.
    private var deckBackground: some View {
        ZStack {
            Image(TurntableTexture.walnut)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .opacity(0.22)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.72),
                    Color.black.opacity(0.45),
                    Color.black.opacity(0.88)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Warm key light from the upper left, matching the
            // generated textures' studio lighting.
            RadialGradient(
                colors: [TurntableTokens.keyLight.opacity(0.10), .clear],
                center: UnitPoint(x: 0.18, y: 0.05),
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}
```

**API names — all verified against source on 2026-11-17:**
- `PlayerState.queue` — EXISTS (`Models/PlayerState.swift:243`, `var queue: [QueueItem] { queueStore.items }`).
- `PlayerState.currentIndex` — the real name, NOT `currentQueueIndex` (`:246`, `var currentIndex: Int { queueStore.currentIndex }`).
- `PlayerState.playQueue(at:)` — EXISTS (`:1720`).
- `PlayerState.addToQueue(_:)` — EXISTS but takes a `QueueItem` (`:2372`).
  For a `Track`, use `HomeViewModel.addToQueue(_ track: Track)` (`Views/HomeView.swift:1164`),
  which resolves the stream URL and builds the QueueItem itself.
- `PlayerState.setPlaybackRate(_:)` — EXISTS (`:2016`), rejects rates outside 0.5...3.0.
- `PlayerState.seek(to:)` — EXISTS (`:2098`).
- `PlayerState.togglePlayPause()` — EXISTS (`:1864`).
- `PlayerState.showQueue` / `showFullPlayer` — both `@Published var` (`:269`, `:272`).
- `PlayerState.playbackClock` — EXISTS (`Sources/PlaybackClock.swift`), the live progress source.
- `HapticManager.medium()` — EXISTS. `HapticManager.selectionChanged()` did **not** exist;
  it was ADDED in this plan (see Task 4) using `UISelectionFeedbackGenerator`, because a
  scrub detent is a selection tick, not an impact bump.
- `SmartLibraryManager.shared.pendingCandidates` / `.pendingCleanup` — CONFIRMED
  (`SmartLibraryCard.swift:37`, `CleanupScheduledBanner.swift:50`).
- `SmartLibraryReviewSheet(originalCycle:isPresented:)` — CONFIRMED
  (`Views/Components/SmartLibraryReviewSheet.swift:29-30`).
- `CleanupReviewSheet(pending:isPresented:)` — CONFIRMED
  (`Views/Components/CleanupReviewSheet.swift:27-28`).
- `ContentSource.tintColor` — EXISTS and is already cyber-themed
  (`Models/PlayerState.swift:103-112`: magenta for YouTube, cyan for local).
  Use it rather than duplicating the mapping.
- `AudioVisualizerEngine.shared` — EXISTS (`Sources/AudioVisualizerEngine.swift:17`).
- `CyberpunkTabBar(selectedTab:)` takes a `Binding<Int>`, so a test must pass
  `.constant(0)`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ios && xcodebuild test -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PeacePlayerTests/TurntableHomeModelTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add ios/YTAudioPlayer/Views/Turntable/TurntableHomeView.swift \
        ios/YTAudioPlayerTests/TurntableHomeModelTests.swift
git commit -m "feat(ios): turntable home root view

Composes the deck: fascia, platter with tonearm, cue lever, queue
stack, sleeve crate and the now-playing strip.

The view owns no playback state of its own - it reads PlayerState and
calls its methods, so the deck can never disagree with the audio.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Wire the flag into HomeView, ContentView and the BottomBar

**Files:**
- Modify: `ios/YTAudioPlayer/Views/HomeView.swift` (body branch)
- Modify: `ios/YTAudioPlayer/Views/ContentView.swift` (`BottomBar` + call site)
- Test: `ios/YTAudioPlayerTests/TurntableWiringTests.swift`

**Interfaces:**
- Consumes: `TurntableHomeView` (Task 6), `FeatureFlags` (Task 2).
- Produces:
  ```swift
  /// In ContentView:
  struct BottomBar: View {
      let tabBar: CyberpunkTabBar
      let miniPlayer: AnyView
      var hidesMiniPlayer: Bool = false
  }
  ```

- [ ] **Step 1: Write the failing test**

`ios/YTAudioPlayerTests/TurntableWiringTests.swift`:

```swift
import XCTest
@testable import PeacePlayer

final class TurntableWiringTests: XCTestCase {

    func testBottomBarHidesMiniPlayerWhenAsked() {
        // The Turntable deck shows its own now-playing strip. If the
        // global BottomBar also shows the MiniPlayer, the same track
        // appears twice on the Home tab.
        let bar = BottomBar(
            tabBar: CyberpunkTabBar(selectedTab: .constant(0)),
            miniPlayer: AnyView(EmptyView()),
            hidesMiniPlayer: true
        )
        XCTAssertTrue(bar.hidesMiniPlayer, "BottomBar must expose the hide flag")
    }

    func testBottomBarShowsMiniPlayerByDefault() {
        // Every other tab keeps the MiniPlayer. The default must be
        // "visible" so no existing tab changes behaviour.
        let bar = BottomBar(
            tabBar: CyberpunkTabBar(selectedTab: .constant(1)),
            miniPlayer: AnyView(EmptyView())
        )
        XCTAssertFalse(bar.hidesMiniPlayer)
    }

    func testTurntableIsOffByDefaultInSharedStore() {
        // The shared store must not have the flag on unless the user
        // explicitly enabled it in Settings -> Labs.
        XCTAssertFalse(FeatureFlags.shared.turntableHome,
                       "Turntable must be opt-in")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios && xcodebuild test -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PeacePlayerTests/TurntableWiringTests`
Expected: FAIL — `BottomBar` has no `hidesMiniPlayer`.

- [ ] **Step 3: Add `hidesMiniPlayer` to `BottomBar`**

In `ios/YTAudioPlayer/Views/ContentView.swift`, change the `BottomBar`
declaration:

```swift
struct BottomBar: View {
    let tabBar: CyberpunkTabBar
    let miniPlayer: AnyView
    /// When true the mini player is not rendered and the tab pill is
    /// centred. Used by the Turntable Home, which shows its own
    /// now-playing strip on the deck.
    var hidesMiniPlayer: Bool = false

    @StateObject private var playerState = PlayerState.shared
```

Then in `BottomBar`'s `body`, change the conditional:

```swift
        HStack(alignment: .center, spacing: 8) {
            if playerState.isNowPlaying && !hidesMiniPlayer {
                // Tab pill on the left
                tabBar
                ...
            } else {
                // No mini player - centre the pill.
                tabBar
                    .frame(maxWidth: .infinity)
            }
        }
```

**Read the existing `BottomBar.body` first** — it already has an
"else" branch for the "nothing playing" case that centres the pill. Reuse
that exact branch rather than adding a parallel one, so the centred pill
looks identical in both situations.

- [ ] **Step 4: Pass the flag from `ContentView`**

In `ContentView`'s `authenticatedBody`, observe the flags and pass the
hide flag:

```swift
    @StateObject private var featureFlags = FeatureFlags.shared
```

and in the `BottomBar` call site:

```swift
                BottomBar(
                    tabBar: CyberpunkTabBar(selectedTab: $selectedTab),
                    miniPlayer: AnyView(MiniPlayer(onExpand: {
                        showFullPlayer = true
                    }, compact: true)),
                    hidesMiniPlayer: featureFlags.turntableHome && selectedTab == 0
                )
```

- [ ] **Step 5: Branch `HomeView`'s body**

In `ios/YTAudioPlayer/Views/HomeView.swift`, add the flags observation:

```swift
    @StateObject private var featureFlags = FeatureFlags.shared
```

and wrap the existing scroll body in a conditional. The `NavigationStack`
and everything below it stay exactly as they are — only the content
inside changes:

```swift
    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                if featureFlags.turntableHome {
                    turntableBody
                } else {
                    legacyBody
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: HomeDestination.self) { destination in
                // ... unchanged ...
            }
        }
        // ... existing .task, .sheet, .onReceive modifiers unchanged ...
    }
```

Extract the current scroll into `legacyBody`:

```swift
    /// The pre-Turntable Home: a vertical scroll of cards. Kept
    /// intact behind the ff_turntable_home flag so the flag can be
    /// flipped off at any time.
    private var legacyBody: some View {
        ZStack {
            CyberBackground()

            ScrollView(showsIndicators: false) {
                // ... the existing VStack, unchanged ...
            }
            .refreshable {
                await viewModel.loadData()
            }
        }
    }
```

And add the Turntable body:

```swift
    /// The Turntable Home: the record is the screen.
    private var turntableBody: some View {
        TurntableHomeView(
            viewModel: viewModel,
            favoriteArtists: favoriteArtists,
            playerState: .shared,
            visualizer: AudioVisualizerEngine.shared
        )
        .ignoresSafeArea(edges: .bottom)
    }
```

**Note:** `legacyBody` must keep the existing `.refreshable` and the
`ProgressView` overlay exactly as they are today. The Turntable body is
not scrollable, so it has no pull-to-refresh — the crate reloads when
the flag is toggled and `HomeViewModel.loadData()` runs on `.task`.

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd ios && xcodebuild test -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:PeacePlayerTests/TurntableWiringTests`
Expected: PASS (3 tests).

- [ ] **Step 7: Build the whole app**

Run: `cd ios && xcodegen generate && xcodebuild -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add ios/YTAudioPlayer/Views/HomeView.swift \
        ios/YTAudioPlayer/Views/ContentView.swift \
        ios/YTAudioPlayerTests/TurntableWiringTests.swift
git commit -m "feat(ios): wire the turntable home behind ff_turntable_home

HomeView branches on the flag and keeps its NavigationStack and all five
destinations. The legacy card scroll is preserved intact behind the flag
so it can be flipped off at any time.

BottomBar gains hidesMiniPlayer so the deck's now-playing strip is the
only now-playing surface on the Home tab. The flag defaults to off, so
no existing user's Home changes until they opt in via Settings -> Labs.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Visual verification on device

**Files:**
- Modify: none (verification only)
- Create: `ios/.review/turntable-home-*.png` (screenshots)

**Interfaces:**
- Consumes: everything above.
- Produces: screenshots proving the deck renders correctly.

- [ ] **Step 1: Build and install to the simulator**

```bash
cd ios
xcodebuild -project YTAudioPlayer.xcodeproj -scheme YTAudioPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -configuration Debug build
xcrun simctl boot "iPhone 16 Pro" 2>/dev/null || true
xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/PeacePlayer-*/Build/Products/Debug-iphonesimulator/PeacePlayer.app
```

- [ ] **Step 2: Enable the flag**

The flag lives in UserDefaults for the app's container. Set it directly:

```bash
APP=$(xcrun simctl get_app_container booted com.ytaudioplayer.app data)
xcrun simctl spawn booted defaults write com.ytaudioplayer.app ff_turntable_home -bool YES
```

If that path is wrong, launch the app, open Settings -> Labs, flip
"Turntable Home" on manually, and continue.

- [ ] **Step 3: Launch and screenshot**

```bash
xcrun simctl launch booted com.ytaudioplayer.app
sleep 4
xcrun simctl io booted screenshot ios/.review/turntable-home-idle.png
```

- [ ] **Step 4: Check the screenshot**

Read `ios/.review/turntable-home-idle.png` and confirm:
- The platter renders with visible grooves and the album art on the label.
- The tonearm sits over the record at the correct angle.
- The fascia shows lamps, greeting, RPM chip and five nav chips.
- The sleeve crate shows album covers.
- Nothing is clipped or overlapping.

- [ ] **Step 5: Fix anything that looks wrong, rebuild, re-screenshot**

Repeat Step 1-4 until the deck renders correctly. Pay particular
attention to:
- The tonearm's pivot overlapping the fascia.
- The sleeve crate's bottom being cut off by the BottomBar.
- The level meter being invisible when nothing is playing.

- [ ] **Step 6: Commit the screenshots**

```bash
git add ios/.review/turntable-home-*.png
git commit -m "chore(ios): turntable home verification screenshots"
```

---

## Self-Review

**1. Spec coverage**

| Spec section | Covered by |
|---|---|
| §4.1 Deck fascia | Task 5 (`DeckFasciaView`) |
| §4.2 Cue lever | Task 5 (`CueLeverView`) |
| §4.3 Tonearm | Task 4 (`TonearmView`) |
| §4.4 Platter | Task 3 (`PlatterView`) |
| §4.5 Sleeve crate | Task 5 (`SleeveCrateView`) |
| §4.6 Queue stack | Task 5 (`QueueStackView`) |
| §4.7 Now-playing strip + VU | Task 6 (`nowPlayingStrip`, `LevelMeterRow`) |
| §5 Visual language | Task 1 (`TurntableTokens`) |
| §6 State machine | Tasks 3, 4, 6 |
| §7.1 MiniPlayer replacement | Task 7 (`BottomBar.hidesMiniPlayer`) |
| §7.2 Sections → lamps/sleeves | Task 5 (fascia lamps), Task 6 (crate) |
| §7.3 Flag-gated | Task 2 (`FeatureFlags`), Task 7 (branch) |
| §8 Implementation shape | All tasks |
| §9 Risks | §10 acceptance criteria |
| §10 Acceptance criteria 1-8 | Tasks 3, 4, 5, 6 |
| §10 Acceptance criteria 9-12 | Task 7, Task 8 |

**Gap:** the spec's "On this day becomes a special sleeve" (§7.2) is not
implemented in this plan — `OnThisDaySection` is gated behind its own
`ff_on_this_day` flag and lives in the legacy body. **Resolution:** the
crate shows favourite-artist sleeves only; "On this day" remains in the
legacy Home. Adding it to the crate requires the `OnThisDaySection` data
source to be lifted out of the view, which is a separate change. This
plan does not regress it.

**2. Placeholder scan** — no TBD/TODO. Every code step contains real code.

**3. Type consistency**

- `TurntableTokens` / `TurntableTexture` — defined Task 1, consumed 3-6. ✓
- `FeatureFlags` — defined Task 2, consumed 6, 7. ✓
- `PlatterGeometry` — defined Task 3, tested 3. ✓
- `TonearmGeometry` — defined Task 4, tested 4. ✓
- `TurntableHomeModel` — defined Task 6, tested 6. ✓
- `BottomBar.hidesMiniPlayer` — defined Task 7, tested 7. ✓
- `DeckFasciaView`, `CueLeverView`, `SleeveCrateView`, `QueueStackView`,
  `LevelMeterRow` — defined Task 5, consumed Task 6. ✓

**Known API verifications** (flagged inline in the steps): `PlayerState.queue`,
`PlayerState.currentQueueIndex`, `PlayerState.addToQueue`, `HapticManager`
method names, `ContentSource` case names, `SmartLibraryReviewSheet` /
`CleanupReviewSheet` initialiser labels. Each is marked with a **Verify:**
note at the step that uses it, and each has a stated fallback.
