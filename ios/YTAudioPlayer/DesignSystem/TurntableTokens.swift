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
