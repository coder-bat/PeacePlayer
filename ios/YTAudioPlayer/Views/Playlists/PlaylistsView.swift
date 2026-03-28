//
//  PlaylistsView.swift
//  YTAudioPlayer
//
//  Modern playlist hub with Apple Music-inspired design
//

import SwiftUI

struct PlaylistsView: View {
    @StateObject private var playlistManager = PlaylistManager.shared
    @StateObject private var playerState = PlayerState.shared
    @StateObject private var downloadManager = DownloadManager.shared
    @StateObject private var dataManager = DataManager.shared

    @State private var showCreateSheet = false
    @State private var selectedPlaylist: Playlist?
    @State private var viewMode: ViewMode = .grid
    @State private var scrollOffset: CGFloat = 0

    enum ViewMode {
        case grid, list
    }

    var body: some View {
        NavigationView {
            ZStack {
                // Cyberpunk background
                Theme.cyberBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        // Header
                        HStack {
                            Text("PLAYLISTS")
                                .font(.system(size: 24, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 10, x: 0, y: 0)

                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 16)

                        // Smart Playlists Section
                        if !smartPlaylists.isEmpty {
                            SmartPlaylistsCyberpunk(playlists: smartPlaylists) { playlist in
                                selectedPlaylist = playlist
                            }
                        }

                        // User Playlists Section
                        UserPlaylistsCyberpunk(
                            playlists: userPlaylists,
                            viewMode: viewMode,
                            onSelect: { playlist in
                                selectedPlaylist = playlist
                            },
                            onCreate: {
                                showCreateSheet = true
                            }
                        )
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewMode = viewMode == .grid ? .list : .grid
                            }
                        } label: {
                            Image(systemName: viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(Theme.cyberCyan)
                        }

                        Button {
                            showCreateSheet = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(Theme.cyberCyan)
                        }
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                CreatePlaylistSheet()
            }
            .sheet(item: $selectedPlaylist) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .preferredColorScheme(.dark)
        }
    }

    private var smartPlaylists: [Playlist] {
        playlistManager.playlists.filter { $0.isSmart }
    }

    private var userPlaylists: [Playlist] {
        playlistManager.playlists
            .filter { !$0.isSmart }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }
}

// MARK: - Smart Playlists Cyberpunk

struct SmartPlaylistsCyberpunk: View {
    let playlists: [Playlist]
    let onSelect: (Playlist) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NEURAL_PLAYLISTS")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.cyberCyan)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(playlists) { playlist in
                        SmartPlaylistCardCyberpunk(playlist: playlist) {
                            onSelect(playlist)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Smart Playlist Card Cyberpunk

struct SmartPlaylistCardCyberpunk: View {
    let playlist: Playlist
    let onTap: () -> Void

    private var accentColor: Color {
        guard let hex = playlist.smartCriteria?.type.color else { return Theme.cyberCyan }
        return Color(hex: hex) ?? Theme.cyberCyan
    }

    private var icon: String {
        playlist.smartCriteria?.type.icon ?? "music.note"
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Cyberpunk card background
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.cyberSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(accentColor.opacity(0.5), lineWidth: 1)
                    )
                    .frame(width: 170, height: 200)

                // Glow effect
                RoundedRectangle(cornerRadius: 16)
                    .fill(accentColor.opacity(0.1))
                    .frame(width: 170, height: 200)
                    .blur(radius: 20)

                // Centered icon with circle around it
                ZStack {
                    Circle()
                        .stroke(accentColor.opacity(0.3), lineWidth: 1)
                        .frame(width: 80, height: 80)

                    Circle()
                        .fill(accentColor.opacity(0.08))
                        .frame(width: 80, height: 80)

                    Image(systemName: icon)
                        .font(.system(size: 36, weight: .light))
                        .foregroundColor(accentColor)
                        .shadow(color: accentColor.opacity(0.6), radius: 8, x: 0, y: 0)
                }
                .offset(y: -20)

                // Text at bottom
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text("\(playlist.trackCount) TRACKS")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.cyberDim)
                }
                .padding(16)
                .frame(width: 170, height: 200, alignment: .bottomLeading)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - User Playlists Cyberpunk

struct UserPlaylistsCyberpunk: View {
    let playlists: [Playlist]
    let viewMode: PlaylistsView.ViewMode
    let onSelect: (Playlist) -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Your Playlists")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.cyberCyan)

                Spacer()

                Text("\(playlists.count)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Theme.cyberDim.opacity(0.5), lineWidth: 1)
                    )
            }
            .padding(.horizontal)

            if playlists.isEmpty {
                EmptyPlaylistsCyberpunk(onCreate: onCreate)
            } else if viewMode == .grid {
                // Grid View
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16)
                    ],
                    spacing: 20
                ) {
                    ForEach(playlists) { playlist in
                        UserPlaylistGridCellCyberpunk(playlist: playlist) {
                            onSelect(playlist)
                        }
                    }
                }
                .padding(.horizontal)
            } else {
                // List View
                LazyVStack(spacing: 12) {
                    ForEach(playlists) { playlist in
                        UserPlaylistListRowCyberpunk(playlist: playlist) {
                            onSelect(playlist)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Empty Playlists Cyberpunk

struct EmptyPlaylistsCyberpunk: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Theme.cyberCyan.opacity(0.3), lineWidth: 1)
                    .frame(width: 100, height: 100)

                Image(systemName: "music.note.list")
                    .font(.system(size: 40))
                    .foregroundColor(Theme.cyberCyan)
                    .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 8, x: 0, y: 0)
            }

            VStack(spacing: 4) {
                Text("No Playlists")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                Text("Create playlists to organize your audio")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.cyberDim)
                    .multilineTextAlignment(.center)
            }

            Button(action: onCreate) {
                Label("Create Playlist", systemImage: "plus")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(Theme.cyberBackground)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Theme.cyberCyan)
                    .cornerRadius(8)
                    .shadow(color: Theme.cyberCyan.opacity(0.4), radius: 8, x: 0, y: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - User Playlist Grid Cell Cyberpunk

struct UserPlaylistGridCellCyberpunk: View {
    let playlist: Playlist
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                // Artwork with cyberpunk border
                PlaylistArtworkCyberpunk(trackIds: Array(playlist.trackIds.prefix(4)), thumbnailURL: playlist.thumbnailURL)
                    .frame(height: 160)
                    .clipped()
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Theme.cyberCyan.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(color: Theme.cyberCyan.opacity(0.1), radius: 8, x: 0, y: 4)

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text("\(playlist.trackCount) TRACKS")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.cyberDim)
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - User Playlist List Row Cyberpunk

struct UserPlaylistListRowCyberpunk: View {
    let playlist: Playlist
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                // Mini artwork with cyberpunk border
                PlaylistArtworkMiniCyberpunk(trackIds: Array(playlist.trackIds.prefix(4)), thumbnailURL: playlist.thumbnailURL)
                    .frame(width: 64, height: 64)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.cyberCyan.opacity(0.3), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text("\(playlist.trackCount) TRACKS")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.cyberDim)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.cyberCyan.opacity(0.5))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Theme.cyberSurface)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.cyberCyan.opacity(0.1), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Playlist Artwork Cyberpunk

struct PlaylistArtworkCyberpunk: View {
    let trackIds: [String]
    var thumbnailURL: String? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.cyberSurface)

                if let urlString = thumbnailURL, let url = URL(string: urlString) {
                    CachedAsyncImage(url: url) {
                        artworkFallback
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                } else {
                    artworkFallback
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var artworkFallback: some View {
        if trackIds.isEmpty {
            Image(systemName: "music.note")
                .font(.system(size: 50, weight: .light))
                .foregroundColor(Theme.cyberDim)
        } else if trackIds.count == 1 {
            LinearGradient(
                colors: [Theme.cyberCyan.opacity(0.3), Theme.cyberCyan.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .cornerRadius(12)

            Image(systemName: "music.note")
                .font(.system(size: 50, weight: .light))
                .foregroundColor(Theme.cyberCyan)
                .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 8, x: 0, y: 0)
        } else if trackIds.count < 4 {
            LinearGradient(
                colors: [Theme.cyberMagenta.opacity(0.3), Theme.cyberMagenta.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .cornerRadius(12)

            Image(systemName: "music.note.list")
                .font(.system(size: 50, weight: .light))
                .foregroundColor(Theme.cyberMagenta)
                .shadow(color: Theme.cyberMagenta.opacity(0.5), radius: 8, x: 0, y: 0)
        } else {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(Theme.cyberMagenta.opacity(0.7))
                    Rectangle()
                        .fill(Theme.cyberCyan.opacity(0.7))
                }
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(Theme.cyberYellow.opacity(0.7))
                    Rectangle()
                        .fill(Theme.cyberCyan.opacity(0.4))
                }
            }
            .padding(4)
            .cornerRadius(12)
        }
    }
}

// MARK: - Playlist Artwork Mini Cyberpunk

struct PlaylistArtworkMiniCyberpunk: View {
    let trackIds: [String]
    var thumbnailURL: String? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.cyberSurface)

                if let urlString = thumbnailURL, let url = URL(string: urlString) {
                    CachedAsyncImage(url: url) {
                        miniArtworkFallback
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                } else {
                    miniArtworkFallback
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var miniArtworkFallback: some View {
        if trackIds.isEmpty {
            Image(systemName: "music.note")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(Theme.cyberDim)
        } else if trackIds.count < 4 {
            LinearGradient(
                colors: [Theme.cyberCyan.opacity(0.3), Theme.cyberCyan.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .cornerRadius(8)

            Image(systemName: "music.note")
                .font(.system(size: 28))
                .foregroundColor(Theme.cyberCyan)
        } else {
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    Rectangle().fill(Theme.cyberMagenta.opacity(0.7))
                    Rectangle().fill(Theme.cyberCyan.opacity(0.7))
                }
                HStack(spacing: 2) {
                    Rectangle().fill(Theme.cyberYellow.opacity(0.7))
                    Rectangle().fill(Theme.cyberCyan.opacity(0.4))
                }
            }
            .padding(2)
            .cornerRadius(8)
        }
    }
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Preview

struct PlaylistsView_Previews: PreviewProvider {
    static var previews: some View {
        PlaylistsView()
    }
}
