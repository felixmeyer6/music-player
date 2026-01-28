//
//  TrackSorting.swift
//  Cosmos Music Player
//
//  Centralized track sorting helper
//

import Foundation

/// Unified sort options for track lists (4 options)
enum TrackSortOption: String, CaseIterable {
    case defaultOrder
    case rating
    case playCount
    case date

    var localizedString: String {
        switch self {
        case .defaultOrder: return "Default"
        case .rating: return "Rating"
        case .playCount: return "Play Count"
        case .date: return "Date Added"
        }
    }
}

/// Centralized track sorting helper
struct TrackSorting {
    /// Sort tracks based on the given option
    /// - Parameters:
    ///   - tracks: The tracks to sort
    ///   - option: The sort option
    ///   - isPlaylist: If true, defaultOrder means manual order; if false, means A-Z by title
    /// - Returns: Sorted array of tracks
    static func sort(_ tracks: [Track], by option: TrackSortOption, isPlaylist: Bool = false) -> [Track] {
        switch option {
        case .defaultOrder:
            if isPlaylist {
                // Playlists: keep manual order (tracks are already in position order)
                return tracks
            } else {
                // Non-playlists: sort alphabetically A-Z by title
                return tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            }
        case .rating:
            // Highest rating first (nil/0 ratings go to the end)
            return tracks.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case .playCount:
            // Most played first
            return tracks.sorted { $0.playCount > $1.playCount }
        case .date:
            // Newest first (using id as proxy for insertion date)
            return tracks.sorted { ($0.id ?? 0) > ($1.id ?? 0) }
        }
    }
}
