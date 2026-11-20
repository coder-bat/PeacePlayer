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

    @ObservedObject private var featureFlags = FeatureFlags.shared

    var body: some View {
        if featureFlags.turntableHome { deckBody } else { legacyBody }
    }

    /// Deck: a walnut board with the title and Cancel, two wells with
    /// their legends engraved above, and the one cream card.
    private var deckBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("New playlist")
                    .font(DeckType.screenTitle)
                    .foregroundColor(TurntableTokens.cream)
                Spacer(minLength: 8)
                DeckButton(title: "Cancel") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .deckPlinth(cornerRadius: 0)

            VStack(alignment: .leading, spacing: 18) {
                deckField("Name", prompt: "Playlist name", text: $name, field: .name, submit: .next) {
                    focusedField = .description
                }
                deckField("Description (optional)", prompt: "Add a description", text: $description, field: .description, submit: .done) {
                    createPlaylist()
                }

                DeckButton(title: "Create playlist", symbol: "plus", kind: .card, fillsWidth: true) {
                    createPlaylist()
                }
                .opacity(name.isEmpty ? 0.45 : 1)
                .disabled(name.isEmpty)
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)

            Spacer()
        }
        .background(DeckRoom())
        .preferredColorScheme(.dark)
        .onAppear { focusedField = .name }
    }

    private func deckField(
        _ legend: String, prompt: String, text: Binding<String>,
        field: Field, submit: SubmitLabel, onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(legend.uppercased())
                .font(DeckType.engraved)
                .tracking(DeckType.engravedTracking)
                .foregroundColor(TurntableTokens.aluminium.opacity(0.7))
                .padding(.leading, 6)

            TextField("", text: text, prompt: Text(prompt).foregroundColor(TurntableTokens.cream.opacity(0.4)))
                .font(DeckType.body)
                .foregroundColor(TurntableTokens.cream)
                .tint(DeckSignal.live)
                .focused($focusedField, equals: field)
                .submitLabel(submit)
                .autocorrectionDisabled()
                .onSubmit(onSubmit)
                .padding(.horizontal, 18)
                .frame(height: 48)
                .deckWell(Capsule(), lit: focusedField == field ? DeckSignal.live : nil)
                .accessibilityLabel(legend)
        }
    }

    private var legacyBody: some View {
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
