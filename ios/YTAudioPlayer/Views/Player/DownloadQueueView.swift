//
//  DownloadQueueView.swift
//  YTAudioPlayer
//
//  Download queue view with improved feedback
//

import SwiftUI

struct DownloadQueueView: View {
    @StateObject private var downloadManager = DownloadManager.shared

    var body: some View {
        NavigationView {
            ZStack {
                Theme.cyberBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Stats header
                        statsHeader

                        // Active downloads
                        activeSection

                        // Completed downloads
                        completedSection
                    }
                    .padding()
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !downloadManager.completedDownloads.isEmpty {
                        Button("Clear") {
                            downloadManager.clearCompleted()
                        }
                        .foregroundColor(Theme.cyberCyan)
                    }
                }
            }
        }
    }

    private var statsHeader: some View {
        HStack(spacing: 20) {
            StatBadge(
                icon: "arrow.down.circle.fill",
                value: "\(downloadManager.activeDownloads.count)",
                label: "Active"
            )

            StatBadge(
                icon: "checkmark.circle.fill",
                value: "\(downloadManager.completedDownloads.filter { $0.status == .completed }.count)",
                label: "Done"
            )

            StatBadge(
                icon: "xmark.circle.fill",
                value: "\(downloadManager.completedDownloads.filter { if case .failed = $0.status { return true }; return false }.count)",
                label: "Failed"
            )
        }
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Downloading", icon: "arrow.down.circle")

            if downloadManager.activeDownloads.isEmpty {
                EmptyStateCard(
                    icon: "arrow.down.circle",
                    title: "No Active Downloads",
                    subtitle: "Queue up some tracks to download"
                )
            } else {
                VStack(spacing: 12) {
                    ForEach(downloadManager.activeDownloads) { task in
                        ActiveDownloadCard(task: task)
                    }
                }
            }
        }
    }

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Completed", icon: "checkmark.circle")

            if downloadManager.completedDownloads.isEmpty {
                EmptyStateCard(
                    icon: "checkmark.circle",
                    title: "No Completed Downloads",
                    subtitle: "Completed downloads appear here"
                )
            } else {
                VStack(spacing: 12) {
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

    var body: some View {
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

    var body: some View {
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

    var body: some View {
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

    var body: some View {
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

                Text(task.track.displayArtist)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.cyberDim)
                    .lineLimit(1)

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
                downloadManager.cancelDownload(id: task.id)
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

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            Image(systemName: statusIcon)
                .font(.system(size: 28))
                .foregroundColor(statusColor)
                .frame(width: 32)

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
                Text(task.track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(task.track.displayArtist)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.cyberDim)
                    .lineLimit(1)

                if let time = task.completionTime {
                    Text(timeAgo(time))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.cyberDim.opacity(0.7))
                }
            }

            Spacer()

            // Retry button for failed downloads
            if case .failed = task.status {
                Button(action: {
                    downloadManager.retryDownload(id: task.id)
                }) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(Theme.cyberCyan)
                }
            }

            // Delete button
            Button(action: {
                downloadManager.clearCompleted()
            }) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.cyberMagenta.opacity(0.6))
            }
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
        switch task.status {
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
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

    private func timeAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct DownloadQueueView_Previews: PreviewProvider {
    static var previews: some View {
        DownloadQueueView()
    }
}
