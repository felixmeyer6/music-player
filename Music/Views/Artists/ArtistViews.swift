import SwiftUI

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

struct ArtistDetailScreen: View {
    let artist: Artist
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var playerEngine = PlayerEngine.shared
    @State private var sortOption: TrackSortOption = .defaultOrder
    @State private var artworkImage: UIImage?

    private var artistTracks: [Track] {
        allTracks.filter { $0.artistId == artist.id }
    }

    private var sortedTracks: [Track] {
        TrackSorting.sort(artistTracks, by: sortOption, isPlaylist: false)
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
        .navigationTitle(artist.name)
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
            loadArtwork()
            loadSortPreference()
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

    private func sortPreferenceKey() -> String {
        "sortPreference_artist_\(artist.id ?? 0)"
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

