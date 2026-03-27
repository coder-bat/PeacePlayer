//
//  TimeCapsuleVaultView.swift
//  YTAudioPlayer
//
//  The "Time Vault" — lists all capsules: sealed, ready-to-open, and opened.
//

import SwiftUI

struct TimeCapsuleVaultView: View {
    @ObservedObject private var capsuleManager = TimeCapsuleManager.shared
    @State private var revealCapsule: TimeCapsuleSnapshot? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                if capsuleManager.capsules.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            if !capsuleManager.readyToOpen.isEmpty {
                                sectionHeader("Ready to Open 💌", color: .cyan)
                                ForEach(capsuleManager.readyToOpen) { capsule in
                                    CapsuleCard(capsule: capsule, style: .readyToOpen)
                                        .onTapGesture { revealCapsule = capsule }
                                }
                            }

                            if !capsuleManager.pendingCapsules.isEmpty {
                                sectionHeader("Sealed ⏳", color: .gray)
                                ForEach(capsuleManager.pendingCapsules) { capsule in
                                    CapsuleCard(capsule: capsule, style: .sealed)
                                }
                            }

                            if !capsuleManager.openedCapsules.isEmpty {
                                sectionHeader("Opened", color: .gray.opacity(0.6))
                                ForEach(capsuleManager.openedCapsules) { capsule in
                                    CapsuleCard(capsule: capsule, style: .opened)
                                        .onTapGesture { revealCapsule = capsule }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Time Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundColor(.gray)
                }
            }
            .fullScreenCover(item: $revealCapsule) { capsule in
                TimeCapsuleRevealView(capsule: capsule)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { capsuleManager.refresh() }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass")
                .font(.system(size: 48))
                .foregroundColor(.gray.opacity(0.4))
            Text("No Time Capsules Yet")
                .font(.headline)
                .foregroundColor(.gray)
            Text("Bury a capsule from the player to\nsend a message to your future self")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.7))
                .multilineTextAlignment(.center)
        }
    }

    private func sectionHeader(_ title: String, color: Color) -> some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundColor(color)
            Spacer()
        }
    }
}

// MARK: - Capsule Card

private enum CapsuleCardStyle {
    case sealed, readyToOpen, opened
}

private struct CapsuleCard: View {
    let capsule: TimeCapsuleSnapshot
    let style: CapsuleCardStyle

    var body: some View {
        HStack(spacing: 14) {
            // Artwork (blurred if sealed)
            AsyncImage(url: capsule.artworkURL) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.2)
                }
            }
            .frame(width: 56, height: 56)
            .cornerRadius(10)
            .blur(radius: style == .sealed ? 8 : 0)
            .overlay(
                Group {
                    if style == .sealed {
                        Image(systemName: "lock.fill")
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(style == .sealed ? "••••••••" : capsule.trackTitle)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)

                if style == .sealed {
                    let days = capsule.daysUntilUnlock
                    Text("Opens in \(days) day\(days == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.cyan.opacity(0.7))
                } else if style == .readyToOpen {
                    Text("Tap to open ✨")
                        .font(.caption)
                        .foregroundColor(.cyan)
                } else {
                    Text("Opened \(capsule.openedAt?.formatted(.dateTime.month().day()) ?? "")")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            if let mood = capsule.mood {
                Text(mood)
                    .font(.title3)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(style == .readyToOpen
                    ? Color.cyan.opacity(0.08)
                    : Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            style == .readyToOpen ? Color.cyan.opacity(0.4) : Color.clear,
                            lineWidth: 1
                        )
                )
        )
    }
}
