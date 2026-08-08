//
//  HapticSymphonyEngine.swift
//  YTAudioPlayer
//
//  Real-time Core Haptics driven by FFT frequency bands.
//  Maps bass → intensity, treble → sharpness for a "feel the music" experience.
//

import Foundation
import CoreHaptics
import Combine
import QuartzCore
import UIKit

final class HapticSymphonyEngine: ObservableObject {
    static let shared = HapticSymphonyEngine()

    // S18 (P0-2 accessibility): UserDefaults key for the "Reduce
    // Haptic Symphony" preference. Default respects the system
    // Reduce Motion setting — if the user already asked for less
    // motion, they almost certainly want less haptic. Otherwise
    // default ON (haptic enabled) so existing users see no
    // behavior change.
    static let reducePreferenceKey = "haptic_symphony_reduce"

    /// True when the user (or the system) has asked to suppress
    /// Haptic Symphony. When this is true, `start()` is a no-op.
    /// Read this from the UI to disable the action button and
    /// show an inline "Reduce Haptics is on" hint.
    var isReducedByPreference: Bool {
        if UserDefaults.standard.object(forKey: Self.reducePreferenceKey) != nil {
            return UserDefaults.standard.bool(forKey: Self.reducePreferenceKey)
        }
        // No explicit setting: defer to the system Reduce Motion.
        return UIAccessibility.isReduceMotionEnabled
    }

    /// True if start() will actually run. False when the device
    /// has no haptic hardware OR the user/system has asked to
    /// reduce. UI uses this to disable the action button.
    var canStart: Bool {
        isSupported && !isReducedByPreference
    }

    @Published var isActive: Bool = false
    @Published var isSupported: Bool = false

    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var cancellable: AnyCancellable?
    private var displayLink: CADisplayLink?

    // Cached band snapshot for timer-driven updates
    private var latestBands: [Float] = []
    private let bandsLock = NSLock()

    // Weights: bass-heavy for intensity, treble-heavy for sharpness
    // 32 bands: 0-3 sub-bass, 4-8 bass, 9-18 mids, 19-31 treble
    private let intensityWeights: [Float] = {
        var w = [Float](repeating: 0, count: 32)
        for i in 0..<4  { w[i] = 1.0 }    // sub-bass: full weight
        for i in 4..<9  { w[i] = 0.8 }    // bass: high weight
        for i in 9..<19 { w[i] = 0.3 }    // mids: moderate
        for i in 19..<32 { w[i] = 0.1 }   // treble: minimal
        return w
    }()

    private let sharpnessWeights: [Float] = {
        var w = [Float](repeating: 0, count: 32)
        for i in 0..<4  { w[i] = 0.0 }    // sub-bass: none
        for i in 4..<9  { w[i] = 0.1 }    // bass: minimal
        for i in 9..<19 { w[i] = 0.4 }    // mids: moderate
        for i in 19..<32 { w[i] = 1.0 }   // treble: full weight
        return w
    }()

    private init() {
        isSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    // MARK: - Public API

    func start() {
        // S18 (P0-2): respect the user's reduce preference AND the
        // system Reduce Motion. If the user disabled the engine via
        // Settings, or the OS-level accessibility setting is on, this
        // is a no-op. The UI is expected to disable the action button
        // in this case, but we double-check here as a safety net so
        // the engine can never spin up against the user's wishes.
        guard isSupported, !isActive, !isReducedByPreference else { return }

        do {
            engine = try CHHapticEngine()
            engine?.isAutoShutdownEnabled = false
            engine?.playsHapticsOnly = true

            engine?.stoppedHandler = { [weak self] reason in
                print("🫳 Haptic engine stopped: \(reason)")
                DispatchQueue.main.async { self?.isActive = false }
            }
            engine?.resetHandler = { [weak self] in
                print("🫳 Haptic engine reset — restarting")
                try? self?.engine?.start()
                self?.restartPlayer()
            }

            try engine?.start()
            try createAndStartPlayer()
            subscribeToFFT()
            startDisplayLink()

            DispatchQueue.main.async { self.isActive = true }
            print("🫳 Haptic Symphony started")
        } catch {
            print("🫳 Haptic engine error: \(error)")
            DispatchQueue.main.async { self.isActive = false }
        }
    }

    func stop() {
        stopDisplayLink()
        cancellable?.cancel()
        cancellable = nil

        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
        engine?.stop()
        engine = nil

        DispatchQueue.main.async { self.isActive = false }
        print("🫳 Haptic Symphony stopped")
    }

    func toggle() {
        if isActive { stop() } else { start() }
    }

    // MARK: - Haptic Pattern

    private func createAndStartPlayer() throws {
        // Use a long continuous haptic event
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.0)
            ],
            relativeTime: 0,
            duration: 600 // 10 minutes
        )

        let pattern = try CHHapticPattern(events: [event], parameters: [])
        player = try engine?.makeAdvancedPlayer(with: pattern)
        player?.loopEnabled = true
        try player?.start(atTime: CHHapticTimeImmediate)
        print("🫳 Haptic player created and started")
    }

    private func restartPlayer() {
        try? createAndStartPlayer()
    }

    // MARK: - FFT Subscription

    private func subscribeToFFT() {
        cancellable = AudioVisualizerEngine.shared.$bands
            .receive(on: DispatchQueue.global(qos: .userInteractive))
            .sink { [weak self] bands in
                guard let self = self else { return }
                self.bandsLock.lock()
                self.latestBands = bands
                self.bandsLock.unlock()
            }
    }

    // MARK: - Display Link (synced haptic updates)

    private func startDisplayLink() {
        stopDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired() {
        updateHaptics()
    }

    private func updateHaptics() {
        bandsLock.lock()
        let bands = latestBands
        bandsLock.unlock()

        guard !bands.isEmpty else { return }
        let count = min(bands.count, 32)

        // Weighted blend: bass → intensity
        var intensitySum: Float = 0
        var intensityWeightSum: Float = 0
        for i in 0..<count {
            intensitySum += bands[i] * intensityWeights[i]
            intensityWeightSum += intensityWeights[i]
        }
        let rawIntensity = intensitySum / max(intensityWeightSum, 1)

        // Weighted blend: treble → sharpness
        var sharpnessSum: Float = 0
        var sharpnessWeightSum: Float = 0
        for i in 0..<count {
            sharpnessSum += bands[i] * sharpnessWeights[i]
            sharpnessWeightSum += sharpnessWeights[i]
        }
        let rawSharpness = sharpnessSum / max(sharpnessWeightSum, 1)

        // Scale: strong boost for perceptibility, clamp to valid ranges
        let intensity = min(max(rawIntensity * 2.5, 0.0), 1.0)
        let sharpness = min(max(rawSharpness * 2.0 - 1.0, -1.0), 1.0)

        guard intensity > 0.01 else { return } // skip silent frames

        let params = [
            CHHapticDynamicParameter(
                parameterID: .hapticIntensityControl,
                value: intensity,
                relativeTime: CHHapticTimeImmediate
            ),
            CHHapticDynamicParameter(
                parameterID: .hapticSharpnessControl,
                value: sharpness,
                relativeTime: CHHapticTimeImmediate
            )
        ]

        try? player?.sendParameters(params, atTime: CHHapticTimeImmediate)
    }
}
