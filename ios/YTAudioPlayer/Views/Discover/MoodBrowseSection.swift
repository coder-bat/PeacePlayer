//
//  MoodBrowseSection.swift
//  YTAudioPlayer
//
//  Browse music by mood/category
//

import SwiftUI

struct MoodBrowseSection: View {
    let moods: [MoodCategory] = [
        MoodCategory(name: "Chill", icon: "cloud", color: .blue),
        MoodCategory(name: "Energetic", icon: "bolt.fill", color: .yellow),
        MoodCategory(name: "Focus", icon: "brain", color: .purple),
        MoodCategory(name: "Party", icon: "party.popper", color: .pink),
        MoodCategory(name: "Workout", icon: "figure.run", color: .orange),
        MoodCategory(name: "Sleep", icon: "moon.fill", color: .indigo)
    ]
    
    var onMoodSelected: ((MoodCategory) -> Void)?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Text("Browse by Mood")
                .font(.title2.bold())
                .padding(.horizontal)
            
            // Grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ForEach(moods) { mood in
                    MoodCard(mood: mood, onTap: {
                        onMoodSelected?(mood)
                    })
                }
            }
            .padding(.horizontal)
        }
    }
}

struct MoodCard: View {
    let mood: MoodCategory
    var onTap: (() -> Void)?
    @State private var isPressed = false
    
    var body: some View {
        Button(action: {
            HapticManager.medium()
            onTap?()
        }) {
            VStack(spacing: 12) {
                // Icon
                ZStack {
                    Circle()
                        .fill(mood.color.opacity(0.15))
                        .frame(width: 60, height: 60)
                    
                    Image(systemName: mood.icon)
                        .font(.system(size: 28))
                        .foregroundColor(mood.color)
                }
                
                // Name
                Text(mood.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(.systemGray6))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(mood.color.opacity(isPressed ? 0.5 : 0), lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.95 : 1)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
    }
}
