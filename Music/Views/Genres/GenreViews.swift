import SwiftUI
import UIKit

struct GenresScreen: View {
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var genres: [GenreSummary] = []

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .genres)

            VStack {
                if genres.isEmpty {
                    EmptyGenresView()
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 20),
                                GridItem(.flexible())
                            ],
                            spacing: 16
                        ) {
                            ForEach(genres, id: \.name) { genre in
                                NavigationLink {
                                    GenreDetailScreen(genreName: genre.name)
                                } label: {
                                    GenreCardView(genre: genre)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 100) // Add padding for mini player
                    }
                }
            }
            .navigationTitle(Localized.genre)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: loadGenres)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LibraryNeedsRefresh"))) { _ in
                loadGenres()
            }
        }
    }

    private func loadGenres() {
        do {
            genres = try appCoordinator.databaseManager.getAllGenres()
        } catch {
            print("Failed to load genres: \(error)")
        }
    }
}

private struct EmptyGenresView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.quarternote.3")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(Localized.noGenresFound)
                .font(.headline)
            Text(Localized.genresWillAppear)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GenreCardView: View {
    let genre: GenreSummary
    @State private var artworkImage: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.15))
                    .overlay {
                        if let image = artworkImage {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geometry.size.width, height: geometry.size.width)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                        }
                    }
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 4) {
                Text(genre.name)
                    .font(.headline)
                    .lineLimit(2)

                Text(Localized.songsCount(genre.trackCount))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .task {
            if artworkImage == nil {
                loadGenreArtwork()
            }
        }
    }

    private func loadGenreArtwork() {
        Task {
            do {
                guard let firstTrack = try DatabaseManager.shared.getFirstTrackByGenre(genre.name) else { return }
                let image = await ArtworkManager.shared.getArtwork(for: firstTrack)
                await MainActor.run {
                    artworkImage = image
                }
            } catch {
                print("Failed to load genre artwork: \(error)")
            }
        }
    }
}

struct GenreDetailScreen: View {
    let genreName: String
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var playerEngine = PlayerEngine.shared
    @State private var tracks: [Track] = []
    @State private var sortOption: TrackSortOption = .defaultOrder
    @State private var artworkImage: UIImage?

    private var sortedTracks: [Track] {
        TrackSorting.sort(tracks, by: sortOption, isPlaylist: false)
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
                    let shuffled = tracks.shuffled()
                    if let first = shuffled.first {
                        Task { await playerEngine.playTrack(first, queue: shuffled) }
                    }
                },
                onTrackTap: { track, queue in
                    Task { await playerEngine.playTrack(track, queue: queue) }
                },
                onPlayNext: { track in playerEngine.insertNext(track) },
                onAddToQueue: { track in playerEngine.addToQueue(track) },
                playlist: nil,
                activeTrackId: playerEngine.currentTrack?.stableId,
                isAudioPlaying: playerEngine.isPlaying
            )
            .padding(.bottom, 90)
        }
        .navigationTitle(genreName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    ForEach(TrackSortOption.allCases, id: \.self) { option in
                        Button {
                            sortOption = option
                            saveSortPreference()
                        } label: {
                            HStack {
                                Text(option.localizedString)
                                if sortOption == option {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundColor(.white)
                }
            }
        }
        .onAppear {
            loadTracks()
            loadSortPreference()
            loadArtwork()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LibraryNeedsRefresh"))) { _ in
            loadTracks()
            loadArtwork()
        }
    }

    private func loadTracks() {
        do {
            tracks = try appCoordinator.databaseManager.getTracksByGenre(genreName)
        } catch {
            print("Failed to load genre tracks: \(error)")
        }
    }

    private func loadArtwork() {
        Task {
            do {
                guard let firstTrack = try appCoordinator.databaseManager.getFirstTrackByGenre(genreName) else { return }
                let image = await ArtworkManager.shared.getArtwork(for: firstTrack)
                await MainActor.run {
                    artworkImage = image
                }
            } catch {
                print("Failed to load genre artwork: \(error)")
            }
        }
    }

    private func sortPreferenceKey() -> String {
        "sortPreference_genre_\(genreName.lowercased())"
    }

    private func loadSortPreference() {
        let key = sortPreferenceKey()
        if let savedRawValue = UserDefaults.standard.string(forKey: key),
           let saved = TrackSortOption(rawValue: savedRawValue) {
            sortOption = saved
        }
    }

    private func saveSortPreference() {
        UserDefaults.standard.set(sortOption.rawValue, forKey: sortPreferenceKey())
    }
}
