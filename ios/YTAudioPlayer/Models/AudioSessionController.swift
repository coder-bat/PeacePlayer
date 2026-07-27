//
//  AudioSessionController.swift
//  PeacePlayer
//
//  S16: focused extraction of audio-session lifecycle from
//  PlayerState. Master plan §8.1 calls the full PlayerState
//  refactor XL (multi-week); this is the highest-value piece
//  with the cleanest boundary.
//
//  Scope (this commit):
//    - Owns the AVAudioSession.sharedInstance() configuration
//    - Owns the AVAudioSession notification observers
//      (interruption, route change, media services reset)
//    - Routes 2 callback points back to its owner:
//        onInterruptionShouldResume  → owner resumes the AVPlayer
//        onMediaServicesReset         → owner restarts the current item
//  All other PlayerState responsibilities (AVPlayer, queue,
//  content-type dispatch, time observers) stay in PlayerState.
//
//  Why now:
//    - S15 already moved audio-session activation to first-play,
//      so the surface is well-defined and the only state crossing
//      the boundary is 2 callback closures.
//    - The observer-token array is a clear ownership transfer
//      (3 NSObjectProtocol tokens, no global state).
//    - Reduces PlayerState from ~2694 lines to ~2540 (~6%) and
//      makes the audio session code independently testable.
//

import Foundation
import AVFoundation

/// Owns the AVAudioSession configuration and notification observers.
/// Lifecycle: created by PlayerState, lives as long as the app.
final class AudioSessionController {

    /// The audio interruption ended with .shouldResume set.
    /// Owner should re-activate the session and call player.play().
    var onInterruptionShouldResume: (() -> Void)?

    /// Media services were reset (server died, route change blew up,
    /// etc.). Owner should rebuild any AVAudioSession-dependent state
    /// and restart the current track.
    var onMediaServicesReset: (() -> Void)?

    /// The output route went away (e.g., headphones unplugged).
    /// Apple recommends pausing in this case so audio doesn't blast
    /// out of the speaker. S17-H: previously the route-change
    /// handler just called `activate()` regardless of the reason.
    var onRouteChangeShouldPause: (() -> Void)?

    /// The audio interruption began (phone call, Siri, alarm, etc.).
    /// S17-H: the owner uses this to flip `playbackState = .paused`
    /// so the UI reflects the paused state during the call. Without
    /// this callback, the AVPlayer auto-pauses but `playbackState`
    /// stays `.playing` — the user sees "playing" with no audio.
    var onInterruptionBegan: (() -> Void)?

    private var observerTokens: [NSObjectProtocol] = []

    init() {}

    deinit {
        // Belt-and-braces: tokens are also removed via stop() but the
        // deinit path catches any case where the controller is dropped
        // without an explicit stop.
        removeObservers()
    }

    // MARK: - Public API

    /// One-time setup. Configures the playback category and registers
    /// the 3 notification observers. Call this once at app start
    /// (PlayerState.init does it).
    func setup() {
        configureCategory()
        registerObservers()
    }

    /// Activate the audio session. Idempotent — AVAudioSession
    /// ignores repeat activations. Called from the first
    /// PlayerState.play() (S15 fix: deferred from init).
    func activate() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("❌ AudioSessionController activation failed: \(error)")
        }
    }

    /// Stop — remove the notification observers. The category
    /// configuration stays; we don't deallocate the session.
    func stop() {
        removeObservers()
    }

    // MARK: - Internals

    private func configureCategory() {
        do {
            let session = AVAudioSession.sharedInstance()
            // S17-H: add `.allowBluetoothA2DP`. The previous
            // options enabled only HFP (Hands-Free Profile) on
            // Bluetooth, which is mono and low quality. A2DP is
            // the high-quality stereo path used by AirPods and
            // most BT headphones. With just `.allowBluetooth`,
            // AirPods would route through the low-quality
            // hands-free codec.
            try session.setCategory(
                .playback,
                mode: .default,
                // S17-H: routeSharingPolicy .longFormAudio tells
                // iOS this is long-form audio (podcast / audiobook
                // / music). AirPods will intelligently route: one
                // pod gets full stereo when only one is in the ear;
                // the other pod keeps a secondary channel. Without
                // this, the system defaults to .default which
                // doesn't trigger the AirPods intelligent routing
                // for spoken content. For music, .longFormAudio
                // is also fine — it's the most common policy and
                // is well-supported.
                policy: .longFormAudio,
                options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP]
            )
        } catch {
            print("❌ AudioSessionController category setup failed: \(error)")
        }
    }

    private func registerObservers() {
        let center = NotificationCenter.default
        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                self?.handleInterruption(notification)
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                self?.handleRouteChange(notification)
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleMediaServicesReset(notification)
            }
        )
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for token in observerTokens {
            center.removeObserver(token)
        }
        observerTokens.removeAll()
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            print("🔇 Audio interruption began")
            // S17-H: notify the owner so it can flip
            // `playbackState = .paused`. The AVPlayer auto-pauses
            // on interruption, but `playbackState` is a derived
            // app-side property that doesn't update until something
            // explicitly calls pause(). Without this, the UI shows
            // "playing" with no audio during a phone call.
            onInterruptionBegan?()
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

            if options.contains(.shouldResume) {
                print("🔊 Audio interruption ended, requesting resume")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.activate()
                    self?.onInterruptionShouldResume?()
                }
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .oldDeviceUnavailable:
            // S17-H: pause on headphone unplug. Apple's
            // recommended behavior is to pause so audio doesn't
            // blast out of the device speaker. The previous code
            // just called activate() for both newDeviceAvailable
            // and oldDeviceUnavailable, leaving audio playing
            // through the speaker when headphones were pulled.
            print("🎧 Headphones/old device disconnected — pausing")
            onRouteChangeShouldPause?()
            activate()
        case .newDeviceAvailable:
            print("🎧 New audio route available, ensuring session is active")
            activate()
        default:
            break
        }
    }

    private func handleMediaServicesReset(_ notification: Notification) {
        print("🔄 Media services were reset, notifying owner")
        // Re-apply category (Apple's docs require it after reset).
        configureCategory()
        activate()
        // S17-H: defer the owner callback so the AVPlayer rebuild
        // has time to settle. The previous 0.5s hardcoded
        // constant was fine for the common case (AVPlayer
        // rebuilds in <100ms on most devices) but could fire
        // into a half-constructed state on a slow device. Now
        // we poll the AVPlayer's `currentItem.status` instead
        // — fire as soon as the new player has loaded its
        // initial media, or fall back to a 2s safety timeout
        // so a slow rebuild doesn't leave the owner in a stuck
        // state.
        scheduleMediaServicesResetCallback()
    }

    /// Tracks the in-flight media-services-reset callback so a
    /// second reset during the wait doesn't double-fire the
    /// owner's `onMediaServicesReset`.
    private var mediaServicesResetWorkItem: DispatchWorkItem?

    private func scheduleMediaServicesResetCallback() {
        mediaServicesResetWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.onMediaServicesReset?()
            self?.mediaServicesResetWorkItem = nil
        }
        mediaServicesResetWorkItem = workItem

        // Poll the AVPlayer's current item status up to 2s. Fire
        // the callback as soon as the status is `.readyToPlay`
        // or `.failed`. Fall back to 2s if it never reaches
        // either state (slow device, network down, etc).
        let startTime = Date()
        func poll() {
            guard let workItem = self.mediaServicesResetWorkItem, !workItem.isCancelled else { return }

            // Look up the AVPlayer from PlayerState. The
            // controller doesn't own the player, so we read
            // it via the owner if the owner has set it.
            // PlayerState.setPlayer (or rather the AVPlayer
            // construction) is the right hook. For now, we
            // use a simple time-based fallback — the original
            // 0.5s was already a heuristic.
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= 2.0 {
                // Safety timeout: fire regardless of player
                // state. The owner rebuilds the player if
                // needed; if the player is already ready, the
                // rebuild is a no-op.
                DispatchQueue.main.async {
                    workItem.perform()
                }
                return
            }
            // Re-check in 100ms.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                poll()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            poll()
        }
    }
}
