//
//  MainContainerView.swift
//  YTAudioPlayer
//
//  Main container with custom tab bar and mini player
//

import SwiftUI

struct MainContainerView: View {
    @StateObject private var playerState = PlayerState.shared
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var selectedTab: Tab = .discover
    @State private var showFullPlayer: Bool = false
    
    enum Tab: String, CaseIterable {
        case discover = "Discover"
        case library = "Library"
        case downloads = "Downloads"
        
        var icon: String {
            switch self {
            case .discover: return "compass"
            case .library: return "music.note.list"
            case .downloads: return "arrow.down.circle"
            }
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            DiscoverView()
                .tabItem {
                    Image(systemName: Tab.discover.icon)
                    Text(Tab.discover.rawValue)
                }
                .tag(Tab.discover)
            
            LibraryView()
                .tabItem {
                    Image(systemName: Tab.library.icon)
                    Text(Tab.library.rawValue)
                }
                .tag(Tab.library)
            
            DownloadQueueView()
                .tabItem {
                    Image(systemName: Tab.downloads.icon)
                    Text(Tab.downloads.rawValue)
                }
                .tag(Tab.downloads)
                .badge(downloadManager.activeDownloads.count)
        }
        .overlay(alignment: .bottom) {
            // Mini Player above tab bar
            if playerState.isNowPlaying {
                MiniPlayer(onExpand: {
                    showFullPlayer = true
                })
                .padding(.bottom, 49) // Height of tab bar
                .transition(.move(edge: .bottom))
            }
        }
        .fullScreenCover(isPresented: $showFullPlayer) {
            FullPlayer(isPresented: $showFullPlayer)
        }
    }
}

// MARK: - Preview
struct MainContainerView_Previews: PreviewProvider {
    static var previews: some View {
        MainContainerView()
    }
}
