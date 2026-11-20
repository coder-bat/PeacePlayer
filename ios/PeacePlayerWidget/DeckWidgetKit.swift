//
//  DeckWidgetKit.swift
//  PeacePlayerWidget
//
//  The Deck design system's materials, for the widget extension.
//
//  The app's TurntableTokens live in the main target and depend on
//  asset-catalog textures the extension doesn't carry, so the handful
//  of colours the widgets need are restated here with the same values.
//  If TurntableTokens changes, change these too.
//
//  Also home of the pieces the 2x2 turntable widget and the Live
//  Activity share: the record, the tonearm, and the pilot lamp.
//

import SwiftUI
import UIKit

enum DeckWidget {
    static let walnut    = Color(red: 0.231, green: 0.165, blue: 0.118)
    static let aluminium = Color(red: 0.788, green: 0.776, blue: 0.745)
    static let cream     = Color(red: 0.953, green: 0.929, blue: 0.878)
    static let amberLamp = Color(red: 0.941, green: 0.663, blue: 0.169)
    static let vinyl     = Color(red: 0.031, green: 0.031, blue: 0.039)
    static let room      = Color(red: 0.047, green: 0.039, blue: 0.035)
    static let anodised  = Color(red: 0.078, green: 0.078, blue: 0.086)
    static let brass     = Color(red: 0.741, green: 0.604, blue: 0.357)

    /// Walnut with the key light from the upper left.
    static var plinth: LinearGradient {
        LinearGradient(
            colors: [walnut.opacity(1.0), Color(red: 0.14, green: 0.098, blue: 0.07)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Pilot lamp

struct DeckWidgetLamp: View {
    let isLit: Bool
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(isLit ? DeckWidget.amberLamp : DeckWidget.amberLamp.opacity(0.18))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 0.5))
            .shadow(color: isLit ? DeckWidget.amberLamp.opacity(0.9) : .clear, radius: size * 0.7)
    }
}

// MARK: - Record

/// A record seen from above: black disc, grooves, a static sheen that
/// stands in for motion, and the artwork as the centre label.
///
/// Widgets cannot run animations, so a playing record is drawn
/// at a different angle on every refresh rather than spinning.
struct DeckWidgetRecord: View {
    let artwork: UIImage?
    let size: CGFloat
    /// Degrees. Rotates the sheen (and label) so successive refreshes
    /// differ while playing.
    var angle: Double = 0

    var body: some View {
        ZStack {
            Circle().fill(DeckWidget.vinyl)

            // Grooves
            ForEach(0..<9, id: \.self) { i in
                Circle()
                    .stroke(Color.white.opacity(0.035 + Double(i % 3) * 0.012), lineWidth: 0.5)
                    .frame(width: size * (0.46 + CGFloat(i) * 0.058),
                           height: size * (0.46 + CGFloat(i) * 0.058))
            }

            // Anisotropic sheen: two opposed wedges of light.
            Circle()
                .fill(
                    AngularGradient(
                        stops: [
                            .init(color: .clear, location: 0.00),
                            .init(color: Color.white.opacity(0.16), location: 0.06),
                            .init(color: .clear, location: 0.16),
                            .init(color: .clear, location: 0.50),
                            .init(color: Color.white.opacity(0.10), location: 0.56),
                            .init(color: .clear, location: 0.66),
                            .init(color: .clear, location: 1.00)
                        ],
                        center: .center,
                        angle: .degrees(angle)
                    )
                )

            // Rim
            Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)

            // Label
            ZStack {
                Circle().fill(DeckWidget.cream)
                    .frame(width: size * 0.40, height: size * 0.40)
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size * 0.36, height: size * 0.36)
                        .clipShape(Circle())
                } else {
                    Circle().fill(DeckWidget.brass.opacity(0.55))
                        .frame(width: size * 0.36, height: size * 0.36)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.14, weight: .bold))
                        .foregroundColor(DeckWidget.walnut)
                }
                Circle().fill(DeckWidget.anodised)
                    .frame(width: size * 0.035, height: size * 0.035)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.55), radius: size * 0.04, x: 0, y: size * 0.02)
    }
}

// MARK: - Tonearm

/// The arm, drawn to the same geometry as the app's `TonearmGeometry`
/// (pivot back-right, 0.64 of the frame long, 103.7° to 129.1° across
/// a track, 84° in its rest).
struct DeckWidgetTonearm: View {
    enum Pose { case parked, lifted, playing }

    let pose: Pose
    let progress: Double
    let size: CGFloat

    private var angle: Double {
        let deg: Double
        switch pose {
        case .parked:  deg = 84.0
        case .lifted:  deg = 100.0
        case .playing: deg = 103.7 + (129.1 - 103.7) * min(max(progress, 0), 1)
        }
        return deg * .pi / 180
    }

    var body: some View {
        let pivot = CGPoint(x: 0.97 * size, y: 0.13 * size)
        let length = 0.64 * size
        let a = angle
        let tip = CGPoint(x: pivot.x + length * CGFloat(cos(a)),
                          y: pivot.y + length * CGFloat(sin(a)))
        // Crank the headshell in toward the record.
        let crank = a + 24.0 * .pi / 180
        let head = CGPoint(x: tip.x + 0.09 * size * CGFloat(cos(crank)),
                           y: tip.y + 0.09 * size * CGFloat(sin(crank)))
        let lift: CGFloat = pose == .playing ? 0 : size * 0.025

        ZStack {
            // Rest post
            if pose != .playing {
                Circle()
                    .fill(DeckWidget.anodised)
                    .frame(width: size * 0.05, height: size * 0.05)
                    .position(x: pivot.x - size * 0.06, y: pivot.y + length * 0.9)
            }

            // Tube shadow
            tube(pivot: pivot, tip: tip)
                .stroke(Color.black.opacity(0.45), style: StrokeStyle(lineWidth: size * 0.026, lineCap: .round))
                .offset(x: lift + 1.5, y: lift + 2)
                .blur(radius: lift > 0 ? 2.5 : 1)

            // Tube
            tube(pivot: pivot, tip: tip)
                .stroke(
                    LinearGradient(colors: [DeckWidget.aluminium, DeckWidget.aluminium.opacity(0.65)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: size * 0.026, lineCap: .round)
                )

            // Headshell + cartridge
            Path { p in
                p.move(to: tip)
                p.addLine(to: head)
            }
            .stroke(DeckWidget.anodised, style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round))
            Path { p in
                p.move(to: tip)
                p.addLine(to: head)
            }
            .stroke(DeckWidget.aluminium.opacity(0.8), style: StrokeStyle(lineWidth: size * 0.012, lineCap: .round))

            // Pivot collar
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(0.9), DeckWidget.aluminium, DeckWidget.anodised],
                                     center: .topLeading, startRadius: 0, endRadius: size * 0.05))
                .frame(width: size * 0.08, height: size * 0.08)
                .position(pivot)
        }
        .frame(width: size, height: size)
    }

    /// An S-shaped tube, as on the real arm.
    private func tube(pivot: CGPoint, tip: CGPoint) -> Path {
        let dx = tip.x - pivot.x, dy = tip.y - pivot.y
        let nx = -dy, ny = dx   // perpendicular, unnormalised
        let k: CGFloat = 0.10
        return Path { p in
            p.move(to: pivot)
            p.addCurve(
                to: tip,
                control1: CGPoint(x: pivot.x + dx * 0.42 + nx * k, y: pivot.y + dy * 0.42 + ny * k),
                control2: CGPoint(x: pivot.x + dx * 0.62 - nx * k * 1.2, y: pivot.y + dy * 0.62 - ny * k * 1.2)
            )
        }
    }
}
