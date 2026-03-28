import SwiftUI

struct AudiobookDetailView: View {
    let book: Audiobook
    @ObservedObject var viewModel: RadioViewModel
    @ObservedObject var library: AudiobookLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var isDescriptionExpanded = false

    var body: some View {
        ZStack {
            Theme.cyberBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Dismiss handle
                    Capsule()
                        .fill(Theme.cyberDim)
                        .frame(width: 36, height: 5)
                        .padding(.top, 12)
                        .padding(.bottom, 16)

                    // Close button
                    HStack {
                        Spacer()
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Theme.cyberDim)
                                .padding(15)
                                .background(Circle().fill(Theme.cyberSurface))
                        }
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Close")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                    headerSection

                    libraryButton

                    continueReadingButton

                    Divider()
                        .background(Theme.cyberDim.opacity(0.2))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)

                    chaptersList
                }
                .padding(.bottom, 90)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            viewModel.loadChapters(for: book)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 16) {
            coverArt

            VStack(spacing: 6) {
                Text(book.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                Text(book.displayAuthors)
                    .font(.system(size: 14))
                    .foregroundColor(Theme.cyberMagenta)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("\(book.durationText) · \(book.chapterCountText)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)

                if !book.description.isEmpty {
                    Button(action: { withAnimation { isDescriptionExpanded.toggle() } }) {
                        Text(book.description)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.tertiaryText)
                            .lineLimit(isDescriptionExpanded ? nil : 3)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.top, 4)
                    .accessibilityLabel("Description")
                    .accessibilityHint(isDescriptionExpanded ? "Tap to collapse" : "Tap to expand")
                }
            }
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title) by \(book.displayAuthors), \(book.durationText), \(book.numSections) chapters")
    }

    private var coverArt: some View {
        Group {
            if let url = book.coverURL {
                CachedAsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    coverPlaceholder
                }
            } else if !viewModel.currentChaptersCoverUrl.isEmpty,
                      let url = URL(string: viewModel.currentChaptersCoverUrl) {
                CachedAsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    coverPlaceholder
                }
            } else {
                coverPlaceholder
            }
        }
        .frame(width: 180, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.md))
        .shadow(color: Theme.cyberMagenta.opacity(0.2), radius: 20, y: 10)
    }

    private var coverPlaceholder: some View {
        ZStack {
            Theme.cyberSurface
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundColor(Theme.cyberMagenta.opacity(0.4))
        }
    }

    // MARK: - Library Button

    private var libraryButton: some View {
        let inLibrary = library.isInLibrary(book)
        return Button(action: {
            HapticManager.medium()
            if inLibrary {
                library.removeBook(book)
            } else {
                library.addBook(book)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: inLibrary ? "minus.circle" : "plus.circle")
                Text(inLibrary ? "Remove from Library" : "Add to Library")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            .foregroundColor(inLibrary ? .red : Theme.cyberCyan)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Theme.cyberSurface)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                inLibrary ? Color.red.opacity(0.4) : Theme.cyberCyan.opacity(0.4),
                                lineWidth: 1
                            )
                    )
            )
        }
        .padding(.top, 16)
        .accessibilityLabel(inLibrary ? "Remove from Library" : "Add to Library")
        .accessibilityHint(inLibrary ? "Removes this audiobook from your library" : "Adds this audiobook to your library")
    }

    // MARK: - Continue Reading

    @ViewBuilder
    private var continueReadingButton: some View {
        if let libraryBook = library.getLibraryBook(for: book),
           libraryBook.currentChapterIndex > 0 || libraryBook.chaptersCompleted > 0 {
            let chapterIndex = libraryBook.currentChapterIndex
            Button(action: {
                HapticManager.medium()
                if chapterIndex < viewModel.currentChapters.count {
                    viewModel.playChapter(viewModel.currentChapters[chapterIndex], from: book)
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "book.fill")
                    Text("Continue · Chapter \(chapterIndex + 1)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(Theme.cyberCyan))
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)
            .accessibilityLabel("Continue reading at chapter \(chapterIndex + 1)")
            .accessibilityHint("Resumes playback from your saved position")
        }
    }

    // MARK: - Chapter List

    private var chaptersList: some View {
        LazyVStack(spacing: 0) {
            if viewModel.isLoadingChapters {
                ForEach(0..<5, id: \.self) { _ in
                    chapterShimmer
                }
            } else if viewModel.currentChapters.isEmpty && viewModel.errorMessage != nil {
                VStack(spacing: 16) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 36))
                        .foregroundColor(Theme.cyberDim)
                    Text("Failed to load chapters")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.tertiaryText)
                    Button(action: {
                        viewModel.loadChapters(for: book)
                    }) {
                        Text("RETRY")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Theme.cyberCyan))
                    }
                    .accessibilityLabel("Retry loading chapters")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if viewModel.currentChapters.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 36))
                        .foregroundColor(Theme.cyberDim)
                    Text("No chapters available")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.tertiaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                HStack {
                    Text("CHAPTERS")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.cyberDim)
                    Spacer()
                    Text("\(viewModel.currentChapters.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.cyberCyan)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                ForEach(viewModel.currentChapters) { chapter in
                    AudiobookChapterRow(
                        chapter: chapter,
                        bookId: book.id
                    ) {
                        viewModel.playChapter(chapter, from: book)
                    }
                    .padding(.horizontal, 20)

                    Divider()
                        .background(Theme.cyberDim.opacity(0.2))
                        .padding(.horizontal, 20)
                }
            }
        }
    }

    private var chapterShimmer: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Theme.cyberDim.opacity(0.15))
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.cyberDim.opacity(0.15))
                    .frame(height: 14)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.cyberDim.opacity(0.1))
                    .frame(width: 80, height: 10)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .shimmer()
    }
}

// MARK: - Chapter Row

struct AudiobookChapterRow: View {
    let chapter: AudiobookChapter
    let bookId: String
    let onPlay: () -> Void

    private var savedPosition: Double {
        UserDefaults.standard.double(forKey: "audiobook_position_\(chapter.guid)")
    }

    private var hasProgress: Bool {
        savedPosition > 0 && chapter.durationSeconds > 0
    }

    private var progressFraction: Double {
        guard chapter.durationSeconds > 0 else { return 0 }
        return min(savedPosition / Double(chapter.durationSeconds), 1.0)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(chapter.chapterNumber)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(Theme.cyberCyan)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.cyberSurface))

            VStack(alignment: .leading, spacing: 4) {
                Text(chapter.displayTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(2)

                Text(chapter.durationText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.cyberDim)

                if hasProgress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Theme.cyberDim.opacity(0.2))
                            Capsule()
                                .fill(Theme.cyberMagenta)
                                .frame(width: geo.size.width * progressFraction)
                                .animation(.easeIn(duration: 0.3), value: progressFraction)
                        }
                    }
                    .frame(height: 3)
                    .padding(.top, 2)
                }
            }

            Spacer()

            Button(action: {
                HapticManager.light()
                onPlay()
            }) {
                Image(systemName: "play.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.cyberMagenta)
                    .contentShape(Circle().inset(by: -6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play chapter \(chapter.chapterNumber)")
            .accessibilityHint("Plays \(chapter.displayTitle)")
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chapter \(chapter.chapterNumber), \(chapter.displayTitle), \(chapter.durationText)")
        .accessibilityHint("Double tap to play chapter")
    }
}
