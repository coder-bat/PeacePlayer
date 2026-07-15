//
//  LandingView.swift
//  PeacePlayer
//
//  Pre-authentication landing screen.
//
//  S15: replaced the previous "wall of text" with a 3-card
//  onboarding intro (TabView-paged). The cards describe the
//  app's three signature features:
//   1. Stream your library — backed by a self-hosted backend
//      that proxies YouTube Music audio
//   2. Build playlists + EQ + crossfade — playback polish
//   3. Time Capsules — bury a song with a note, unlock it in
//      the future
//
//  Each card uses the same OnboardingCard component for
//  visual consistency. After swiping through all three, the
//  user sees the Sign in with Apple button.
//

import SwiftUI
import AuthenticationServices

struct LandingView: View {
    @StateObject private var auth = AuthService.shared
    @State private var currentPage = 0
    @State private var buttonPressed = false

    /// The three onboarding pages. Add or remove freely — the
    /// pager and the page indicator re-derive from the array
    /// length.
    private let cards: [OnboardingCard] = [
        OnboardingCard(
            icon: "music.note.list",
            iconColor: Theme.cyberCyan,
            title: "Stream Your Library",
            description: "Search, play, and download from a self-hosted YouTube Music backend. No ads, no algorithm.",
            details: nil
        ),
        OnboardingCard(
            icon: "slider.vertical.3",
            iconColor: Theme.cyberMagenta,
            title: "Make It Sound Right",
            description: "10-band parametric EQ, gapless playback, crossfade, and 32-band real-time visualizer.",
            details: "EQ + Visualizer"
        ),
        OnboardingCard(
            icon: "hourglass",
            iconColor: Theme.cyberYellow,
            title: "Bury a Time Capsule",
            description: "Seal a song with a note today. Unlock it in a week, a year, or a decade — for your future self.",
            details: "Time Capsules"
        )
    ]

    var body: some View {
        ZStack {
            // Animated background — same as Home so the visual
            // language is consistent pre- and post-sign-in.
            CyberBackground()

            VStack(spacing: 24) {
                // Brand mark — always visible at the top so the
                // user knows what app they're in even mid-swipe.
                brandHeader
                    .padding(.top, 24)

                Spacer(minLength: 12)

                // Pager: one card visible at a time, swipe to
                // advance. TabView with .page style is the
                // iOS-native way to do this; the index binding
                // drives the page indicator below.
                TabView(selection: $currentPage) {
                    ForEach(0..<cards.count, id: \.self) { index in
                        cards[index]
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: .infinity)

                OnboardingPageIndicator(
                    count: cards.count,
                    currentIndex: currentPage
                ) { index in
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        currentPage = index
                    }
                }

                // Sign in section — only show after the user has
                // seen all cards. A small "Next" button on the
                // last card advances; "Get Started" replaces the
                // indicator on the final page.
                signInSection
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 16)
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: auth.lastError)
    }

    // MARK: - Sub-views

    private var brandHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.cyberCyan, .cyberMagenta],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .cyberCyan.opacity(0.5), radius: 12)

            Text("PeacePlayer")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    private var signInSection: some View {
        // The sign-in button is shown when the user has reached
        // the last card. On the first two pages we show a
        // friendly "swipe to learn more" hint; on the last
        // page the Apple button appears.
        VStack(spacing: 12) {
            if currentPage == cards.count - 1 {
                signInButton
                if let error = auth.lastError, !error.isEmpty {
                    errorLabel(error)
                }
            } else {
                swipeHint
            }
        }
    }

    private var signInButton: some View {
        Button {
            buttonPressed = true
            Task { await auth.signIn() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 16, weight: .semibold))
                Text("Sign in with Apple")
                    .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.white)
            .foregroundColor(.black)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 320)
        .overlay(alignment: .center) {
            if auth.isSigningIn {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.black)
            }
        }
        .allowsHitTesting(!auth.isSigningIn)
        // S15: small kick to the Apple Pay haptic pattern on
        // press for tactile feedback. The button shape and
        // colors match the rest of the app's primary CTAs.
        .simultaneousGesture(
            TapGesture().onEnded { _ in
                HapticManager.medium()
            }
        )
    }

    private var swipeHint: some View {
        HStack(spacing: 6) {
            Text("Swipe to learn more")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(Theme.cyberDim)
        .padding(.vertical, 12)
    }

    private func errorLabel(_ error: String) -> some View {
        Text(error)
            .font(.system(size: 12))
            .foregroundColor(.red.opacity(0.85))
            .multilineTextAlignment(.center)
            .transition(.opacity)
    }
}

struct LandingView_Previews: PreviewProvider {
    static var previews: some View {
        LandingView()
    }
}
