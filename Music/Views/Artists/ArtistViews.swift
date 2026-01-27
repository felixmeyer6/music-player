import SwiftUI
import GRDB

struct ArtistsScreen: View {
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var artists: [Artist] = []
    
    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .artists)
            
            VStack {
                if artists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "person.2")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        
                        Text("No artists found")
                            .font(.headline)
                        
                        Text("Artists will appear here once you add music to your library")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(artists, id: \.id) { artist in
                        ZStack {
                            NavigationLink(destination: ArtistDetailScreen(artist: artist, allTracks: allTracks)) {
                                EmptyView()
                            }
                            .opacity(0.0)
                            
                            HStack {
                                Image(systemName: "person")
                                    .foregroundColor(.purple)
                                    .frame(width: 24, height: 24)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(artist.name)
                                        .font(.headline)
                                    
                                    Text(Localized.artist)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial)
                                    .opacity(0.7)
                            )
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(PlainListStyle())
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .safeAreaInset(edge: .bottom) {
                        Color.clear.frame(height: 100) // Space for mini player
                    }
                }
            }
            .navigationTitle(Localized.artists)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadArtists()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
                loadArtists()
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            }
        }
    } // end body
    
    private func loadArtists() {
        do {
            artists = try appCoordinator.databaseManager.getAllArtists()
        } catch {
            print("Failed to load artists: \(error)")
        }
    }
}

struct ArtistListView: View {
    let artists: [Artist]
    let onArtistTap: (Artist) -> Void
    
    var body: some View {
        if artists.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "person.2")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                
                Text("No artists found")
                    .font(.headline)
                
                Text("Artists will appear here once you add music to your library")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(artists, id: \.id) { artist in
                HStack {
                    Image(systemName: "person")
                        .foregroundColor(.purple)
                        .frame(width: 24, height: 24)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artist.name)
                            .font(.headline)
                        
                        Text("Artist")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(height: 66)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    onArtistTap(artist)
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }
            .listStyle(PlainListStyle())
        }
    }
}

struct ArtistDetailScreen: View {
    let artist: Artist
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var playerEngine = PlayerEngine.shared
    
    private var artistTracks: [Track] {
        return allTracks.filter { $0.artistId == artist.id }
    }
    
    private var artistAlbums: [Album] {
        do {
            let albums = try appCoordinator.getAllAlbums()
            return albums.filter { $0.artistId == artist.id }
        } catch {
            return []
        }
    }
    
    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .artistDetail)
            simpleView
        }
        .navigationBarTitleDisplayMode(.inline)
    }
    
    @ViewBuilder
    private var simpleView: some View {
        ScrollView {
            VStack(spacing: 20) {
                simpleHeader
                if !artistTracks.isEmpty { songsSection }
                if !artistAlbums.isEmpty { albumsSection }
            }
            .padding(.bottom, 100) // Add padding for mini player
        }
    }
    
    // MARK: - Subsections
    
    @ViewBuilder
    private var simpleHeader: some View {
        VStack(spacing: 16) {
            Text(artist.name)
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            playButtons
        }
        .padding(.horizontal)
    }
    
    private var playButtons: some View {
        HStack(spacing: 12) {
            Button {
                guard let first = artistTracks.first else { return }
                Task { await playerEngine.playTrack(first, queue: artistTracks) }
            } label: {
                HStack { Image(systemName: "play.fill"); Text(Localized.play) }
                    .font(.title3).fontWeight(.semibold)
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color.white)
                    .cornerRadius(28)
            }
            Button {
                let shuffled = artistTracks.shuffled()
                guard let first = shuffled.first else { return }
                Task { await playerEngine.playTrack(first, queue: shuffled) }
            } label: {
                HStack { Image(systemName: "shuffle"); Text(Localized.shuffle) }
                    .font(.title3).fontWeight(.semibold)
                    .foregroundColor(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(28)
            }
        }
        .padding(.horizontal, 8)
    }
    
    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Localized.songs).font(.title3).fontWeight(.bold)
                Spacer()
                Text("\(artistTracks.count) track\(artistTracks.count == 1 ? "" : "s")")
                    .font(.body).foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
            LazyVStack(spacing: 0) {
                ForEach(artistTracks.indices, id: \.self) { index in
                    let track = artistTracks[index]
                    TrackRowView(
                        track: track,
                        activeTrackId: playerEngine.currentTrack?.stableId,
                        isAudioPlaying: playerEngine.isPlaying,
                        onTap: {
                            Task { await playerEngine.playTrack(track, queue: artistTracks) }
                        },
                        playlist: nil,
                        showDirectDeleteButton: false,
                        onEnterBulkMode: nil
                    )
                    .equatable()
                    .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial).opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Localized.albums).font(.title3).fontWeight(.bold)
                Spacer()
                Text("\(artistAlbums.count) album\(artistAlbums.count == 1 ? "" : "s")")
                    .font(.body).foregroundColor(.secondary)
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(artistAlbums, id: \.id) { album in
                        NavigationLink {
                            AlbumDetailScreen(album: album, allTracks: allTracks)
                        } label: {
                            ArtistAlbumCardView(album: album, tracks: allTracks)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct ArtistAlbumCardView: View {
    let album: Album
    let tracks: [Track]
    @State private var artworkImage: UIImage?
    
    private var albumTracks: [Track] {
        tracks.filter { $0.albumId == album.id }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 120, height: 120)
                .overlay {
                    if let image = artworkImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }
            
            Text(album.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 120)
                .frame(minHeight: 32) // Min height for 2 lines alignment
                .foregroundColor(.primary)
        }
        .onAppear {
            loadAlbumArtwork()
        }
    }
    
    private func loadAlbumArtwork() {
        guard let firstTrack = albumTracks.first else { return }
        
        Task {
            let image = await ArtworkManager.shared.getArtwork(for: firstTrack)
            await MainActor.run {
                self.artworkImage = image
            }
        }
    }
}
