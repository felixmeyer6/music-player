import SwiftUI
import GRDB

// Album detail view using CollectionDetailView
struct AlbumDetailScreen: View {
    let album: Album
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var playerEngine = PlayerEngine.shared
    @State private var artworkImage: UIImage?
    @State private var albumTracks: [Track] = []
    @State private var albumLookup: [Int64: String] = [:]
    @State private var artistLookup: [Int64: String] = [:]
    @State private var filterState = TrackFilterState()

    // 1. Sort State (Removed showSortPopover as Menu handles this automatically)
    @State private var sortOption: TrackSortOption = .defaultOrder

    private var canShowFilterButton: Bool {
        !albumTracks.isEmpty
    }

    // 2. Filter available options (Exclude .album since we are in an album)
    private var availableSortOptions: [TrackSortOption] {
        TrackSortOption.allCases.filter { $0 != .album }
    }

    // 3. Sorting Logic
    private var sortedTracks: [Track] {
        TrackSorting.sort(albumTracks, by: sortOption, isPlaylist: false)
    }

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .albumDetail)

            CollectionDetailView(
                title: album.name,
                subtitle: Localized.songsCount(albumTracks.count),
                artwork: artworkImage,
                displayTracks: sortedTracks,
                sortOptions: availableSortOptions,
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
                artistLookup: artistLookup,
                filterState: filterState,
                filterConfig: TrackFilterConfiguration(showAlbum: false)
            )
            .padding(.bottom, playerEngine.currentTrack != nil ? 5 : 0)
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(CollectionDetailToolbar(
            hasFilterOptions: canShowFilterButton,
            filterState: filterState,
            sortOption: $sortOption,
            sortOptions: availableSortOptions,
            onSortChanged: saveSortPreference,
            isEditMode: .constant(false)
        ))
        .onAppear {
            loadAlbumTracks()
            loadAlbumArtwork()
            loadSortPreference()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
            loadAlbumTracks()
        }
    }

    private func loadAlbumTracks() {
        guard let albumId = album.id else { return }
        do {
            albumTracks = try DatabaseManager.shared.getTracksByAlbumId(albumId)
            loadAlbumLookup()
            loadArtistLookup()
        } catch {
            print("Failed to load album tracks: \(error)")
        }
    }

    private func loadAlbumLookup() {
        do {
            albumLookup = try DatabaseManager.shared.getAlbumLookup()
        } catch {
            print("Failed to load album lookup: \(error)")
        }
    }

    private func loadArtistLookup() {
        let artistIds = Set(albumTracks.compactMap { $0.artistId })
        guard !artistIds.isEmpty else {
            artistLookup = [:]
            return
        }
        Task.detached(priority: .userInitiated) {
            let lookup = (try? DatabaseManager.shared.getArtistLookup(for: artistIds)) ?? [:]
            await MainActor.run {
                artistLookup = lookup
            }
        }
    }

    private func loadAlbumArtwork() {
        guard let first = albumTracks.first else { return }
        Task {
            let image = await ArtworkManager.shared.getArtwork(for: first)
            await MainActor.run {
                artworkImage = image
            }
        }
    }

    private var sortStore: SortPreferenceStore {
        SortPreferenceStore(keyPrefix: "album", entityId: "\(album.id ?? 0)")
    }

    private func loadSortPreference() {
        if let saved = sortStore.load() { sortOption = saved }
    }

    private func saveSortPreference() {
        sortStore.save(sortOption)
    }
}

struct ArtistDetailScreenWrapper: View {
    let artistName: String
    let allTracks: [Track]
    @State private var artist: Artist?

    var body: some View {
        Group {
            if let artist {
                ArtistDetailScreen(artist: artist, allTracks: allTracks)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(Localized.loadingArtist)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: loadArtist)
    }

    private func loadArtist() {
        do {
            artist = try DatabaseManager.shared.read { db in
                try Artist.filter(Column("name") == artistName).fetchOne(db)
            } ?? Artist(id: nil, name: artistName)
        } catch {
            print("Failed to load artist: \(error)")
            artist = Artist(id: nil, name: artistName)
        }
    }
}
