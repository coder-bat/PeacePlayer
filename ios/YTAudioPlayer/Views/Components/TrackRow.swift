//
//  TrackRow.swift
//  PeacePlayer
//
//  Unified track row component for the S15 polish sprint.
//
//  Replaces 8+ near-identical row implementations across the app
//  (LibraryView.ListTrackRow, QueueView.QueueItemRow, HistoryView.HistoryRow,
//  SearchView.SearchResultRow, HomeView.HomeRecentTrackRow, RadioView.SongRadioRow,
//  RadioView.RadioStationRow, DiscoverView.DiscoverTrackRow, etc.). Each of those
//  was independently implemented with subtle inconsistencies — different title
//  sizes (14/15/16), different subtitle sizes (12/13/14), different
//  "now playing" highlight colors (`.cyberCyan`, `Theme.cyberCyan`, `.accentColor`,
//  `.white`), and different right-side accessory treatments.
//
//  TrackRow is the single source of truth. It always uses
//  `Theme.cyberCyan` for the playing highlight, 50pt artwork,
//  two-line text (title + optional subtitle), and a single
//  configurable right-side accessory. Call sites pick the
//  variant that matches their context.
//

import SwiftUI

// MARK: - Accessory

/// Right-side accessory for a `TrackRow`. Most rows have no
/// accessory; the now-playing row shows animated bars; the
/// download-status row shows a checkmark or download icon.
enum TrackRowAccessory {
    case none
    case playingBars
    case downloadedCheck
    case downloadingBadge
    case dotIndicator(color: Color)
    case chevron
    case custom(AnyView)
}

// MARK: - TrackRow

struct TrackRow: View {
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let isPlaying: Bool
    let titleSize: CGFloat
    let subtitleSize: CGFloat
    let showSubtitle: Bool
    let accessory: TrackRowAccessory
    let onTap: (() -> Void)?
    let onLongPress: (() -> Void)?

    init(
        title: String,
        subtitle: String? = nil,
        artworkURL: URL? = nil,
        isPlaying: Bool = false,
        titleSize: CGFloat = 16,
        subtitleSize: CGFloat = 14,
        showSubtitle: Bool = true,
        accessory: TrackRowAccessory = .none,
        onTap: (() -> Void)? = nil,
        onLongPress: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.isPlaying = isPlaying
        self.titleSize = titleSize
        self.subtitleSize = subtitleSize
        self.showSubtitle = showSubtitle
        self.accessory = accessory
        self.onTap = onTap
        self.onLongPress = onLongPress
    }

    var body: some View {
        // S13: Wrap the entire row content in a Button so the tap
        // target is unambiguous and works alongside the row's
        // `.contextMenu` and any SwiftUI `List` swipeActions the
        // parent attaches.
        Button {
            onTap?()
        } label: {
            HStack(spacing: 12) {
                artworkView
                textBlock
                Spacer(minLength: 8)
                accessoryView
            }
            .padding(.vertical, 4)
            .background(isPlaying ? Theme.cyberCyan.opacity(0.08) : Color.clear)
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .if(onLongPress != nil) { view in
            view.simultaneousGesture(
                LongPressGesture().onEnded { _ in
                    onLongPress?()
                }
            )
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var artworkView: some View {
        Group {
            if let url = artworkURL {
                CachedAsyncImage(url: url) {
                    placeholderArtwork
                }
            } else {
                placeholderArtwork
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm))
    }

    private var placeholderArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.sm)
                .fill(Theme.cyberSurface)
            Image(systemName: "music.note")
                .foregroundColor(Theme.cyberDim)
        }
    }

    @ViewBuilder
    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: titleSize, weight: isPlaying ? .semibold : .medium))
                // S15: single source of truth for the "now playing"
                // highlight color. The previous 4 row implementations
                // disagreed (`.cyberCyan`, `Theme.cyberCyan`,
                // `.accentColor`, `.white`); all now use
                // `Theme.cyberCyan`.
                .foregroundColor(isPlaying ? Theme.cyberCyan : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if showSubtitle, let subtitle = subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: subtitleSize))
                    .foregroundColor(Theme.cyberDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .playingBars:
            CyberPlayingBars()
                .frame(width: 20, height: 20)
        case .downloadedCheck:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(Theme.cyberCyan)
        case .downloadingBadge:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18))
                .foregroundColor(Theme.cyberCyan.opacity(0.6))
        case .dotIndicator(let color):
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.cyberDim)
        case .custom(let anyView):
            anyView
        }
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        if let subtitle = subtitle, !subtitle.isEmpty {
            return "\(title), \(subtitle)"
        }
        return title
    }

    private var accessibilityHint: String {
        if isPlaying { return "Now playing" }
        if onTap != nil { return "Double tap to play" }
        return ""
    }
}

// MARK: - View helper for conditional modifier

private extension View {
    /// Conditional view modifier used by `TrackRow` to attach the
    /// long-press handler only when the caller provided one. Keeps
    /// the public `body` clean.
    @ViewBuilder
    func `if`<Transform: View>(
        _ condition: Bool,
        transform: (Self) -> Transform
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
