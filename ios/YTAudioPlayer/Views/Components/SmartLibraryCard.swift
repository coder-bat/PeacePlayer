//
//  SmartLibraryCard.swift
//  PeacePlayer
//
//  2026-08-30: v1.9.0 Smart Library card.
//
//  Shown in the Home tab above the "Your Library" section
//  when SmartLibraryManager.pendingCandidates is non-nil.
//  Three states:
//
//    - idle (no pending cycle, no recent summary) — the
//      card is not rendered at all. Absence is the right
//      signal here; otherwise the card becomes visual
//      clutter for the 95% of opens that have nothing
//      to say.
//    - candidates-ready — the card appears with the
//      preview thumbs, byte estimate, auto-confirm
//      countdown, and the Download / Review / Skip
//      actions. User taps one or the timer fires.
//    - reviewing — the full-height Review sheet is
//      presented (lives in SmartLibraryReviewSheet.swift).
//
//  The card itself does NOT publish or commit — it just
//  reads SmartLibraryManager's published state and routes
//  the user's actions back through the manager's public
//  API (commitCycle / cancelPendingCycle).
//

import SwiftUI

struct SmartLibraryCard: View {
    @ObservedObject var smartLibrary = SmartLibraryManager.shared
    @State private var showReviewSheet: Bool = false
    // Drives a 1Hz re-render of the auto-confirm countdown
    // text. The actual commit-on-deadline logic lives in
    // SmartLibraryManager (scheduleAutoConfirm) — this
    // timer is purely for the visual countdown.
    @State private var now: Date = Date()

    var body: some View {
        Group {
            if let cycle = smartLibrary.pendingCandidates {
                pendingCard(for: cycle)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            // idle = nothing rendered
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: smartLibrary.pendingCandidates?.id)
        .sheet(isPresented: $showReviewSheet) {
            if let cycle = smartLibrary.pendingCandidates {
                SmartLibraryReviewSheet(originalCycle: cycle, isPresented: $showReviewSheet)
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            // Cheap 1Hz tick. The view re-renders so the
            // countdown text updates. No side effects.
            now = date
        }
    }

    // MARK: - Pending card

    @ViewBuilder
    private func pendingCard(for cycle: PendingCycle) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            headerRow(cycle: cycle)
            titleBlock(cycle: cycle)
            artworkRow(cycle: cycle)
            if let countdown = smartLibrary.autoConfirmRemainingFormatted {
                countdownRow(text: countdown)
            }
            actionRow(cycle: cycle)
        }
        .padding(Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.lg)
                .fill(Theme.cyberSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.lg)
                .stroke(
                    LinearGradient(
                        colors: [Theme.cyberCyan.opacity(0.6), Theme.cyberCyan.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Theme.cyberCyan.opacity(0.15), radius: 12, x: 0, y: 4)
        .padding(.horizontal, Spacing.md)
    }

    private func headerRow(cycle: PendingCycle) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Theme.cyberCyan)
            Text("SMART LIBRARY")
                .font(Typography.eyebrow)
                .foregroundColor(Theme.cyberCyan)
            Spacer()
            // Live status: "WiFi · 12:32 PM" — context for
            // when this cycle was prepared. The time is
            // refreshed every 1s by the parent onReceive.
            HStack(spacing: 4) {
                Image(systemName: "wifi")
                    .font(.system(size: 10))
                Text(timestampString)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundColor(Theme.cyberTextSecondary)
        }
    }

    private func titleBlock(cycle: PendingCycle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ready to top up your library")
                .font(Typography.title3)
                .foregroundColor(.white)
            HStack(spacing: 6) {
                Text("\(cycle.candidates.count) \(cycle.candidates.count == 1 ? "track" : "tracks")")
                    .font(Typography.subheadline)
                    .foregroundColor(Theme.cyberCyan)
                Text("·")
                    .foregroundColor(Theme.cyberTextSecondary)
                Text(byteEstimateString(bytes: cycle.estimatedBytes))
                    .font(Typography.subheadline)
                    .foregroundColor(Theme.cyberTextSecondary)
            }
        }
    }

    private func artworkRow(cycle: PendingCycle) -> some View {
        // Stacked thumbnails — the visual hook. Up to 3
        // visible, with a "+N more" tag if there are more.
        // Tapping the row opens the Review sheet.
        HStack(spacing: -Spacing.sm) {
            ForEach(Array(cycle.candidates.prefix(3).enumerated()), id: \.element.videoId) { index, track in
                artworkThumb(track: track, index: index)
            }
            if cycle.candidates.count > 3 {
                moreChip(remaining: cycle.candidates.count - 3)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            HapticManager.light()
            showReviewSheet = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview \(cycle.candidates.count) candidates")
        .accessibilityAddTraits(.isButton)
    }

    private func artworkThumb(track: Track, index: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .fill(Theme.cyberBackground)
            if let url = track.artworkURL {
                CachedAsyncImage(url: url) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "music.note")
                        .foregroundColor(Theme.cyberDim)
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
            } else {
                Image(systemName: "music.note")
                    .foregroundColor(Theme.cyberDim)
            }
        }
        .frame(width: 56, height: 56)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .stroke(Theme.cyberBackground, lineWidth: 2)
        )
        .zIndex(Double(3 - index))
    }

    private func moreChip(remaining: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .fill(Theme.cyberBackground)
            Text("+\(remaining) more")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.cyberCyan)
        }
        .frame(width: 56, height: 56)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .stroke(Theme.cyberBackground, lineWidth: 2)
        )
    }

    @ViewBuilder
    private func countdownRow(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 11))
            Text("Auto-confirming in ")
                .font(.system(size: 12, design: .monospaced))
            // The countdown text. Animated digit transitions
            // would be over-engineering for 1Hz — SwiftUI's
            // Text diff handles the visual update fine.
            Text(text)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.cyberCyan)
                .contentTransition(.numericText(countsDown: true))
            Spacer()
        }
        .foregroundColor(Theme.cyberTextSecondary)
    }

    private func actionRow(cycle: PendingCycle) -> some View {
        HStack(spacing: Spacing.sm) {
            // Primary action: Download all (commits the cycle)
            Button {
                HapticManager.medium()
                Task {
                    await smartLibrary.commitCycle(cycle, source: .userConfirmed)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Download all")
                        .fontWeight(.bold)
                    Text("(\(cycle.candidates.count))")
                        .fontWeight(.medium)
                        .foregroundColor(Theme.cyberCyan.opacity(0.8))
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(Theme.cyberCyan)
                )
            }
            .buttonStyle(.plain)

            // Secondary action: Review (opens the edit sheet)
            Button {
                HapticManager.light()
                showReviewSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Review")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.cyberCyan)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .stroke(Theme.cyberCyan.opacity(0.6), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            // Tertiary action: Skip (cancels the cycle)
            Button {
                HapticManager.light()
                smartLibrary.cancelPendingCycle(reason: "user skipped")
            } label: {
                Text("Skip")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.cyberTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.sm)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Formatting helpers

    private var timestampString: String {
        // Use the cycle's createdAt if available — tells
        // the user how long ago the cycle was prepared.
        guard let cycle = smartLibrary.pendingCandidates else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: cycle.createdAt)
    }

    private func byteEstimateString(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        let pretty = formatter.string(fromByteCount: bytes)
        return "~\(pretty)"
    }
}
