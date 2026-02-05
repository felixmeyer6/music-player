import SwiftUI

struct ArtistDetailScreen: View {
    let artist: Artist
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var playerEngine = PlayerEngine.shared
    @State private var sortOption: TrackSortOption = .defaultOrder
    @State private var artworkImage: UIImage?
    @State private var albumLookup: [Int64: String] = [:]
    @State private var filterState = TrackFilterState()

    private var artistTracks: [Track] {
        allTracks.filter { $0.artistId == artist.id }
    }

    private var sortedTracks: [Track] {
        TrackSorting.sort(artistTracks, by: sortOption, isPlaylist: false)
    }

    private var canShowFilterButton: Bool {
        !sortedTracks.isEmpty
    }

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .artistDetail)

            CollectionDetailView(
                title: artist.name,
                subtitle: Localized.songsCountOnly(artistTracks.count),
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
                        Task { await playerEngine.playTrack(first, queue: tracks) }
                    }
                },
                onShuffle: { tracks in
                    Task { await playerEngine.shuffleAndPlay(tracks) }
                },
                onTrackTap: { track, queue in
                    Task { await playerEngine.playTrack(track, queue: queue) }
                },
                onPlayNext: { track in playerEngine.insertNext(track) },
                onAddToQueue: { track in playerEngine.addToQueue(track) },
                playlist: nil,
                activeTrackId: playerEngine.currentTrack?.stableId,
                isAudioPlaying: playerEngine.isPlaying,
                albumLookup: albumLookup,
                filterState: filterState
            )
            .padding(.bottom, playerEngine.currentTrack != nil ? 5 : 0)
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(CollectionDetailToolbar(
            hasFilterOptions: canShowFilterButton,
            filterState: filterState,
            sortOption: $sortOption,
            onSortChanged: saveSortPreference,
            isEditMode: .constant(false)
        ))
        .onAppear {
            loadArtwork()
            loadSortPreference()
            loadAlbumLookup()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
            loadArtwork()
            loadAlbumLookup()
        }
    }

    private func loadArtwork() {
        guard let firstTrack = artistTracks.first else { return }
        Task {
            let image = await ArtworkManager.shared.getArtwork(for: firstTrack)
            await MainActor.run {
                artworkImage = image
            }
        }
    }

    private func loadAlbumLookup() {
        do {
            albumLookup = try DatabaseManager.shared.getAlbumLookup()
        } catch {
            print("Failed to load album lookup: \(error)")
        }
    }

    private var sortStore: SortPreferenceStore {
        SortPreferenceStore(keyPrefix: "artist", entityId: "\(artist.id ?? 0)")
    }

    private func loadSortPreference() {
        if let saved = sortStore.load() { sortOption = saved }
    }

    private func saveSortPreference() {
        sortStore.save(sortOption)
    }
}
