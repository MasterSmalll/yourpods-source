import Foundation

struct Chapter: Codable, Identifiable, Hashable {
    var id: Double { startTime }
    
    let startTime: Double  // seconds
    let title: String
    let img: String?       // optional chapter image URL
    let url: String?       // optional link
}
