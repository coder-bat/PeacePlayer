//
//  AudioEqualizer.swift
//  PeacePlayer
//
//  10-band parametric EQ applied in real time to the audio
//  buffer the visualizer tap reads from. Because the visualizer
//  tap is on the same MTAudioProcessingTap that feeds the
//  audio output, modifying the samples in place is equivalent
//  to modifying the audio output — the user hears the EQ
//  while the visualizer shows the post-EQ spectrum.
//
//  EQ design (matches iOS Music's bands):
//  - 32 Hz (low shelf)
//  - 64, 125, 250, 500 Hz (low peaking)
//  - 1k, 2k, 4k Hz (mid peaking)
//  - 8k Hz (high peaking)
//  - 16 kHz (high shelf)
//
//  8 presets covering the most common EQ curves. Each preset
//  is a dictionary of `bandIndex -> dB` overrides; a value
//  of nil means "leave at 0 dB" so the user can blend a
//  preset with their own customizations.
//
//  State persists via UserDefaults under
//  `AudioEqualizer.settingsDefaultsKey` so the user's EQ
//  choice survives app launches.
//

import Foundation
import Combine

@MainActor
final class AudioEqualizer: ObservableObject {
    static let shared = AudioEqualizer()

    // MARK: - Public observable state

    /// Master switch — when off, EQ is bypassed entirely (no
    /// per-sample work, no CPU cost).
    @Published var isEnabled: Bool {
        didSet { persist(); propagateToEngine() }
    }

    /// Currently selected preset name. `.custom` means the user
    /// has tweaked individual bands away from the preset values.
    @Published var preset: EqualizerPreset {
        didSet { persist() }
    }

    /// Per-band gain in dB. Index 0 = 32 Hz, ..., index 9 = 16 kHz.
    /// Range: -12 dB to +12 dB (clamped on set).
    @Published var bandGains: [Double] {
        didSet {
            persist()
            // If the user changes a band and the current preset
            // is non-custom, switch to custom so the next preset
            // selection doesn't surprise them.
            if preset != .custom {
                preset = .custom
            }
            propagateToEngine()
        }
    }

    // MARK: - Band definitions

    /// The 10 fixed bands. Frequencies match iOS Music's EQ and
    /// most third-party EQs.
    nonisolated static let bandFrequencies: [Double] = [
        32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]
    nonisolated static let bandCount: Int = bandFrequencies.count

    /// Center frequencies in Hz; mirrors `bandFrequencies` so
    /// the UI can label each slider.
    nonisolated static var bandLabels: [String] {
        bandFrequencies.map { freq in
            if freq >= 1_000 {
                return "\(Int(freq / 1_000))k Hz"
            }
            return "\(Int(freq)) Hz"
        }
    }

    /// Filter type per band. Low shelf for the bottom band, high
    /// shelf for the top, peaking for the middle 8. Matches the
    /// standard music-EQ topology.
    nonisolated static func bandType(at index: Int) -> BiquadFilterType {
        switch index {
        case 0: return .lowShelf
        case 9: return .highShelf
        default: return .peaking
        }
    }

    // MARK: - EQ presets

    enum EqualizerPreset: String, CaseIterable, Identifiable {
        case flat = "Flat"
        case bassBoost = "Bass Boost"
        case trebleBoost = "Treble Boost"
        case vocal = "Vocal"
        case electronic = "Electronic"
        case hipHop = "Hip-Hop"
        case rock = "Rock"
        case acoustic = "Acoustic"
        case custom = "Custom"

        var id: String { rawValue }

        /// Gain per band in dB. Indices that aren't listed
        /// default to 0 dB (flat). The Custom preset is set
        /// implicitly when the user tweaks any band; selecting
        /// it from the UI just keeps the current bandGains.
        var bandGains: [Double] {
            switch self {
            case .flat:        return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            case .bassBoost:   return [6, 5, 4, 1, 0, 0, 0, 0, 1, 2]
            case .trebleBoost: return [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]
            case .vocal:       return [-1, -1, 0, 1, 3, 4, 4, 3, 1, 0]
            case .electronic:  return [5, 4, 1, 0, -2, -1, 0, 1, 3, 5]
            case .hipHop:      return [6, 5, 2, 1, -1, -1, 0, 1, 2, 3]
            case .rock:        return [4, 3, 2, 0, -1, -1, 0, 2, 3, 4]
            case .acoustic:    return [3, 3, 2, 1, 0, 0, 1, 2, 3, 4]
            case .custom:      return []  // sentinel — keep current bandGains
            }
        }
    }

    // MARK: - Storage

    private static let settingsDefaultsKey = "peaceplayer.equalizer"

    private enum Keys {
        static let enabled = "enabled"
        static let preset = "preset"
        static let gains = "gains"
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Load from UserDefaults. Falls back to a flat, disabled
        // EQ if the user has never touched the settings.
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.settingsDefaultsKey),
           let saved = try? JSONDecoder().decode(SavedSettings.self, from: data) {
            self.isEnabled = saved.enabled
            self.preset = EqualizerPreset(rawValue: saved.preset) ?? .flat
            self.bandGains = saved.gains
        } else {
            self.isEnabled = false
            self.preset = .flat
            self.bandGains = Array(repeating: 0.0, count: Self.bandCount)
        }
        // Push initial state into the audio engine on first
        // access. The engine reads the live values via
        // `currentSettings()` on each audio callback, so the
        // initial push is best-effort and the engine will pick
        // up changes via the @Published didSet above.
        propagateToEngine()
    }

    private struct SavedSettings: Codable {
        let enabled: Bool
        let preset: String
        let gains: [Double]
    }

    private func persist() {
        let snapshot = SavedSettings(
            enabled: isEnabled,
            preset: preset.rawValue,
            gains: bandGains
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.settingsDefaultsKey)
        }
    }

    // MARK: - Public API

    /// Apply a preset: copies its per-band gains into
    /// `bandGains`. The `.custom` preset is a no-op (keeps
    /// current values); use the individual sliders for
    /// custom EQ.
    func apply(preset newPreset: EqualizerPreset) {
        preset = newPreset
        if newPreset != .custom {
            bandGains = newPreset.bandGains
        }
    }

    /// Set a single band's gain (in dB, clamped to ±12).
    /// Triggers the custom-preset sentinel.
    func setBand(_ index: Int, gain: Double) {
        guard bandGains.indices.contains(index) else { return }
        let clamped = max(-12, min(12, gain))
        if bandGains[index] != clamped {
            bandGains[index] = clamped
        }
    }

    /// Snapshot of the current settings — read by the audio
    /// engine on each tap. Cheap to call; returns by value.
    func currentSettings() -> (enabled: Bool, gains: [Double]) {
        (isEnabled, isEnabled ? bandGains : Array(repeating: 0, count: bandGains.count))
    }

    // MARK: - Engine integration

    private func propagateToEngine() {
        // Push the new settings to the visualizer/eq pipeline.
        // The engine applies the cascade in its tap callback
        // (which is the same tap feeding the audio output, so
        // modifying the in-flight buffer modifies the speakers).
        AudioVisualizerEngine.shared.applyEQSettings(
            enabled: isEnabled,
            gains: bandGains
        )
        // Posting `objectWillChange` so any UI bound to this
        // object updates immediately.
        objectWillChange.send()
    }
}
