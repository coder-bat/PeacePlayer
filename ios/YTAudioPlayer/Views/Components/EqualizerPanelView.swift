//
//  EqualizerPanelView.swift
//  PeacePlayer
//
//  10-band parametric EQ settings panel. Lets the user pick
//  from 8 presets (Flat / Bass Boost / Treble Boost / Vocal /
//  Electronic / Hip-Hop / Rock / Acoustic) or adjust the 10
//  bands manually. Adjusting any band switches the preset to
//  "Custom" so the next preset selection is a clean change.
//
//  Bands and types (matching the AudioEqualizer static API):
//  32 Hz (low shelf) — 16 kHz (high shelf) with peaking in
//  between. Range: -12 dB to +12 dB per band.
//

import SwiftUI

struct EqualizerPanelView: View {
    @StateObject private var eq = AudioEqualizer.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.cyberBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Master toggle
                        masterSection

                        // Preset picker
                        presetSection

                        // 10-band slider grid
                        bandsSection

                        // Reset
                        resetSection
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Theme.cyberCyan)
                }
            }
        }
    }

    // MARK: - Master section

    private var masterSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(Theme.cyberCyan)
                .frame(width: 32, height: 32)
                .background(Theme.cyberCyan.opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Parametric EQ")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("10 bands · 32 Hz – 16 kHz · ±12 dB")
                    .font(.caption)
                    .foregroundColor(Theme.cyberDim)
            }

            Spacer()

            Toggle("", isOn: $eq.isEnabled)
                .labelsHidden()
                .tint(Theme.cyberCyan)
        }
        .padding(16)
        .background(Theme.cyberSurface)
        .cornerRadius(CornerRadius.md)
    }

    // MARK: - Preset section

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PRESET")
                .font(Typography.sectionHeader)
                .foregroundColor(Theme.cyberCyan)
                .textCase(.uppercase)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), spacing: 10)],
                spacing: 10
            ) {
                ForEach(AudioEqualizer.EqualizerPreset.allCases) { preset in
                    presetChip(for: preset)
                }
            }
        }
    }

    private func presetChip(for preset: AudioEqualizer.EqualizerPreset) -> some View {
        let isSelected = eq.preset == preset
        return Button {
            eq.apply(preset: preset)
            HapticManager.light()
        } label: {
            Text(preset.rawValue)
                .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .monospaced))
                .foregroundColor(isSelected ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Theme.cyberCyan : Theme.cyberSurface)
                .cornerRadius(CornerRadius.sm)
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.sm)
                        .stroke(
                            isSelected ? Theme.cyberCyan : Theme.cyberDim.opacity(0.3),
                            lineWidth: 1
                        )
                )
                .neonGlow(isSelected ? .cyan : .dim, opacity: isSelected ? 0.5 : 0)
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Bands section

    private var bandsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BANDS")
                    .font(Typography.sectionHeader)
                    .foregroundColor(Theme.cyberCyan)
                    .textCase(.uppercase)
                Spacer()
                if eq.preset == .custom {
                    Text("CUSTOM")
                        .font(Typography.eyebrow)
                        .foregroundColor(Theme.cyberMagenta)
                }
            }

            // 10-band slider grid. Two rows of 5 bands each on
            // larger phones; wraps gracefully on smaller screens.
            VStack(spacing: 18) {
                ForEach(0..<2) { row in
                    HStack(spacing: 10) {
                        ForEach(0..<5) { col in
                            let index = row * 5 + col
                            bandSlider(at: index)
                        }
                    }
                }
            }
            .padding(16)
            .background(Theme.cyberSurface)
            .cornerRadius(CornerRadius.md)
        }
    }

    private func bandSlider(at index: Int) -> some View {
        VStack(spacing: 6) {
            // Center-line dot at 0 dB
            ZStack(alignment: .center) {
                GeometryReader { geo in
                    let trackWidth = geo.size.width - 24
                    let centerX = 12 + trackWidth / 2
                    VStack(spacing: 0) {
                        // The dB readout above the slider
                        Text(formattedGain(index))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(bandColor(at: index))
                            .frame(height: 12)

                        // Vertical slider, custom-styled to match
                        // the cyberpunk palette. Using a regular
                        // Slider is simpler and a11y-friendly.
                        VStack(spacing: 0) {
                            // +12 dB cap
                            Text("+12")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(Theme.cyberDim)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.trailing, 2)

                            Slider(
                                value: Binding(
                                    get: { eq.bandGains[index] },
                                    set: { eq.setBand(index, gain: $0) }
                                ),
                                in: -12...12,
                                step: 0.5
                            )
                            .tint(bandColor(at: index))

                            // -12 dB cap
                            Text("-12")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(Theme.cyberDim)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.trailing, 2)
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
                .frame(height: 130)
            }
            .frame(width: 60, height: 150)

            // Band label
            Text(AudioEqualizer.bandLabels[index])
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.cyberDim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func bandColor(at index: Int) -> Color {
        // Bands 0-2 (low) get cyan tint, 3-6 (mid) get magenta,
        // 7-9 (high) get yellow. Visual cue that distinguishes
        // low/mid/high without a numeric readout.
        switch index {
        case 0...2: return Theme.cyberCyan
        case 3...6: return Theme.cyberMagenta
        default:   return Theme.cyberYellow
        }
    }

    private func formattedGain(_ index: Int) -> String {
        let g = eq.bandGains[index]
        if g == 0 { return "0" }
        return g > 0 ? String(format: "+%.1f", g) : String(format: "%.1f", g)
    }

    // MARK: - Reset

    private var resetSection: some View {
        Button {
            eq.apply(preset: .flat)
            HapticManager.medium()
        } label: {
            HStack {
                Image(systemName: "arrow.counterclockwise")
                Text("Reset to Flat")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(Theme.cyberCyan)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.cyberSurface)
            .cornerRadius(CornerRadius.md)
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .stroke(Theme.cyberCyan.opacity(0.3), lineWidth: 1)
            )
        }
    }
}
