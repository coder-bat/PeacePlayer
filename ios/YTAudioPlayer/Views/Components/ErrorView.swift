//
//  ErrorView.swift
//  YTAudioPlayer
//
//  Comprehensive error states with retry actions
//

import SwiftUI

enum ErrorType {
    case network
    case playback
    case download
    case search
    case server
    case unknown
    
    var icon: String {
        switch self {
        case .network: return "wifi.slash"
        case .playback: return "play.slash"
        case .download: return "arrow.down.circle"
        case .search: return "magnifyingglass.circle"
        case .server: return "server.rack"
        case .unknown: return "exclamationmark.triangle"
        }
    }
    
    var title: String {
        switch self {
        case .network: return "No Connection"
        case .playback: return "Playback Error"
        case .download: return "Download Failed"
        case .search: return "Search Failed"
        case .server: return "Server Error"
        case .unknown: return "Something Went Wrong"
        }
    }
    
    var message: String {
        switch self {
        case .network:
            return "Check your internet connection and try again."
        case .playback:
            return "Unable to play this track. It may be unavailable or removed."
        case .download:
            return "The download couldn't be completed. Please try again."
        case .search:
            return "We couldn't complete your search. Please try again."
        case .server:
            return "Our servers are having issues. Please try again later."
        case .unknown:
            return "An unexpected error occurred. Please try again."
        }
    }
    
    var primaryAction: String {
        switch self {
        case .network, .playback, .download, .search, .server, .unknown:
            return "Try Again"
        }
    }
    
    var secondaryAction: String? {
        switch self {
        case .network:
            return "Settings"
        case .playback:
            return "Skip Track"
        case .download:
            return "Cancel"
        case .search:
            return "Clear Search"
        default:
            return nil
        }
    }
}

struct ErrorView: View {
    let type: ErrorType
    let details: String?
    let onRetry: () -> Void
    let onSecondary: (() -> Void)?
    let onDismiss: (() -> Void)?
    
    init(
        type: ErrorType,
        details: String? = nil,
        onRetry: @escaping () -> Void,
        onSecondary: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.type = type
        self.details = details
        self.onRetry = onRetry
        self.onSecondary = onSecondary
        self.onDismiss = onDismiss
    }
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            // Icon with animation
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 120, height: 120)
                
                Image(systemName: type.icon)
                    .font(.system(size: 50))
                    .foregroundColor(.red)
            }
            
            // Text content
            VStack(spacing: 12) {
                Text(type.title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                
                Text(type.message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                
                if let details = details {
                    Text(details)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.top, 8)
                }
            }
            
            Spacer()
            
            // Action buttons
            VStack(spacing: 12) {
                // Primary action (Retry)
                Button(action: {
                    HapticManager.medium()
                    onRetry()
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text(type.primaryAction)
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .cornerRadius(12)
                }
                
                // Secondary action
                if let secondaryAction = type.secondaryAction, let onSecondary = onSecondary {
                    Button(action: {
                        HapticManager.light()
                        onSecondary()
                    }) {
                        Text(secondaryAction)
                            .font(.headline)
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(12)
                    }
                }
                
                // Dismiss button
                if let onDismiss = onDismiss {
                    Button(action: {
                        HapticManager.light()
                        onDismiss()
                    }) {
                        Text("Dismiss")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
    }
}

// MARK: - Inline Error Row
struct InlineErrorRow: View {
    let message: String
    let onRetry: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)
            
            Spacer()
            
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(.accentColor)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.05))
        .cornerRadius(8)
        .padding(.horizontal)
    }
}

// MARK: - Toast Error
struct ErrorToast: View {
    let message: String
    @Binding var isShowing: Bool
    
    var body: some View {
        VStack {
            Spacer()
            
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                
                Spacer()
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(12)
            .padding(.horizontal, 16)
            .padding(.bottom, 100)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    isShowing = false
                }
            }
        }
    }
}

// MARK: - Preview
struct ErrorView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ErrorView(
                type: .network,
                onRetry: {}
            )
            
            ErrorView(
                type: .playback,
                details: "Track ID: ABC123",
                onRetry: {},
                onSecondary: {},
                onDismiss: {}
            )
        }
    }
}
