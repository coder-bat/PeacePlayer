//
//  ContentView.swift
//  YTAudioPlayer
//

import SwiftUI

struct ContentView: View {
    @StateObject private var playerState = PlayerState.shared
    @State private var selectedTab = 0
    @State private var showFullPlayer = false
    @State private var showRestorePrompt = false
    
    var body: some View {
        ZStack {
            // Main tab content
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem {
                        Image(systemName: "house.fill")
                        Text("Home")
                    }
                    .tag(0)
                
                DiscoverView()
                    .tabItem {
                        Image(systemName: "safari")
                        Text("Discover")
                    }
                    .tag(1)
                
                PlaylistsView()
                    .tabItem {
                        Image(systemName: "music.note.list")
                        Text("Playlists")
                    }
                    .tag(2)
                
                LibraryView()
                    .tabItem {
                        Image(systemName: "arrow.down.circle")
                        Text("Library")
                    }
                    .tag(3)

                DownloadQueueView()
                    .tabItem {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Downloads")
                    }
                    .tag(4)
            }
            
            // Mini Player overlay at bottom
            VStack {
                Spacer()
                
                if playerState.isNowPlaying {
                    MiniPlayer {
                        showFullPlayer = true
                    }
                    .padding(.bottom, 49) // Tab bar height
                    .transition(.move(edge: .bottom))
                }
            }
            .ignoresSafeArea(.keyboard)
            

            
            // Queue restore overlay
            if showRestorePrompt {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                
                QueueRestorePrompt {
                    showRestorePrompt = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchTab)) { notification in
            if let tab = notification.object as? Int {
                selectedTab = tab
            }
        }
        .fullScreenCover(isPresented: $showFullPlayer) {
            FullPlayer()
        }
        .errorAlert()
        .onAppear {
            // Check if we should show restore prompt
            if QueueRestorer.shared.shouldShowRestorePrompt() {
                showRestorePrompt = true
            }
        }
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
