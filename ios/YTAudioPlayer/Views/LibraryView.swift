//
//  LibraryView.swift
//  YTAudioPlayer
//

import SwiftUI
import Combine

enum LibraryViewMode: String, CaseIterable {
    case grid = "Grid"
    case list = "List"
}

enum LibrarySortOption: String, CaseIterable, Identifiable {
    case recentlyAdded = "Recently Added"
    case title = "Title"
    case artist = "Artist"
    case size = "Size"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .recentlyAdded: return "clock.arrow.circlepath"
        case .title: return "textformat.abc"
        case .artist: return "person"
        case .size: return "externaldrive"
        }
    }
}

struct LibraryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @StateObject private var playerState = PlayerState.shared
    @StateObject private var songMemoryManager = SongMemoryManager.shared
    @ObservedObject var undoService = UndoService.shared
    @State private var viewMode: LibraryViewMode = .grid
    @State private var showStorageInfo = false
    @State private var selectedTracks: Set<String> = []
    @State private var isEditing = false
    @State private var searchQuery = ""

    var body: some View {
        NavigationView {
            ZStack {
                // Cyberpunk background
                Theme.cyberBackground
                    .ignoresSafeArea()

                Group {
                    if viewModel.tracks.isEmpty {
                        emptyView
                    } else {
                        contentView
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isEditing {
                        HStack(spacing: 16) {
                            Button("DONE") {
                                isEditing = false
                                selectedTracks.removeAll()
                            }
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.cyberCyan)

                            if !selectedTracks.isEmpty {
                                Button("DELETE", role: .destructive) {
                                    print("🗑️ Toolbar Delete button tapped. selectedTracks: \(selectedTracks.count)")
                                    viewModel.showDeleteConfirmation = true
                                }
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                            }
                        }
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        if !viewModel.tracks.isEmpty {
                            Button(isEditing ? "\(selectedTracks.count)" : "SELECT") {
                                isEditing.toggle()
                                if !isEditing {
                                    selectedTracks.removeAll()
                                }
                            }
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.cyberCyan)

                            Button {
                                viewMode = viewMode == .grid ? .list : .grid
                            } label: {
                                Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                                    .foregroundColor(Theme.cyberCyan)
                            }

                            Menu {
                                Section("SORT BY") {
                                    ForEach(LibrarySortOption.allCases) { option in
                                        Button {
                                            viewModel.sortOption = option
                                        } label: {
                                            Label(option.rawValue,
                                                  systemImage: viewModel.sortOption == option ? "checkmark" : option.icon)
                                        }
                                    }
                                }

                                Divider()

                                Button {
                                    showStorageInfo = true
                                } label: {
                                    Label("STORAGE INFO", systemImage: "externaldrive")
                                }
                            } label: {
                                Image(systemName: "arrow.up.arrow.down.circle")
                                    .foregroundColor(Theme.cyberCyan)
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showStorageInfo) {
                StorageInfoSheetCyberpunk(
                    totalSize: viewModel.totalSize,
                    trackCount: viewModel.tracks.count,
                    onClearAll: {
                        viewModel.clearLibrary()
                    }
                )
            }
            .alert("DELETE \(selectedTracks.count) TRACKS?", isPresented: $viewModel.showDeleteConfirmation) {
                Button("CANCEL", role: .cancel) {
                    print("🗑️ Delete cancelled")
                }
                Button("DELETE", role: .destructive) {
                    print("🗑️ Alert Delete button tapped. Selected tracks: \(selectedTracks.count)")
                    let ids = Array(selectedTracks)
                    print("🗑️ Track IDs to delete: \(ids)")
                    HapticManager.heavy()
                    let count = ids.count
                    viewModel.deleteTracks(ids)
                    selectedTracks.removeAll()
                    isEditing = false
                    // TODO: True undo requires re-downloading files; showing confirmation toast for now
                    undoService.registerUndo(message: "Deleted \(count) track(s)") {}
                }
            } message: {
                Text("This will permanently remove the selected tracks from your library.")
            }
            .preferredColorScheme(.dark)
        }
        .onAppear {
            viewModel.loadLibrary()
        }
    }

    private var emptyView: some View {
        EmptyStateView(type: .library)
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Library")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 10, x: 0, y: 0)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)

            // Search bar
            searchBar
                .padding(.horizontal)
                .padding(.bottom, 8)

            // Stats bar
            HStack {
                Text("\(viewModel.filteredTracks(searchQuery: searchQuery).count) TRACKS")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)

                Spacer()

                Text(viewModel.totalSizeFormatted.uppercased())
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Content
            if viewMode == .grid {
                gridView
            } else {
                listView
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(Theme.cyberDim)

            TextField("Search library...", text: $searchQuery)
                .font(.system(.body, design: .default))
                .foregroundColor(.white)
                .accentColor(Theme.cyberCyan)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.cyberDim)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.cyberSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.cyberCyan.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 16
            ) {
                ForEach(viewModel.filteredTracks(searchQuery: searchQuery)) { track in
                    GridTrackCell(
                        track: track,
                        isSelected: selectedTracks.contains(track.videoId),
                        isEditing: isEditing,
                        isPlaying: viewModel.isCurrentlyPlaying(track),
                        memoryPreview: songMemoryManager.memory(for: track.track)?.previewText,
                        onTap: {
                            if isEditing {
                                toggleSelection(track)
                            } else {
                                viewModel.playTrack(track)
                            }
                        },
                        onPlay: {
                            viewModel.playTrack(track)
                        },
                        onPlayNext: {
                            HapticManager.light()
                            viewModel.playNextTrack(track)
                        },
                        onAddToQueue: {
                            HapticManager.light()
                            viewModel.addToQueue(track)
                        },
                        onDelete: {
                            HapticManager.medium()
                            let trackName = track.title
                            viewModel.deleteTracks([track.videoId])
                            // TODO: True undo requires re-downloading files; showing confirmation toast for now
                            undoService.registerUndo(message: "Deleted \"\(trackName)\"") {}
                        }
                    )
                }
            }
            .padding(16)
        }
        .refreshable {
            viewModel.loadLibrary()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private var listView: some View {
        List {
            ForEach(viewModel.filteredTracks(searchQuery: searchQuery)) { track in
                    ListTrackRow(
                        track: track,
                        isSelected: selectedTracks.contains(track.videoId),
                        isEditing: isEditing,
                        isPlaying: viewModel.isCurrentlyPlaying(track),
                        memoryPreview: songMemoryManager.memory(for: track.track)?.previewText,
                        onTap: {
                            if isEditing {
                                toggleSelection(track)
                            } else {
                                viewModel.playTrack(track)
                            }
                        },
                        onPlay: {
                            viewModel.playTrack(track)
                        },
                        onPlayNext: {
                            HapticManager.light()
                            viewModel.playNextTrack(track)
                        },
                        onAddToQueue: {
                            HapticManager.light()
                            viewModel.addToQueue(track)
                        },
                        onDelete: {
                            HapticManager.medium()
                            let trackName = track.title
                            viewModel.deleteTracks([track.videoId])
                            // TODO: True undo requires re-downloading files; showing confirmation toast for now
                            undoService.registerUndo(message: "Deleted \"\(trackName)\"") {}
                        }
                    )
            }
        }
        .listStyle(.plain)
        .refreshable {
            viewModel.loadLibrary()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func toggleSelection(_ track: DownloadedTrackItem) {
        let id = track.videoId
        if selectedTracks.contains(id) {
            selectedTracks.remove(id)
            print("🗑️ Deselected: \(track.title)")
        } else {
            selectedTracks.insert(id)
            print("🗑️ Selected: \(track.title)")
        }
        print("🗑️ Total selected: \(selectedTracks.count)")
    }
}

// MARK: - Grid Track Cell
struct GridTrackCell: View {
    let track: DownloadedTrackItem
    let isSelected: Bool
    let isEditing: Bool
    let isPlaying: Bool
    let memoryPreview: String?
    let onTap: () -> Void
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.cyberSurface)

                // Artwork image
                if let url = track.thumbnailURL {
                    CachedAsyncImage(url: url) {
                        Image(systemName: "music.note")
                            .font(.system(size: 40))
                            .foregroundColor(Theme.cyberDim)
                    }
                    .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundColor(Theme.cyberDim)
                }

                // Cyberpunk border
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isPlaying ? Theme.cyberCyan.opacity(0.5) : Theme.cyberCyan.opacity(0.1), lineWidth: 1)

                if memoryPreview != nil {
                    SongMemoryBadge(text: nil)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                // Playing indicator overlay
                if isPlaying {
                    Color.black.opacity(0.3)

                    CyberPlayingBars()
                        .frame(width: 30, height: 30)
                }

                if !isEditing && !isPlaying {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .frame(width: 50, height: 50)
                            .background(Theme.cyberCyan.opacity(0.8))
                            .clipShape(Circle())
                            .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 10, x: 0, y: 0)
                    }
                }

                if isEditing {
                    Circle()
                        .fill(isSelected ? Theme.cyberCyan : Theme.cyberDim.opacity(0.3))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: isSelected ? "checkmark" : "")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Theme.cyberBackground)
                        )
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isPlaying ? Theme.cyberCyan : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(track.artist)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.cyberDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(track.fileSizeFormatted.uppercased())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.cyberDim.opacity(0.7))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button(action: onPlay) {
                Label(isPlaying ? "Now Playing" : "Play", systemImage: "play.fill")
            }

            Button(action: onPlayNext) {
                Label("Play Next", systemImage: "text.badge.plus")
            }

            Button(action: onAddToQueue) {
                Label("Add to Queue", systemImage: "plus")
            }

            Button {
                ShareHelper.shareTrack(
                    title: track.title,
                    artist: track.artist,
                    videoId: track.videoId
                )
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Button {
                ShareHelper.copyTrackInfo(
                    title: track.title,
                    artist: track.artist
                )
            } label: {
                Label("Copy Info", systemImage: "doc.on.doc")
            }

            Button {
                Task {
                    if let card = await ShareCardGenerator.generateCard(for: track.track) {
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

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("Remove from Library", systemImage: "trash")
            }
        }
    }
}

// MARK: - List Track Row
struct ListTrackRow: View {
    let track: DownloadedTrackItem
    let isSelected: Bool
    let isEditing: Bool
    let isPlaying: Bool
    let memoryPreview: String?
    let onTap: () -> Void
    let onPlay: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                Circle()
                    .fill(isSelected ? Theme.cyberCyan : Theme.cyberDim.opacity(0.3))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: isSelected ? "checkmark" : "")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Theme.cyberBackground)
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.cyberSurface)
                        .frame(width: 50, height: 50)

                    if let url = track.thumbnailURL {
                        CachedAsyncImage(url: url) {
                            Image(systemName: "music.note")
                                .foregroundColor(Theme.cyberDim)
                        }
                        .frame(width: 50, height: 50)
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "music.note")
                            .foregroundColor(Theme.cyberDim)
                    }

                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isPlaying ? Theme.cyberCyan.opacity(0.5) : Color.clear, lineWidth: 1)

                    if isPlaying {
                        CyberPlayingBars()
                            .frame(width: 20, height: 20)
                            .padding(4)
                            .background(Theme.cyberBackground.opacity(0.8))
                            .cornerRadius(4)
                    }
                }
                .frame(width: 50, height: 50)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 15, weight: isPlaying ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundColor(isPlaying ? Theme.cyberCyan : .white)

                Text(track.artist)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.cyberDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(track.fileSizeFormatted.uppercased())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.cyberDim.opacity(0.7))

                if let memoryPreview {
                    SongMemoryBadge(text: memoryPreview)
                }
            }

            Spacer()

            if !isEditing {
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "waveform" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundColor(isPlaying ? Theme.cyberCyan : Theme.cyberDim)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(isPlaying ? Theme.cyberCyan.opacity(0.05) : Theme.cyberSurface.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isPlaying ? Theme.cyberCyan.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button(action: onPlay) {
                Label(isPlaying ? "Now Playing" : "Play", systemImage: "play.fill")
            }

            Button(action: onPlayNext) {
                Label("Play Next", systemImage: "text.badge.plus")
            }

            Button(action: onAddToQueue) {
                Label("Add to Queue", systemImage: "plus")
            }

            Button {
                ShareHelper.shareTrack(
                    title: track.title,
                    artist: track.artist,
                    videoId: track.videoId
                )
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Button {
                ShareHelper.copyTrackInfo(
                    title: track.title,
                    artist: track.artist
                )
            } label: {
                Label("Copy Info", systemImage: "doc.on.doc")
            }

            Button {
                Task {
                    if let card = await ShareCardGenerator.generateCard(for: track.track) {
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

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("Remove from Library", systemImage: "trash")
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

// MARK: - Storage Info Sheet Cyberpunk
struct StorageInfoSheetCyberpunk: View {
    let totalSize: Int64
    let trackCount: Int
    let onClearAll: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Theme.cyberBackground
                    .ignoresSafeArea()

                VStack(spacing: 24) {
                    // Header
                    Text("NEURAL_STORAGE")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.top, 24)

                    // Storage ring
                    ZStack {
                        Circle()
                            .stroke(Theme.cyberDim.opacity(0.2), lineWidth: 20)
                            .frame(width: 200, height: 200)

                        Circle()
                            .trim(from: 0, to: min(CGFloat(totalSize) / (500 * 1024 * 1024), 1.0))
                            .stroke(Theme.cyberCyan, style: StrokeStyle(lineWidth: 20, lineCap: .round))
                            .frame(width: 200, height: 200)
                            .rotationEffect(.degrees(-90))
                            .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 10, x: 0, y: 0)

                        VStack {
                            Text(formattedSize(totalSize).uppercased())
                                .font(.system(size: 28, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                            Text("OF 500 MB")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Theme.cyberDim)
                        }
                    }
                    .padding(.top, 16)

                    // Stats
                    VStack(spacing: 16) {
                        StatRowCyberpunk(title: "TRACKS", value: "\(trackCount)")
                        StatRowCyberpunk(title: "AVERAGE", value: trackCount > 0 ? formattedSize(totalSize / Int64(trackCount)) : "0")
                        StatRowCyberpunk(title: "TOTAL", value: formattedSize(totalSize))
                    }
                    .padding(.horizontal)

                    Spacer()

                    VStack(spacing: 12) {
                        Button(action: {
                            onClearAll()
                            dismiss()
                        }) {
                            Text("PURGE_ALL")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.cyberMagenta)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Theme.cyberMagenta.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Theme.cyberMagenta.opacity(0.3), lineWidth: 1)
                                )
                                .cornerRadius(8)
                        }

                        Button(action: { dismiss() }) {
                            Text("CLOSE")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Theme.cyberSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Theme.cyberCyan.opacity(0.3), lineWidth: 1)
                                )
                                .cornerRadius(8)
                        }
                    }
                    .padding()
                }
            }
            .navigationBarHidden(true)
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct StatRowCyberpunk: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Theme.cyberDim)
            Spacer()
            Text(value.uppercased())
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.vertical, 12)
        Divider()
            .background(Theme.cyberCyan.opacity(0.2))
    }
}

struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryView()
    }
}
