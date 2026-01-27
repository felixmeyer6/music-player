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

            // Prefer playlists that still need tracks added.
            let lhsNeedsAdd = lhsMissing > 0
            let rhsNeedsAdd = rhsMissing > 0
            if lhsNeedsAdd != rhsNeedsAdd {
                return lhsNeedsAdd && !rhsNeedsAdd
            }

            // Then sort by most recently played, then by title.
            if lhs.lastPlayedAt != rhs.lastPlayedAt {
                return lhs.lastPlayedAt > rhs.lastPlayedAt
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(.systemGray5)
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
                        .background(Color(.systemGray5))
                    }
                }
                .padding()
            }
            .navigationTitle(Localized.addToPlaylist)
            .navigationBarTitleDisplayMode(.inline)
            // Force a consistent navigation bar style regardless of the presenting screen's toolbar settings.
            .toolbarBackground(Color.black.opacity(0.8), for: .navigationBar)
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
            for trackId in trackIds {
                try appCoordinator.addToPlaylist(playlistId: playlistId, trackStableId: trackId)
            }
            onComplete?()
            dismiss()
        } catch {
            print("Failed to add to playlist: \(error)")
        }
    }
}
