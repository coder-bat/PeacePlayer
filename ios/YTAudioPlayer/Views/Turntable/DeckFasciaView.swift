//
//  DeckFasciaView.swift
//  YTAudioPlayer
//
//  The strip across the top of the deck.
//
//  It replaces the current Home header (profile chip + 5 nav chips).
//
//  Revision history (2026-11-18), three passes:
//  1. The strip was ONE row — the deck's etched wordmark on the left
//     and the five destinations in the top-right corner. The profile
//     chip moved out of the deck entirely: the deck is a record
//     player, not an account screen. The avatar, display name and
//     sign-out sheet live in Settings, behind the email row.
//  2. The etched PEACEPLAYER wordmark was removed and the five
//     destinations were centred as one group.
//  3. The strip lost its background altogether — no frosted material,
//     no border, no shadow. It is now just a row of icons floating
//     over the deck, and the actionable lamps (Smart Library review,
//     scheduled cleanup) became icons in that row instead of dots
//     underneath it.
//
//  The nav chips are injected rather than owned so Home keeps control
//  of its NavigationStack routes — the fascia only draws the row.
//

import SwiftUI

struct DeckFasciaView<Chips: View>: View {
    private let navChips: () -> Chips

    init(@ViewBuilder navChips: @escaping () -> Chips) {
        self.navChips = navChips
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            navChips()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}
