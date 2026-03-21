//
//  ContentView.swift
//  YTAudioPlayer
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var playerState = PlayerState.shared
    @State private var selectedTab = 0
    @State private var showFullPlayer = false
    @State private var showRestorePrompt = false
    @Namespace private var playerNamespace

    var body: some View {
        ZStack {
            // Main tab content — MiniPlayer injected via safeAreaInset on each tab
            // so it appears ABOVE the tab bar (not overlapping it)
            TabView(selection: $selectedTab) {
                HomeView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerView }
                    .tabItem {
                        Image(systemName: "house.fill")
                        Text("Home")
                    }
                    .tag(0)

                SearchView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerView }
                    .tabItem {
                        Image(systemName: "magnifyingglass")
                        Text("Search")
                    }
                    .tag(1)

                PlaylistsView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerView }
                    .tabItem {
                        Image(systemName: "music.note.list")
                        Text("Playlists")
                    }
                    .tag(2)

                LibraryView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerView }
                    .tabItem {
                        Image(systemName: "arrow.down.circle")
                        Text("Library")
                    }
                    .tag(3)

                DownloadQueueView()
                    .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerView }
                    .tabItem {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Downloads")
                    }
                    .tag(4)
            }

            // Queue restore overlay
            if showRestorePrompt {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()

                QueueRestorePrompt {
                    showRestorePrompt = false
                }
            }

            // Full player overlay — smooth spring transition
            if showFullPlayer {
                FullPlayer(isPresented: $showFullPlayer)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom),
                        removal: .move(edge: .bottom)
                    ))
                    .zIndex(1)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchTab)) { notification in
            if let tab = notification.object as? Int {
                selectedTab = tab
            }
        }
        .errorAlert()
        .onAppear {
            setupAppearance()
            if QueueRestorer.shared.shouldShowRestorePrompt() {
                showRestorePrompt = true
            }
        }
    }

    // Single MiniPlayer instance injected into each tab's safe area.
    // safeAreaInset on a tab content view places the view ABOVE the tab bar,
    // and automatically scrolls content above it.
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
        // Tab bar
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = .black
        tabAppearance.shadowColor = UIColor(red: 0, green: 0.9, blue: 1, alpha: 0.15)

        let activeColor = UIColor(red: 0, green: 0.9, blue: 1, alpha: 1)
        let inactiveColor = UIColor(red: 0.3, green: 0.3, blue: 0.4, alpha: 1)
        let monoFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)

        let itemAppearance = UITabBarItemAppearance()
        itemAppearance.selected.iconColor = activeColor
        itemAppearance.selected.titleTextAttributes = [.foregroundColor: activeColor, .font: monoFont]
        itemAppearance.normal.iconColor = inactiveColor
        itemAppearance.normal.titleTextAttributes = [.foregroundColor: inactiveColor, .font: monoFont]

        tabAppearance.stackedLayoutAppearance = itemAppearance
        tabAppearance.inlineLayoutAppearance = itemAppearance
        tabAppearance.compactInlineLayoutAppearance = itemAppearance

        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        // Navigation bar — black opaque across all screens
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
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).tintColor = UIColor(red: 0, green: 0.9, blue: 1, alpha: 1)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let switchTab = Notification.Name("switchTab")
}
