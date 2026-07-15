//
//  CreatePlaylistSheet.swift
//  PeacePlayer
//
//  Sheet for creating a new playlist. 2026-06-28 (S6): redesigned
//  to match the app's cyber design — neon-themed background, cyan
//  gradient CTA, custom header instead of the iOS list chrome that
//  was producing a black bar across the title row.
//

import SwiftUI

struct CreatePlaylistSheet: View {
    enum Field { case name, description }
    @StateObject private var playlistManager = PlaylistManager.shared
    @State private var name = ""
    @State private var description = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    var body: some View {
        ZStack {
            // Cyberpunk background — same as the rest of the app
            Theme.cyberBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Custom header (replaces the NavigationView bar
                // which was rendering as a black strip). Title on
                // the left, Cancel on the right.
                HStack {
                    Text("New Playlist")
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 6, x: 0, y: 0)

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(Theme.cyberCyan)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

                // Divider with neon glow
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Theme.cyberCyan.opacity(0.4), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)

                VStack(spacing: 16) {
                    // Name field
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NAME")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.cyberDim)
                            .tracking(1.5)

                        TextField("Playlist Name", text: $name)
                            .textFieldStyle(NeonTextFieldStyle(focused: focusedField == .name))
                            .focused($focusedField, equals: .name)
                            .submitLabel(.next)
                            .autocorrectionDisabled()
                            .onSubmit { focusedField = .description }
                    }

                    // Description field
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DESCRIPTION (OPTIONAL)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.cyberDim)
                            .tracking(1.5)

                        TextField("Add a description", text: $description)
                            .textFieldStyle(NeonTextFieldStyle(focused: focusedField == .description))
                            .focused($focusedField, equals: .description)
                            .submitLabel(.done)
                            .autocorrectionDisabled()
                            .onSubmit { createPlaylist() }
                    }

                    // Create button — neon CTA
                    Button {
                        createPlaylist()
                    } label: {
                        Text("CREATE PLAYLIST")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundColor(name.isEmpty ? Theme.cyberDim : Theme.cyberBackground)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(
                                ZStack {
                                    if !name.isEmpty {
                                        LinearGradient(
                                            colors: [Theme.cyberCyan, Theme.cyberMagenta],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    } else {
                                        Color.cyberSurface
                                    }
                                }
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(color: name.isEmpty ? .clear : Theme.cyberCyan.opacity(0.4), radius: 12)
                    }
                    .disabled(name.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 32)

                Spacer()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func createPlaylist() {
        guard !name.isEmpty else { return }

        let playlist = playlistManager.createPlaylist(
            name: name,
            description: description.isEmpty ? nil : description
        )

        HapticManager.success()
        dismiss()
    }
}
