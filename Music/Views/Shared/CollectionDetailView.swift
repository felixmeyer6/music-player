import SwiftUI

/// A reusable detail view for displaying collections of tracks (Albums, Genres, Playlists).
/// This component is "dumb" - it receives all data and callbacks from parent views,
/// with no internal dependencies on @EnvironmentObject or PlayerEngine.shared.
struct CollectionDetailView: View {
    // MARK: - Header Content (optional - set to nil to hide artwork/title header)
    let title: String?
    let subtitle: String?
    let artwork: UIImage?

    // MARK: - Tracks
    let displayTracks: [Track]

    // MARK: - Sort Configuration
    let sortOptions: [TrackSortOption]
    let selectedSort: TrackSortOption
    let onSelectSort: (TrackSortOption) -> Void

    // MARK: - Playback Callbacks
    let onPlay: ([Track]) -> Void
    let onShuffle: ([Track]) -> Void
    let onTrackTap: (Track, [Track]) -> Void

    // MARK: - Row Actions
    let onPlayNext: (Track) -> Void
    let onAddToQueue: (Track) -> Void
    let playlist: Playlist?

    // MARK: - Player State (for TrackRowView highlighting)
    let activeTrackId: String?
    let isAudioPlaying: Bool

    // MARK: - Playlist Edit Mode (optional)
    var isEditMode: Bool = false
    var onDelete: ((Track) -> Void)? = nil
    var onMove: ((IndexSet, Int) -> Void)? = nil

    // MARK: - Bulk Selection (optional)
    var supportsBulkSelection: Bool = false
    var onBulkAddToPlaylist: (([Track]) -> Void)? = nil

    // MARK: - Private State
    @State private var recentlyActedTracks: Set<String> = []
    @State private var isBulkMode: Bool = false
    @State private var selectedTracks: Set<String> = []

    // MARK: - Layout Constants
    private let headerArtworkSize: CGFloat = 140
    private var headerTextTopOffset: CGFloat { headerArtworkSize * 0.15 }

    // Computed property for whether to show artwork header
    private var showArtworkHeader: Bool {
        title != nil || subtitle != nil || artwork != nil
    }

    // MARK: - Body
    var body: some View {
        List {
            // Header Section (only if artwork/title/subtitle provided)
            if showArtworkHeader {
                Section {
                    headerContent
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            } else {
                // Just Play/Shuffle buttons without artwork header
                Section {
                    playShuffleButtons
                        .padding(.vertical, 16)
                        .padding(.horizontal)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }

            // Track List
            if displayTracks.isEmpty {
                emptyStateView
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            } else {
                ForEach(displayTracks, id: \.stableId) { track in
                    trackRow(for: track)
                }
                .onMove(perform: onMove)
            }
        }
        .listStyle(PlainListStyle())
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(isEditMode ? .active : .inactive))
    }

    // MARK: - Sort Toolbar
    @ToolbarContentBuilder
    func sortToolbarContent() -> some ToolbarContent {
        if !sortOptions.isEmpty && !isBulkMode {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    ForEach(sortOptions, id: \.self) { option in
                        Button {
                            onSelectSort(option)
                        } label: {
                            HStack {
                                Text(option.localizedString)
                                if selectedSort == option {
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
    }

    // MARK: - Bulk Selection Toolbar
    @ToolbarContentBuilder
    func bulkToolbarContent() -> some ToolbarContent {
        if isBulkMode {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(Localized.cancel) { exitBulkMode() }
                    .foregroundColor(Color.white)
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: { selectAll() }) {
                        Label(Localized.selectAll, systemImage: "checkmark.circle")
                    }
                    Divider()
                    Button(action: { bulkAddToPlaylist() }) {
                        Label(Localized.addToPlaylist, systemImage: "music.note.list")
                    }
                    .disabled(selectedTracks.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundColor(Color.white)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Bulk Selection State Access (for parent views)
    var bulkModeBinding: Binding<Bool> {
        Binding(get: { isBulkMode }, set: { isBulkMode = $0 })
    }

    var selectedTracksBinding: Binding<Set<String>> {
        Binding(get: { selectedTracks }, set: { selectedTracks = $0 })
    }

    // MARK: - Header Content
    @ViewBuilder
    private var headerContent: some View {
        VStack(spacing: 16) {
            // Artwork + Info Row
            HStack(alignment: .top, spacing: 16) {
                // Artwork
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: headerArtworkSize, height: headerArtworkSize)
                    .overlay {
                        if let image = artwork {
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

                // Title + Subtitle
                VStack(alignment: .leading, spacing: 6) {
                    Spacer()
                        .frame(height: headerTextTopOffset)

                    if let title = title {
                        Text(title)
                            .font(.title2)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.leading)
                    }

                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Play/Shuffle Buttons
            playShuffleButtons
        }
        .padding(.vertical, 16)
        .padding(.horizontal)
    }

    // MARK: - Play/Shuffle Buttons
    @ViewBuilder
    private var playShuffleButtons: some View {
        HStack(spacing: 12) {
            // Play Button
            Button {
                onPlay(displayTracks)
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
            .disabled(displayTracks.isEmpty)

            // Shuffle Button
            Button {
                onShuffle(displayTracks)
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
            .disabled(displayTracks.isEmpty)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    // MARK: - Track Row
    @ViewBuilder
    private func trackRow(for track: Track) -> some View {
        HStack(spacing: 0) {
            // Bulk selection checkbox
            if isBulkMode && supportsBulkSelection {
                Image(systemName: selectedTracks.contains(track.stableId) ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(selectedTracks.contains(track.stableId) ? Color.white : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleSelection(for: track) }
            }

            TrackRowView(
                track: track,
                activeTrackId: activeTrackId,
                isAudioPlaying: isAudioPlaying,
                onTap: {
                    if isBulkMode && supportsBulkSelection {
                        toggleSelection(for: track)
                    } else {
                        onTrackTap(track, displayTracks)
                    }
                },
                playlist: playlist,
                showDirectDeleteButton: isEditMode && onDelete != nil,
                onEnterBulkMode: supportsBulkSelection ? { enterBulkMode(initialSelection: track.stableId) } : nil
            )
            .equatable()
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .opacity(0.7)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .onLongPressGesture(minimumDuration: 0.5) {
            if supportsBulkSelection && !isBulkMode {
                enterBulkMode(initialSelection: track.stableId)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !isBulkMode && !recentlyActedTracks.contains(track.stableId) {
                Button {
                    onPlayNext(track)
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
            if !isBulkMode && !recentlyActedTracks.contains(track.stableId) {
                Button {
                    onAddToQueue(track)
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

    // MARK: - Empty State
    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text(Localized.noSongsFound)
                .font(.headline)

            Text(Localized.yourMusicWillAppearHere)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Helper Methods
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

    private func markAsActed(_ trackId: String) {
        recentlyActedTracks.insert(trackId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            recentlyActedTracks.remove(trackId)
        }
    }

    // MARK: - Bulk Selection Helpers
    private func enterBulkMode(initialSelection: String? = nil) {
        isBulkMode = true
        if let trackId = initialSelection {
            selectedTracks.insert(trackId)
        }
    }

    func exitBulkMode() {
        isBulkMode = false
        selectedTracks.removeAll()
    }

    private func toggleSelection(for track: Track) {
        if selectedTracks.contains(track.stableId) {
            selectedTracks.remove(track.stableId)
        } else {
            selectedTracks.insert(track.stableId)
        }
    }

    private func selectAll() {
        selectedTracks = Set(displayTracks.map { $0.stableId })
    }

    private func bulkAddToPlaylist() {
        let tracks = displayTracks.filter { selectedTracks.contains($0.stableId) }
        onBulkAddToPlaylist?(tracks)
    }

}
