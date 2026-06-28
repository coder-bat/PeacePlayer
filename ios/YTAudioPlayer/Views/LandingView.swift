//
//  LandingView.swift
//  PeacePlayer
//
//  2026-06-28: pre-authentication landing screen. The next version
//  of PeacePlayer requires Apple sign-in — there is no guest path.
//  This view is the only thing visible to a logged-out user; tapping
//  the Sign in with Apple button runs the ASAuthorization flow and,
//  on success, drops the user into the main app.
//

import SwiftUI
import AuthenticationServices

struct LandingView: View {
    @StateObject private var auth = AuthService.shared
    @State private var buttonPressed = false

    var body: some View {
        ZStack {
            // Animated background — same as Home so the visual
            // language is consistent pre- and post-sign-in.
            CyberBackground()

            VStack(spacing: 32) {
                Spacer()

                // Brand mark
                VStack(spacing: 18) {
                    Image(systemName: "waveform")
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.cyberCyan, .cyberMagenta],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .cyberCyan.opacity(0.5), radius: 18)

                    VStack(spacing: 8) {
                        Text("PeacePlayer")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text("your music, your way")
                            .font(.system(size: 15, weight: .regular, design: .monospaced))
                            .foregroundColor(.cyberDim)
                            .textCase(.lowercase)
                    }
                }

                Spacer()

                // Tagline + value prop
                VStack(spacing: 12) {
                    Text("Sign in to start listening")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Stream your library, build playlists, and pick up where you left off across devices.")
                        .font(.system(size: 13))
                        .foregroundColor(.cyberDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // Sign in with Apple
                // The button's body is its own tap target — we wrap
                // the call to AuthService.signIn() around the actual
                // press, which is reported via the button's onTapGesture
                // (a regular button style wouldn't work — this is a
                // native UIView wrapped in UIViewRepresentable).
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

                // Error feedback (shown only when present).
                if let error = auth.lastError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .transition(.opacity)
                }

                Spacer()
                    .frame(height: 60)
            }
            .padding(.horizontal, 24)
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: auth.lastError)
    }
}

struct LandingView_Previews: PreviewProvider {
    static var previews: some View {
        LandingView()
    }
}
