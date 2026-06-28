//
//  MainContainerView.swift
//  YTAudioPlayer
//
//  Main container with custom tab bar and mini player
//

import SwiftUI

struct MainContainerView: View {
    @StateObject private var playerState = PlayerState.shared
    @State private var selectedTab: Tab = .discover
    @State private var showFullPlayer: Bool = false

    enum Tab: String, CaseIterable {
        case discover = "Discover"
        case library = "Library"

        var icon: String {
            switch self {
            case .discover: return "compass"
            case .library: return "music.note.list"
            }
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            DiscoverView()
                .tabItem {
                    // 2026-06-28: icons-only bottom nav. Text labels
                    // removed so the tab bar reads as a clean icon
                    // strip. The icon name itself is the accessibility
                    // label (iOS reads it via VoiceOver).
                    Image(systemName: Tab.discover.icon)
                        .accessibilityLabel(Text(Tab.discover.rawValue))
                }
                .tag(Tab.discover)

            LibraryView()
                .tabItem {
                    Image(systemName: Tab.library.icon)
                        .accessibilityLabel(Text(Tab.library.rawValue))
                }
                .tag(Tab.library)
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
