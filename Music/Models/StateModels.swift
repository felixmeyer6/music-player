//  JSON state models for playlists sync

import Foundation

extension Notification.Name {
    static let libraryNeedsRefresh = Notification.Name("LibraryNeedsRefresh")
}

struct PlaylistState: Codable {
    let version: Int
    let slug: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let items: [PlaylistItem]
    
    struct PlaylistItem: Codable {
        let trackId: String
        let addedAt: Date
    }
    
    init(slug: String, title: String, createdAt: Date, items: [(String, Date)]) {
        self.version = 1
        self.slug = slug
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = Date()
        self.items = items.map { PlaylistItem(trackId: $0.0, addedAt: $0.1) }
    }
}
