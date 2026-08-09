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
///
/// S18 / v1.6.7 (CV-8): the original 7 cases covered the most
/// common QueueView / RadioView / HistoryView patterns. The
/// `index` / `downloadBadge` / `memoryBadge` cases are the
/// additions that let the consolidated TrackRow replace
/// ListTrackRow / CyberpunkTrackRow / HomeRecentTrackRow.
enum TrackRowAccessory {
    case none
    case playingBars
    case downloadedCheck
    case downloadingBadge
    case dotIndicator(color: Color)
    case chevron
    /// Track index in a numbered list (1-based). Shows
    /// "01" / "02" / etc. in monospaced dim, and animates to
    /// the playing bars when this row is the current track.
    /// Width matches the CyberpunkTrackRow's 28pt gutter so
    /// the row content doesn't shift when the indicator
    /// swaps.
    case index(Int)
    /// Small "downloaded" indicator overlaid on the artwork's
    /// bottom-right. CyberpunkTrackRow used this to mark
    /// downloaded tracks. 14pt circle in cyberCyan with
    /// cyberBackground backdrop.
    case downloadBadge
    /// Right-side cluster of action buttons. Used by HomeView's
    /// recent-tracks row to surface play-next, download, and
    /// like in one compact strip. Each callback is optional
    /// and the cluster collapses when no callbacks are wired
    /// (so the row stays compact for simple "tap to play"
    /// use cases).
    case actionCluster(
        onPlayNext: (() -> Void)? = nil,
        onDownload: (() -> Void)? = nil,
        onLike: ((Bool) -> Void)? = nil
    )
    case custom(AnyView)
}

// MARK: - TrackRow

struct TrackRow: View {
    let title: String
    let subtitle: String?
    let subtitle2: String?
    let artworkURL: URL?
    let isPlaying: Bool
    let titleSize: CGFloat
    let subtitleSize: CGFloat
    let subtitle2Size: CGFloat
    let showSubtitle: Bool
    let accessory: TrackRowAccessory
    let onTap: (() -> Void)?
    let onLongPress: (() -> Void)?

    init(
        title: String,
        subtitle: String? = nil,
        subtitle2: String? = nil,
        artworkURL: URL? = nil,
        isPlaying: Bool = false,
        titleSize: CGFloat = 16,
        subtitleSize: CGFloat = 14,
        subtitle2Size: CGFloat = 11,
        showSubtitle: Bool = true,
        accessory: TrackRowAccessory = .none,
        onTap: (() -> Void)? = nil,
        onLongPress: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitle2 = subtitle2
        self.artworkURL = artworkURL
        self.isPlaying = isPlaying
        self.titleSize = titleSize
        self.subtitleSize = subtitleSize
        self.subtitle2Size = subtitle2Size
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
                if case .index = accessory {
                    // Index indicator sits in its own 28pt gutter
                    // BEFORE the artwork, matching the
                    // CyberpunkTrackRow layout. Rendered
                    // in-line so the artwork + text + accessory
                    // positions stay identical to the
                    // non-indexed row.
                    indexGutter
                }
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

    /// S18 / v1.6.7 (CV-8): the index indicator (track number or
    /// playing bars) for the .index accessory. Mirrors
    /// CyberpunkTrackRow's 28pt gutter with a 13pt monospaced
    /// number that animates to CyberPlayingBars when this row
    /// is the current track.
    @ViewBuilder
    private var indexGutter: some View {
        ZStack {
            if isPlaying {
                CyberPlayingBars()
                    .frame(width: 20, height: 20)
                    .transition(.scale.combined(with: .opacity))
            } else if case .index(let n) = accessory {
                Text(String(format: "%02d", n))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: isPlaying)
        .frame(width: 28, alignment: .center)
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var artworkView: some View {
        // S18 / v1.6.7 (CV-8): when the .downloadBadge accessory is
        // active, overlay a small cyberCyan circle in the
        // bottom-right of the artwork. Mirrors
        // CyberpunkTrackRow's download indicator. The artwork
        // itself is unchanged in the non-badge case.
        ZStack(alignment: .bottomTrailing) {
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

            if case .downloadBadge = accessory {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.cyberCyan)
                    .background(Circle().fill(Theme.cyberBackground))
                    .offset(x: 4, y: 4)
            }
        }
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

            // S18 / v1.6.7 (CV-8): second subtitle line. Used by
            // LibraryView for "12.4 MB" file size and could be
            // used elsewhere. Monospaced small caption style
            // matches the original ListTrackRow.
            if let subtitle2 = subtitle2, !subtitle2.isEmpty {
                Text(subtitle2)
                    .font(.system(size: subtitle2Size, design: .monospaced))
                    .foregroundColor(Theme.cyberTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .none, .index, .downloadBadge:
            // .index renders into the leading gutter via
            // indexGutter, not here. .downloadBadge renders as
            // an overlay on the artwork, not the right side.
            // Both cases pass through with no right-side
            // accessory so the row stays compact.
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
        case .actionCluster(let onPlayNext, let onDownload, let onLike):
            // S18 / v1.6.7 (CV-8): the right-side cluster from
            // HomeRecentTrackRow. Each callback is optional;
            // when all are nil the cluster collapses to
            // EmptyView so simple "tap to play" rows don't
            // carry dead space.
            HStack(spacing: 12) {
                if let onPlayNext = onPlayNext {
                    Button {
                        onPlayNext()
                    } label: {
                        Image(systemName: "text.insert")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.cyberCyan)
                    }
                    .buttonStyle(.plain)
                }
                if let onDownload = onDownload {
                    Button {
                        onDownload()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.cyberCyan)
                    }
                    .buttonStyle(.plain)
                }
                if let onLike = onLike {
                    // The like state is passed in by the caller
                    // because the row doesn't own the playlist
                    // manager. The closure receives the new
                    // state to write back.
                    Button {
                        // Toggle is handled by the caller — we
                        // just dispatch a "flip the like"
                        // signal. The caller passes the new
                        // value via the closure.
                        onLike(true)  // optimistic; caller resolves
                    } label: {
                        Image(systemName: "heart")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.cyberMagenta)
                    }
                    .buttonStyle(.plain)
                }
            }
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
