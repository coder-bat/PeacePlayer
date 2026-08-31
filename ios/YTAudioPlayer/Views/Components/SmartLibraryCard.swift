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
    }

    // MARK: - Pending card

    @ViewBuilder
    private func pendingCard(for cycle: PendingCycle) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // v1.9.0 (r2): combined header — the X dismiss
            // lives in the top-right of the title row, so
            // we drop the separate "headerRow" and put the
            // dismiss in the title block instead. Saves a
            // row + the "SMART LIBRARY" eyebrow was
            // requested to be removed.
            titleBlock(cycle: cycle)
            artworkRow(cycle: cycle)
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

    private func titleBlock(cycle: PendingCycle) -> some View {
        // v1.9.0 (r2): top row is "Title — N tracks · ~X MB
        // · WiFi time" with the X dismiss on the right.
        // The X is a standard dismiss control for a card —
        // same visual weight as a sheet's close button.
        HStack(alignment: .top, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ready to top up your library")
                    .font(Typography.title3)
                    .foregroundColor(.white)
                    .lineLimit(2)
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
            Spacer(minLength: Spacing.xs)
            // X dismiss button — same affordance as Skip
            // (cancels the cycle) but visually less prominent
            // than the primary actions. Hides the card
            // entirely.
            Button {
                HapticManager.light()
                smartLibrary.cancelPendingCycle(reason: "user dismissed card")
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
            .accessibilityLabel("Dismiss Smart Library card")
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
        // v1.9.0 (r2): widen the chip so "+N more" doesn't
        // get clipped at narrow card widths. The artwork
        // thumbs are 56pt wide; this chip auto-sizes to its
        // text (min 56pt, expands to fit). Bumped the
        // horizontal padding so the text breathes.
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .fill(Theme.cyberBackground)
            Text("+\(remaining) more")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.cyberCyan)
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

    private func actionRow(cycle: PendingCycle) -> some View {
        // v1.9.0 (r2): just two buttons now — Download all +
        // Review. The Skip button is gone; the X on the top
        // right of the card handles the "don't do anything"
        // intent. Two buttons means each gets ~50% width
        // instead of ~33%, so "Download all (N)" fits on a
        // single line.
        HStack(spacing: Spacing.sm) {
            // Primary action: Download all
            Button {
                HapticManager.medium()
                Task {
                    await smartLibrary.commitCycle(cycle, source: .userConfirmed)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    // Single Text with inline count — the
                    // v1 split into 2 Text views wrapped
                    // on narrow widths. Concatenating into
                    // one string lets SwiftUI break the
                    // line as a whole if it must, instead
                    // of breaking inside the label.
                    Text("Download all (\(cycle.candidates.count))")
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
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
        }
    }

    // MARK: - Formatting helpers

    private func byteEstimateString(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        let pretty = formatter.string(fromByteCount: bytes)
        return "~\(pretty)"
    }
}
