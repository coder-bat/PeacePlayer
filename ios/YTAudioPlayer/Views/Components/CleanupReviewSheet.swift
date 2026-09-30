//
//  CleanupReviewSheet.swift
//  PeacePlayer
//
//  2026-09-08: v1.9.3 — full-height sheet presented from
//  CleanupScheduledBanner's "Review" button. Lets the user:
//
//    - See the full list of tracks scheduled for cleanup
//    - Filter by tier (Auto / Manual / All)
//    - Cancel individual candidates (the X on each row
//      clears that row's `cleanupScheduledAt`)
//    - Cancel the entire batch
//    - "Clean up now" to skip the 24h grace and move the
//      files to trash immediately
//
//  Per-row cancel mutates the manager's published state
//  synchronously, so the row disappears from the sheet
//  immediately (no need to wait for the next foreground
//  cycle). The Smart Library manager's `cancelCleanupItem`
//  is the single point of mutation; the sheet just calls
//  it and reads the updated state on the next render.
//

import SwiftUI

struct CleanupReviewSheet: View {
    let pending: PendingCleanup
    @Binding var isPresented: Bool

    @ObservedObject var smartLibrary = SmartLibraryManager.shared

    // Tier filter — defaults to .all, same as the
    // download-cycle review sheet.
    @State private var tierFilter: TierFilter = .all

    enum TierFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case auto = "Auto"
        case manual = "Manual"
        var id: String { rawValue }
    }

    // Live, derived from the manager's published state so
    // per-row cancels update the list immediately. If the
    // user cancels the only entry, this becomes empty and
    // the sheet shows the empty state.
    private var visibleEntries: [CleanupEntry] {
        pending.entries.filter { entry in
            switch tierFilter {
            case .all: return true
            case .auto: return entry.tier == .auto
            case .manual: return entry.tier == .manual
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CyberBackground()
                VStack(spacing: 0) {
                    headerSummary
                    tierFilterChips
                    candidateList
                    commitBar
                }
            }
            .navigationBarHidden(true)
            .overlay(alignment: .topTrailing) {
                Button {
                    HapticManager.light()
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.cyberTextSecondary)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(Theme.cyberSurface)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, Spacing.md)
                .padding(.trailing, Spacing.md)
            }
        }
    }

    // MARK: - Header

    private var headerSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "trash.circle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.cyberMagenta)
                Text("REVIEW CLEANUP")
                    .font(Typography.eyebrow)
                    .foregroundColor(Theme.cyberMagenta)
            }
            HStack(spacing: 6) {
                Text("\(visibleEntries.count) \(visibleEntries.count == 1 ? "track" : "tracks")")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.cyberMagenta)
                Text("·")
                    .foregroundColor(Theme.cyberTextSecondary)
                Text(byteEstimateString)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(Theme.cyberTextSecondary)
                Text("·")
                    .foregroundColor(Theme.cyberTextSecondary)
                Text("cleanup in \(formatRemaining(pending.cleanupIn))")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(Theme.cyberTextSecondary)
                Spacer()
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
    }

    // MARK: - Tier filter

    private var tierFilterChips: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(TierFilter.allCases) { filter in
                chip(for: filter)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private func chip(for filter: TierFilter) -> some View {
        let isActive = tierFilter == filter
        let count: Int = {
            switch filter {
            case .all: return pending.entries.count
            case .auto: return pending.entries.filter { $0.tier == .auto }.count
            case .manual: return pending.entries.filter { $0.tier == .manual }.count
            }
        }()
        return Button {
            HapticManager.light()
            tierFilter = filter
        } label: {
            HStack(spacing: 4) {
                Text(filter.rawValue)
                    .font(.system(size: 12, weight: .medium))
                Text("(\(count))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(isActive ? .black.opacity(0.6) : Theme.cyberTextSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isActive ? Theme.cyberMagenta : Theme.cyberSurface)
            )
            .foregroundColor(isActive ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Candidate list

    private var candidateList: some View {
        ScrollView {
            LazyVStack(spacing: Spacing.xs) {
                ForEach(visibleEntries, id: \.videoId) { entry in
                    candidateRow(entry: entry)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .leading)),
                            removal: .opacity
                        ))
                }
                if visibleEntries.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, Spacing.md)
        }
        .animation(.easeInOut(duration: 0.2), value: visibleEntries)
    }

    private func candidateRow(entry: CleanupEntry) -> some View {
        HStack(spacing: Spacing.sm) {
            // Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .fill(Theme.cyberBackground)
                if let url = entry.thumbnailURL {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "music.note").foregroundColor(Theme.cyberDim)
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
                } else {
                    Image(systemName: "music.note").foregroundColor(Theme.cyberDim)
                }
            }
            .frame(width: 44, height: 44)

            // Title + artist + tier label
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.artist)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.cyberTextSecondary)
                        .lineLimit(1)
                    Text("·")
                        .foregroundColor(Theme.cyberTextSecondary)
                    Text(byteString(entry.fileSize))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.cyberTextSecondary)
                }
                // Tier label — distinguishes auto from manual
                // at a glance so the user knows what they're
                // agreeing to.
                tierLabel(for: entry)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(tierColor(for: entry.tier).opacity(0.8))
            }
            Spacer()
            // Cancel button — clears this row's
            // `cleanupScheduledAt` and dismisses it from
            // the sheet immediately.
            Button {
                HapticManager.light()
                smartLibrary.cancelCleanupItem(videoId: entry.videoId)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.cyberTextSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Keep \(entry.title)")
        }
        .padding(Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(Theme.cyberSurface.opacity(0.5))
        )
    }

    private func tierLabel(for entry: CleanupEntry) -> Text {
        switch entry.tier {
        case .liked: return Text("Liked · protected")
        case .auto: return Text("Auto-downloaded · \(smartLibrary.cleanupDaysAuto)d unplayed")
        case .manual: return Text("Manual · \(smartLibrary.cleanupDaysManual)d unplayed")
        }
    }

    private func tierColor(for tier: DownloadTier) -> Color {
        switch tier {
        case .liked: return Theme.cyberCyan
        case .auto: return Theme.cyberMagenta
        case .manual: return Theme.warning
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundColor(Theme.cyberCyan)
            Text("All scheduled cleanups cancelled")
                .font(.system(size: 14))
                .foregroundColor(Theme.cyberTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
    }

    // MARK: - Commit bar

    private var commitBar: some View {
        VStack(spacing: 0) {
            Divider().background(Theme.cyberSurface)
            HStack(spacing: Spacing.sm) {
                // Cancel all — left secondary action.
                Button {
                    HapticManager.light()
                    smartLibrary.cancelPendingCleanup()
                    isPresented = false
                } label: {
                    Text("Cancel all")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.cyberTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.sm)
                }
                .buttonStyle(.plain)

                // Clean up now — primary action, magenta.
                Button {
                    HapticManager.medium()
                    isPresented = false
                    Task {
                        await smartLibrary.commitPendingCleanupNow()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash.fill")
                        Text(visibleEntries.isEmpty ? "Clean up (0)" : "Clean up \(visibleEntries.count)")
                        if !visibleEntries.isEmpty {
                            Text("(\(byteEstimateString))")
                                .fontWeight(.medium)
                                .foregroundColor(.black.opacity(0.6))
                        }
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .fill(visibleEntries.isEmpty ? Theme.cyberDim : Theme.cyberMagenta)
                    )
                }
                .buttonStyle(.plain)
                .disabled(visibleEntries.isEmpty)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Theme.cyberBackground)
        }
    }

    // MARK: - Formatting

    private var byteEstimateString: String {
        let bytes = visibleEntries.reduce(0) { $0 + $1.fileSize }
        return byteString(bytes)
    }

    private func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

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
