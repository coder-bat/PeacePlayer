import Foundation

struct Audiobook: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let title: String
    let description: String
    let authors: [String]
    let language: String
    let totalTime: String
    let totalTimeSecs: Int
    let numSections: Int
    let rssUrl: String
    let coverUrl: String
    let urlLibrivox: String
    
    var coverURL: URL? {
        coverUrl.isEmpty ? nil : URL(string: coverUrl)
    }
    
    var rssURL: URL? { URL(string: rssUrl) }
    
    var displayAuthors: String {
        authors.isEmpty ? "Unknown Author" : authors.joined(separator: ", ")
    }
    
    var durationText: String {
        if totalTimeSecs > 0 {
            let hours = totalTimeSecs / 3600
            let minutes = (totalTimeSecs % 3600) / 60
            return "\(hours)h \(minutes)m"
        }
        return totalTime
    }
    
    var chapterCountText: String {
        "\(numSections) chapters"
    }
}

struct AudiobookChapter: Identifiable, Codable, Equatable, Hashable {
    let guid: String
    let title: String
    let chapterNumber: Int
    let audioUrl: String
    let durationSeconds: Int
    
    var id: String { guid }
    
    var audioURL: URL? { URL(string: audioUrl) }
    
    var durationText: String {
        if durationSeconds <= 0 { return "" }
        let hours = durationSeconds / 3600
        let minutes = (durationSeconds % 3600) / 60
        let seconds = durationSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var displayTitle: String {
        title.isEmpty ? "Chapter \(chapterNumber)" : title
    }
}

struct LibraryBook: Identifiable, Codable, Equatable {
    let audiobook: Audiobook
    var currentChapterIndex: Int
    var chaptersCompleted: Int
    var lastPlayedDate: Date
    let addedDate: Date
    
    var id: String { audiobook.id }
    
    var progress: Double {
        Double(chaptersCompleted) / Double(max(audiobook.numSections, 1))
    }
    
    var progressText: String {
        "\(chaptersCompleted)/\(audiobook.numSections) chapters"
    }
    
    var isComplete: Bool {
        chaptersCompleted >= audiobook.numSections
    }
}
