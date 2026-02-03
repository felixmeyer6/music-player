//
//  TrackSorting.swift
//  Cosmos Music Player
//
//  Centralized track sorting helper
//

import Foundation
import SwiftUI
import GRDB

/// Unified sort options for track lists
enum TrackSortOption: String, CaseIterable {
    case defaultOrder
    case rating
    case playCount
    case genre
    case album
    case artist
    case date

    var localizedString: String {
        switch self {
        case .defaultOrder: return "Default"
        case .rating: return "Rating"
        case .playCount: return "Plays"
        case .genre: return "Genre"
        case .album: return "Album"
        case .artist: return "Artist"
        case .date: return "Date"
        }
    }

    var iconName: String {
        switch self {
        case .defaultOrder: return "line.3.horizontal"
        case .rating: return "star"
        case .playCount: return "play"
        case .genre: return "music.quarternote.3"
        case .album: return "rectangle.stack"
        case .artist: return "person"
        case .date: return "calendar"
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
        case .genre:
            // Alphabetically by genre name
            return tracks.sorted { ($0.genre ?? "").localizedCaseInsensitiveCompare($1.genre ?? "") == .orderedAscending }
        case .album:
            // Alphabetically by album title
            let albumNames = fetchAlbumNames(for: tracks)
            return tracks.sorted {
                let name1 = albumNames[$0.albumId ?? -1] ?? ""
                let name2 = albumNames[$1.albumId ?? -1] ?? ""
                return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
            }
        case .artist:
            // Alphabetically by artist name
            let artistNames = fetchArtistNames(for: tracks)
            return tracks.sorted {
                let name1 = artistNames[$0.artistId ?? -1] ?? ""
                let name2 = artistNames[$1.artistId ?? -1] ?? ""
                return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
            }
        case .date:
            // Newest first (using id as proxy for insertion date)
            return tracks.sorted { ($0.id ?? 0) > ($1.id ?? 0) }
        }
    }

    /// Fetch album names for a set of tracks (batch lookup for efficiency)
    private static func fetchAlbumNames(for tracks: [Track]) -> [Int64: String] {
        let albumIds = Set(tracks.compactMap { $0.albumId })
        guard !albumIds.isEmpty else { return [:] }

        var result: [Int64: String] = [:]
        do {
            try DatabaseManager.shared.read { db in
                let albums = try Album.filter(albumIds.contains(Column("id"))).fetchAll(db)
                for album in albums {
                    if let id = album.id {
                        result[id] = album.name
                    }
                }
            }
        } catch {
            print("⚠️ Failed to fetch album names for sorting: \(error)")
        }
        return result
    }

    /// Fetch artist names for a set of tracks (batch lookup for efficiency)
    private static func fetchArtistNames(for tracks: [Track]) -> [Int64: String] {
        let artistIds = Set(tracks.compactMap { $0.artistId })
        guard !artistIds.isEmpty else { return [:] }

        var result: [Int64: String] = [:]
        do {
            try DatabaseManager.shared.read { db in
                let artists = try Artist.filter(artistIds.contains(Column("id"))).fetchAll(db)
                for artist in artists {
                    if let id = artist.id {
                        result[id] = artist.name
                    }
                }
            }
        } catch {
            print("⚠️ Failed to fetch artist names for sorting: \(error)")
        }
        return result
    }
}

// MARK: - Sort Menu View
struct SortMenuView: View {
    @Binding var selection: TrackSortOption
    var options: [TrackSortOption] = TrackSortOption.allCases
    var onSelectionChanged: (() -> Void)? = nil

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Label(option.localizedString, systemImage: option.iconName)
                        .tag(option)
                }
            } label: {}
            .pickerStyle(.inline)
            .fixedSize(horizontal: true, vertical: false)
            .onChange(of: selection) { onSelectionChanged?() }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .foregroundColor(.white)
        }
    }
}
