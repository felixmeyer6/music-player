import SwiftUI
import GRDB
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
    @State private var sortOption: TrackSortOption = .nameAZ
    @State private var recentlyActedTracks: Set<String> = []
    @State private var artworkImage: UIImage?
    private let headerArtworkSize: CGFloat = 140
    private var headerTextTopOffset: CGFloat { headerArtworkSize * 0.15 }

    @ViewBuilder
    private func swipeIcon(systemName: String) -> some View {
        if let icon = UIImage(systemName: systemName)?
            .withTintColor(.black, renderingMode: .alwaysOriginal) {
            Image(uiImage: icon)
        } else {
            Image(systemName: systemName)
                .foregroundColor(.black)
        }
    }

    private var availableSortOptions: [TrackSortOption] {
        TrackSortOption.allCases.filter { $0 != .playlistOrder }
    }

    private func markAsActed(_ trackId: String) {
        recentlyActedTracks.insert(trackId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            recentlyActedTracks.remove(trackId)
        }
    }

    private var sortedTracks: [Track] {
        switch sortOption {
        case .playlistOrder:
            return tracks
        case .dateNewest:
            return tracks.sorted { ($0.id ?? 0) > ($1.id ?? 0) }
        case .dateOldest:
            return tracks.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        case .nameAZ:
            return tracks.sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .nameZA:
            return tracks.sorted { $0.title.lowercased() > $1.title.lowercased() }
        case .artistAZ:
            let artistCache = buildArtistCache(for: tracks)
            return tracks.sorted { track1, track2 in
                let artist1 = artistCache[track1.artistId ?? -1] ?? ""
                let artist2 = artistCache[track2.artistId ?? -1] ?? ""
                return artist1.lowercased() < artist2.lowercased()
            }
        case .artistZA:
            let artistCache = buildArtistCache(for: tracks)
            return tracks.sorted { track1, track2 in
                let artist1 = artistCache[track1.artistId ?? -1] ?? ""
                let artist2 = artistCache[track2.artistId ?? -1] ?? ""
                return artist1.lowercased() > artist2.lowercased()
            }
        case .sizeLargest:
            return tracks.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        case .sizeSmallest:
            return tracks.sorted { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }
        }
    }

    private func buildArtistCache(for tracks: [Track]) -> [Int64: String] {
        let artistIds = Set(tracks.compactMap { $0.artistId })
        var cache: [Int64: String] = [:]

        do {
            try DatabaseManager.shared.read { db in
                let artists = try Artist.filter(artistIds.contains(Column("id"))).fetchAll(db)
                for artist in artists {
                    if let id = artist.id {
                        cache[id] = artist.name
                    }
                }
            }
        } catch {
            print("Failed to build artist cache: \(error)")
        }

        return cache
    }

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .genreDetail)

            List {
                Section {
                    VStack(spacing: 16) {
                        HStack(alignment: .top, spacing: 16) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: headerArtworkSize, height: headerArtworkSize)
                                .overlay {
                                    if let image = artworkImage {
                                        Image(uiImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: headerArtworkSize, height: headerArtworkSize)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    } else {
                                        Image(systemName: "music.note")
                                            .font(.system(size: 40))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)

                            VStack(alignment: .leading, spacing: 6) {
                                Spacer()
                                    .frame(height: headerTextTopOffset)

                                Text(genreName)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .multilineTextAlignment(.leading)

                                Text(Localized.songsCountOnly(tracks.count))
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.leading)

                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 12) {
                            Button {
                                if let first = sortedTracks.first {
                                    Task {
                                        await playerEngine.playTrack(first, queue: sortedTracks)
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text(Localized.play)
                                }
                                .font(.title3.weight(.semibold))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(Color.white)
                                .cornerRadius(28)
                            }

                            Button {
                                guard !sortedTracks.isEmpty else { return }
                                let shuffled = sortedTracks.shuffled()
                                Task {
                                    await playerEngine.playTrack(shuffled[0], queue: shuffled)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "shuffle")
                                    Text(Localized.shuffle)
                                }
                                .font(.title3.weight(.semibold))
                                .foregroundColor(Color.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(28)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .padding(.horizontal)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    HStack {
                        Text(Localized.songs)
                            .font(.title3.weight(.bold))

                        Spacer()

                        Text(Localized.songsCount(sortedTracks.count))
                            .font(.body)
                            .foregroundColor(.secondary)

                        Menu {
                            ForEach(availableSortOptions, id: \.self) { option in
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
                                .foregroundColor(.primary)
                        }
                    }
                    .textCase(nil)
                    .padding(.horizontal, 16)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())

                    if sortedTracks.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "music.note")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text(Localized.noSongsFound)
                                .font(.headline)
                            Text(Localized.yourMusicWillAppearHere)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                    } else {
                        ForEach(sortedTracks, id: \.stableId) { track in
                            TrackRowView(
                                track: track,
                                activeTrackId: playerEngine.currentTrack?.stableId,
                                isAudioPlaying: playerEngine.isPlaying,
                                onTap: {
                                    Task {
                                        await playerEngine.playTrack(track, queue: sortedTracks)
                                    }
                                },
                                playlist: nil,
                                showDirectDeleteButton: false,
                                onEnterBulkMode: nil
                            )
                            .equatable()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial)
                                    .opacity(0.7)
                            )
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if !recentlyActedTracks.contains(track.stableId) {
                                    Button {
                                        playerEngine.insertNext(track)
                                        markAsActed(track.stableId)
                                    } label: {
                                        HStack(spacing: 8) {
                                            swipeIcon(systemName: "text.line.first.and.arrowtriangle.forward")
                                            Text(Localized.playNext)
                                        }
                                        .foregroundColor(.black)
                                    }
                                    .tint(.white)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if !recentlyActedTracks.contains(track.stableId) {
                                    Button {
                                        playerEngine.addToQueue(track)
                                        markAsActed(track.stableId)
                                    } label: {
                                        HStack(spacing: 8) {
                                            swipeIcon(systemName: "text.append")
                                            Text(Localized.addToQueue)
                                        }
                                        .foregroundColor(.black)
                                    }
                                    .tint(.white)
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                        }
                    }
                }
            }
            .listStyle(PlainListStyle())
            .scrollContentBackground(.hidden)
            .padding(.bottom, 90) // Space for mini player
        }
        .navigationTitle(genreName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadTracks()
            loadSortPreference()
            loadGenreArtwork()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LibraryNeedsRefresh"))) { _ in
            loadTracks()
            loadGenreArtwork()
        }
        .task {
            if tracks.isEmpty {
                loadTracks()
            }
            if artworkImage == nil {
                loadGenreArtwork()
            }
        }
    }

    private func loadTracks() {
        do {
            tracks = try appCoordinator.databaseManager.getTracksByGenre(genreName)
        } catch {
            print("Failed to load genre tracks: \(error)")
        }
    }

    private func loadGenreArtwork() {
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
           let saved = TrackSortOption(rawValue: savedRawValue),
           saved != .playlistOrder {
            sortOption = saved
        }
    }

    private func saveSortPreference() {
        UserDefaults.standard.set(sortOption.rawValue, forKey: sortPreferenceKey())
    }
}
