//
//  OrbitalMenu.swift
// YTAudioPlayer
//
//  Orbital ring radial menu - tap album art to reveal navigation
//

import SwiftUI

struct OrbitalMenuItem: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let tabTag: Int
    var color: Color = .cyberCyan
}

struct OrbitalMenu: View {
    @Binding var isPresented: Bool
    let onSelectTab: (Int) -> Void
    let onDismiss: () -> Void

    @State private var isAnimating = false
    @State private var orbitRotation: Double = 0
    @State private var selectedIndex: Int? = nil
    @State private var showLabels = false
    @State private var itemScales: [Double] = []
    @State private var itemOffsets: [CGSize] = []

    @Environment(\.accessibilityReduceMotion) var reduceMotion

    private let items: [OrbitalMenuItem] = [
        OrbitalMenuItem(icon: "house.fill",        label: "Home",      tabTag: 0),
        OrbitalMenuItem(icon: "magnifyingglass",   label: "Search",   tabTag: 1),
        OrbitalMenuItem(icon: "music.note.list",   label: "Queue",    tabTag: 2),
        OrbitalMenuItem(icon: "music.note.house.fill", label: "Library", tabTag: 3),
        OrbitalMenuItem(icon: "radio.fill",        label: "Radio",    tabTag: 5),
    ]

    private let orbitRadius: CGFloat = 120
    private let iconSize: CGFloat = 48
    private let animationDuration: Double = 0.65

    var body: some View {
        ZStack {
            // Dimmed backdrop
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            // Center artwork
            centerPiece

            // Orbiting icons
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                orbitingIcon(item: item, index: index)
            }

            // Label for selected item
            if let idx = selectedIndex, showLabels {
                VStack {
                    Spacer()
                        .frame(height: orbitRadius * 2 + 100)
                    Text(items[idx].label)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(items[idx].color.opacity(0.9))
                                .shadow(color: items[idx].color.opacity(0.5), radius: 8)
                        )
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .onAppear {
            itemScales = Array(repeating: 0.01, count: items.count)
            itemOffsets = Array(repeating: .zero, count: items.count)
            animateIn()
        }
    }

    private var centerPiece: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 80, height: 80)

            Image(systemName: "xmark")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.cyberDim)
        }
        .scaleEffect(isAnimating ? 1 : 0.5)
        .opacity(isAnimating ? 1 : 0)
        .onTapGesture {
            dismiss()
        }
    }

    private func orbitingIcon(item: OrbitalMenuItem, index: Int) -> some View {
        let angle = (2 * .pi / Double(items.count)) * Double(index) - (.pi / 2)

        return ZStack {
            Circle()
                .fill(Color.cyberSurface.opacity(0.95))
                .frame(width: iconSize, height: iconSize)
                .overlay(
                    Circle()
                        .stroke(item.color.opacity(0.6), lineWidth: 1.5)
                )
                .shadow(color: item.color.opacity(0.3), radius: 8)

            Image(systemName: item.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(item.color)
        }
        .scaleEffect(itemScales.indices.contains(index) ? itemScales[index] : 1)
        .offset(
            x: itemOffsets.indices.contains(index) ? itemOffsets[index].width : 0,
            y: itemOffsets.indices.contains(index) ? itemOffsets[index].height : 0
        )
        .onTapGesture {
            HapticManager.medium()
            onSelectTab(item.tabTag)
        }
        .onLongPressGesture(minimumDuration: 0.3, pressing: { pressing in
            if pressing {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    selectedIndex = index
                    showLabels = true
                    itemScales[index] = 1.15
                }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    selectedIndex = nil
                    showLabels = false
                    itemScales[index] = 1.0
                }
            }
        }, perform: {})
        .onAppear {
            let delay = Double(index) * 0.06
            let x = orbitRadius * CGFloat(cos(angle))
            let y = orbitRadius * CGFloat(sin(angle))

            if reduceMotion {
                withAnimation(.easeOut(duration: animationDuration).delay(delay)) {
                    itemOffsets[index] = CGSize(width: x, height: y)
                    itemScales[index] = 1.0
                }
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(delay)) {
                    itemOffsets[index] = CGSize(width: x, height: y)
                    itemScales[index] = 1.0
                }
            }
        }
    }

    private func animateIn() {
        if reduceMotion {
            isAnimating = true
            return
        }

        withAnimation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.1)) {
            isAnimating = true
        }

        // Start slow orbit rotation
        withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
            orbitRotation = 360
        }
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            isAnimating = false
            for i in 0..<items.count {
                itemScales[i] = 0.01
                itemOffsets[i] = .zero
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            onDismiss()
        }
    }
}

// MARK: - Preview
struct OrbitalMenu_Previews: PreviewProvider {
    static var previews: some View {
        OrbitalMenu(
            isPresented: .constant(true),
            onSelectTab: { _ in },
            onDismiss: {}
        )
        .preferredColorScheme(.dark)
    }
}
