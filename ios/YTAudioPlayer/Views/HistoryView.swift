//
//  HistoryView.swift
//  YTAudioPlayer
//
//  Play history view with recently played tracks
//

import SwiftUI
import CoreData
import Combine

struct HistoryView: View {
    @StateObject private var viewModel = HistoryViewModel()
    @StateObject private var songMemoryManager = SongMemoryManager.shared
    @ObservedObject var undoService = UndoService.shared
    @State private var selectedTrack: Track?
    @State private var memoryTrack: Track?
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.cyberBackground
                    .ignoresSafeArea()

                Group {
                    if viewModel.historyItems.isEmpty {
                        emptyStateView
                    } else {
                        historyListView
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !viewModel.historyItems.isEmpty {
                        Button {
                            showClearConfirmation = true
                        } label: {
                            Text("Clear")
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundColor(.cyberCyan)
                        }
                    }
                }
            }
            .confirmationDialog(
                "Clear History?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All History", role: .destructive) {
                    HapticManager.medium()
                    let count = viewModel.historyItems.count
                    viewModel.clearHistory()
                    // TODO: True undo requires re-creating CoreData entries; showing confirmation toast for now
                    undoService.registerUndo(message: "Cleared \(count) history item(s)") {}
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all tracks from your play history. This cannot be undone.")
            }
            .onAppear {
                viewModel.loadHistory()
            }
            .sheet(item: $memoryTrack) { track in
                SongMemorySheet(track: track)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 60))
                .foregroundColor(.cyberDim)

            Text("No History Yet")
                .font(.system(.title2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(.white)

            Text("Tracks you play will appear here")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundColor(.cyberDim)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    // MARK: - History List

    private var historyListView: some View {
        List {
            // Header & stats in a single row
            VStack(spacing: 0) {
                headerSection

                // Stats section
                statsSection

                // Section header
                HStack {
                    Text("Recently Played")
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.bold)
                        .textCase(.uppercase)
                        .foregroundColor(.cyberCyan)

                    Spacer()

                    Text("\(viewModel.historyItems.count) tracks")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.cyberDim)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.cyberBackground)

            // History items
            ForEach(viewModel.historyItems) { item in
                HistoryRow(
                    item: item,
                    memoryPreview: songMemoryManager.memory(for: item.track)?.previewText,
                    onTap: {
                        playTrack(item)
                    },
                    onEditMemory: {
                        memoryTrack = item.track
                    },
                    onDelete: {
                        let itemTitle = item.track.title
                        viewModel.deleteHistoryItem(item)
                        // TODO: True undo requires re-creating CoreData entry; showing confirmation toast for now
                        undoService.registerUndo(message: "Removed \"\(itemTitle)\"") {}
                    },
                    onPlayNext: {
                        HapticManager.light()
                        viewModel.addToQueueNext(item)
                    },
                    onAddToQueue: {
                        HapticManager.light()
                        viewModel.addToQueue(item)
                    }
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.cyberBackground)
            }
        }
        .listStyle(.plain)
        .refreshable {
            viewModel.loadHistory()
        }
    }

    private var headerSection: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("History")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 10, x: 0, y: 0)

                    Text("Recently played tracks")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.cyberDim)
                        .textCase(.uppercase)
                }

                Spacer()
            }

            HStack(spacing: 12) {
                HistoryActionButton(
                    title: "Play",
                    icon: "play.fill",
                    color: .cyberCyan
                ) {
                    HapticManager.medium()
                    viewModel.playHistory(shuffle: false)
                }
                .disabled(viewModel.historyItems.isEmpty)

                HistoryActionButton(
                    title: "Shuffle",
                    icon: "shuffle",
                    color: .cyberYellow
                ) {
                    HapticManager.medium()
                    viewModel.playHistory(shuffle: true)
                }
                .disabled(viewModel.historyItems.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        VStack(spacing: 16) {
            HStack(spacing: 20) {
                StatCard(
                    value: viewModel.totalPlaysFormatted,
                    label: "Total Plays",
                    icon: "play.fill"
                )

                StatCard(
                    value: viewModel.listeningTimeFormatted,
                    label: "Listening Time",
                    icon: "clock.fill"
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.md)
                .fill(Color.cyberSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.md)
                        .stroke(Color.cyberCyan.opacity(0.15), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func playTrack(_ item: HistoryItem) {
        PlayerState.shared.play(track: item.track)
    }
}

// MARK: - History Row

struct HistoryRow: View {
    let item: HistoryItem
    let memoryPreview: String?
    let onTap: () -> Void
    let onEditMemory: () -> Void
    let onDelete: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void

    @State private var showingOptions = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Thumbnail
                CachedAsyncImage(url: item.artworkURL) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.cyberSurface)
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundColor(.cyberDim)
                        )
                }
                    .frame(width: 50, height: 50)
                    .cornerRadius(6)

                // Track info
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(.body, design: .default))
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    HStack(spacing: 6) {
                        Text(item.artist)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.cyberDim)

                        Text("•")
                            .font(.caption)
                            .foregroundColor(.cyberDim)

                        Text(item.playedAtFormatted)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.cyberCyan.opacity(0.7))
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                    if let memoryPreview {
                        SongMemoryBadge(text: memoryPreview)
                    }
                }

                Spacer()

                // Progress indicator if partially played
                if item.progress > 0 && item.progress < 0.95 {
                    ZStack {
                        Circle()
                            .stroke(Color.cyberSurface, lineWidth: 2)
                            .frame(width: 20, height: 20)

                        Circle()
                            .trim(from: 0, to: CGFloat(item.progress))
                            .stroke(Color.cyberCyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 20, height: 20)
                            .rotationEffect(.degrees(-90))
                    }
                }

                // More options
                Button {
                    showingOptions = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.cyberDim)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.cyberBackground)
        }
        .buttonStyle(.plain)
        .confirmationDialog("", isPresented: $showingOptions, titleVisibility: .hidden) {
            Button(memoryPreview == nil ? "Add Memory" : "Edit Memory") {
                HapticManager.light()
                onEditMemory()
            }
            Button("Remove from History", role: .destructive) {
                HapticManager.medium()
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        }
        .contextMenu {
            Button(action: onTap) {
                Label("Play Now", systemImage: "play.fill")
            }

            Button(action: onPlayNext) {
                Label("Play Next", systemImage: "text.badge.plus")
            }

            Button(action: onAddToQueue) {
                Label("Add to Queue", systemImage: "plus")
            }

            Button(action: onEditMemory) {
                Label(memoryPreview == nil ? "Add Memory" : "Edit Memory",
                      systemImage: memoryPreview == nil ? "square.and.pencil" : "sparkles.rectangle.stack.fill")
            }

            Button {
                ShareHelper.shareTrack(
                    title: item.title,
                    artist: item.artist,
                    videoId: item.track.videoId
                )
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Button {
                ShareHelper.copyTrackInfo(
                    title: item.title,
                    artist: item.artist
                )
            } label: {
                Label("Copy Info", systemImage: "doc.on.doc")
            }

            Button {
                Task {
                    if let card = await ShareCardGenerator.generateCard(for: item.track) {
                        let activityVC = UIActivityViewController(activityItems: [card], applicationActivities: nil)
                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let rootVC = windowScene.windows.first?.rootViewController {
                            if let popover = activityVC.popoverPresentationController {
                                popover.sourceView = rootVC.view
                                popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
                                popover.permittedArrowDirections = []
                            }
                            rootVC.present(activityVC, animated: true)
                        }
                    }
                }
            } label: {
                Label("Share Card", systemImage: "rectangle.on.rectangle")
            }

            Button {
                NotificationCenter.default.post(name: .startSongRadio, object: item.track)
                HapticManager.light()
            } label: {
                Label("Start Radio", systemImage: "antenna.radiowaves.left.and.right")
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("Remove from History", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label("Remove", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button(action: onPlayNext) {
                Label("Next", systemImage: "text.badge.plus")
            }
            .tint(Theme.cyberMagenta)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(.cyberCyan)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(.title2, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                Text(label.uppercased())
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundColor(.cyberDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .fill(Color.cyberBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .stroke(Color.cyberCyan.opacity(0.1), lineWidth: 1)
        )
    }
}

struct HistoryActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))

                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .textCase(.uppercase)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.md)
                    .fill(color.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.md)
                            .stroke(color.opacity(0.35), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - View Model

class HistoryViewModel: ObservableObject {
    @Published var historyItems: [HistoryItem] = []
    @Published var totalPlays: Int = 0
    @Published var listeningTime: TimeInterval = 0

    private let persistence = PersistenceController.shared
    private var cancellables = Set<AnyCancellable>()

    var totalPlaysFormatted: String {
        if totalPlays >= 1000 {
            return String(format: "%.1fk", Double(totalPlays) / 1000)
        }
        return "\(totalPlays)"
    }

    var listeningTimeFormatted: String {
        let hours = Int(listeningTime / 3600)
        let minutes = Int((listeningTime.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    func loadHistory() {
        // Load from CDPlayHistory
        let context = persistence.viewContext
        let request: NSFetchRequest<CDPlayHistory> = CDPlayHistory.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \CDPlayHistory.playedAt, ascending: false)]
        request.fetchLimit = 100

        do {
            let results = try context.fetch(request)
            historyItems = results.compactMap { HistoryItem(from: $0) }
        } catch {
            print("❌ Error loading history: \(error)")
            historyItems = []
        }

        // Load stats from CDUserStats
        loadStats()
    }

    private func loadStats() {
        let context = persistence.viewContext
        let request: NSFetchRequest<CDUserStats> = CDUserStats.fetchRequest()

        do {
            if let stats = try context.fetch(request).first {
                totalPlays = Int(stats.tracksPlayedCount)
                listeningTime = stats.totalListeningSeconds
            }
        } catch {
            print("❌ Error loading stats: \(error)")
        }
    }

    func deleteHistoryItem(_ item: HistoryItem) {
        let context = persistence.newBackgroundContext()

        context.perform {
            let request: NSFetchRequest<CDPlayHistory> = CDPlayHistory.fetchRequest()
            request.predicate = NSPredicate(format: "playedAt == %@", item.playedAt as NSDate)

            do {
                if let historyEntry = try context.fetch(request).first {
                    context.delete(historyEntry)
                    try context.save()

                    DispatchQueue.main.async {
                        self.loadHistory()
                    }
                }
            } catch {
                print("❌ Error deleting history item: \(error)")
            }
        }
    }

    func addToQueueNext(_ item: HistoryItem) {
        let track = item.track
        let localURL = AudioFileManager.shared.localFileURL(for: track.videoId)
        if FileManager.default.fileExists(atPath: localURL.path) {
            let queueItem = QueueItem(track: track, streamUrl: localURL.absoluteString, source: .local(path: localURL.path))
            PlayerState.shared.addToQueueNext(queueItem)
        } else {
            APIService.shared.getStreamUrl(videoId: track.videoId)
                .sink(receiveCompletion: { _ in }, receiveValue: { streamInfo in
                    let queueItem = QueueItem(track: track, streamUrl: streamInfo.streamUrl, source: .stream)
                    PlayerState.shared.addToQueueNext(queueItem)
                })
                .store(in: &cancellables)
        }
    }

    func addToQueue(_ item: HistoryItem) {
        let track = item.track
        let localURL = AudioFileManager.shared.localFileURL(for: track.videoId)
        if FileManager.default.fileExists(atPath: localURL.path) {
            let queueItem = QueueItem(track: track, streamUrl: localURL.absoluteString, source: .local(path: localURL.path))
            PlayerState.shared.addToQueue(queueItem)
        } else {
            APIService.shared.getStreamUrl(videoId: track.videoId)
                .sink(receiveCompletion: { _ in }, receiveValue: { streamInfo in
                    let queueItem = QueueItem(track: track, streamUrl: streamInfo.streamUrl, source: .stream)
                    PlayerState.shared.addToQueue(queueItem)
                })
                .store(in: &cancellables)
        }
    }

    func clearHistory() {
        let context = persistence.newBackgroundContext()

        context.perform {
            let request: NSFetchRequest<NSFetchRequestResult> = CDPlayHistory.fetchRequest()
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
            deleteRequest.resultType = .resultTypeObjectIDs

            do {
                let result = try context.execute(deleteRequest) as? NSBatchDeleteResult
                if let objectIDs = result?.result as? [NSManagedObjectID] {
                    let changes = [NSDeletedObjectsKey: objectIDs]
                    NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
                }
                try context.save()

                DispatchQueue.main.async {
                    self.historyItems = []
                    DataManager.shared.clearRecentlyPlayed()
                }
            } catch {
                print("❌ Error clearing history: \(error)")
            }
        }
    }

    func playHistory(shuffle: Bool) {
        let orderedTracks = historyItems.map(\.track)
        let tracksToPlay = Array((shuffle ? orderedTracks.shuffled() : orderedTracks).prefix(20))
        guard !tracksToPlay.isEmpty else { return }

        var streamInfos: [(track: Track, streamUrl: String)] = []
        let streamInfoLock = NSLock()
        let group = DispatchGroup()

        for track in tracksToPlay {
            group.enter()
            APIService.shared.getStreamUrl(videoId: track.videoId)
                .sink(receiveCompletion: { _ in
                    group.leave()
                }, receiveValue: { streamInfo in
                    streamInfoLock.lock()
                    streamInfos.append((track, streamInfo.streamUrl))
                    streamInfoLock.unlock()
                })
                .store(in: &cancellables)
        }

        group.notify(queue: .main) {
            let orderedInfos = tracksToPlay.compactMap { track in
                streamInfos.first { $0.track.videoId == track.videoId }
            }

            guard !orderedInfos.isEmpty else { return }

            let playerState = PlayerState.shared
            playerState.queue.removeAll()

            for info in orderedInfos {
                let item = QueueItem(
                    track: info.track,
                    streamUrl: info.streamUrl,
                    source: .stream
                )
                playerState.addToQueue(item)
            }

            if !playerState.queue.isEmpty {
                playerState.playQueue(at: 0)
                playerState.showFullPlayer = true
                HapticManager.medium()
            }
        }
    }
}

// MARK: - History Item Model

struct HistoryItem: Identifiable {
    let id: String
    let track: Track
    let title: String
    let artist: String
    let artworkURL: URL?
    let playedAt: Date
    let progress: Double
    let completed: Bool

    init?(from cdHistory: CDPlayHistory) {
        guard let track = cdHistory.track else { return nil }

        self.id = "\(track.videoId)_\(cdHistory.playedAt.timeIntervalSince1970)"
        self.track = track.toTrack
        self.title = track.title
        self.artist = track.displayArtist
        self.artworkURL = track.artworkURL
        self.playedAt = cdHistory.playedAt
        self.progress = cdHistory.progress
        self.completed = cdHistory.completed
    }

    var playedAtFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: playedAt, relativeTo: Date())
    }
}
