import Foundation

struct RadioStation: Identifiable, Codable, Equatable {
    let stationuuid: String
    let name: String
    let urlResolved: String
    let favicon: String?
    let country: String
    let tags: String
    let codec: String
    let bitrate: Int
    let clickcount: Int
    let votes: Int
    
    var id: String { stationuuid }
    
    var faviconURL: URL? {
        guard let favicon = favicon, !favicon.isEmpty else { return nil }
        return URL(string: favicon)
    }
    
    var tagList: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    
    var bitrateText: String {
        bitrate > 0 ? "\(bitrate) kbps" : ""
    }
    
    var displayCountry: String {
        country.isEmpty ? "" : country
    }
}
