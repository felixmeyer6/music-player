import SwiftUI
import UIKit


struct PlaylistsScreen: View {
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var playlists: [Playlist] = []
    @State private var isEditMode: Bool = false
    @State private var playlistToEdit: Playlist?
    @State private var playlistToDelete: Playlist?
    @State private var showEditDialog = false
    @State private var showDeleteConfirmation = false
    @State private var editPlaylistName = ""
    @State private var showCreateDialog = false
    @State private var newPlaylistName = ""

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .playlists)

            VStack {
                if playlists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        
                        Text(Localized.noPlaylistsYet)
                            .font(.headline)
                        
                        Text(Localized.createPlaylistsInstruction)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 8),
                            GridItem(.flexible(), spacing: 8)
                        ], spacing: 16) {
                            ForEach(playlists, id: \.id) { playlist in
                                if isEditMode {
                                    PlaylistCardView(playlist: playlist, allTracks: getAllPlaylistTracks(playlist), isEditMode: true, onEdit: {
                                        playlistToEdit = playlist
                                        editPlaylistName = playlist.title
                                        showEditDialog = true
                                    }, onDelete: {
                                        playlistToDelete = playlist
                                        showDeleteConfirmation = true
                                    })
                                } else {
                                    NavigationLink {
                                        PlaylistDetailScreen(playlist: playlist)
                                    } label: {
                                        PlaylistCardView(playlist: playlist, allTracks: getAllPlaylistTracks(playlist))
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 100) // Add padding for mini player
                    }
                }
            }
            .navigationTitle(Localized.playlists)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            withAnimation {
                                isEditMode.toggle()
                            }
                        } label: {
                            Image(systemName: isEditMode ? "checkmark" : "pencil")
                        }
                        .disabled(playlists.isEmpty)

                        Button {
                            newPlaylistName = ""
                            showCreateDialog = true
                        } label: {
                            Image(systemName: "plus")
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
            .onAppear {
                loadPlaylists()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
                loadPlaylists()
            }
        }
    }
    
    private func getAllPlaylistTracks(_ playlist: Playlist) -> [Track] {
        guard let playlistId = playlist.id else { return [] }
        do {
            let playlistItems = try appCoordinator.databaseManager.getPlaylistItems(playlistId: playlistId)
            var tracks: [Track] = []
            for item in playlistItems {
                if let track = try appCoordinator.databaseManager.getTrack(byStableId: item.trackStableId) {
                    tracks.append(track)
                }
            }
            return tracks
        } catch {
            print("Failed to get playlist tracks: \(error)")
            return []
        }
    }
    
    private func loadPlaylists() {
        do {
            playlists = try appCoordinator.databaseManager.getAllPlaylists().sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        } catch {
            print("Failed to load playlists: \(error)")
        }
    }

    private func editPlaylist(_ playlist: Playlist, newName: String) {
        guard let playlistId = playlist.id else { return }
        do {
            try appCoordinator.renamePlaylist(playlistId: playlistId, newTitle: newName)
            loadPlaylists()
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
            loadPlaylists()
            playlistToDelete = nil
        } catch {
            print("Failed to delete playlist: \(error)")
        }
    }

    private func createPlaylist(name: String) {
        do {
            _ = try appCoordinator.createPlaylist(title: name)
            loadPlaylists()
            newPlaylistName = ""
        } catch {
            print("Failed to create playlist: \(error)")
        }
    }
}

struct PlaylistCardView: View {
    let playlist: Playlist
    let allTracks: [Track]
    let isEditMode: Bool
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    @StateObject private var artworkManager = ArtworkManager.shared
    @State private var artworks: [UIImage] = []
    @State private var customCoverImage: UIImage?

    init(playlist: Playlist, allTracks: [Track], isEditMode: Bool = false, onEdit: (() -> Void)? = nil, onDelete: (() -> Void)? = nil) {
        self.playlist = playlist
        self.allTracks = allTracks
        self.isEditMode = isEditMode
        self.onEdit = onEdit
        self.onDelete = onDelete
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Artwork area
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(1, contentMode: .fit)

                // Edit mode overlay with buttons - always on top
                if isEditMode {
                    VStack {
                        HStack {
                            Button(action: {
                                onEdit?()
                            }) {
                                Image(systemName: "pencil")
                                    .font(.title2)
                                    .foregroundColor(.black)
                                    .frame(width: 36, height: 36)
                                    .background(Color.white, in: Circle())
                            }
                            .buttonStyle(PlainButtonStyle())

                            Spacer()

                            Button(action: {
                                onDelete?()
                            }) {
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
                
                // Artwork content - same in both edit and normal mode
                // Show custom cover if available, otherwise show auto-generated mashup
                if let customCover = customCoverImage {
                    Image(uiImage: customCover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .clipped()
                } else if allTracks.count >= 4 {
                    // 2x2 mashup for 4+ tracks
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
                } else if !allTracks.isEmpty {
                    // Single artwork for 1-3 tracks
                    GeometryReader { geometry in
                        artworkView(at: 0, size: geometry.size.width)
                    }
                } else {
                    // Default icon for empty playlist
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))

            // Text info
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.headline)
                    .lineLimit(1)
                
                Text(Localized.songsCount(allTracks.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .task {
            await loadCustomCover()
            await loadArtworks()
        }
    }
    
    @ViewBuilder
    private func artworkView(at index: Int, size: CGFloat?) -> some View {
        if index < artworks.count {
            Image(uiImage: artworks[index])
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: index < 4 && allTracks.count >= 4 ? 6 : 12))
        } else if index < allTracks.count {
            RoundedRectangle(cornerRadius: index < 4 && allTracks.count >= 4 ? 6 : 12)
                .fill(Color.gray.opacity(0.3))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundColor(.secondary)
                        .font(.system(size: size != nil ? size!/4 : 40))
                )
        }
    }
    
    private func loadArtworks() async {
        var loadedArtworks: [UIImage] = []
        let tracksToLoad = Array(allTracks.prefix(4))

        for track in tracksToLoad {
            if let artwork = await artworkManager.getArtwork(for: track) {
                loadedArtworks.append(artwork)
            }
        }

        await MainActor.run {
            artworks = loadedArtworks
        }
    }

    private func loadCustomCover() async {
        // Check if playlist has a custom cover path
        guard let customPath = playlist.customCoverImagePath,
              !customPath.isEmpty else { return }

        // Load image from shared container
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.dev.neofx.music-player"
        ) else { return }

        let fileURL = containerURL.appendingPathComponent(customPath)
        if let data = try? Data(contentsOf: fileURL),
           let image = UIImage(data: data) {
            await MainActor.run {
                customCoverImage = image
            }
        }
    }
}

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
                    guard !tracks.isEmpty else { return }
                    var shuffled = tracks
                    let startIndex = Int.random(in: 0..<shuffled.count)
                    let startTrack = shuffled.remove(at: startIndex)
                    shuffled.shuffle()
                    shuffled.insert(startTrack, at: 0)
                    Task {
                        if let playlistId = playlist.id {
                            try? appCoordinator.updatePlaylistAccessed(playlistId: playlistId)
                            try? appCoordinator.updatePlaylistLastPlayed(playlistId: playlistId)
                        }
                        await playerEngine.playTrack(startTrack, queue: shuffled)
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
            .padding(.bottom, 90)
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    // Edit button (leftmost)
                    Button {
                        withAnimation { isEditMode.toggle() }
                    } label: {
                        Image(systemName: isEditMode ? "checkmark" : "pencil")
                    }
                    .disabled(tracks.isEmpty)

                    // Filter button
                    if hasFilterOptions {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                filterState.toggleFilter()
                            }
                        } label: {
                            Image(systemName: filterState.isFilterVisible ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                .foregroundColor(.white)
                        }
                    }

                    // Sort button (rightmost)
                    SortMenuView(selection: $sortOption, onSelectionChanged: saveSortPreference)
                }
            }
        }
        .onAppear {
            loadPlaylistTracks()
            loadSortPreference()
            loadArtwork()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            loadPlaylistTracks()
            loadArtwork()
        }
    }

    private func loadPlaylistTracks() {
        guard let playlistId = playlist.id else { return }
        do {
            let playlistItems = try appCoordinator.databaseManager.getPlaylistItems(playlistId: playlistId)
            let allTracks = try appCoordinator.getAllTracks()
            tracks = playlistItems.compactMap { item in
                allTracks.first { $0.stableId == item.trackStableId }
            }
            loadAlbumLookup()
        } catch {
            print("Failed to load playlist tracks: \(error)")
        }
    }

    private func loadAlbumLookup() {
        do {
            let albums = try appCoordinator.databaseManager.getAllAlbums()
            albumLookup = Dictionary(uniqueKeysWithValues: albums.compactMap { album in
                guard let id = album.id else { return nil }
                return (id, album.title)
            })
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

    private func sortPreferenceKey() -> String {
        "sortPreference_playlist_\(playlist.id ?? 0)"
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

struct PlaylistManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var playlists: [Playlist] = []
    @State private var playlistToDelete: Playlist?
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if playlists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        
                        Text(Localized.noPlaylistsYet)
                            .font(.headline)
                        
                        Text(Localized.createPlaylistsInstruction)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(playlists, id: \.id) { playlist in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playlist.title)
                                        .font(.headline)
                                    
                                    Text(Localized.createdDate(formatDate(Date(timeIntervalSince1970: TimeInterval(playlist.createdAt)))))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Button(action: {
                                    playlistToDelete = playlist
                                    showDeleteConfirmation = true
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .padding()
            .navigationTitle(Localized.managePlaylists)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Localized.done) {
                        dismiss()
                    }
                }
            }
        }
        .alert(Localized.deletePlaylist, isPresented: $showDeleteConfirmation) {
            Button(Localized.delete, role: .destructive) {
                deletePlaylist()
            }
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            if let playlist = playlistToDelete {
                Text(Localized.deletePlaylistConfirmation(playlist.title))
            }
        }
        .onAppear {
            loadPlaylists()
        }
    }
    
    private func loadPlaylists() {
        do {
            playlists = try DatabaseManager.shared.getAllPlaylists()
        } catch {
            print("Failed to load playlists: \(error)")
        }
    }
    
    private func deletePlaylist() {
        guard let playlist = playlistToDelete,
              let playlistId = playlist.id else { return }
        
        do {
            try appCoordinator.deletePlaylist(playlistId: playlistId)
            playlists.removeAll { $0.id == playlistId }
            playlistToDelete = nil
        } catch {
            print("Failed to delete playlist: \(error)")
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}
