//
//  TrashView.swift
//  PeacePlayer
//
//  2026-09-08: v1.9.3 — Settings → Trash view. Lists the
//  tracks that have been moved to `Library/Downloads/.trash/`
//  by the ask-before-cleanup flow and are still recoverable.
//
//  Per row:
//    - Restore: moves the file back to the active downloads
//      directory and clears `trashedAt` on the row.
//    - Delete now: permanently deletes the file + the
//      CoreData row (skips the 7d retention).
//
//  The view is mostly a thin shell over `trashedFiles` from
//  the SmartLibraryManager. It owns no state of its own —
//  the manager is the source of truth for the trash
//  contents.
//

import SwiftUI
import CoreData

struct TrashView: View {
    @ObservedObject var smartLibrary = SmartLibraryManager.shared

    var body: some View {
        ZStack {
            Theme.cyberBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                if smartLibrary.trashedFiles.isEmpty {
                    emptyState
                } else {
                    trashList
                }
            }
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.cyberBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear {
            // Refresh on appear in case the user navigated
            // here from a different state (e.g. fresh app
            // launch). The init() call already populates
            // this, but explicit-refresh is cheap.
            smartLibrary.refreshTrashBytes()
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "trash")
                .font(.system(size: 56))
                .foregroundColor(Theme.cyberDim)
            Text("Trash is empty")
                .font(Typography.title3)
                .foregroundColor(.white)
            Text("Tracks you've cleaned up appear here for 7 days before being permanently deleted.")
                .font(.system(size: 13))
                .foregroundColor(Theme.cyberTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var trashList: some View {
        List {
            Section {
                ForEach(smartLibrary.trashedFiles) { file in
                    trashRow(file: file)
                }
            } header: {
                HStack {
                    Text("Recoverable · \(byteString(smartLibrary.trashBytes))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.cyberMagenta)
                        .textCase(.uppercase)
                    Spacer()
                    Text("Auto-purge in 7d")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.cyberTextSecondary)
                }
            } footer: {
                Text("Files are kept here for 7 days after cleanup so you can recover them. After that they're permanently deleted. Tap Restore to bring a track back to your library, or Delete now to skip the wait.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.cyberTextSecondary)
            }
            .listRowBackground(Theme.cyberSurface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func trashRow(file: TrashedFile) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    // Look up the track metadata for a friendlier
                    // row. videoId is the join key; if the CDTrack
                    // row is gone (e.g. user deleted in Files.app)
                    // we fall back to the raw videoId.
                    let title = trackTitle(for: file.videoId)
                    let artist = trackArtist(for: file.videoId)
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(artist)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.cyberTextSecondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(byteString(file.size))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.cyberTextSecondary)
                        Text("·")
                            .foregroundColor(Theme.cyberTextSecondary)
                        Text("Trashed \(relativeTrashed(file.trashedAt))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.cyberTextSecondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: Spacing.sm) {
                Button {
                    HapticManager.medium()
                    if smartLibrary.restoreFromTrash(videoId: file.videoId) {
                        ErrorHandler.shared.showInfo("Restored \"\(trackTitle(for: file.videoId))\"")
                    } else {
                        ErrorHandler.shared.show(.unknown("Couldn't restore — the file may have been re-downloaded."))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("Restore")
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.cyberCyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .stroke(Theme.cyberCyan.opacity(0.6), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    HapticManager.error()
                    smartLibrary.permanentlyDeleteTrashed(videoId: file.videoId)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Delete now")
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.cyberMagenta)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .stroke(Theme.cyberMagenta.opacity(0.6), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Track lookup helpers

    private func trackTitle(for videoId: String) -> String {
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
        request.predicate = NSPredicate(format: "videoId == %@", videoId)
        request.fetchLimit = 1
        return (try? context.fetch(request).first?.title) ?? videoId
    }

    private func trackArtist(for videoId: String) -> String {
        let context = PersistenceController.shared.viewContext
        let request: NSFetchRequest<CDTrack> = CDTrack.fetchRequest()
        request.predicate = NSPredicate(format: "videoId == %@", videoId)
        request.fetchLimit = 1
        return (try? context.fetch(request).first?.displayArtist) ?? "Unknown"
    }

    // MARK: - Formatting

    private func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func relativeTrashed(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        let days = Int(interval / 86400)
        let hours = Int(interval / 3600)
        let minutes = Int(interval / 60)
        if days > 0 { return "\(days)d ago" }
        if hours > 0 { return "\(hours)h ago" }
        if minutes > 0 { return "\(minutes)m ago" }
        return "just now"
    }
}
