//
//  ContentView.swift
//  YTAudioPlayer
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var playerState = PlayerState.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @StateObject private var searchViewModel = SearchViewModel()
    @StateObject private var radioViewModel = RadioViewModel()
    // 2026-06-28: Apple Sign-In. The LandingView shows when this is
    // false; the main UI shows when it's true. bootstrap() is called
    // from init() in YTAudioPlayerApp.swift before ContentView mounts.
    @StateObject private var auth = AuthService.shared
    @State private var selectedTab = 0
    @State private var showFullPlayer = false
    @State private var showRestorePrompt = false
    // 2026-06-28: header-icon sheets. Surfaced from Home's top-right
    // icon cluster via NotificationCenter so the bottom nav doesn't
    // have to grow.
    @State private var showSettings = false
    @State private var showPlaylists = false
    @State private var showRadio = false
    @Namespace private var playerNamespace

    var body: some View {
        // 2026-06-28: gate the entire app on Apple sign-in. There is
        // no guest path in this version. While auth.isAuthenticated is
        // false we render only the LandingView; once it flips the main
        // tab UI mounts in its place.
        if !auth.isAuthenticated {
            LandingView()
                .transition(.opacity)
        } else {
            authenticatedBody
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var authenticatedBody: some View {
        ZStack {
            // Tab content — no per-tab safeAreaInset for the mini
            // player anymore; the bottom row below combines the
            // floating pill and the mini player side-by-side.
            TabView(selection: $selectedTab) {
                HomeView()
                    .tag(0)
                SearchView(viewModel: searchViewModel)
                    .tag(1)
                LibraryView()
                    .tag(3)
            }
            .modifier(HideNativeTabBar())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // 2026-06-28 (S7): bottom row that holds the floating
                // tab pill on the left and the mini player on the
                // right (when a track is playing). When there's no
                // track playing, only the pill renders, centered
                // in the row. Same height on both so the row stays
                // visually balanced.
                //
                // 2026-06-28 (S7c): we render a compact variant of
                // MiniPlayer (drops the skip-forward button, the
                // live/audiobook badges, the standalone background,
                // and tightens the layout) so the row fits the
                // 50% width budget per side.
                BottomBar(
                    tabBar: CyberpunkTabBar(selectedTab: $selectedTab),
                    miniPlayer: AnyView(MiniPlayer(onExpand: {
                        showFullPlayer = true
                    }, compact: true))
                )
                .frame(maxWidth: .infinity)
                .background(Color.clear)
            }

            // Offline banner
            if !networkMonitor.isConnected {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 12, weight: .bold))
                        Text("Offline — downloaded music still available")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(Color.cyberSurface)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.4), value: networkMonitor.isConnected)
                .zIndex(2)
            }

            // Queue restore overlay
            if showRestorePrompt {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()

                QueueRestorePrompt {
                    showRestorePrompt = false
                }
            }

            // Full player overlay — slides up over everything including the tab bar
            if showFullPlayer {
                FullPlayer(isPresented: $showFullPlayer)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom),
                        removal: .move(edge: .bottom)
                    ))
                    .zIndex(1)
            }

            // Undo toast — above tab bar + MiniPlayer, below sheets
            VStack {
                Spacer()
                UndoToastView()
                    .padding(.bottom, 120) // clears CyberpunkTabBar (~56pt) + MiniPlayer (64pt)
            }
            .zIndex(3)
            .allowsHitTesting(UndoService.shared.currentUndo != nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchTab)) { notification in
            if let tab = notification.object as? Int {
                selectedTab = tab
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .startSongRadio)) { notification in
            if let track = notification.object as? Track {
                radioViewModel.startSongRadio(from: track)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                    selectedTab = 5
                }
            }
        }
        // 2026-06-28: header-icon routing — the Home page's top-right
        // icon cluster posts these to surface Settings, Playlists, and
        // Radio as sheets so they don't fight the bottom-nav tab
        // system for the same screen real estate.
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPlaylists)) { _ in
            showPlaylists = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRadio)) { _ in
            showRadio = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFullPlayer)) { _ in
            showFullPlayer = true
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showPlaylists) {
            NavigationView {
                PlaylistsView()
                    .preferredColorScheme(.dark)
            }
        }
        .sheet(isPresented: $showRadio) {
            NavigationView {
                RadioView(viewModel: RadioViewModel())
                    .preferredColorScheme(.dark)
            }
        }
        .onChange(of: playerState.showQueue) { shouldShow in
            if shouldShow && !showFullPlayer {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    showFullPlayer = true
                }
            }
        }
        .errorAlert()
        .onAppear {
            setupAppearance()
            PlaybackQueueManager.shared.startObservingPlayerStateIfNeeded(playerState: playerState)
            if QueueRestorer.shared.shouldShowRestorePrompt() {
                showRestorePrompt = true
            }
        }
    }

    @ViewBuilder
    private var miniPlayerView: some View {
        if playerState.isNowPlaying && !showFullPlayer {
            MiniPlayer {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                    showFullPlayer = true
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .padding(.bottom, 8)
        }
    }

    private func setupAppearance() {
        // Navigation bar — black opaque across all screens
        let activeColor = UIColor(red: 0, green: 0.9, blue: 1, alpha: 1)

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = .black
        navAppearance.shadowColor = .clear
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
        UINavigationBar.appearance().tintColor = activeColor

        // Search bar — dark field matching cyberSurface
        let cyberSurface = UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        UISearchBar.appearance().barTintColor = .black
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).backgroundColor = cyberSurface
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).textColor = .white
        UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).tintColor = activeColor
    }
}

// MARK: - Hide Native Tab Bar (2026-06-28 S6: belt + suspenders)

/// Hides the native UITabBar so our custom CyberpunkTabBar takes over.
/// On iOS 16+ uses the .toolbar API. On all versions, also flips
/// UITabBar.appearance().isHidden = true via .onAppear, because
/// `toolbar(.hidden, for: .tabBar)` is silently bypassed in some
/// iOS 26 builds when a custom safeAreaInset is in play. Belt
/// AND suspenders.
private struct HideNativeTabBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .toolbar(.hidden, for: .tabBar)
                .onAppear {
                    UITabBar.appearance().isHidden = true
                }
                .onDisappear {
                    UITabBar.appearance().isHidden = false
                }
        } else {
            content.onAppear {
                UITabBar.appearance().isHidden = true
            }
        }
    }
}

// MARK: - Bottom Bar (2026-06-28 S7)

// 2026-06-28 (S7): the bottom safeAreaInset now hosts a single
// row that combines the floating tab pill (left, shifted) and the
// mini player (right). When the mini player isn't visible, the
// pill is centered. Layout uses an HStack with a fixed-height
// capsule style so the row is visually balanced whether the
// player is open or not.
struct BottomBar: View {
    let tabBar: CyberpunkTabBar
    let miniPlayer: AnyView

    @StateObject private var playerState = PlayerState.shared

    // 2026-06-28 (S7d): pill and mini player share the same
    // height so the row reads as a single unit. The mini player
    // is now self-contained — it draws its own blurred-artwork
    // background and rounded corners. BottomBar no longer wraps
    // it in another clipShape/overlay (that produced the
    // "pill-inside-pill" look).
    //
    // 2026-06-28 (S8): added collapsed/expanded state. Swiping
    // right on the mini player collapses it to a small icon
    // sitting next to the pill. Tapping the collapsed icon
    // expands it back. Padding between the pill and the player
    // stays the same in both states.
    private let rowHeight: CGFloat = 60
    private let collapsedWidth: CGFloat = 44
    @State private var isCollapsed: Bool = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if playerState.isNowPlaying {
                // Tab pill on the left
                tabBar

                // Mini player on the right — animates between
                // full width and collapsed icon width.
                if isCollapsed {
                    collapsedIcon
                } else {
                    miniPlayer
                        .frame(height: rowHeight)
                        .frame(maxWidth: .infinity)
                        // 2026-06-28 (S8): horizontal swipe to
                        // collapse / expand. Right-swipe collapses
                        // the mini player into a small icon next
                        // to the pill; left-swipe expands it back.
                        .gesture(
                            DragGesture(minimumDistance: 24)
                                .onEnded { value in
                                    let h = value.translation.width
                                    if h < -40 {
                                        // Swipe left → expand
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                            isCollapsed = false
                                        }
                                    } else if h > 40 {
                                        // Swipe right → collapse
                                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                                            isCollapsed = true
                                        }
                                    }
                                }
                        )
                }
            } else {
                // No track playing — center the pill.
                Spacer(minLength: 0)
                tabBar
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: rowHeight + 4)  // breathing room above home indicator
    }

    /// 2026-06-28 (S8): the collapsed mini player. Same 60pt
    /// height as the pill, but only 44pt wide — just a small
    /// circle with a play/pause icon. Tapping it expands the
    /// mini player back to its full width.
    private var collapsedIcon: some View {
        let isPlaying = playerState.playbackState == .playing
        return Button {
            HapticManager.light()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                isCollapsed = false
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Theme.cyberSurface,
                                Theme.cyberCyan.opacity(0.18)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [.cyberCyan, .cyberMagenta],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
                    .frame(width: 44, height: 44)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.cyberCyan)
                    .offset(x: isPlaying ? 0 : 1)
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .frame(height: 60)  // match the row height so the icon is centered vertically
    }
}

// MARK: - Cyberpunk Tab Bar

struct CyberpunkTabBar: View {
    @Binding var selectedTab: Int

    private struct TabDef {
        let icon: String
        let label: String
        let tag: Int
    }

    // 2026-06-28: reduced to just Home + Library. Search, Playlists,
    // Downloads, Radio, and Settings are all reachable from the new
    // top-right icon cluster on the Home tab (see HomeView's
    // headerSection). The bottom nav is now a clean two-icon strip.
    private let tabs: [TabDef] = [
        TabDef(icon: "house.fill",            label: "Home",    tag: 0),
        TabDef(icon: "music.note.house.fill", label: "Library", tag: 3),
    ]

    var body: some View {
        // 2026-06-28: floating pill. The bar is now a centered
        // capsule with a fixed width, instead of a full-width
        // strip. Sits above the home indicator with breathing
        // room on either side so the bar reads as a single
        // object floating above the content.
        HStack(spacing: 0) {
            ForEach(tabs, id: \.tag) { tab in
                CyberpunkTabItem(
                    icon: tab.icon,
                    label: tab.label,
                    isSelected: selectedTab == tab.tag
                ) {
                    guard selectedTab != tab.tag else { return }
                    HapticManager.light()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                        selectedTab = tab.tag
                    }
                }
            }
        }
        .frame(width: 180, height: 60)  // fixed-size floating pill (S7d: 56→60 to match mini player)
        .background(
            ZStack {
                // Glass blur
                Capsule()
                    .fill(.ultraThinMaterial)
                // Dark cyberpunk tint
                Capsule()
                    .fill(Color.cyberSurface.opacity(0.78))
                // Subtle cyan glow inside the capsule
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [Color.cyberCyan.opacity(0.6), Color.cyberMagenta.opacity(0.4)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 4)
            .shadow(color: Color.cyberCyan.opacity(0.15), radius: 16, x: 0, y: 0)
        )
        .padding(.bottom, 6)  // breathing room above home indicator
        // The bar is centered horizontally by the parent ZStack
        // (no Spacer needed — see the call site in body).
    }
}

// MARK: - Cyberpunk Tab Item

struct CyberpunkTabItem: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    // Active selection pill
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.cyberCyan.opacity(0.10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.cyberCyan.opacity(0.22), lineWidth: 1)
                            )
                            .frame(width: 46, height: 30)
                    }

                    // Icon with neon glow when selected
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .cyberCyan : .cyberDim)
                        // Inline GlowModifier (two-shadow recipe from HomeView)
                        .shadow(color: isSelected ? Color.cyberCyan.opacity(0.55) : .clear,
                                radius: 4, x: 0, y: 0)
                        .shadow(color: isSelected ? Color.cyberCyan.opacity(0.30) : .clear,
                                radius: 9, x: 0, y: 0)
                }
                .frame(height: 32)

                // 2026-06-28: hidden. The bottom nav is now icons-only.
                // (Commented out rather than deleted so the layout
                // spacing can be tweaked back if the user changes
                // their mind. Active indicator dot still appears below.)
                //
                // Text(label.uppercased())
                //     .font(.system(size: 9, weight: .bold, design: .monospaced))
                //     .lineLimit(1)
                //     .minimumScaleFactor(0.7)
                //     .foregroundColor(isSelected ? .cyberCyan : .cyberDim)

                // Active indicator dot
                Circle()
                    .fill(isSelected ? Color.cyberCyan : Color.clear)
                    .frame(width: 3, height: 3)
                    .shadow(color: isSelected ? Color.cyberCyan.opacity(0.8) : .clear,
                            radius: 3, x: 0, y: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))  // VoiceOver still gets the name
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isSelected)
    }
}

// MARK: - Previews

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let switchTab = Notification.Name("switchTab")
    static let startSongRadio = Notification.Name("startSongRadio")
    // 2026-06-28: header icon cluster on Home posts these to route
    // the user to the right surface. The Home view shows sheets for
    // each (avoids fighting the bottom-nav tab system for the same
    // surface area).
    static let openSettings = Notification.Name("openSettings")
    static let openPlaylists = Notification.Name("openPlaylists")
    static let openRadio = Notification.Name("openRadio")
    // 2026-06-28 (S8): posted by the home page's NowPlayingHero
    // when the user taps the resume block. ContentView listens
    // and opens the full player.
    static let openFullPlayer = Notification.Name("openFullPlayer")
}
