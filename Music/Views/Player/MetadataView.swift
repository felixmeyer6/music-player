//
//  MetadataView.swift
//  Cosmos Music Player
//
//  Track metadata dialog view with editing capabilities
//

import SwiftUI

struct MetadataView: View {
    @State var track: Track
    @Environment(\.dismiss) private var dismiss
    @StateObject private var artworkManager = ArtworkManager.shared

    // Original values for change detection
    private let originalTrack: Track
    @State private var originalArtistName: String?
    @State private var originalAlbumName: String?
    @State private var originalGenreName: String?

    // Current display values
    @State private var artwork: UIImage?
    @State private var artistName: String?
    @State private var albumName: String?
    @State private var genreName: String?
    @State private var currentRating: Int?

    // Edit dialog states
    @State private var showTitleEdit = false
    @State private var showArtistEdit = false
    @State private var showAlbumEdit = false
    @State private var showGenreEdit = false
    @State private var showRatingEdit = false
    @State private var showArtworkRemoval = false
    @State private var showDiscardAlert = false

    // Edit field values
    @State private var editedTitle = ""
    @State private var editedArtist = ""

    // Picker data
    @State private var allAlbums: [Album] = []
    @State private var allGenres: [Genre] = []
    @State private var selectedAlbumId: Int64?
    @State private var selectedGenreId: Int64?

    // Save state
    @State private var isSaving = false
    @State private var hasUnsavedChanges = false

    init(track: Track) {
        self._track = State(initialValue: track)
        self.originalTrack = track
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "181818")
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Cover art (tappable)
                        artworkSection
                            .onTapGesture {
                                if artwork != nil {
                                    showArtworkRemoval = true
                                }
                            }

                        // Metadata fields
                        VStack(spacing: 16) {
                            // Title row
                            tappableMetadataRow(label: "Title", value: track.title) {
                                editedTitle = track.title
                                showTitleEdit = true
                            }

                            // Artist row
                            tappableMetadataRow(label: "Artist", value: artistName ?? "Unknown Artist") {
                                editedArtist = artistName ?? ""
                                showArtistEdit = true
                            }

                            // Album row
                            tappableMetadataRow(label: "Album", value: albumName ?? "Unknown Album") {
                                selectedAlbumId = track.albumId
                                showAlbumEdit = true
                            }

                            // Genre row
                            tappableMetadataRow(label: "Genre", value: genreName ?? "Unknown") {
                                selectedGenreId = track.genreId
                                showGenreEdit = true
                            }

                            // Rating row
                            tappableRatingRow {
                                currentRating = track.rating
                                showRatingEdit = true
                            }

                            // Plays (not editable)
                            metadataRow(label: "Plays", value: "\(track.playCount)")

                            // File format info
                            if !MetadataWriter.shared.supportsWriting(for: track.path) {
                                HStack {
                                    Image(systemName: "info.circle")
                                        .foregroundColor(.orange)
                                    Text("File metadata writing only supported for MP3 files")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.top, 8)
                            }
                        }
                        .padding(.horizontal, 24)

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 20)
                }

                if isSaving {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                }
            }
            .navigationTitle("Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: {
                        if hasUnsavedChanges {
                            showDiscardAlert = true
                        } else {
                            dismiss()
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.body)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: {
                        saveAllChanges()
                    }) {
                        Image(systemName: "arrow.down.doc")
                            .font(.body)
                    }
                    .disabled(!hasUnsavedChanges || isSaving)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(hasUnsavedChanges)
        .task {
            await loadMetadata()
            await loadPickerData()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TrackPlayCountUpdated"))) { notification in
            if let stableId = notification.userInfo?["stableId"] as? String,
               let playCount = notification.userInfo?["playCount"] as? Int,
               stableId == track.stableId {
                track.playCount = playCount
            }
        }
        .onDisappear {
            // Auto-save when view disappears if there are unsaved changes
            if hasUnsavedChanges {
                saveAllChanges()
            }
        }
        // Title edit dialog
        .alert("Edit Title", isPresented: $showTitleEdit) {
            TextField("Title", text: $editedTitle)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                updateTitle()
            }
        }
        // Artist edit dialog
        .alert("Edit Artist", isPresented: $showArtistEdit) {
            TextField("Artist", text: $editedArtist)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                updateArtist()
            }
        }
        // Album picker dialog
        .sheet(isPresented: $showAlbumEdit) {
            albumPickerSheet
        }
        // Genre picker dialog
        .sheet(isPresented: $showGenreEdit) {
            genrePickerSheet
        }
        // Rating edit dialog
        .sheet(isPresented: $showRatingEdit) {
            ratingEditSheet
        }
        // Artwork removal dialog
        .alert("Remove Cover Art", isPresented: $showArtworkRemoval) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                removeArtwork()
            }
        } message: {
            Text("This will permanently remove the cover art from the audio file. This action cannot be undone.")
        }
        // Discard changes dialog
        .alert("Discard Changes?", isPresented: $showDiscardAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Discard", role: .destructive) {
                dismiss()
            }
        } message: {
            Text("You have unsaved changes. Are you sure you want to discard them?")
        }
    }

    // MARK: - Artwork Section

    private var artworkSection: some View {
        ZStack {
            if let artwork = artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 200, height: 200)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                    )
            }
        }
        .padding(.top, 20)
    }

    // MARK: - Metadata Rows

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            Text(value)
                .font(.body)
                .foregroundColor(.primary)
                .lineLimit(2)

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private func tappableMetadataRow(label: String, value: String, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(width: 100, alignment: .leading)

                Text(value)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineLimit(2)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func tappableRatingRow(onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack {
                Text("Rating")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(width: 100, alignment: .leading)

                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: starImageName(for: star))
                            .font(.body)
                            .foregroundColor(starColor(for: star))
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func starImageName(for star: Int) -> String {
        guard let rating = track.rating else {
            return "star"
        }
        return star <= rating ? "star.fill" : "star"
    }

    private func starColor(for star: Int) -> Color {
        guard let rating = track.rating else {
            return .gray.opacity(0.5)
        }
        return star <= rating ? .yellow : .gray.opacity(0.5)
    }

    // MARK: - Picker Sheets

    private var albumPickerSheet: some View {
        NavigationView {
            ZStack {
                Color(hex: "181818")
                    .ignoresSafeArea()

                List {
                    ForEach(allAlbums, id: \.id) { album in
                        Button(action: {
                            selectedAlbumId = album.id
                            updateAlbum()
                            showAlbumEdit = false
                        }) {
                            HStack {
                                Text(album.name)
                                    .foregroundColor(.primary)
                                Spacer()
                                if selectedAlbumId == album.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Select Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showAlbumEdit = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var genrePickerSheet: some View {
        NavigationView {
            ZStack {
                Color(hex: "181818")
                    .ignoresSafeArea()

                List {
                    ForEach(allGenres, id: \.id) { genre in
                        Button(action: {
                            selectedGenreId = genre.id
                            updateGenre()
                            showGenreEdit = false
                        }) {
                            HStack {
                                Text(genre.name)
                                    .foregroundColor(.primary)
                                Spacer()
                                if selectedGenreId == genre.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Select Genre")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showGenreEdit = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var ratingEditSheet: some View {
        NavigationView {
            ZStack {
                Color(hex: "181818")
                    .ignoresSafeArea()

                VStack(spacing: 32) {
                    Text("Select Rating")
                        .font(.headline)
                        .foregroundColor(.primary)

                    HStack(spacing: 12) {
                        ForEach(1...5, id: \.self) { star in
                            Button(action: {
                                currentRating = star
                            }) {
                                Image(systemName: (currentRating ?? 0) >= star ? "star.fill" : "star")
                                    .font(.system(size: 40))
                                    .foregroundColor((currentRating ?? 0) >= star ? .yellow : .gray.opacity(0.5))
                            }
                        }
                    }

                    Button(action: {
                        currentRating = nil
                    }) {
                        Text("Clear Rating")
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 8)

                    Spacer()
                }
                .padding(.top, 40)
            }
            .navigationTitle("Edit Rating")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showRatingEdit = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        updateRating()
                        showRatingEdit = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Data Loading

    private func loadMetadata() async {
        // Load artwork
        let loadedArtwork = await artworkManager.getArtwork(for: track)
        await MainActor.run {
            artwork = loadedArtwork
        }

        // Load artist name
        if let artistId = track.artistId {
            let artist = try? await Task.detached(priority: .userInitiated) {
                try DatabaseManager.shared.read { db in
                    try Artist.fetchOne(db, key: artistId)
                }
            }.value
            await MainActor.run {
                artistName = artist?.name
                originalArtistName = artist?.name
            }
        }

        // Load album name
        if let albumId = track.albumId {
            let album = try? await Task.detached(priority: .userInitiated) {
                try DatabaseManager.shared.read { db in
                    try Album.fetchOne(db, key: albumId)
                }
            }.value
            await MainActor.run {
                albumName = album?.name
                originalAlbumName = album?.name
            }
        }

        // Load genre name
        if let genreId = track.genreId {
            let genre = try? await Task.detached(priority: .userInitiated) {
                try DatabaseManager.shared.getGenre(byId: genreId)
            }.value
            await MainActor.run {
                genreName = genre?.name
                originalGenreName = genre?.name
            }
        } else if let genreText = track.genre, !genreText.isEmpty {
            await MainActor.run {
                genreName = genreText
                originalGenreName = genreText
            }
        }
    }

    private func loadPickerData() async {
        // Load all albums
        let albums = try? await Task.detached(priority: .userInitiated) {
            try DatabaseManager.shared.getAllAlbums()
        }.value
        await MainActor.run {
            allAlbums = albums ?? []
        }

        // Load all genres
        let genres = try? await Task.detached(priority: .userInitiated) {
            try DatabaseManager.shared.getAllGenreRecords()
        }.value
        await MainActor.run {
            allGenres = genres ?? []
        }
    }

    // MARK: - Update Methods (local state only)

    private func updateTitle() {
        guard !editedTitle.isEmpty else { return }
        track.title = editedTitle
        checkForChanges()
    }

    private func updateArtist() {
        guard !editedArtist.isEmpty else { return }
        artistName = editedArtist
        checkForChanges()
    }

    private func updateAlbum() {
        guard let albumId = selectedAlbumId else { return }
        track.albumId = albumId

        // Update displayed album name
        if let album = allAlbums.first(where: { $0.id == albumId }) {
            albumName = album.name
        }
        checkForChanges()
    }

    private func updateGenre() {
        guard let genreId = selectedGenreId else { return }
        track.genreId = genreId

        // Update displayed genre name
        if let genre = allGenres.first(where: { $0.id == genreId }) {
            genreName = genre.name
            track.genre = genre.name
        }
        checkForChanges()
    }

    private func updateRating() {
        track.rating = currentRating
        checkForChanges()
    }

    private func removeArtwork() {
        var trackToUpdate = track
        trackToUpdate.hasEmbeddedArt = false
        let currentArtistName = artistName

        artwork = nil
        track.hasEmbeddedArt = false

        Task {
            // Remove artwork from file (MP3 only)
            let trackForFile = trackToUpdate
            await Task.detached(priority: .userInitiated) {
                _ = MetadataWriter.shared.removeArtwork(from: trackForFile)
            }.value

            // Update database
            let trackForDb = trackToUpdate
            try? await Task.detached(priority: .userInitiated) {
                try DatabaseManager.shared.upsertTrack(trackForDb)
            }.value

            // Clear artwork from cache
            artworkManager.clearCache()
            artworkManager.clearDiskCache()

            // Post notification to update other views
            let trackForNotification = trackToUpdate
            NotificationCenter.default.post(
                name: NSNotification.Name("TrackMetadataUpdated"),
                object: nil,
                userInfo: [
                    "track": trackForNotification,
                    "artistName": currentArtistName as Any
                ]
            )
            NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)
        }
    }

    private func checkForChanges() {
        hasUnsavedChanges = track.title != originalTrack.title ||
            track.albumId != originalTrack.albumId ||
            track.genreId != originalTrack.genreId ||
            track.genre != originalTrack.genre ||
            track.rating != originalTrack.rating ||
            track.hasEmbeddedArt != originalTrack.hasEmbeddedArt ||
            artistName != originalArtistName
    }

    // MARK: - Save All Changes

    private func saveAllChanges() {
        guard hasUnsavedChanges else { return }
        isSaving = true

        Task {
            // First, handle artist update if changed
            if artistName != originalArtistName, let newArtistName = artistName, !newArtistName.isEmpty {
                let artist = try? await Task.detached(priority: .userInitiated) {
                    try DatabaseManager.shared.upsertArtist(name: newArtistName)
                }.value

                await MainActor.run {
                    if let artist = artist {
                        track.artistId = artist.id
                    }
                }
            }

            // Save to database
            let trackToSave = track
            let artistNameToSave = artistName
            let albumNameToSave = albumName
            let genreNameToSave = genreName

            try? await Task.detached(priority: .userInitiated) {
                try DatabaseManager.shared.upsertTrack(trackToSave)
            }.value

            // Write to file (MP3 only)
            await Task.detached(priority: .userInitiated) {
                _ = MetadataWriter.shared.writeMetadata(
                    to: trackToSave,
                    artistName: artistNameToSave,
                    albumName: albumNameToSave,
                    genreName: genreNameToSave
                )
            }.value

            await MainActor.run {
                isSaving = false
                hasUnsavedChanges = false

                // Post notification with updated track data for player/views to refresh
                NotificationCenter.default.post(
                    name: NSNotification.Name("TrackMetadataUpdated"),
                    object: nil,
                    userInfo: [
                        "track": trackToSave,
                        "artistName": artistNameToSave as Any
                    ]
                )
                NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)
            }
        }
    }
}
