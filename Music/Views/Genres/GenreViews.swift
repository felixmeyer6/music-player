import SwiftUI
import UIKit

struct GenreDetailScreen: View {
    let genreName: String
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var playerEngine = PlayerEngine.shared
    @State private var tracks: [Track] = []
    @State private var sortOption: TrackSortOption = .defaultOrder
    @State private var artworkImage: UIImage?
    @State private var albumLookup: [Int64: String] = [:]
    @State private var filterState = TrackFilterState()

    private var sortedTracks: [Track] {
        TrackSorting.sort(tracks, by: sortOption, isPlaylist: false)
    }

    private var canShowFilterButton: Bool {
        !tracks.isEmpty
    }

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .genreDetail)

            CollectionDetailView(
                title: genreName,
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
                filterState: filterState,
                filterConfig: TrackFilterConfiguration(showGenre: false)
            )
            .padding(.bottom, playerEngine.currentTrack != nil ? 5 : 0)
        }
        .navigationTitle(genreName)
        .navigationBarTitleDisplayMode(.inline)
        .modifier(CollectionDetailToolbar(
            hasFilterOptions: canShowFilterButton,
            filterState: filterState,
            sortOption: $sortOption,
            onSortChanged: saveSortPreference,
            isEditMode: .constant(false)
        ))
        .onAppear {
            loadTracks()
            loadSortPreference()
            loadArtwork()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
            loadTracks()
            loadArtwork()
        }
    }

    private func loadTracks() {
        do {
            tracks = try DatabaseManager.shared.getTracksByGenre(genreName)
            loadAlbumLookup()
        } catch {
            print("Failed to load genre tracks: \(error)")
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
        Task {
            do {
                guard let firstTrack = try DatabaseManager.shared.getFirstTrackByGenre(genreName) else { return }
                let image = await ArtworkManager.shared.getArtwork(for: firstTrack)
                await MainActor.run {
                    artworkImage = image
                }
            } catch {
                print("Failed to load genre artwork: \(error)")
            }
        }
    }

    private var sortStore: SortPreferenceStore {
        SortPreferenceStore(keyPrefix: "genre", entityId: genreName.lowercased())
    }

    private func loadSortPreference() {
        if let saved = sortStore.load() { sortOption = saved }
    }

    private func saveSortPreference() {
        sortStore.save(sortOption)
    }
}
