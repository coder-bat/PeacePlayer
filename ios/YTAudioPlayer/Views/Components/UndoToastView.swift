//
//  UndoToastView.swift
//  YTAudioPlayer
//
//  Cyberpunk-styled floating undo toast
//

import SwiftUI

struct UndoToastView: View {
    @ObservedObject var undoService = UndoService.shared
    
    var body: some View {
        if let action = undoService.currentUndo {
            HStack(spacing: 12) {
                // S15: pick an icon that matches the action's
                // capability. With-Undo shows the classic
                // `arrow.uturn.backward.circle.fill`; confirmation-
                // only shows a checkmark so the user reads it as
                // "done", not "you can revert this".
                Image(systemName: action.showUndoButton
                      ? "arrow.uturn.backward.circle.fill"
                      : "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.cyberCyan)

                Text(action.message)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer()

                if action.showUndoButton {
                    Button(action: {
                        HapticManager.medium()
                        undoService.executeUndo()
                    }) {
                        Text("Undo")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Theme.cyberCyan)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Theme.cyberCyan.opacity(0.15))
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.cyberSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Theme.cyberCyan.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(color: Theme.cyberCyan.opacity(0.2), radius: 8, x: 0, y: 4)
            )
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: undoService.currentUndo != nil)
        }
    }
}
