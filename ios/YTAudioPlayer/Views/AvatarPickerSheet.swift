//
//  AvatarPickerSheet.swift
//  PeacePlayer
//
//  2026-06-28 (S6): Avatar picker. Lets the user pick an SF Symbol
//  for the home page header chip. The grid mirrors the rest of
//  the app's cyber aesthetic — glass cells, neon borders, cyan
//  glow on the selected option.
//

import SwiftUI

struct AvatarPickerSheet: View {
    @StateObject private var profile = UserProfile.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draftSelection: String
    @State private var draftName: String

    init() {
        let p = UserProfile.shared
        _draftSelection = State(initialValue: p.avatarSymbolName)
        _draftName = State(initialValue: p.displayName ?? "")
    }

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 14)]

    var body: some View {
        ZStack {
            Theme.cyberBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Custom header (matches CreatePlaylistSheet)
                HStack {
                    Text("Choose Avatar")
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .shadow(color: Theme.cyberCyan.opacity(0.5), radius: 6, x: 0, y: 0)
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Theme.cyberDim)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

                Rectangle()
                    .fill(LinearGradient(
                        colors: [.clear, Theme.cyberCyan.opacity(0.4), .clear],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)

                ScrollView {
                    VStack(spacing: 20) {
                        // Display name input
                        VStack(alignment: .leading, spacing: 6) {
                            Text("DISPLAY NAME (OPTIONAL)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.cyberDim)
                                .tracking(1.5)

                            TextField("Your name", text: $draftName)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Theme.cyberSurface)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Theme.cyberCyan.opacity(0.4), lineWidth: 1)
                                        )
                                )
                                .foregroundColor(.white)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.words)
                        }

                        // Avatar grid
                        VStack(alignment: .leading, spacing: 8) {
                            Text("AVATAR")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.cyberDim)
                                .tracking(1.5)

                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(UserProfile.avatarCatalog) { choice in
                                    AvatarCell(
                                        choice: choice,
                                        isSelected: draftSelection == choice.symbol,
                                        onTap: { draftSelection = choice.symbol }
                                    )
                                }
                            }
                        }

                        // Save button
                        Button {
                            profile.avatarSymbolName = draftSelection
                            profile.displayName = draftName.isEmpty ? nil : draftName
                            HapticManager.success()
                            dismiss()
                        } label: {
                            Text("SAVE")
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .tracking(1.5)
                                .foregroundColor(Theme.cyberBackground)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(
                                    LinearGradient(
                                        colors: [Theme.cyberCyan, Theme.cyberMagenta],
                                        startPoint: .leading, endPoint: .trailing)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(color: Theme.cyberCyan.opacity(0.4), radius: 12)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct AvatarCell: View {
    let choice: AvatarChoice
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Theme.cyberCyan.opacity(0.18) : Theme.cyberSurface)
                        .frame(width: 56, height: 56)
                        .overlay(
                            Circle()
                                .stroke(
                                    isSelected
                                        ? Theme.cyberCyan
                                        : Theme.cyberCyan.opacity(0.25),
                                    lineWidth: isSelected ? 2 : 1)
                        )
                        .shadow(color: isSelected ? Theme.cyberCyan.opacity(0.6) : .clear, radius: 10)

                    Image(systemName: choice.symbol)
                        .font(.system(size: 26, weight: .regular))
                        .foregroundColor(isSelected ? Theme.cyberCyan : .white)
                }

                Text(choice.label.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? Theme.cyberCyan : Theme.cyberDim)
                    .tracking(1.0)
            }
        }
        .buttonStyle(.plain)
    }
}
