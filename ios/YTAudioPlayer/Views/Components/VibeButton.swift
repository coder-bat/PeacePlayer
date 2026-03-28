//
//  VibeButton.swift
//  YTAudioPlayer
//
//  Context-aware floating action button
//

import SwiftUI
import Combine

struct VibeButton: View {
    @StateObject private var playerState = PlayerState.shared
    @State private var isExpanded = false
    @State private var isLoading = false
    @State private var currentVibe: VibeSuggestion?
    @State private var showVibePicker = false
    @StateObject private var cancellableHolder = CancellableHolder()
    
    var body: some View {
        ZStack {
            // Expanded menu
            if isExpanded {
                VibeMenu(
                    vibes: currentVibe != nil ? [currentVibe!] + defaultVibes : defaultVibes,
                    onSelect: { vibe in
                        playVibe(vibe)
                        withAnimation(.spring()) {
                            isExpanded = false
                        }
                    },
                    onClose: {
                        withAnimation(.spring()) {
                            isExpanded = false
                        }
                    }
                )
                .transition(.scale.combined(with: .opacity))
            }
            
            // Main button
            Button(action: {
                HapticManager.medium()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    isExpanded.toggle()
                }
            }) {
                ZStack {
                    // Pulse animation when collapsed
                    if !isExpanded {
                        Circle()
                            .fill(currentVibe?.color ?? .accentColor)
                            .opacity(0.3)
                            .scaleEffect(1.3)
                            .animation(
                                Animation.easeInOut(duration: 1.5)
                                    .repeatForever(autoreverses: true),
                                value: isExpanded
                            )
                    }
                    
                    Circle()
                        .fill(currentVibe?.color ?? .accentColor)
                        .shadow(color: (currentVibe?.color ?? .accentColor).opacity(0.4), radius: 10, x: 0, y: 4)
                    
                    VStack(spacing: 2) {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: isExpanded ? "xmark" : (currentVibe?.icon ?? "sparkles"))
                                .font(.system(size: isExpanded ? 20 : 24, weight: .semibold))
                            
                            if !isExpanded {
                                Text("VIBE")
                                    .font(.system(size: 8, weight: .bold))
                            }
                        }
                    }
                    .foregroundColor(.white)
                }
                .frame(width: isExpanded ? 50 : 60, height: isExpanded ? 50 : 60)
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            updateCurrentVibe()
        }
        .sheet(isPresented: $showVibePicker) {
            VibePickerSheet()
        }
    }
    
    private func updateCurrentVibe() {
        currentVibe = getContextualVibe()
    }
    
    private func playVibe(_ vibe: VibeSuggestion) {
        guard !isLoading else { return }
        isLoading = true
        
        // Cancel any in-flight requests
        cancellableHolder.cancellables.removeAll()
        
        let query = vibe.searchQuery
        APIService.shared.search(query: query, limit: 10)
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion {
                    isLoading = false
                    ErrorHandler.shared.handleAPIError(error)
                }
            }, receiveValue: { tracks in
                guard let first = tracks.first else {
                    isLoading = false
                    return
                }
                
                APIService.shared.getStreamUrl(videoId: first.videoId)
                    .sink(receiveCompletion: { completion in
                        isLoading = false
                        if case .failure(let error) = completion {
                            ErrorHandler.shared.handleAPIError(error)
                        }
                    }, receiveValue: { streamInfo in
                        let item = QueueItem(
                            track: first,
                            streamUrl: streamInfo.streamUrl,
                            source: .stream
                        )
                        playerState.play(item: item)
                        HapticManager.success()
                        
                        // Add rest to queue
                        for track in tracks.dropFirst() {
                            APIService.shared.getStreamUrl(videoId: track.videoId)
                                .sink(receiveCompletion: { _ in }, receiveValue: { streamInfo in
                                    let queueItem = QueueItem(
                                        track: track,
                                        streamUrl: streamInfo.streamUrl,
                                        source: .stream
                                    )
                                    playerState.addToQueue(queueItem)
                                })
                                .store(in: &cancellableHolder.cancellables)
                        }
                    })
                    .store(in: &cancellableHolder.cancellables)
            })
            .store(in: &cancellableHolder.cancellables)
    }
    
    private func getContextualVibe() -> VibeSuggestion {
        let hour = Calendar.current.component(.hour, from: Date())
        let weekday = Calendar.current.component(.weekday, from: Date())
        let isWeekend = weekday == 1 || weekday == 7
        
        // Morning: 6-11
        if hour >= 6 && hour < 11 {
            return VibeSuggestion(
                icon: "sun.max.fill",
                title: "Good Morning",
                subtitle: "Start your day",
                color: .orange,
                searchQuery: "morning energy upbeat"
            )
        }
        
        // Work hours: 11-17 on weekdays
        if !isWeekend && hour >= 11 && hour < 17 {
            return VibeSuggestion(
                icon: "briefcase.fill",
                title: "Focus Mode",
                subtitle: "Deep work flow",
                color: .blue,
                searchQuery: "focus concentration instrumental"
            )
        }
        
        // Evening: 17-22
        if hour >= 17 && hour < 22 {
            return VibeSuggestion(
                icon: "moon.stars.fill",
                title: "Evening Chill",
                subtitle: "Wind down",
                color: .indigo,
                searchQuery: "chill evening relax"
            )
        }
        
        // Late night: 22-6
        return VibeSuggestion(
            icon: "moon.fill",
            title: "Late Night",
            subtitle: "Sleep & dream",
            color: .purple,
            searchQuery: "sleep ambient calm"
        )
    }
    
    private var defaultVibes: [VibeSuggestion] {
        [
            VibeSuggestion(
                icon: "flame.fill",
                title: "Workout",
                subtitle: "High energy",
                color: .red,
                searchQuery: "workout gym pump up"
            ),
            VibeSuggestion(
                icon: "heart.fill",
                title: "Feel Good",
                subtitle: "Happy vibes",
                color: .pink,
                searchQuery: "happy feel good pop"
            ),
            VibeSuggestion(
                icon: "cloud.rain.fill",
                title: "Rainy Day",
                subtitle: "Cozy & calm",
                color: Theme.tertiaryText,
                searchQuery: "rainy day lo-fi acoustic"
            )
        ]
    }
}

// MARK: - Vibe Menu
struct VibeMenu: View {
    let vibes: [VibeSuggestion]
    let onSelect: (VibeSuggestion) -> Void
    let onClose: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            ForEach(vibes) { vibe in
                VibeMenuItem(vibe: vibe, onTap: {
                    onSelect(vibe)
                })
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
        )
    }
}

struct VibeMenuItem: View {
    let vibe: VibeSuggestion
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: vibe.icon)
                    .font(.system(size: 20))
                    .foregroundColor(vibe.color)
                    .frame(width: 40, height: 40)
                    .background(vibe.color.opacity(0.15))
                    .cornerRadius(10)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(vibe.title)
                        .font(.system(size: 16, weight: .semibold))
                    
                    Text(vibe.subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "play.fill")
                    .foregroundColor(vibe.color)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Vibe Picker Sheet
struct VibePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    let allVibes: [VibeSuggestion] = [
        VibeSuggestion(icon: "sun.max.fill", title: "Morning", subtitle: "Start your day", color: .orange, searchQuery: "morning"),
        VibeSuggestion(icon: "briefcase.fill", title: "Focus", subtitle: "Work & study", color: .blue, searchQuery: "focus"),
        VibeSuggestion(icon: "flame.fill", title: "Workout", subtitle: "High energy", color: .red, searchQuery: "workout"),
        VibeSuggestion(icon: "moon.stars.fill", title: "Evening", subtitle: "Wind down", color: .indigo, searchQuery: "chill"),
        VibeSuggestion(icon: "moon.fill", title: "Sleep", subtitle: "Rest easy", color: .purple, searchQuery: "sleep"),
        VibeSuggestion(icon: "heart.fill", title: "Feel Good", subtitle: "Happy vibes", color: .pink, searchQuery: "happy"),
        VibeSuggestion(icon: "cloud.rain.fill", title: "Rainy Day", subtitle: "Cozy & calm", color: Theme.tertiaryText, searchQuery: "lofi"),
        VibeSuggestion(icon: "party.popper.fill", title: "Party", subtitle: "Let's celebrate", color: .yellow, searchQuery: "party")
    ]
    
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 16) {
                    ForEach(allVibes) { vibe in
                        VibeGridItem(vibe: vibe)
                    }
                }
                .padding()
            }
            .navigationTitle("Choose Your Vibe")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct VibeGridItem: View {
    let vibe: VibeSuggestion
    
    var body: some View {
        Button(action: {
            // Play vibe
        }) {
            VStack(spacing: 12) {
                Image(systemName: vibe.icon)
                    .font(.system(size: 32))
                    .foregroundColor(vibe.color)
                    .frame(width: 70, height: 70)
                    .background(vibe.color.opacity(0.15))
                    .cornerRadius(20)
                
                VStack(spacing: 2) {
                    Text(vibe.title)
                        .font(.system(size: 16, weight: .semibold))
                    
                    Text(vibe.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Color(.systemGray6))
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Models
struct VibeSuggestion: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let searchQuery: String
}

// MARK: - Preview
struct VibeButton_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VibeButton()
                    .padding()
            }
        }
    }
}


private class CancellableHolder: ObservableObject {
    var cancellables = Set<AnyCancellable>()
}
