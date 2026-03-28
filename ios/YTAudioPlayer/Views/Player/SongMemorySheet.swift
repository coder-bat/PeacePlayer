//
//  SongMemorySheet.swift
//  YTAudioPlayer
//
//  Create and edit a personal note attached to a song
//

import SwiftUI

struct SongMemorySheet: View {
    let track: Track

    @StateObject private var memoryManager = SongMemoryManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var noteText = ""
    @State private var didLoadMemory = false
    @State private var showDeleteConfirmation = false

    private let noteLimit = 280

    private var existingMemory: SongMemorySnapshot? {
        memoryManager.memory(for: track)
    }

    private var trimmedNote: String {
        noteText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationView {
            ZStack {
                Theme.cyberBackground
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        trackCard
                        editorCard

                        if let existingMemory {
                            memoryMetaCard(existingMemory)

                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "trash")
                                    Text("Delete Memory")
                                        .textCase(.uppercase)
                                }
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.red.opacity(0.18))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.red.opacity(0.35), lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(existingMemory == nil ? "Add Memory" : "Edit Memory")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.cyberDim)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(existingMemory == nil ? "Save" : "Update") {
                        saveMemory()
                    }
                    .foregroundColor(trimmedNote.isEmpty ? .cyberDim : .cyberCyan)
                    .disabled(trimmedNote.isEmpty)
                }
            }
            .confirmationDialog(
                "Delete this memory?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Memory", role: .destructive) {
                    memoryManager.deleteMemory(for: track)
                    HapticManager.light()
                    dismiss()
                }

                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This note will be removed from this song.")
            }
            .onAppear {
                guard !didLoadMemory else { return }
                noteText = existingMemory?.noteText ?? ""
                didLoadMemory = true
            }
            .onChange(of: noteText) { newValue in
                if newValue.count > noteLimit {
                    noteText = String(newValue.prefix(noteLimit))
                }
            }
        }
    }

    private var trackCard: some View {
        HStack(spacing: 14) {
            ArtworkThumbnail(url: track.artworkURL)
                .frame(width: 64, height: 64)
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 6) {
                Text(track.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                Text(track.displayArtist)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyberDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("This song means something — save a memory for it.")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyberCyan.opacity(0.85))
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.cyberSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Theme.cyberCyan.opacity(0.16), lineWidth: 1)
                )
        )
    }

    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YOUR MEMORY")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyberCyan)

                Spacer()

                Text("\(noteText.count)/\(noteLimit)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyberDim)
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.cyberBackground.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Theme.cyberCyan.opacity(0.14), lineWidth: 1)
                    )

                if noteText.isEmpty {
                    Text("What does this song remind you of?")
                        .font(.system(size: 15))
                        .foregroundColor(.cyberDim)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                }

                TextEditor(text: $noteText)
                    .foregroundColor(.white)
                    .font(.system(size: 15))
                    .padding(10)
                    .frame(minHeight: 180)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.cyberSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Theme.cyberMagenta.opacity(0.14), lineWidth: 1)
                )
        )
    }

    private func memoryMetaCard(_ memory: SongMemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MEMORY DETAILS")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.cyberCyan)

            MemoryMetaRow(label: "Created", value: memory.createdAt.formatted(date: .abbreviated, time: .shortened))
            MemoryMetaRow(label: "Updated", value: memory.updatedAt.formatted(date: .abbreviated, time: .shortened))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.cyberSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Theme.cyberYellow.opacity(0.14), lineWidth: 1)
                )
        )
    }

    private func saveMemory() {
        memoryManager.saveMemory(noteText: noteText, for: track)
        HapticManager.success()
        dismiss()
    }
}

private struct MemoryMetaRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.cyberDim)

            Spacer()

            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
        }
    }
}
