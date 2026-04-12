import Foundation
import Combine

class AudiobookLibrary: ObservableObject {
    static let shared = AudiobookLibrary()

    @Published var books: [LibraryBook] = []

    private let storageKey = "audiobookLibrary"

    private init() {
        loadLibrary()
    }

    // MARK: - Library Management

    func addBook(_ audiobook: Audiobook) {
        guard !books.contains(where: { $0.audiobook.id == audiobook.id }) else { return }
        let libraryBook = LibraryBook(
            audiobook: audiobook,
            currentChapterIndex: 0,
            chaptersCompleted: 0,
            lastPlayedDate: Date(),
            addedDate: Date()
        )
        books.insert(libraryBook, at: 0)
        saveLibrary()
    }

    func removeBook(_ audiobook: Audiobook) {
        books.removeAll { $0.audiobook.id == audiobook.id }
        saveLibrary()
    }

    func isInLibrary(_ audiobook: Audiobook) -> Bool {
        books.contains { $0.audiobook.id == audiobook.id }
    }

    func updateProgress(bookId: String, chapterIndex: Int, chaptersCompleted: Int) {
        guard let index = books.firstIndex(where: { $0.audiobook.id == bookId }) else { return }
        books[index].currentChapterIndex = chapterIndex
        books[index].chaptersCompleted = chaptersCompleted
        books[index].lastPlayedDate = Date()
        // Move to front (most recently played)
        let book = books.remove(at: index)
        books.insert(book, at: 0)
        saveLibrary()
    }

    func getLibraryBook(for audiobook: Audiobook) -> LibraryBook? {
        books.first { $0.audiobook.id == audiobook.id }
    }

    // MARK: - Persistence

    private func saveLibrary() {
        if let data = try? JSONEncoder().encode(books) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadLibrary() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let savedBooks = try? JSONDecoder().decode([LibraryBook].self, from: data) else { return }
        books = savedBooks
    }
}
