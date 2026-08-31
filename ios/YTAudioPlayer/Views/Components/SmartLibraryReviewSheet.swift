//
//  SmartLibraryReviewSheet.swift
//  PeacePlayer
//
//  2026-08-30: v1.9.0 Smart Library review sheet.
//
//  Full-height sheet presented from SmartLibraryCard when
//  the user taps "Review". Lets the user:
//
//    - See the full candidate list with track + artist
//    - Filter by source (Liked artists / Recently played / All)
//    - Remove individual candidates they don't want
//    - Add candidates via inline search (hits the same
//      APIService.search the auto-cycle uses)
//    - Commit the modified list, or cancel (revert to
//      the card's auto-confirm flow)
//
//  The sheet mutates a local copy of the cycle. On
//  "Download N tracks" the modified list is committed
//  via SmartLibraryManager.commitCycle. On "Cancel" the
//  sheet dismisses and the original cycle is left
//  pending — the auto-confirm timer continues.
//

import SwiftUI
import Combine

struct SmartLibraryReviewSheet: View {
    let originalCycle: PendingCycle
    @Binding var isPresented: Bool

    @ObservedObject var smartLibrary = SmartLibraryManager.shared

    // Local mutable copy of the cycle. The user can
    // remove tracks; the commit uses this copy, not the
    // original.
    @State private var workingCandidates: [Track] = []
    @State private var workingBreakdown: TierBreakdown = TierBreakdown(fromLikedArtists: 0, fromRecentlyPlayed: 0)

    // Source filter
    @State private var sourceFilter: SourceFilter = .all

    // Add-track search
    @State private var addSearchQuery: String = ""
    @State private var addSearchResults: [Track] = []
    @State private var isSearching: Bool = false
    @State private var searchCancellable: AnyCancellable? = nil

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case likedArtists = "Liked artists"
        case recentlyPlayed = "Recently played"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CyberBackground()
                VStack(spacing: 0) {
                    headerSummary
                    sourceFilterChips
                    candidateList
                    addTrackRow
                    commitBar
                }
            }
            // v1.9.0 (r2): drop the system nav title + the
            // system Cancel button — they read as "iOS
            // settings" not "PeacePlayer". The custom
            // header summary at the top of the content
            // already shows the cycle count + bytes; the
            // close affordance lives in a custom X button
            // matching the card's X.
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
        .onAppear {
            // Snapshot the cycle. The original is still
            // pending; the auto-confirm timer is still
            // ticking. If the user takes too long, the
            // auto-confirm fires with the ORIGINAL cycle
            // (since commitCycle is gated on the id
            // matching the current pendingCandidates).
            // After this sheet dismisses via "Download N",
            // we commit the LOCAL copy, which has a
            // different (empty) candidate list and a
            // different id — so it would be rejected by
            // the stale-cycle guard.
            //
            // Solution: the commit button constructs a
            // NEW PendingCycle with the local candidates
            // and replaces pendingCandidates directly
            // (via a new method on the manager). See
            // SmartLibraryManager.replacePendingCandidates.
            // This is wired below in commitBar.
            workingCandidates = originalCycle.candidates
            workingBreakdown = originalCycle.tierBreakdown
        }
    }

    // MARK: - Header

    private var headerSummary: some View {
        // v1.9.0 (r2): custom title row + count summary.
        // The system nav title is hidden (see body); the
        // title is rendered inline so the X close button
        // has room to live at the top-right.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.cyberCyan)
                Text("REVIEW AUTO-DOWNLOAD")
                    .font(Typography.eyebrow)
                    .foregroundColor(Theme.cyberCyan)
            }
            HStack(spacing: 6) {
                Text("\(workingCandidates.count) \(workingCandidates.count == 1 ? "track" : "tracks")")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.cyberCyan)
                Text("·")
                    .foregroundColor(Theme.cyberTextSecondary)
                Text(byteEstimateString)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(Theme.cyberTextSecondary)
                Spacer()
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
    }

    // MARK: - Source filter

    private var sourceFilterChips: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(SourceFilter.allCases) { filter in
                chip(for: filter)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private func chip(for filter: SourceFilter) -> some View {
        let isActive = sourceFilter == filter
        let count: Int = {
            switch filter {
            case .all: return workingCandidates.count
            case .likedArtists: return workingBreakdown.fromLikedArtists
            case .recentlyPlayed: return workingBreakdown.fromRecentlyPlayed
            }
        }()
        return Button {
            HapticManager.light()
            sourceFilter = filter
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
                    .fill(isActive ? Theme.cyberCyan : Theme.cyberSurface)
            )
            .foregroundColor(isActive ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Candidate list

    private var candidateList: some View {
        ScrollView {
            LazyVStack(spacing: Spacing.xs) {
                ForEach(filteredCandidates, id: \.videoId) { track in
                    candidateRow(track: track)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .leading)),
                            removal: .opacity
                        ))
                }
                if filteredCandidates.isEmpty {
                    emptyFilterState
                }
            }
            .padding(.horizontal, Spacing.md)
        }
        .animation(.easeInOut(duration: 0.2), value: filteredCandidates)
    }

    private var filteredCandidates: [Track] {
        switch sourceFilter {
        case .all:
            return workingCandidates
        case .likedArtists:
            // We don't have a "tier" per-candidate; the
            // breakdown is the cycle-level count. For a
            // best-effort filter, take the first
            // workingBreakdown.fromLikedArtists entries
            // (the original order — tier 1 was prepended
            // to tier 2 in computePendingCycle).
            return Array(workingCandidates.prefix(workingBreakdown.fromLikedArtists))
        case .recentlyPlayed:
            return Array(workingCandidates.dropFirst(workingBreakdown.fromLikedArtists))
        }
    }

    private func candidateRow(track: Track) -> some View {
        HStack(spacing: Spacing.sm) {
            // Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: CornerRadius.sm)
                    .fill(Theme.cyberBackground)
                if let url = track.artworkURL {
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

            // Title + artist + source label
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(track.artists.first ?? "Unknown artist")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.cyberTextSecondary)
                        .lineLimit(1)
                    Text("·")
                        .foregroundColor(Theme.cyberTextSecondary)
                    Text(formatDuration(track.durationSeconds))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.cyberTextSecondary)
                }
                // Source label — "from: Liked artist — Tame Impala"
                // or "from: Recently played"
                sourceLabel(for: track)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.cyberCyan.opacity(0.7))
            }
            Spacer()
            // Remove button
            Button {
                HapticManager.light()
                removeCandidate(track)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.cyberTextSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(track.title)")
        }
        .padding(Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(Theme.cyberSurface.opacity(0.5))
        )
    }

    private func sourceLabel(for track: Track) -> Text {
        // Heuristic: tier-1 candidates are the first
        // fromLikedArtists in workingCandidates (matching
        // the order produced by computePendingCycle).
        let isTier1 = workingCandidates.prefix(workingBreakdown.fromLikedArtists).contains(where: { $0.videoId == track.videoId })
        if isTier1 {
            return Text("from: Liked artist search")
        } else {
            return Text("from: Recently played")
        }
    }

    private var emptyFilterState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(Theme.cyberDim)
            Text("No candidates match this filter")
                .font(.system(size: 14))
                .foregroundColor(Theme.cyberTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
    }

    // MARK: - Add track

    private var addTrackRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(Theme.cyberCyan)
                Text("Add a track")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.cyberCyan)
            }
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.cyberDim)
                TextField("Search to add...", text: $addSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .onChange(of: addSearchQuery) { _, newValue in
                        triggerAddSearch(query: newValue)
                    }
                if isSearching {
                    ProgressView()
                        .tint(Theme.cyberCyan)
                        .scaleEffect(0.7)
                }
            }
            .padding(Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(Theme.cyberSurface)
            )

            // Inline results
            if !addSearchResults.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(addSearchResults, id: \.videoId) { track in
                            addResultRow(track: track)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    private func addResultRow(track: Track) -> some View {
        HStack(spacing: Spacing.xs) {
            // Small thumb
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.cyberBackground)
                if let url = track.artworkURL {
                    CachedAsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "music.note")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.cyberDim)
                    }
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.cyberDim)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(track.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(track.artists.first ?? "")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.cyberTextSecondary)
                    .lineLimit(1)
            }
            Spacer()
            let alreadyAdded = workingCandidates.contains(where: { $0.videoId == track.videoId })
            Button {
                HapticManager.light()
                if alreadyAdded {
                    removeCandidate(track)
                } else {
                    addCandidate(track)
                }
            } label: {
                Image(systemName: alreadyAdded ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 18))
                    .foregroundColor(alreadyAdded ? Theme.cyberCyan : Theme.cyberTextSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.xs)
                .fill(Theme.cyberSurface.opacity(0.3))
        )
    }

    private func triggerAddSearch(query: String) {
        // Debounce + cancel any in-flight search.
        searchCancellable?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            addSearchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchCancellable = APIService.shared.search(query: trimmed, limit: 5)
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { _ in
                    isSearching = false
                },
                receiveValue: { tracks in
                    addSearchResults = tracks.filter { Self.isAutoDownloadEligibleLocal($0) }
                    isSearching = false
                }
            )
    }

    /// Reuse the manager's filter for the inline add
    /// search — we don't want to add karaoke or
    /// podcast-style results to the download list.
    private static func isAutoDownloadEligibleLocal(_ track: Track) -> Bool {
        SmartLibraryManager.isAutoDownloadEligible(track)
    }

    private func addCandidate(_ track: Track) {
        guard !workingCandidates.contains(where: { $0.videoId == track.videoId }) else { return }
        workingCandidates.append(track)
        // Additions count as "recently played" for
        // breakdown purposes (they didn't come from
        // the liked-artist probe).
        workingBreakdown = TierBreakdown(
            fromLikedArtists: workingBreakdown.fromLikedArtists,
            fromRecentlyPlayed: workingBreakdown.fromRecentlyPlayed + 1
        )
        // Clear the search after a successful add so
        // the user can search for the next track.
        addSearchQuery = ""
        addSearchResults = []
    }

    private func removeCandidate(_ track: Track) {
        guard let idx = workingCandidates.firstIndex(where: { $0.videoId == track.videoId }) else { return }
        let wasTier1 = idx < workingBreakdown.fromLikedArtists
        workingCandidates.remove(at: idx)
        workingBreakdown = TierBreakdown(
            fromLikedArtists: max(0, workingBreakdown.fromLikedArtists - (wasTier1 ? 1 : 0)),
            fromRecentlyPlayed: max(0, workingBreakdown.fromRecentlyPlayed - (wasTier1 ? 0 : 1))
        )
    }

    // MARK: - Commit bar

    private var commitBar: some View {
        VStack(spacing: 0) {
            Divider().background(Theme.cyberSurface)
            HStack(spacing: Spacing.sm) {
                Button {
                    HapticManager.light()
                    isPresented = false
                } label: {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.cyberTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.sm)
                }
                .buttonStyle(.plain)

                Button {
                    HapticManager.medium()
                    let modifiedCycle = PendingCycle(
                        id: UUID(),
                        candidates: workingCandidates,
                        estimatedBytes: Int64(workingCandidates.count) * 5_000_000,
                        createdAt: originalCycle.createdAt,
                        tierBreakdown: workingBreakdown,
                        downloadSource: originalCycle.downloadSource
                    )
                    isPresented = false
                    Task {
                        // Replace the manager's pending cycle
                        // with the user's edited version, then
                        // commit. The replace keeps the
                        // auto-confirm timer consistent.
                        await smartLibrary.replaceAndCommit(modifiedCycle, source: .userConfirmed)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(workingCandidates.isEmpty ? "Download (0)" : "Download \(workingCandidates.count)")
                        if !workingCandidates.isEmpty {
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
                            .fill(workingCandidates.isEmpty ? Theme.cyberDim : Theme.cyberCyan)
                    )
                }
                .buttonStyle(.plain)
                .disabled(workingCandidates.isEmpty)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Theme.cyberBackground)
        }
    }

    // MARK: - Formatting

    private var byteEstimateString: String {
        let bytes = Int64(workingCandidates.count) * 5_000_000
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
