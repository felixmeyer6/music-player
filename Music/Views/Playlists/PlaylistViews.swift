import SwiftUI
import UIKit

struct PlaylistDetailScreen: View {
    let playlist: Playlist
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var playerEngine = PlayerEngine.shared
    @State private var tracks: [Track] = []
    @State private var isEditMode: Bool = false
    @State private var sortOption: TrackSortOption = .defaultOrder
    @State private var artworkImage: UIImage?
    @State private var albumLookup: [Int64: String] = [:]
    @State private var filterState = TrackFilterState()

    private var sortedTracks: [Track] {
        TrackSorting.sort(tracks, by: sortOption, isPlaylist: true)
    }

    private var hasFilterOptions: Bool {
        TrackFiltering.hasFilterOptions(tracks: sortedTracks, albumLookup: albumLookup)
    }

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .playlistDetail)

            CollectionDetailView(
                title: playlist.title,
                subtitle: Localized.songsCountOnly(tracks.count),
                artwork: artworkImage,
                displayTracks: sortedTracks,
                sortOptions: TrackSortOption.allCases,
                selectedSort: sortOption,
                onSelectSort: { newSort in
                    sortOption = newSort
                    saveSortPreference()
                },
                onPlay: { tracks in
                    if let first = tracks.first {
                        Task {
                            if let playlistId = playlist.id {
                                try? appCoordinator.updatePlaylistAccessed(playlistId: playlistId)
                                try? appCoordinator.updatePlaylistLastPlayed(playlistId: playlistId)
                            }
                            await playerEngine.playTrack(first, queue: tracks)
                        }
                    }
                },
                onShuffle: { tracks in
                    Task {
                        await playerEngine.shuffleAndPlay(tracks) {
                            if let playlistId = playlist.id {
                                try? appCoordinator.updatePlaylistAccessed(playlistId: playlistId)
                                try? appCoordinator.updatePlaylistLastPlayed(playlistId: playlistId)
                            }
                        }
                    }
                },
                onTrackTap: { track, queue in
                    Task {
                        if let playlistId = playlist.id {
                            try? appCoordinator.updatePlaylistAccessed(playlistId: playlistId)
                            try? appCoordinator.updatePlaylistLastPlayed(playlistId: playlistId)
                        }
                        await playerEngine.playTrack(track, queue: queue)
                    }
                },
                onPlayNext: { track in playerEngine.insertNext(track) },
                onAddToQueue: { track in playerEngine.addToQueue(track) },
                playlist: playlist,
                activeTrackId: playerEngine.currentTrack?.stableId,
                isAudioPlaying: playerEngine.isPlaying,
                isEditMode: isEditMode,
                onDelete: { track in
                    removeFromPlaylist(track)
                },
                onMove: sortOption == .defaultOrder ? { source, dest in
                    reorderPlaylistItems(from: source, to: dest)
                } : nil,
                albumLookup: albumLookup,
                filterState: filterState
            )
            .padding(.bottom, playerEngine.currentTrack != nil ? 5 : 0)
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(CollectionDetailToolbar(
            hasFilterOptions: hasFilterOptions,
            filterState: filterState,
            sortOption: $sortOption,
            onSortChanged: saveSortPreference,
            showEditButton: true,
            isEditMode: $isEditMode,
            tracksEmpty: tracks.isEmpty
        ))
        .onAppear {
            loadPlaylistTracks()
            loadSortPreference()
            loadArtwork()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
            loadPlaylistTracks()
            loadArtwork()
        }
    }

    private func loadPlaylistTracks() {
        guard let playlistId = playlist.id else { return }
        do {
            tracks = try DatabaseManager.shared.getPlaylistTracks(playlistId: playlistId)
            loadAlbumLookup()
        } catch {
            print("Failed to load playlist tracks: \(error)")
        }
    }

    private func loadAlbumLookup() {
        do {
            albumLookup = try DatabaseManager.shared.getAlbumLookup()
        } catch {
            print("Failed to load album lookup: \(error)")
        }
    }

    private func loadArtwork() {
        guard let firstTrack = tracks.first else { return }
        Task {
            let image = await ArtworkManager.shared.getArtwork(for: firstTrack)
            await MainActor.run {
                artworkImage = image
            }
        }
    }

    private func removeFromPlaylist(_ track: Track) {
        guard let playlistId = playlist.id else { return }
        do {
            try appCoordinator.removeFromPlaylist(
                playlistId: playlistId,
                trackStableId: track.stableId
            )
            loadPlaylistTracks()
        } catch {
            print("Failed to remove track from playlist: \(error)")
        }
    }

    private func reorderPlaylistItems(from source: IndexSet, to destination: Int) {
        guard let playlistId = playlist.id else { return }
        do {
            let sourceIndex = source.first ?? 0
            let destinationIndex = sourceIndex < destination ? destination - 1 : destination
            try appCoordinator.reorderPlaylistItems(
                playlistId: playlistId,
                from: sourceIndex,
                to: destinationIndex
            )
            loadPlaylistTracks()
        } catch {
            print("Failed to reorder tracks: \(error)")
        }
    }

    private var sortStore: SortPreferenceStore {
        SortPreferenceStore(keyPrefix: "playlist", entityId: "\(playlist.id ?? 0)")
    }

    private func loadSortPreference() {
        if let saved = sortStore.load() { sortOption = saved }
    }

    private func saveSortPreference() {
        sortStore.save(sortOption)
    }
}

struct PlaylistSelectionView: View {
    let track: Track

    var body: some View {
        AddToPlaylistView(
            trackIds: [track.stableId],
            onComplete: nil,
            showTrackCount: false
        )
    }
}
