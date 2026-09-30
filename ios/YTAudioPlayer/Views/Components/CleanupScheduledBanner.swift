//
//  CleanupScheduledBanner.swift
//  PeacePlayer
//
//  2026-09-08: v1.9.3 — "These tracks are ready for cleanup"
//  banner. Appears in the Home tab above the Smart Library
//  card (urgent decision first) when
//  SmartLibraryManager.pendingCleanup is non-nil.
//
//  Two states:
//
//    - grace-active — the 24h window is still open. Card
//      shows "N tracks ready in Xh · Review" with two
//      actions: Review (open the sheet) and an X to
//      cancel all.
//
//    - grace-ending — less than 1h left. Card swaps the
//      hour countdown to a minute countdown + a stronger
//      warning tint, so the user notices before the auto-
//      commit kicks in.
//
//  The banner is the read-only summary; per-row + cancel-all
//  lives in the CleanupReviewSheet (the Review action opens
//  it). The Clean up now button is the banner's primary
//  action — it skips the 24h wait and moves the files
//  straight to trash, with the post-run Undo toast.
//

import SwiftUI

struct CleanupScheduledBanner: View {
    @ObservedObject var smartLibrary = SmartLibraryManager.shared
    @State private var showReviewSheet: Bool = false

    // Tick state to refresh the countdown every minute. The
    // banner's "Cleanup in 23h" text would otherwise feel
    // static — the user opens the app, sees "23h", and
    // wonders if it's even running. A 60s tick is enough
    // granularity without burning battery.
    @State private var nowTick: Date = Date()
    private let tickTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let pending = smartLibrary.pendingCleanup {
                banner(for: pending)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            // idle = nothing rendered (matches SmartLibraryCard pattern)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: smartLibrary.pendingCleanup?.id)
        .onReceive(tickTimer) { _ in
            nowTick = Date()
        }
        .sheet(isPresented: $showReviewSheet) {
            if let pending = smartLibrary.pendingCleanup {
                CleanupReviewSheet(pending: pending, isPresented: $showReviewSheet)
            }
        }
    }

    // MARK: - Banner layout

    @ViewBuilder
    private func banner(for pending: PendingCleanup) -> some View {
        let endingSoon = pending.cleanupIn < 3600  // < 1h
        VStack(alignment: .leading, spacing: Spacing.md) {
            headerRow(pending: pending, endingSoon: endingSoon)
            statsRow(pending: pending)
            actionRow(pending: pending, endingSoon: endingSoon)
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
                        colors: endingSoon
                            ? [Theme.warning.opacity(0.7), Theme.warning.opacity(0.2)]
                            : [Theme.cyberMagenta.opacity(0.6), Theme.cyberMagenta.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: (endingSoon ? Theme.warning : Theme.cyberMagenta).opacity(0.15), radius: 12, x: 0, y: 4)
        .padding(.horizontal, Spacing.md)
    }

    private func headerRow(pending: PendingCleanup, endingSoon: Bool) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: endingSoon ? "exclamationmark.triangle.fill" : "trash.circle")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(endingSoon ? Theme.warning : Theme.cyberMagenta)
                    Text(endingSoon ? "Cleanup ending soon" : "Ready for cleanup")
                        .font(Typography.title3)
                        .foregroundColor(.white)
                        .lineLimit(2)
                }
                Text(endingSoon
                    ? "Auto-cleanup runs in \(formatRemaining(pending.cleanupIn))"
                    : "\(pending.entries.count) \(pending.entries.count == 1 ? "track" : "tracks") · auto-cleanup in \(formatRemaining(pending.cleanupIn))"
                )
                .font(Typography.subheadline)
                .foregroundColor(Theme.cyberTextSecondary)
            }
            Spacer(minLength: Spacing.xs)
            // X dismisses the entire pending batch.
            // Same affordance as the Smart Library card's X.
            Button {
                HapticManager.light()
                smartLibrary.cancelPendingCleanup()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.cyberTextSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(Theme.cyberBackground.opacity(0.5))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel all scheduled cleanups")
        }
    }

    private func statsRow(pending: PendingCleanup) -> some View {
        // Stacked thumbnails — the visual hook. Up to 3
        // visible, with a "+N more" tag if there are more.
        // Tapping the row opens the Review sheet.
        HStack(spacing: -Spacing.sm) {
            ForEach(Array(pending.entries.prefix(3).enumerated()), id: \.element.videoId) { index, entry in
                artworkThumb(entry: entry, index: index)
            }
            if pending.entries.count > 3 {
                moreChip(remaining: pending.entries.count - 3)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            HapticManager.light()
            showReviewSheet = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview \(pending.entries.count) cleanup candidates")
        .accessibilityAddTraits(.isButton)
    }

    private func artworkThumb(entry: CleanupEntry, index: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .fill(Theme.cyberBackground)
            if let url = entry.thumbnailURL {
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
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.cyberMagenta)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 8)
        }
        .frame(width: 76, height: 56)
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .stroke(Theme.cyberBackground, lineWidth: 2)
        )
    }

    private func actionRow(pending: PendingCleanup, endingSoon: Bool) -> some View {
        // Two buttons: primary (Clean up now, magenta) +
        // secondary (Review, outline). Mirrors the Smart
        // Library card's button pattern.
        HStack(spacing: Spacing.sm) {
            // Primary action: Clean up now (skip the 24h grace)
            Button {
                HapticManager.medium()
                Task {
                    await smartLibrary.commitPendingCleanupNow()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash.fill")
                    Text("Clean up (\(pending.entries.count))")
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .fill(Theme.cyberMagenta)
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.cyberMagenta)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .stroke(Theme.cyberMagenta.opacity(0.6), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Formatting

    /// "23h 45m" / "12m" / "47s" — compact countdown that
    /// reads naturally at any remaining duration. Used by
    /// both states.
    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return "\(h)h \(m)m"
        }
        if m > 0 {
            return "\(m)m"
        }
        return "\(max(1, total))s"
    }
}
