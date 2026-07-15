//
//  BiquadFilter.swift
//  PeacePlayer
//
//  Real-time digital biquad filter for the audio EQ.
//
//  Implements the biquad (bi-quadratic) IIR filter design from
//  the RBJ Audio EQ Cookbook
//  (https://www.w3.org/TR/audio-eq-cookbook/) — the same
//  formulae used by every major audio framework for
//  parametric EQ, low-shelf, and high-shelf filters.
//
//  Each filter has 5 coefficients (b0, b1, b2, a1, a2) and
//  2 state variables (z1, z2) — the classic "Direct Form I"
//  structure. Coefficients are recomputed when the user changes
//  the gain; state is preserved between samples so changing
//  gain doesn't cause a click.
//
//  Used in cascade by `AudioEqualizer` for a 10-band
//  parametric EQ. The cascade is a stable, low-CPU path
//  suitable for real-time per-sample work in the audio
//  rendering thread.
//

import Foundation
import Darwin

/// Type of biquad filter — the cookbook's "Raw Equations" use
/// different coefficient sets for each type. We support the
/// three types we need for a music EQ: low-shelf (boost/cut
/// below the cutoff), high-shelf (boost/cut above), and
/// peaking (boost/cut around a center frequency, the rest
/// of the spectrum flat).
enum BiquadFilterType {
    case lowShelf
    case highShelf
    case peaking
}

/// Single biquad filter. State is two samples; coefficients
/// are recomputed by `setParameters(...)` and re-used across
/// every sample in `process(_:)`. This is real-time-safe: no
/// allocations, no locks, no Swift overhead per sample —
/// just the five FMA-friendly multiplies.
///
/// Implemented as a class (not a struct) because the per-sample
/// `process` method needs to mutate the filter state (z1, z2)
/// in place. A struct's `mutating func` would copy-on-write the
/// whole struct on every sample, which is wasteful in a
/// real-time audio path.
final class BiquadFilter {
    let type: BiquadFilterType
    /// Center / cutoff frequency in Hz.
    var frequency: Double
    /// Sample rate in Hz (typically 44100 or 48000).
    var sampleRate: Double
    /// Quality factor / Q — bandwidth in octaves for peaking
    /// filters, slope for shelves (we use 0.707 for shelves).
    var q: Double = 0.707
    /// Gain in dB. Recomputes the coefficients when set.
    var gainDb: Double = 0 {
        didSet { recomputeCoefficients() }
    }

    // Coefficients (Direct Form I)
    private var b0: Double = 1
    private var b1: Double = 0
    private var b2: Double = 0
    private var a1: Double = 0
    private var a2: Double = 0

    // State
    private var z1: Double = 0
    private var z2: Double = 0

    init(type: BiquadFilterType, frequency: Double, sampleRate: Double, q: Double = 0.707, gainDb: Double = 0) {
        self.type = type
        self.frequency = frequency
        self.sampleRate = sampleRate
        self.q = q
        self.gainDb = gainDb
        recomputeCoefficients()
    }

    /// Process a single sample through the filter. Direct Form I
    /// transposed: `y[n] = b0*x[n] + z1; z1 = b1*x[n] - a1*y[n] + z2; z2 = b2*x[n] - a2*y[n]`.
    /// Inline to keep this hot path Swift-overhead-free.
    @inline(__always)
    func process(_ x: Float) -> Float {
        let y = b0 * Double(x) + z1
        z1 = b1 * Double(x) - a1 * y + z2
        z2 = b2 * Double(x) - a2 * y
        return Float(y)
    }

    /// Recompute coefficients from frequency / Q / gain. Called
    /// from the gain setter; callers that change frequency or Q
    /// directly should invoke this manually.
    func recomputeCoefficients() {
        // RBJ Audio EQ Cookbook (constant 0 dB peak gain shelf formulae).
        // Use peak gain A = 10^(gainDb/40) — the +20 dB doubling of the
        // half-amplitude for shelves.
        let A = pow(10.0, gainDb / 40.0)
        let omega = 2.0 * .pi * frequency / sampleRate
        let sn = sin(omega)
        let cs = cos(omega)
        let alpha = sn / (2.0 * q)
        let beta = 2.0 * sqrt(A) * alpha

        let b0: Double
        let b1: Double
        let b2: Double
        let a0: Double
        let a1: Double
        let a2: Double

        switch type {
        case .peaking:
            b0 = 1.0 + alpha * A
            b1 = -2.0 * cs
            b2 = 1.0 - alpha * A
            a0 = 1.0 + alpha / A
            a1 = -2.0 * cs
            a2 = 1.0 - alpha / A
        case .lowShelf:
            b0 = A * ((A + 1) - (A - 1) * cs + beta)
            b1 = 2.0 * A * ((A - 1) - (A + 1) * cs)
            b2 = A * ((A + 1) - (A - 1) * cs - beta)
            a0 = (A + 1) + (A - 1) * cs + beta
            a1 = -2.0 * ((A - 1) + (A + 1) * cs)
            a2 = (A + 1) + (A - 1) * cs - beta
        case .highShelf:
            b0 = A * ((A + 1) + (A - 1) * cs + beta)
            b1 = -2.0 * A * ((A - 1) + (A + 1) * cs)
            b2 = A * ((A + 1) + (A - 1) * cs - beta)
            a0 = (A + 1) - (A - 1) * cs + beta
            a1 = 2.0 * ((A - 1) - (A + 1) * cs)
            a2 = (A + 1) - (A - 1) * cs - beta
        }

        // Normalize by a0
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }
}
