//
//  LibraryTierBadge.swift
//  PeacePlayer
//
//  2026-08-30: v1.9.0 Smart Library tier badge.
//
//  Inline badge shown next to auto-downloaded tracks in
//  the Library tab. Visualises the cleanup grace period
//  countdown so the user can see "this track was
//  auto-downloaded; it'll be auto-removed in 9 days
//  unless I heart it".
//
//  Three color states (per the plan):
//    - > 7d remaining: Theme.cyberCyan  (calm)
//    - 7d .. 3d:        Theme.cyberYellow (warning)
//    - < 3d:            Theme.cyberMagenta (urgent)
//
//  Tapping the badge presents an action sheet:
//    - "Keep" — heart the track, promotes to .liked,
//      never auto-removed. Uses the same
//      PlaylistManager.toggleLike path the heart
//      button uses.
//    - "Remove now" — manual delete with a confirm
//      alert. The user can always do this from the
//      context menu, but the badge gives it prominence
//      when the grace period is running down.
//
//  Live countdown: 60-second Timer.publish ticks while
//  the badge is on screen so the "9d" text refreshes
//  when the day boundary actually rolls over. This is
//  cheap (one Timer per visible badge) and avoids
//  stale displays.
//

import SwiftUI
import Combine

struct LibraryTierBadge: View {
    let videoId: String

    @ObservedObject var smartLibrary = SmartLibraryManager.shared
    @ObservedObject var playlistManager = PlaylistManager.shared

    @State private var now: Date = Date()
    @State private var showActionSheet: Bool = false
    @State private var showDeleteConfirm: Bool = false

    /// v1.9.0: only render for tracks in the .auto tier.
    /// Liked and manual tracks don't get a badge (per
    /// the plan: "Auto only (Recommended)").
    private var tier: SmartLibraryManager.DownloadTier {
        smartLibrary.tier(for: videoId)
    }

    var body: some View {
        Group {
            if tier == .auto, let daysRemaining = daysRemaining() {
                Button {
                    HapticManager.light()
                    showActionSheet = true
                } label: {
                    badgeContent(daysRemaining: daysRemaining)
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    "Auto-downloaded track",
                    isPresented: $showActionSheet,
                    titleVisibility: .visible
                ) {
                    Button("Keep (heart)") {
                        // Promotes to .liked. Never auto-removed.
                        playlistManager.toggleLike(trackId: videoId)
                    }
                    Button("Remove now", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This track was auto-downloaded. It will be removed in \(daysRemaining) \(daysRemaining == 1 ? "day" : "days") unless you keep it.")
                }
                .alert("Remove this track?", isPresented: $showDeleteConfirm) {
                    Button("Remove", role: .destructive) {
                        DownloadManager.shared.deleteDownload(videoId: videoId)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This deletes the local file. You can re-download it from the search.")
                }
            }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            // 60s tick. Cheap, only re-renders the badge
            // text. Not per-second because the day
            // boundary only matters at 1-day granularity.
            now = date
        }
    }

    // MARK: - Badge content

    private func badgeContent(daysRemaining: Int) -> some View {
        let color = colorState(for: daysRemaining)
        return HStack(spacing: 4) {
            // Small color dot or ring
            ZStack {
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: 1.5)
                    .frame(width: 10, height: 10)
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
            }
            Text("AUTO · \(daysRemaining)d")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .contentTransition(.numericText(countsDown: true))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(color.opacity(0.1))
        )
        .overlay(
            Capsule()
                .stroke(color.opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    /// Days remaining until auto-removal. Returns nil
    /// if the track is not in the auto tier (caller
    /// checks tier separately, so this is just a
    /// safety net).
    private func daysRemaining() -> Int? {
        guard tier == .auto else { return nil }
        let lastPlayed = DataManager.shared.recentlyPlayed
            .first(where: { $0.videoId == videoId })?
            .playedAt
        // nil = never played → unplayed since download →
        // past the threshold by definition. The
        // "days remaining" doesn't apply; the track is
        // already eligible for cleanup. Render 0d.
        guard let last = lastPlayed else { return 0 }
        let elapsed = now.timeIntervalSince(last)
        let days = TimeInterval(smartLibrary.cleanupDaysAuto) * 24 * 3600
        let remaining = days - elapsed
        return max(0, Int(remaining / (24 * 3600)))
    }

    private func colorState(for daysRemaining: Int) -> Color {
        switch daysRemaining {
        case ..<3: return Theme.cyberMagenta
        case 3..<7: return Theme.cyberYellow
        default: return Theme.cyberCyan
        }
    }
}
