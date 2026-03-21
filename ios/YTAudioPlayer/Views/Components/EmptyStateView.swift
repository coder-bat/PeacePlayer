//
//  EmptyStateView.swift
//  YTAudioPlayer
//
//  Empty state illustration with action button
//

import SwiftUI

enum EmptyStateType {
    case search
    case library
    case noResults(query: String)
    case noInternet
    case error(message: String)
    
    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .library: return "music.note.list"
        case .noResults: return "magnifyingglass.circle"
        case .noInternet: return "wifi.slash"
        case .error: return "exclamationmark.triangle"
        }
    }
    
    var title: String {
        switch self {
        case .search: return "Search Music"
        case .library: return "Your Library is Empty"
        case .noResults(let query): return "No results for \"\(query)\""
        case .noInternet: return "No Connection"
        case .error: return "Something Went Wrong"
        }
    }
    
    var message: String {
        switch self {
        case .search:
            return "Search for songs, artists, or albums from YouTube Music"
        case .library:
            return "Download songs to listen offline. Your downloads will appear here."
        case .noResults:
            return "Try a different search term or check your spelling"
        case .noInternet:
            return "Check your internet connection and try again"
        case .error(let message):
            return message
        }
    }
}

struct EmptyStateView: View {
    let type: EmptyStateType
    var action: (() -> Void)?
    var actionTitle: String?
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Icon
            Image(systemName: type.icon)
                .font(.system(size: 80, weight: .light))
                .foregroundColor(Theme.primary.opacity(0.5))
                .frame(width: 120, height: 120)
                .background(
                    Circle()
                        .fill(Theme.primary.opacity(0.1))
                )
            
            // Text
            VStack(spacing: 8) {
                Text(type.title)
                    .font(Typography.title3)
                    .foregroundColor(Theme.primaryText)
                    .multilineTextAlignment(.center)
                
                Text(type.message)
                    .font(Typography.body)
                    .foregroundColor(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            // Action Button
            if let action = action, let title = actionTitle {
                Button(action: action) {
                    Text(title)
                        .font(Typography.bodyBold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(Theme.primary)
                        .cornerRadius(CornerRadius.md)
                }
                .buttonStyle(.pressable)
                .padding(.top, 8)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview
struct EmptyStateView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            EmptyStateView(
                type: .search,
                action: {},
                actionTitle: "Browse Popular"
            )
            
            EmptyStateView(
                type: .library,
                action: {},
                actionTitle: "Search Songs"
            )
            
            EmptyStateView(
                type: .noResults(query: "asdfghjkl")
            )
        }
    }
}
