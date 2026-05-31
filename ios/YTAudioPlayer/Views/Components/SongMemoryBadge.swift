//
//  SongMemoryBadge.swift
//  YTAudioPlayer
//
//  Reusable badge for tracks with personal memories
//

import SwiftUI

struct SongMemoryBadge: View {
    let text: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .bold))

            Text((text?.isEmpty == false ? text : "MEMORY") ?? "MEMORY")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .foregroundColor(Theme.cyberYellow)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Theme.cyberYellow.opacity(0.12))
                .overlay(
                    Capsule()
                        .stroke(Theme.cyberYellow.opacity(0.3), lineWidth: 1)
                )
        )
    }
}
