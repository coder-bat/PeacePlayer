//
//  SleepTimerView.swift
//  YTAudioPlayer
//
//  Sleep timer with presets and custom duration
//

import SwiftUI

class SleepTimer: ObservableObject {
    static let shared = SleepTimer()
    
    @Published var isActive = false
    @Published var remainingTime: TimeInterval = 0
    @Published var selectedMinutes: Int = 30
    
    private var timer: Timer?
    private var endTime: Date?
    
    private init() {}
    
    let presets = [5, 15, 30, 45, 60]
    
    func start(minutes: Int) {
        selectedMinutes = minutes
        endTime = Date().addingTimeInterval(TimeInterval(minutes * 60))
        isActive = true
        
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateRemainingTime()
        }
        
        HapticManager.success()
    }
    
    func startEndOfTrack() {
        // Will stop at end of current track
        isActive = true
        selectedMinutes = 0
        HapticManager.success()
    }
    
    func cancel() {
        timer?.invalidate()
        timer = nil
        isActive = false
        remainingTime = 0
        endTime = nil
        HapticManager.light()
    }
    
    private func updateRemainingTime() {
        guard let endTime = endTime else { return }
        remainingTime = endTime.timeIntervalSince(Date())
        
        if remainingTime <= 0 {
            // Time's up - stop playback
            PlayerState.shared.pause()
            cancel()
        }
    }
    
    var formattedRemainingTime: String {
        let minutes = Int(remainingTime) / 60
        let seconds = Int(remainingTime) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct SleepTimerView: View {
    @StateObject private var timer = SleepTimer.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Theme.cyberBackground.ignoresSafeArea()

                VStack(spacing: 32) {
                    // Icon
                    Image(systemName: "moon.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.cyberCyan)
                        .shadow(color: Color.cyberCyan.opacity(0.6), radius: 12)
                        .padding(.top, 20)

                    if timer.isActive {
                        activeTimerView
                    } else {
                        timerSelectionView
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.large)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(.cyberCyan)
                }
            }
        }
    }
    
    private var activeTimerView: some View {
        VStack(spacing: 24) {
            // Countdown circle
            ZStack {
                Circle()
                    .stroke(Color.cyberDim.opacity(0.2), lineWidth: 12)
                    .frame(width: 200, height: 200)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.cyberCyan, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear, value: timer.remainingTime)
                    .shadow(color: Color.cyberCyan.opacity(0.5), radius: 8)

                VStack {
                    Text(timer.selectedMinutes == 0 ? "End of Track" : timer.formattedRemainingTime)
                        .font(.system(size: timer.selectedMinutes == 0 ? 20 : 48, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("until sleep")
                        .font(.subheadline)
                        .foregroundColor(.cyberDim)
                }
            }

            // Cancel button
            Button(action: { timer.cancel() }) {
                Text("Cancel Timer")
                    .font(.headline)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.3), lineWidth: 0.5))
            }
            .padding(.horizontal, 32)
        }
    }
    
    private var timerSelectionView: some View {
        VStack(spacing: 24) {
            Text("Stop playback after")
                .font(.headline)
                .foregroundColor(.cyberDim)

            // Preset buttons
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                ForEach(timer.presets, id: \.self) { minutes in
                    PresetButton(minutes: minutes) {
                        timer.start(minutes: minutes)
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, 16)

            // End of track option
            Button(action: {
                timer.startEndOfTrack()
                dismiss()
            }) {
                HStack {
                    Image(systemName: "music.note")
                    Text("End of Track")
                        .font(.headline)
                }
                .foregroundColor(.cyberCyan)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.cyberCyan.opacity(0.1))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cyberCyan.opacity(0.3), lineWidth: 0.5))
            }
            .padding(.horizontal, 32)
        }
    }
    
    private var progress: CGFloat {
        guard timer.selectedMinutes > 0 else { return 1 }
        let total = TimeInterval(timer.selectedMinutes * 60)
        let remaining = max(timer.remainingTime, 0)
        // Starts at 1.0 (full ring) and shrinks to 0.0 as time depletes
        return CGFloat(remaining / total)
    }
}

struct PresetButton: View {
    let minutes: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text("\(minutes)")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                Text("min")
                    .font(.caption)
                    .foregroundColor(.cyberDim)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(Color.cyberSurface)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.cyberDim.opacity(0.3), lineWidth: 0.5)
            )
        }
    }
}

struct SleepTimerView_Previews: PreviewProvider {
    static var previews: some View {
        SleepTimerView()
    }
}
