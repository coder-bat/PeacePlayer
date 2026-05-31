import SwiftUI

struct GestureCoachOverlay: View {
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Theme.playerBackgroundOverlay
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Text("Gesture Guide")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.cyberCyan)

                VStack(spacing: 24) {
                    hintRow(
                        icon: "hand.draw",
                        gesture: "Swipe artwork",
                        action: "Toggle visualizer"
                    )
                    hintRow(
                        icon: "hand.tap",
                        gesture: "Double-tap artwork",
                        action: "Like song"
                    )
                    hintRow(
                        icon: "hand.tap.fill",
                        gesture: "Long-press capsule",
                        action: "Open vault"
                    )
                    hintRow(
                        icon: "hand.point.up.left.and.text",
                        gesture: "Swipe down",
                        action: "Dismiss player"
                    )
                }

                Text("Tap anywhere to dismiss")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
            }
            .padding(32)
        }
        .transition(.opacity)
        .onTapGesture {
            HapticManager.light()
            onDismiss()
        }
    }

    private func hintRow(icon: String, gesture: String, action: String) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(Theme.cyberCyan)
                .frame(width: 36, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(gesture)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.inverseText)
                Text(action)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
            }

            Spacer()
        }
    }
}
