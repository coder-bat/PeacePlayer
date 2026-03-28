import Foundation

struct PodcastShow: Identifiable, Codable, Equatable {
    let collectionId: Int
    let collectionName: String
    let artistName: String
    let artworkUrl600: String
    let feedUrl: String
    let genres: [String]
    let trackCount: Int
    let releaseDate: String
    
    var id: Int { collectionId }
    
    var artworkURL: URL? { URL(string: artworkUrl600) }
    
    var displayGenres: String {
        genres.prefix(3).joined(separator: " · ")
    }
}

struct PodcastEpisode: Identifiable, Codable, Equatable {
    let guid: String
    let title: String
    let description: String
    let audioUrl: String
    let durationSeconds: Int
    let pubDate: String
    let artworkUrl: String?
    
    var id: String { guid }
    
    var audioURL: URL? { URL(string: audioUrl) }
    var artworkURL: URL? { artworkUrl.flatMap { URL(string: $0) } }
    
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
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            formatter.dateFormat = fmt
            if let date = formatter.date(from: pubDate) {
                let display = DateFormatter()
                display.dateStyle = .medium
                display.timeStyle = .none
                return display.string(from: date)
            }
        }
        return pubDate
    }
}
