//
//  ContentView.swift
//  YTAudioPlayer
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var playerState = PlayerState.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @State private var selectedTab = 0
    @State private var showFullPlayer = false
    @State private var showRestorePrompt = false
    @Namespace private var playerNamespace

    var body: some View {
        ZStack {
            // Tab content — MiniPlayer injected via safeAreaInset on each tab
            // so it appears ABOVE the custom tab bar (not overlapping it).
            // CyberpunkTabBar is injected via safeAreaInset on the TabView itself.
            TabView(selection: $selectedTab) {
                HomeView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerView }
                    .tag(0)

                SearchView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerView }
                    .tag(1)

                PlaylistsView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerView }
                    .tag(2)

                LibraryView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerView }
                    .tag(3)

                DownloadQueueView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerView }
                    .tag(4)
            }
            .modifier(HideNativeTabBar())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                CyberpunkTabBar(selectedTab: $selectedTab)
            }

            // Offline banner
            if !networkMonitor.isConnected {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 12, weight: .bold))
                        Text("Offline — downloaded music still available")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.cyberSurface)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.4), value: networkMonitor.isConnected)
                .zIndex(2)
            }

            // Queue restore overlay
            if showRestorePrompt {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()

                QueueRestorePrompt {
                    showRestorePrompt = false
                }
            }

            // Full player overlay — slides up over everything including the tab bar
            if showFullPlayer {
                FullPlayer(isPresented: $showFullPlayer)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom),
                        removal: .move(edge: .bottom)
                    ))
                    .zIndex(1)
            }

            // Undo toast — above tab bar + MiniPlayer, below sheets
            VStack {
                Spacer()
                UndoToastView()
                    .padding(.bottom, 120) // clears CyberpunkTabBar (~56pt) + MiniPlayer (64pt)
            }
            .zIndex(3)
            .allowsHitTesting(UndoService.shared.currentUndo != nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchTab)) { notification in
            if let tab = notification.object as? Int {
                selectedTab = tab
            }
        }
        .onChange(of: playerState.showQueue) { shouldShow in
            if shouldShow && !showFullPlayer {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    showFullPlayer = true
                }
            }
        }
        .errorAlert()
        .onAppear {
            setupAppearance()
            PlaybackQueueManager.shared.startObservingPlayerStateIfNeeded(playerState: playerState)
            if QueueRestorer.shared.shouldShowRestorePrompt() {
                showRestorePrompt = true
            }
        }
    }

    @ViewBuilder
    private var miniPlayerView: some View {
        if playerState.isNowPlaying && !showFullPlayer {
            MiniPlayer {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    showFullPlayer = true
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .padding(.bottom, 8)
        }
    }

    private func setupAppearance() {
        // Navigation bar — black opaque across all screens
        let activeColor = UIColor(red: 0, green: 0.9, blue: 1, alpha: 1)

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = .black
        navAppearance.shadowColor = .clear
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
        UINavigationBar.appearance().tintColor = activeColor

        // Search bar — dark field matching cyberSurface
        let cyberSurface = UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        UISearchBar.appearance().barTintColor = .black
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).backgroundColor = cyberSurface
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).textColor = .white
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).tintColor = activeColor
    }
}

// MARK: - Hide Native Tab Bar (iOS 15/16 compatible)

/// Hides the native UITabBar so our custom CyberpunkTabBar takes over.
/// On iOS 16+ uses the proper .toolbar API which cleanly removes the safe area contribution.
/// On iOS 15 falls back to UIAppearance (visual hide; safe area may still be present but
/// the CyberpunkTabBar safeAreaInset overrides the layout correctly in practice).
private struct HideNativeTabBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.toolbar(.hidden, for: .tabBar)
        } else {
            content.onAppear {
                UITabBar.appearance().isHidden = true
            }
        }
    }
}

// MARK: - Cyberpunk Tab Bar

struct CyberpunkTabBar: View {
    @Binding var selectedTab: Int

    private struct TabDef {
        let icon: String
        let label: String
        let tag: Int
    }

    private let tabs: [TabDef] = [
        TabDef(icon: "house.fill",                  label: "Home",      tag: 0),
        TabDef(icon: "magnifyingglass",              label: "Search",    tag: 1),
        TabDef(icon: "music.note.list",              label: "Playlists", tag: 2),
        TabDef(icon: "music.note.house.fill",        label: "Library",   tag: 3),
        TabDef(icon: "arrow.down.circle.fill",       label: "Downloads", tag: 4),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.tag) { tab in
                CyberpunkTabItem(
                    icon: tab.icon,
                    label: tab.label,
                    isSelected: selectedTab == tab.tag
                ) {
                    guard selectedTab != tab.tag else { return }
                    HapticManager.light()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                        selectedTab = tab.tag
                    }
                }
            }
        }
        .padding(.top, 6)
        // Glass background that extends behind the home indicator
        .background(
            ZStack {
                // Base blur
                Rectangle()
                    .fill(.ultraThinMaterial)
                // Dark cyberpunk tint over the blur
                Rectangle()
                    .fill(Color.cyberSurface.opacity(0.82))
                // Very subtle cyan top-glow gradient
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color.cyberCyan.opacity(0.05), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 36)
                    Spacer()
                }
            }
            .ignoresSafeArea(edges: .bottom)
        )
        // Glowing top border
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.cyberCyan.opacity(0.45))
                .frame(height: 1)
                .shadow(color: Color.cyberCyan.opacity(0.5), radius: 6, x: 0, y: -3)
        }
    }
}

// MARK: - Cyberpunk Tab Item

struct CyberpunkTabItem: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    // Active selection pill
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.cyberCyan.opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.cyberCyan.opacity(0.22), lineWidth: 1)
                            )
                            .frame(width: 46, height: 30)
                    }

                    // Icon with neon glow when selected
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .cyberCyan : .cyberDim)
                        // Inline GlowModifier (two-shadow recipe from HomeView)
                        .shadow(color: isSelected ? Color.cyberCyan.opacity(0.55) : .clear,
                                radius: 4, x: 0, y: 0)
                        .shadow(color: isSelected ? Color.cyberCyan.opacity(0.30) : .clear,
                                radius: 9, x: 0, y: 0)
                }
                .frame(height: 32)

                // Monospaced uppercase label
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? .cyberCyan : .cyberDim)

                // Active indicator dot
                Circle()
                    .fill(isSelected ? Color.cyberCyan : Color.clear)
                    .frame(width: 3, height: 3)
                    .shadow(color: isSelected ? Color.cyberCyan.opacity(0.8) : .clear,
                            radius: 3, x: 0, y: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isSelected)
    }
}

// MARK: - Previews

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let switchTab = Notification.Name("switchTab")
}
