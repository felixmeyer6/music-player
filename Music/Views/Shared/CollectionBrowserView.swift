import SwiftUI
import UIKit

// MARK: - CollectionType

enum CollectionType {
    case albums, artists, genres, playlists

    var navigationTitle: String {
        switch self {
        case .albums: Localized.albums
        case .artists: Localized.artists
        case .genres: Localized.genre
        case .playlists: Localized.playlists
        }
    }

    var screenType: ScreenType {
        switch self {
        case .albums: .albums
        case .artists: .artists
        case .genres: .genres
        case .playlists: .playlists
        }
    }

    var emptyIcon: String {
        switch self {
        case .albums: "rectangle.stack.fill"
        case .artists: "person.2"
        case .genres: "music.quarternote.3"
        case .playlists: "music.note.list"
        }
    }

    var emptyTitle: String {
        switch self {
        case .albums: Localized.noAlbumsFound
        case .artists: "No artists found"
        case .genres: Localized.noGenresFound
        case .playlists: Localized.noPlaylistsYet
        }
    }

    var emptySubtitle: String {
        switch self {
        case .albums: Localized.albumsWillAppear
        case .artists: "Artists will appear here once you add music to your library"
        case .genres: Localized.genresWillAppear
        case .playlists: Localized.createPlaylistsInstruction
        }
    }

    var isPlaylist: Bool { self == .playlists }
}

// MARK: - Collection Item Wrapper

private struct CollectionItem: Identifiable {
    let id: String
    let name: String
    let tracks: [Track]
    // Source data for navigation
    let album: Album?
    let artist: Artist?
    let genreName: String?
    let playlist: Playlist?
}

// MARK: - CollectionBrowserView

struct CollectionBrowserView: View {
    let type: CollectionType
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var playerEngine = PlayerEngine.shared
    @State private var items: [CollectionItem] = []
    // Playlist-only state
    @State private var isEditMode = false
    @State private var playlistToEdit: Playlist?
    @State private var playlistToDelete: Playlist?
    @State private var showEditDialog = false
    @State private var showDeleteConfirmation = false
    @State private var editPlaylistName = ""
    @State private var showCreateDialog = false
    @State private var newPlaylistName = ""

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: type.screenType)

            VStack {
                if items.isEmpty {
                    emptyView
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: type.isPlaylist ? 8 : 20),
                                GridItem(.flexible(), spacing: type.isPlaylist ? 8 : 0)
                            ],
                            spacing: 16
                        ) {
                            ForEach(items) { item in
                                if type.isPlaylist && isEditMode {
                                    CollectionCardView(
                                        name: item.name,
                                        tracks: item.tracks,
                                        isEditMode: true,
                                        onEdit: {
                                            if let playlist = item.playlist {
                                                playlistToEdit = playlist
                                                editPlaylistName = playlist.title
                                                showEditDialog = true
                                            }
                                        },
                                        onDelete: {
                                            if let playlist = item.playlist {
                                                playlistToDelete = playlist
                                                showDeleteConfirmation = true
                                            }
                                        }
                                    )
                                } else {
                                    NavigationLink {
                                        destinationView(for: item)
                                    } label: {
                                        CollectionCardView(
                                            name: item.name,
                                            tracks: item.tracks,
                                            isEditMode: false,
                                            onEdit: nil,
                                            onDelete: nil
                                        )
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 100)
                    }
                }
            }
            .padding(.bottom, playerEngine.currentTrack != nil ? 5 : 0)
        }
        .navigationTitle(type.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if type.isPlaylist {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            withAnimation { isEditMode.toggle() }
                        } label: {
                            Image(systemName: isEditMode ? "checkmark" : "pencil")
                        }
                        .disabled(items.isEmpty)

                        Button {
                            newPlaylistName = ""
                            showCreateDialog = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
        .alert(Localized.editPlaylist, isPresented: $showEditDialog) {
            TextField(Localized.playlistNamePlaceholder, text: $editPlaylistName)
            Button(Localized.save) {
                if let playlist = playlistToEdit, !editPlaylistName.isEmpty {
                    editPlaylist(playlist, newName: editPlaylistName)
                }
            }
            .disabled(editPlaylistName.isEmpty)
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            Text(Localized.enterNewName)
        }
        .alert(Localized.areYouSure, isPresented: $showDeleteConfirmation) {
            Button(Localized.delete, role: .destructive) {
                if let playlist = playlistToDelete {
                    deletePlaylist(playlist)
                }
            }
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            if let playlist = playlistToDelete {
                Text(Localized.deletingPlaylistCantBeUndone(playlist.title))
            }
        }
        .alert(Localized.createNewPlaylist, isPresented: $showCreateDialog) {
            TextField(Localized.playlistNamePlaceholder, text: $newPlaylistName)
            Button(Localized.create) {
                if !newPlaylistName.isEmpty {
                    createPlaylist(name: newPlaylistName)
                }
            }
            .disabled(newPlaylistName.isEmpty)
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            Text(Localized.enterPlaylistName)
        }
        .onAppear(perform: loadItems)
        .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
            loadItems()
        }
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: type.emptyIcon)
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(type.emptyTitle)
                .font(.headline)
            Text(type.emptySubtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Navigation

    @ViewBuilder
    private func destinationView(for item: CollectionItem) -> some View {
        switch type {
        case .albums:
            if let album = item.album {
                AlbumDetailScreen(album: album, allTracks: allTracks)
            }
        case .artists:
            if let artist = item.artist {
                ArtistDetailScreen(artist: artist, allTracks: allTracks)
            }
        case .genres:
            if let genreName = item.genreName {
                GenreDetailScreen(genreName: genreName)
            }
        case .playlists:
            if let playlist = item.playlist {
                PlaylistDetailScreen(playlist: playlist)
            }
        }
    }

    // MARK: - Data Loading

    private var allTracks: [Track] {
        (try? appCoordinator.getAllTracks()) ?? []
    }

    private func loadItems() {
        do {
            switch type {
            case .albums:
                let albums = try appCoordinator.getAllAlbums()
                let tracks = try appCoordinator.getAllTracks()
                items = albums.map { album in
                    let albumTracks = tracks.filter { $0.albumId == album.id }
                    return CollectionItem(
                        id: "album-\(album.id ?? 0)",
                        name: album.name,
                        tracks: albumTracks,
                        album: album,
                        artist: nil,
                        genreName: nil,
                        playlist: nil
                    )
                }

            case .artists:
                let artists = try DatabaseManager.shared.getAllArtists()
                let tracks = try appCoordinator.getAllTracks()
                items = artists.map { artist in
                    let artistTracks = tracks.filter { $0.artistId == artist.id }
                    return CollectionItem(
                        id: "artist-\(artist.id ?? 0)",
                        name: artist.name,
                        tracks: artistTracks,
                        album: nil,
                        artist: artist,
                        genreName: nil,
                        playlist: nil
                    )
                }

            case .genres:
                let genres = try DatabaseManager.shared.getAllGenreRecords()
                let tracks = try appCoordinator.getAllTracks()
                items = genres.map { genre in
                    let genreTracks = tracks.filter { $0.genreId == genre.id }
                    return CollectionItem(
                        id: "genre-\(genre.id ?? 0)",
                        name: genre.name,
                        tracks: genreTracks,
                        album: nil,
                        artist: nil,
                        genreName: genre.name,
                        playlist: nil
                    )
                }

            case .playlists:
                let playlists = try DatabaseManager.shared.getAllPlaylists().sorted { lhs, rhs in
                    if lhs.updatedAt != rhs.updatedAt {
                        return lhs.updatedAt > rhs.updatedAt
                    }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                items = playlists.map { playlist in
                    let tracks = getAllPlaylistTracks(playlist)
                    return CollectionItem(
                        id: "playlist-\(playlist.id ?? 0)",
                        name: playlist.title,
                        tracks: tracks,
                        album: nil,
                        artist: nil,
                        genreName: nil,
                        playlist: playlist
                    )
                }
            }
        } catch {
            print("Failed to load \(type) items: \(error)")
        }
    }

    // MARK: - Playlist Helpers

    private func getAllPlaylistTracks(_ playlist: Playlist) -> [Track] {
        guard let playlistId = playlist.id else { return [] }
        do {
            let playlistItems = try DatabaseManager.shared.getPlaylistItems(playlistId: playlistId)
            var tracks: [Track] = []
            for item in playlistItems {
                if let track = try DatabaseManager.shared.getTrack(byStableId: item.trackStableId) {
                    tracks.append(track)
                }
            }
            return tracks
        } catch {
            print("Failed to get playlist tracks: \(error)")
            return []
        }
    }

    private func editPlaylist(_ playlist: Playlist, newName: String) {
        guard let playlistId = playlist.id else { return }
        do {
            try appCoordinator.renamePlaylist(playlistId: playlistId, newTitle: newName)
            loadItems()
            playlistToEdit = nil
            editPlaylistName = ""
        } catch {
            print("Failed to rename playlist: \(error)")
        }
    }

    private func deletePlaylist(_ playlist: Playlist) {
        guard let playlistId = playlist.id else { return }
        do {
            try appCoordinator.deletePlaylist(playlistId: playlistId)
            loadItems()
            playlistToDelete = nil
        } catch {
            print("Failed to delete playlist: \(error)")
        }
    }

    private func createPlaylist(name: String) {
        do {
            _ = try appCoordinator.createPlaylist(title: name)
            loadItems()
            newPlaylistName = ""
        } catch {
            print("Failed to create playlist: \(error)")
        }
    }
}

// MARK: - CollectionCardView

struct CollectionCardView: View {
    let name: String
    let tracks: [Track]
    let isEditMode: Bool
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    @State private var artworks: [UIImage] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Artwork area
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black)
                    .aspectRatio(1, contentMode: .fit)

                // Edit mode overlay
                if isEditMode {
                    VStack {
                        HStack {
                            Button(action: { onEdit?() }) {
                                Image(systemName: "pencil")
                                    .font(.title2)
                                    .foregroundColor(.black)
                                    .frame(width: 36, height: 36)
                                    .background(Color.white, in: Circle())
                            }
                            .buttonStyle(PlainButtonStyle())

                            Spacer()

                            Button(action: { onDelete?() }) {
                                Image(systemName: "trash")
                                    .font(.title2)
                                    .foregroundColor(.black)
                                    .frame(width: 36, height: 36)
                                    .background(Color.red, in: Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        Spacer()
                    }
                    .padding(8)
                    .zIndex(1000)
                }

                // Artwork content
                if tracks.count >= 4 {
                    // 2x2 mashup
                    GeometryReader { geometry in
                        let size = (geometry.size.width - 2) / 2
                        VStack(spacing: 2) {
                            HStack(spacing: 2) {
                                artworkView(at: 0, size: size)
                                artworkView(at: 1, size: size)
                            }
                            HStack(spacing: 2) {
                                artworkView(at: 2, size: size)
                                artworkView(at: 3, size: size)
                            }
                        }
                    }
                } else if !tracks.isEmpty {
                    // Single artwork for 1-3 tracks
                    GeometryReader { geometry in
                        artworkView(at: 0, size: geometry.size.width)
                    }
                } else {
                    // Placeholder
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))

            // Text info
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                    .lineLimit(2)

                Text(Localized.songsCount(tracks.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(minHeight: 60, alignment: .topLeading)
        }
        .task {
            await loadArtworks()
        }
    }

    @ViewBuilder
    private func artworkView(at index: Int, size: CGFloat?) -> some View {
        let isMashup = tracks.count >= 4
        let cornerRadius: CGFloat = isMashup && index < 4 ? 6 : 12
        if index < artworks.count {
            Image(uiImage: artworks[index])
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        } else if index < tracks.count {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.gray.opacity(0.3))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundColor(.secondary)
                        .font(.system(size: size != nil ? size! / 4 : 40))
                )
        }
    }

    private func loadArtworks() async {
        var loaded: [UIImage] = []
        let tracksToLoad = Array(tracks.prefix(4))
        for track in tracksToLoad {
            if let artwork = await ArtworkManager.shared.getArtwork(for: track) {
                loaded.append(artwork)
            }
        }
        await MainActor.run {
            artworks = loaded
        }
    }
}
