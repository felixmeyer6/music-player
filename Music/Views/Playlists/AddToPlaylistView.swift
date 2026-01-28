import SwiftUI

/// Unified "Add to Playlist" sheet used across the app.
/// Single-track and bulk flows both delegate here so the add logic lives in one place.
struct AddToPlaylistView: View {
    let trackIds: [String]
    let onComplete: (() -> Void)?
    let showTrackCount: Bool

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appCoordinator: AppCoordinator

    @State private var playlists: [Playlist] = []
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""

    init(trackIds: [String], onComplete: (() -> Void)? = nil, showTrackCount: Bool = true) {
        self.trackIds = trackIds
        self.onComplete = onComplete
        self.showTrackCount = showTrackCount
    }

    private func missingCount(in playlist: Playlist) -> Int {
        guard let playlistId = playlist.id else { return trackIds.count }
        var missing = 0
        for trackId in trackIds {
            let isInPlaylist = (try? appCoordinator.isTrackInPlaylist(playlistId: playlistId, trackStableId: trackId)) ?? false
            if !isInPlaylist {
                missing += 1
            }
        }
        return missing
    }

    private var sortedPlaylists: [Playlist] {
        playlists.sorted { lhs, rhs in
            let lhsMissing = missingCount(in: lhs)
            let rhsMissing = missingCount(in: rhs)

            // Show playlists that already contain all selected tracks first.
            let lhsHasAll = lhsMissing == 0
            let rhsHasAll = rhsMissing == 0
            if lhsHasAll != rhsHasAll {
                return lhsHasAll && !rhsHasAll
            }

            // Then sort by last modified date (updated_at), then by title.
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 24.0 / 255.0, green: 24.0 / 255.0, blue: 24.0 / 255.0)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    if showTrackCount {
                        VStack(spacing: 8) {
                            Text(Localized.addToPlaylist)
                                .font(.title2)
                                .fontWeight(.semibold)

                            Text(Localized.songsCountOnly(trackIds.count))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.bottom, 12)
                        .padding(.horizontal)
                    }

                    if playlists.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)

                            Text(Localized.noPlaylistsYet)
                                .font(.headline)

                            Text(Localized.createFirstPlaylist)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal)
                    } else {
                        List {
                            ForEach(sortedPlaylists, id: \.id) { playlist in
                                let missing = missingCount(in: playlist)
                                let isFullyInPlaylist = missing == 0

                                HStack {
                                    Image(systemName: "music.note.list")
                                        .foregroundColor(.white)

                                    Text(playlist.title)
                                        .foregroundColor(.primary)

                                    Spacer()

                                    if isFullyInPlaylist {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title2)
                                            .foregroundColor(.green)
                                    } else {
                                        Image(systemName: "plus.circle")
                                            .font(.title2)
                                            .foregroundColor(.white)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    addToPlaylist(playlist)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .contentMargins(.vertical, 6, for: .scrollContent)
                        .background(Color(red: 24.0 / 255.0, green: 24.0 / 255.0, blue: 24.0 / 255.0))
                    }
                }
            }
            .navigationTitle(Localized.addToPlaylist)
            .navigationBarTitleDisplayMode(.inline)
            // Force a consistent navigation bar style regardless of the presenting screen's toolbar settings.
            .toolbarBackground(Color(red: 24.0 / 255.0, green: 24.0 / 255.0, blue: 24.0 / 255.0), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(.white)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(Localized.addToPlaylist)
                        .font(.headline)
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(Localized.cancel) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreatePlaylist = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.white)
                    }
                    .accessibilityLabel(Localized.createNewPlaylist)
                }
            }
        }
        .alert(Localized.createPlaylist, isPresented: $showCreatePlaylist) {
            TextField(Localized.playlistNamePlaceholder, text: $newPlaylistName)
            Button(Localized.create) {
                createPlaylist()
            }
            .disabled(newPlaylistName.isEmpty)
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            Text(Localized.enterPlaylistName)
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

    private func createPlaylist() {
        guard !newPlaylistName.isEmpty else { return }
        do {
            let playlist = try appCoordinator.createPlaylist(title: newPlaylistName)
            playlists.append(playlist)
            newPlaylistName = ""

            guard let playlistId = playlist.id else {
                print("Error: Created playlist has no ID")
                return
            }
            for trackId in trackIds {
                try appCoordinator.addToPlaylist(playlistId: playlistId, trackStableId: trackId)
            }

            onComplete?()
            dismiss()
        } catch {
            print("Failed to create playlist: \(error)")
        }
    }

    private func addToPlaylist(_ playlist: Playlist) {
        guard let playlistId = playlist.id else {
            print("Error: Playlist has no ID")
            return
        }
        do {
            if missingCount(in: playlist) == 0 {
                for trackId in trackIds {
                    try appCoordinator.removeFromPlaylist(playlistId: playlistId, trackStableId: trackId)
                }
            } else {
                for trackId in trackIds {
                    try appCoordinator.addToPlaylist(playlistId: playlistId, trackStableId: trackId)
                }
            }
            onComplete?()
            dismiss()
        } catch {
            print("Failed to add to playlist: \(error)")
        }
    }
}
