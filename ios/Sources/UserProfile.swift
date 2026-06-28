//
//  UserProfile.swift
//  PeacePlayer
//
//  2026-06-28 (S6): User profile singleton. Holds the chosen
//  avatar (SF Symbol) and display name for the home-page header
//  chip. Persisted to UserDefaults so the choice survives a
//  relaunch. The avatar picker sheet lets the user pick from
//  ~12 SF Symbols in the cyber aesthetic.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class UserProfile: ObservableObject {
    static let shared = UserProfile()

    /// SF Symbol name for the user's chosen avatar. Defaults to
    /// "person.crop.circle" so the home page shows something
    /// before the user has picked.
    @Published var avatarSymbolName: String {
        didSet { UserDefaults.standard.set(avatarSymbolName, forKey: avatarKey) }
    }

    /// Optional display name (Apple doesn't always share the
    /// user's real name; we keep what they tell us).
    @Published var displayName: String? {
        didSet { UserDefaults.standard.set(displayName, forKey: nameKey) }
    }

    private let avatarKey = "peaceplayer.avatar_symbol"
    private let nameKey = "peaceplayer.display_name"

    private init() {
        self.avatarSymbolName =
            UserDefaults.standard.string(forKey: "peaceplayer.avatar_symbol")
            ?? "person.crop.circle"
        self.displayName = UserDefaults.standard.string(forKey: "peaceplayer.display_name")
    }

    /// The catalog of avatars the user can pick from. All SF
    /// Symbols that fit the cyber aesthetic — silhouettes,
    /// waves, stars, etc.
    static let avatarCatalog: [AvatarChoice] = [
        AvatarChoice(symbol: "person.crop.circle",     label: "Default"),
        AvatarChoice(symbol: "waveform",              label: "Waveform"),
        AvatarChoice(symbol: "music.note",             label: "Music"),
        AvatarChoice(symbol: "headphones",             label: "Headphones"),
        AvatarChoice(symbol: "bolt.fill",              label: "Energy"),
        AvatarChoice(symbol: "leaf.fill",              label: "Chill"),
        AvatarChoice(symbol: "moon.stars.fill",        label: "Dream"),
        AvatarChoice(symbol: "sun.max.fill",           label: "Bright"),
        AvatarChoice(symbol: "sparkles",               label: "Sparkle"),
        AvatarChoice(symbol: "star.fill",              label: "Star"),
        AvatarChoice(symbol: "flame.fill",             label: "Flame"),
        AvatarChoice(symbol: "snowflake",              label: "Snowflake"),
    ]
}

struct AvatarChoice: Identifiable, Hashable {
    let symbol: String
    let label: String
    var id: String { symbol }
}
