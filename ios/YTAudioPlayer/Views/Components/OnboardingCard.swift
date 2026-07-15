//
//  OnboardingCard.swift
//  PeacePlayer
//
//  S15: reusable onboarding card component for the LandingView
//  3-card intro. Used to be a wall of text on the pre-sign-in
//  screen; the audit identified the lack of an app-intro
//  carousel as a friction point. Each card is one feature of
//  PeacePlayer — the user can swipe through them or tap page
//  indicators to jump.
//

import SwiftUI

struct OnboardingCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let details: String?

    init(
        icon: String,
        iconColor: Color = Theme.cyberCyan,
        title: String,
        description: String,
        details: String? = nil
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.description = description
        self.details = details
    }

    var body: some View {
        VStack(spacing: 18) {
            // Icon
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 100, height: 100)
                Image(systemName: icon)
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [iconColor, iconColor.opacity(0.6)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                Text(description)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let details = details {
                Text(details)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(iconColor.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
    }
}

/// Page indicator — three small dots, the active one is the
/// cyberCyan accent and the rest are dim. Used at the bottom
/// of the onboarding pager.
struct OnboardingPageIndicator: View {
    let count: Int
    let currentIndex: Int
    let onTap: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Button {
                    onTap(index)
                } label: {
                    Circle()
                        .fill(index == currentIndex ? Theme.cyberCyan : Theme.cyberDim.opacity(0.4))
                        .frame(width: index == currentIndex ? 10 : 8, height: index == currentIndex ? 10 : 8)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentIndex)
                }
                .accessibilityLabel("Page \(index + 1) of \(count)")
            }
        }
        .padding(.vertical, 8)
    }
}
