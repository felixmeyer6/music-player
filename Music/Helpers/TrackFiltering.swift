//
//  TrackFiltering.swift
//  Cosmos Music Player
//
//  Track filtering logic for Genre, Album, and Rating filters
//

import Foundation
import SwiftUI

// MARK: - Filter State

@Observable
class TrackFilterState {
    var isFilterVisible: Bool = false
    var selectedGenres: Set<String> = []
    var selectedAlbums: Set<Int64> = []
    var selectedRatings: Set<Int> = []

    private var filterHiddenAt: Date? = nil
    private let filterResetDelay: TimeInterval = 10.0

    func toggleFilter() {
        if isFilterVisible {
            // Hiding filter - record timestamp
            filterHiddenAt = Date()
            isFilterVisible = false
        } else {
            // Showing filter - check if we need to reset
            if let hiddenAt = filterHiddenAt,
               Date().timeIntervalSince(hiddenAt) > filterResetDelay {
                // More than 10 seconds passed, reset selections
                resetFilters()
            }
            isFilterVisible = true
        }
    }

    func resetFilters() {
        selectedGenres.removeAll()
        selectedAlbums.removeAll()
        selectedRatings.removeAll()
    }

    var hasActiveFilters: Bool {
        !selectedGenres.isEmpty || !selectedAlbums.isEmpty || !selectedRatings.isEmpty
    }
}

// MARK: - Filter Configuration

struct TrackFilterConfiguration {
    var showGenre: Bool = true
    var showAlbum: Bool = true
    var showRating: Bool = true

    static let all = TrackFilterConfiguration()
}

// MARK: - Track Filtering

struct TrackFiltering {

    /// Extracts available filter options from tracks
    static func availableGenres(from tracks: [Track]) -> [String] {
        Array(Set(tracks.compactMap { $0.genre?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })).sorted()
    }

    static func availableAlbums(from tracks: [Track], albumLookup: [Int64: String]) -> [(id: Int64, title: String)] {
        let albumIds = Set(tracks.compactMap { $0.albumId })
        return albumIds.compactMap { id in
            guard let title = albumLookup[id] else { return nil }
            return (id: id, title: title)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func availableRatings(from tracks: [Track]) -> [Int] {
        Array(Set(tracks.compactMap { $0.rating })).sorted()
    }

    /// Check if there are any filter options available
    static func hasFilterOptions(
        tracks: [Track],
        albumLookup: [Int64: String],
        filterConfig: TrackFilterConfiguration = .all
    ) -> Bool {
        (filterConfig.showGenre && !availableGenres(from: tracks).isEmpty) ||
        (filterConfig.showAlbum && !availableAlbums(from: tracks, albumLookup: albumLookup).isEmpty) ||
        (filterConfig.showRating && !availableRatings(from: tracks).isEmpty)
    }

    /// Filters tracks based on filter state
    /// Returns empty array if filter is visible but no selections made
    static func filter(
        tracks: [Track],
        with state: TrackFilterState,
        albumLookup: [Int64: String],
        filterConfig: TrackFilterConfiguration = .all
    ) -> [Track] {
        guard state.isFilterVisible else { return tracks }

        let hasSelectedGenres = filterConfig.showGenre && !state.selectedGenres.isEmpty
        let hasSelectedAlbums = filterConfig.showAlbum && !state.selectedAlbums.isEmpty
        let hasSelectedRatings = filterConfig.showRating && !state.selectedRatings.isEmpty

        // If no relevant filters selected, show nothing (per requirements)
        if !(hasSelectedGenres || hasSelectedAlbums || hasSelectedRatings) {
            return []
        }

        return tracks.filter { track in
            let genreMatch = !filterConfig.showGenre ||
                state.selectedGenres.isEmpty ||
                (track.genre.map { state.selectedGenres.contains($0) } ?? false)
            let albumMatch = !filterConfig.showAlbum ||
                state.selectedAlbums.isEmpty ||
                (track.albumId.map { state.selectedAlbums.contains($0) } ?? false)
            let ratingMatch = !filterConfig.showRating ||
                state.selectedRatings.isEmpty ||
                (track.rating.map { state.selectedRatings.contains($0) } ?? false)
            return genreMatch && albumMatch && ratingMatch
        }
    }

    /// Converts rating int to star string
    static func ratingString(_ rating: Int) -> String {
        String(repeating: "\u{2605}", count: rating)
    }
}
