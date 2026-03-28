//
//  TimeCapsuleSheet.swift
//  YTAudioPlayer
//
//  Sheet to "bury" a time capsule: write a note, pick date, seal it.
//

import SwiftUI

struct TimeCapsuleSheet: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var noteText = ""
    @State private var unlockDate = Calendar.current.date(byAdding: .month, value: 1, to: Date())!
    @State private var selectedMood: String? = nil
    @State private var isSealing = false
    @State private var isSealed = false

    private let moods = ["💌", "🥹", "🔥", "🌙", "💔", "🎉", "🧘", "⚡️"]
    private let minDate = Calendar.current.date(byAdding: .weekOfYear, value: 1, to: Date())!
    private let maxDate = Calendar.current.date(byAdding: .year, value: 5, to: Date())!

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                if isSealed {
                    sealedConfirmation
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            headerSection
                            noteSection
                            moodSection
                            dateSection
                            sealButton
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Bury a Capsule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.gray)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(spacing: 14) {
            CachedAsyncImage(url: track.artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.gray.opacity(0.3)
            }
            .frame(width: 60, height: 60)
            .cornerRadius(10)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(track.displayArtist)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer()
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your message to the future")
                .font(.caption)
                .foregroundColor(.cyan)

            TextEditor(text: $noteText)
                .frame(minHeight: 120)
                .padding(12)
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)
                .foregroundColor(.white)
                .overlay(
                    Group {
                        if noteText.isEmpty {
                            Text("Write something your future self will read...")
                                .foregroundColor(.gray.opacity(0.5))
                                .padding(16)
                        }
                    },
                    alignment: .topLeading
                )
        }
    }

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mood")
                .font(.caption)
                .foregroundColor(.cyan)

            HStack(spacing: 12) {
                ForEach(moods, id: \.self) { mood in
                    Text(mood)
                        .font(.title2)
                        .padding(8)
                        .background(
                            selectedMood == mood ? Color.cyan.opacity(0.3) : Color.white.opacity(0.05)
                        )
                        .cornerRadius(8)
                        .onTapGesture { selectedMood = (selectedMood == mood) ? nil : mood }
                }
            }
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unlock date")
                .font(.caption)
                .foregroundColor(.cyan)

            DatePicker(
                "Opens on",
                selection: $unlockDate,
                in: minDate...maxDate,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .tint(.cyan)
            .colorScheme(.dark)

            let days = Calendar.current.dateComponents([.day], from: Date(), to: unlockDate).day ?? 0
            Text("This capsule will be sealed for \(days) days")
                .font(.caption2)
                .foregroundColor(.gray)
        }
    }

    private var sealButton: some View {
        Button {
            seal()
        } label: {
            HStack {
                Image(systemName: "lock.fill")
                Text("Seal This Capsule")
                    .fontWeight(.semibold)
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? Color.gray : Color.cyan
            )
            .cornerRadius(14)
        }
        .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSealing)
    }

    // MARK: - Sealed Confirmation

    private var sealedConfirmation: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "envelope.fill")
                .font(.system(size: 64))
                .foregroundColor(.cyan)
                .shadow(color: .cyan.opacity(0.5), radius: 20)

            Text("Capsule Sealed ✨")
                .font(.title2.bold())
                .foregroundColor(.white)

            let days = Calendar.current.dateComponents([.day], from: Date(), to: unlockDate).day ?? 0
            Text("See you in \(days) days")
                .font(.subheadline)
                .foregroundColor(.gray)

            Text("Long-press the Capsule button to view your vault")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.6))

            Spacer()

            Button("Done") { dismiss() }
                .foregroundColor(.cyan)
                .padding()
        }
        .transition(.opacity.combined(with: .scale))
    }

    // MARK: - Actions

    private func seal() {
        isSealing = true
        HapticManager.heavy()

        TimeCapsuleManager.shared.requestNotificationPermission()
        TimeCapsuleManager.shared.buryCapsule(
            track: track,
            noteText: noteText.trimmingCharacters(in: .whitespacesAndNewlines),
            unlockDate: unlockDate,
            mood: selectedMood
        )

        withAnimation(.easeInOut(duration: 0.6)) {
            isSealed = true
        }
    }
}
