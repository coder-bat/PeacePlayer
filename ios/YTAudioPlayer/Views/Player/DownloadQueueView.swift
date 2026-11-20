//
//  DownloadQueueView.swift
//  YTAudioPlayer
//
//  Download queue view with improved feedback
//

import SwiftUI

struct DownloadQueueView: View {
    @StateObject private var downloadManager = DownloadManager.shared
    @StateObject private var libraryViewModel = LibraryViewModel()
    @State private var showHistory = false
    @State private var showClearConfirmation = false

    // Deck design system (docs/design/deck-design-system.md §8). Drawn
    // on the Deck when the turntable flag is on; the old drawing stays
    // as `legacyContent` until the flag retires.
    @ObservedObject private var featureFlags = FeatureFlags.shared
    private var deck: Bool { featureFlags.turntableHome }

    private var failedCount: Int {
        downloadManager.completedDownloads.filter { if case .failed = $0.status { return true }; return false }.count
    }

    var body: some View {
        Group {
            if deck { deckContent } else { legacyContent }
        }
        .environment(\.deckStyle, deck)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showHistory) {
            HistoryView()
        }
        .alert("Clear Completed Downloads?", isPresented: $showClearConfirmation) {
            Button("Clear", role: .destructive) {
                HapticManager.heavy()
                withAnimation(.spring()) {
                    downloadManager.clearCompleted()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove \(downloadManager.completedDownloads.count) completed items from the queue.")
        }
    }

    /// Deck: the title on the wall, two keys, three readouts, then a
    /// ledge and its rows for each of the queue's states.
    private var deckContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Downloads")
                    .font(DeckType.screenTitle)
                    .foregroundColor(TurntableTokens.cream)
                    .accessibilityAddTraits(.isHeader)

                HStack(spacing: 12) {
                    DeckButton(title: "History", symbol: "clock.arrow.circlepath") {
                        HapticManager.light()
                        showHistory = true
                    }
                    if !downloadManager.completedDownloads.isEmpty {
                        DeckButton(title: "Clear queue", symbol: "xmark") {
                            showClearConfirmation = true
                        }
                    }
                }

                statsHeader
                activeSection
                completedSection
                savedSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            // The tab bar floats: leave room under the last row.
            .padding(.bottom, 104)
        }
        .background(DeckRoom())
    }

    private var legacyContent: some View {
        NavigationStack {
            ZStack {
                Theme.cyberBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Custom title header
                        HStack {
                            Text("Downloads")
                                .font(.system(size: 24, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 10, x: 0, y: 0)
                            Spacer()
                            HStack(spacing: 12) {
                                Button {
                                    showHistory = true
                                } label: {
                                    Label("History", systemImage: "clock.arrow.circlepath")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundColor(Theme.cyberCyan)
                                }

                                if !downloadManager.completedDownloads.isEmpty {
                                    Button("Clear Queue") {
                                        showClearConfirmation = true
                                    }
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundColor(Theme.cyberCyan)
                                }
                            }
                        }

                        // Stats header
                        statsHeader

                        // Active downloads
                        activeSection

                        // Completed queue (current session)
                        completedSection

                        // Saved downloads from Core Data
                        savedSection
                    }
                    .padding()
                    .padding(.bottom, 80)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
        }
    }

    private var statsHeader: some View {
        HStack(spacing: deck ? 12 : 20) {
            StatBadge(
                icon: "arrow.down.circle.fill",
                value: "\(downloadManager.activeDownloads.count)",
                label: "Active",
                lamp: downloadManager.activeDownloads.isEmpty ? .idle : .working,
                lampColor: DeckSignal.power
            )

            StatBadge(
                icon: "internaldrive.fill",
                value: "\(libraryViewModel.tracks.count)",
                label: "Saved",
                lamp: .idle,
                lampColor: DeckSignal.power
            )

            StatBadge(
                icon: "xmark.circle.fill",
                value: "\(failedCount)",
                label: "Failed",
                lamp: failedCount == 0 ? .idle : .lit,
                lampColor: DeckSignal.attention
            )
        }
    }

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: deck ? 8 : 16) {
            SectionHeader(title: "Downloaded files", icon: "internaldrive", count: libraryViewModel.tracks.count)

            if libraryViewModel.tracks.isEmpty {
                EmptyStateCard(
                    icon: "internaldrive",
                    title: "No Saved Downloads",
                    subtitle: "Downloaded tracks appear here"
                )
            } else {
                VStack(spacing: deck ? 0 : 12) {
                    ForEach(libraryViewModel.sortedTracks) { item in
                        SavedDownloadCard(item: item) {
                            libraryViewModel.playTrack(item)
                        }
                    }
                }
            }
        }
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: deck ? 8 : 16) {
            SectionHeader(title: "Downloading", icon: "arrow.down.circle", count: downloadManager.activeDownloads.count)

            if downloadManager.activeDownloads.isEmpty {
                EmptyStateCard(
                    icon: "arrow.down.circle",
                    title: "No Active Downloads",
                    subtitle: "Queue up some tracks to download"
                )
            } else {
                VStack(spacing: deck ? 0 : 12) {
                    ForEach(downloadManager.activeDownloads) { task in
                        ActiveDownloadCard(task: task)
                    }
                }
            }
        }
    }

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: deck ? 8 : 16) {
            SectionHeader(title: "Completed", icon: "checkmark.circle", count: downloadManager.completedDownloads.count)

            if downloadManager.completedDownloads.isEmpty {
                EmptyStateCard(
                    icon: "checkmark.circle",
                    title: "No Completed Downloads",
                    subtitle: "Completed downloads appear here"
                )
            } else {
                VStack(spacing: deck ? 0 : 12) {
                    ForEach(downloadManager.completedDownloads) { task in
                        CompletedDownloadCard(task: task)
                    }
                }
            }
        }
    }
}

// MARK: - Supporting Views

struct StatBadge: View {
    let icon: String
    let value: String
    let label: String
    var lamp: DeckLampState = .idle
    var lampColor: Color = DeckSignal.power

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck { deckBody } else { legacyBody }
    }

    /// Deck: a readout on an anodised panel — the number, what it
    /// counts engraved under it, and a lamp that lights when it matters.
    private var deckBody: some View {
        VStack(spacing: 6) {
            HStack {
                Spacer()
                DeckLamp(color: lampColor, state: lamp, size: 5)
            }
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(TurntableTokens.cream)
            Text(label.uppercased())
                .font(DeckType.engraved)
                .tracking(DeckType.engravedTracking)
                .foregroundColor(TurntableTokens.aluminium.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .deckPanel()
        .accessibilityElement(children: .combine)
    }

    private var legacyBody: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundColor(Theme.cyberCyan)

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(.white)

            Text(label.uppercased())
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.cyberDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Theme.cyberSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.cyberCyan.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(12)
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String
    var count: Int?

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck { deckBody } else { legacyBody }
    }

    private var deckBody: some View {
        DeckLedge(title: title, count: count)
    }

    private var legacyBody: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(Theme.cyberCyan)

            Text(title.uppercased())
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.cyberCyan)

            Spacer()
        }
    }
}

struct EmptyStateCard: View {
    let icon: String
    let title: String
    let subtitle: String

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck { deckBody } else { legacyBody }
    }

    /// Deck: two quiet lines under the ledge, nothing in a box.
    private var deckBody: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(DeckType.title)
                .foregroundColor(TurntableTokens.cream)
            Text(subtitle)
                .font(DeckType.subtitle)
                .foregroundColor(TurntableTokens.cream.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .accessibilityElement(children: .combine)
    }

    private var legacyBody: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(Theme.cyberDim)

            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(Theme.cyberDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Theme.cyberSurface)
        .cornerRadius(12)
    }
}

struct ActiveDownloadCard: View {
    let task: DownloadTask
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var showCancelAlert = false

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck { deckBody } else { legacyBody }
    }

    /// Deck: the record's sleeve and name, its percentage in small
    /// print, a metal cancel button, and a progress channel under it
    /// that fills amber. A failure lights the attention lamp instead.
    private var deckBody: some View {
        VStack(spacing: 0) {
            DeckTrackRow(
                title: task.track.title,
                subtitle: task.status.description,
                artworkURL: task.track.artworkURL,
                smallPrint: "\(Int(task.progress * 100))%"
            ) {
                DeckMetalButton(symbol: "xmark", size: 28) {
                    showCancelAlert = true
                }
                .accessibilityLabel("Cancel download")
                .accessibilityHint("Asks before stopping this download")
            }

            GeometryReader { geometry in
                Capsule()
                    .fill(DeckSignal.power)
                    .frame(width: max(4, geometry.size.width * CGFloat(task.progress)))
                    .animation(.linear(duration: 0.3), value: task.progress)
            }
            .frame(height: 4)
            .deckWell(Capsule())
            .padding(.bottom, 10)
            .accessibilityHidden(true)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(TurntableTokens.cream.opacity(0.08)).frame(height: 1)
        }
        .alert("Cancel Download?", isPresented: $showCancelAlert) {
            Button("Cancel Download", role: .destructive) {
                HapticManager.medium()
                downloadManager.cancelDownload(id: task.id)
            }
            Button("Keep Downloading", role: .cancel) { }
        } message: {
            Text("This will stop the current download.")
        }
    }

    private var legacyBody: some View {
        HStack(spacing: 12) {
            // Thumbnail placeholder
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.cyberSurface)
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 24))
                        .foregroundColor(Theme.cyberDim)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.cyberCyan.opacity(0.3), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(task.track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(task.track.displayArtist)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.cyberDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                HStack(spacing: 8) {
                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Theme.cyberDim.opacity(0.3))
                                .frame(height: 4)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(progressColor)
                                .frame(width: geometry.size.width * CGFloat(task.progress), height: 4)
                                .animation(.linear(duration: 0.3), value: task.progress)
                        }
                    }
                    .frame(height: 4)

                    Text("\(Int(task.progress * 100))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(progressColor)
                        .frame(width: 40, alignment: .trailing)
                }

                Text(task.status.description)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(statusColor)
            }

            Spacer()

            // Cancel button
            Button(action: {
                showCancelAlert = true
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.cyberMagenta.opacity(0.8))
            }
        }
        .padding(12)
        .background(Theme.cyberSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.cyberCyan.opacity(0.2), lineWidth: 1)
        )
        .cornerRadius(12)
        .alert("Cancel Download?", isPresented: $showCancelAlert) {
            Button("Cancel Download", role: .destructive) {
                HapticManager.medium()
                downloadManager.cancelDownload(id: task.id)
            }
            Button("Keep Downloading", role: .cancel) { }
        } message: {
            Text("This will stop the current download.")
        }
    }

    private var progressColor: Color {
        switch task.status {
        case .converting:
            return Theme.cyberCyan
        case .failed:
            return Theme.cyberMagenta
        default:
            return Theme.cyberCyan
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .failed(let _):
            return Theme.cyberMagenta
        case .completed:
            return .green
        case .converting:
            return Theme.cyberCyan
        default:
            return Theme.cyberDim
        }
    }
}

struct CompletedDownloadCard: View {
    let task: DownloadTask
    @StateObject private var downloadManager = DownloadManager.shared

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck { deckBody } else { legacyBody }
    }

    private var isFailed: Bool {
        if case .failed = task.status { return true }
        return false
    }

    /// Deck: a lamp says how it ended (amber lit: saved, yellow lit:
    /// failed). Retry and remove are metal buttons; removing asks
    /// nothing because it only clears a line from the queue.
    private var deckBody: some View {
        DeckTrackRow(
            title: task.track.title,
            subtitle: isFailed ? "Download failed" : task.track.displayArtist,
            artworkURL: task.track.artworkURL,
            smallPrint: task.completionTime.map { timeAgo($0).uppercased() }
        ) {
            DeckLamp(color: isFailed ? DeckSignal.attention : DeckSignal.power, state: .lit)
                .accessibilityLabel(statusIconAccessibilityLabel)
            if isFailed {
                DeckMetalButton(symbol: "arrow.counterclockwise", accent: DeckSignal.attention, size: 28) {
                    HapticManager.light()
                    downloadManager.retryDownload(id: task.id)
                }
                .accessibilityLabel("Retry download")
            }
            DeckMetalButton(symbol: "trash", size: 28) {
                downloadManager.removeCompleted(id: task.id)
            }
            .accessibilityLabel("Remove download")
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(TurntableTokens.cream.opacity(0.08)).frame(height: 1)
        }
    }

    private var legacyBody: some View {
        HStack(spacing: 12) {
            // Status icon
            Image(systemName: statusIcon)
                .font(.system(size: 28))
                .foregroundColor(statusColor)
                .frame(width: 32)
                .accessibilityLabel(statusIconAccessibilityLabel)

            // Thumbnail placeholder
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.cyberSurface)
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.cyberDim)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.track.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    // S13: explicit "FAILED" badge inline with the title
                    // makes the failure state unmistakable at a glance.
                    if case .failed = task.status {
                        Text("FAILED")
                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.cyberMagenta))
                    }
                }

                Text(task.track.displayArtist)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.cyberDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                if let time = task.completionTime {
                    Text(timeAgo(time))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.cyberTextSecondary)
                }
            }

            Spacer()

            // Retry button for failed downloads
            if case .failed = task.status {
                Button(action: {
                    HapticManager.light()
                    downloadManager.retryDownload(id: task.id)
                }) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.cyberCyan)
                }
                // S13: 44pt minimum hit target.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Retry download")
            }

            // Delete button (per-item)
            Button(action: {
                downloadManager.removeCompleted(id: task.id)
            }) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.cyberMagenta.opacity(0.6))
            }
            // S13: 44pt minimum hit target.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Remove download")
        }
        .padding(12)
        .background(Theme.cyberSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
    }

    private var statusIcon: String {
        // S13: failed rows now use `exclamationmark.triangle.fill`
        // instead of `exclamationmark.circle.fill` to make the error
        // state visually unmistakable. The icon is the user's first
        // signal that something went wrong with this download.
        switch task.status {
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        default:
            return "questionmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .completed:
            return .green
        case .failed:
            return Theme.cyberMagenta
        default:
            return Theme.cyberDim
        }
    }

    // S13: a11y label for the status icon. VoiceOver users hear what
    // state the download is in, not the SF Symbol name.
    private var statusIconAccessibilityLabel: String {
        switch task.status {
        case .completed: return "Download completed"
        case .failed: return "Download failed"
        case .pending: return "Download pending"
        case .downloading: return "Downloading"
        case .converting: return "Converting"
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Saved Download Card (Core Data backed)

struct SavedDownloadCard: View {
    let item: DownloadedTrackItem
    let onPlay: () -> Void

    @Environment(\.deckStyle) private var deck

    var body: some View {
        if deck { deckBody } else { legacyBody }
    }

    /// Deck: the same row as everywhere else; the file size is the
    /// small print.
    private var deckBody: some View {
        Button(action: onPlay) {
            DeckTrackRow(
                title: item.title,
                subtitle: item.artist,
                artworkURL: item.thumbnailURL,
                smallPrint: item.fileSizeFormatted.uppercased()
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TurntableTokens.cream.opacity(0.08)).frame(height: 1)
        }
    }

    private var legacyBody: some View {
        HStack(spacing: 12) {
            // Artwork
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.cyberSurface)
                    .frame(width: 52, height: 52)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.cyberCyan.opacity(0.2), lineWidth: 1)
                    )

                if let url = item.thumbnailURL {
                    CachedAsyncImage(url: url) {
                        Image(systemName: "music.note")
                            .font(.system(size: 20))
                            .foregroundColor(Theme.cyberDim)
                    }
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.cyberDim)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(item.artist)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.cyberDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(item.fileSizeFormatted)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.cyberTextSecondary)
            }

            Spacer()

            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.cyberCyan)
            }
        }
        .padding(12)
        .background(Theme.cyberSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.cyberCyan.opacity(0.15), lineWidth: 1)
        )
        .cornerRadius(12)
        .onTapGesture { onPlay() }
    }
}

struct DownloadQueueView_Previews: PreviewProvider {
    static var previews: some View {
        DownloadQueueView()
    }
}
