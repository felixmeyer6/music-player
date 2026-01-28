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

    // MARK: - Filter Support (optional)
    var albumLookup: [Int64: String] = [:]
    var filterState: TrackFilterState? = nil

    // MARK: - Private State
    @State private var recentlyActedTracks: Set<String> = []
    @State private var isBulkMode: Bool = false
    @State private var selectedTracks: Set<String> = []
    @State private var showAddToPlaylistSheet: Bool = false
    @State private var scrollPosition: String?

    // MARK: - Layout Constants
    private let headerArtworkSize: CGFloat = 140
    private var headerTextTopOffset: CGFloat { headerArtworkSize * 0.15 }

    // Computed property for whether to show artwork header
    private var showArtworkHeader: Bool {
        title != nil || subtitle != nil || artwork != nil
    }

    // MARK: - Filter Computed Properties
    private var isFilterVisible: Bool {
        filterState?.isFilterVisible ?? false
    }

    private var availableGenres: [String] {
        TrackFiltering.availableGenres(from: displayTracks)
    }

    private var availableAlbums: [(id: Int64, title: String)] {
        TrackFiltering.availableAlbums(from: displayTracks, albumLookup: albumLookup)
    }

    private var availableRatings: [Int] {
        TrackFiltering.availableRatings(from: displayTracks)
    }

    private var filteredTracks: [Track] {
        guard let state = filterState else { return displayTracks }
        return TrackFiltering.filter(tracks: displayTracks, with: state, albumLookup: albumLookup)
    }

    private var hasAnyFilterOptions: Bool {
        TrackFiltering.hasFilterOptions(tracks: displayTracks, albumLookup: albumLookup)
    }

    // MARK: - Body
    var body: some View {
        ZStack(alignment: .top) {
            List {
                // Spacer for filter row when visible
                if isFilterVisible {
                    Color.clear
                        .frame(height: 56)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                        .id("__filter_spacer__")
                }

                // Header Section (only if artwork/title/subtitle provided)
                if showArtworkHeader {
                    Section {
                        headerContent
                            .id("__header__")
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
                            .id("__buttons__")
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                }

                // Track List
                if filteredTracks.isEmpty {
                    if isFilterVisible && !displayTracks.isEmpty {
                        filterEmptyStateView
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                            .id("__filter_empty__")
                    } else {
                        emptyStateView
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets())
                            .id("__empty__")
                    }
                } else {
                    ForEach(filteredTracks, id: \.stableId) { track in
                        trackRow(for: track)
                            .id(track.stableId)
                    }
                    .onMove(perform: isEditMode ? onMove : nil)
                }
            }
            .listStyle(PlainListStyle())
            .scrollContentBackground(.hidden)
            .scrollPosition(id: $scrollPosition, anchor: .top)
            .environment(\.editMode, .constant(isEditMode ? .active : .inactive))

            // Sticky filter row
            if isFilterVisible {
                filterRow
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFilterVisible)
        .sheet(isPresented: $showAddToPlaylistSheet) {
            AddToPlaylistView(
                trackIds: Array(selectedTracks),
                onComplete: { exitBulkMode() },
                showTrackCount: true
            )
        }
    }

    // MARK: - Sort Toolbar
    @ToolbarContentBuilder
    func sortToolbarContent() -> some ToolbarContent {
        if !sortOptions.isEmpty && !isBulkMode {
            ToolbarItem(placement: .navigationBarTrailing) {
                SortMenuView(
                    selection: Binding(
                        get: { selectedSort },
                        set: { onSelectSort($0) }
                    ),
                    options: sortOptions
                )
            }
        }
    }

    // MARK: - Filter Toolbar
    @ToolbarContentBuilder
    func filterToolbarContent() -> some ToolbarContent {
        if let state = filterState, hasAnyFilterOptions && !isBulkMode {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        state.toggleFilter()
                    }
                } label: {
                    Image(systemName: state.isFilterVisible ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
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
                    Button(action: { showAddToPlaylistSheet = true }) {
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
        VStack(spacing: 12) {
            // Artwork + Buttons Row
            HStack(alignment: .center, spacing: 16) {
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

                // Play/Shuffle Buttons (stacked vertically) with subtitle below
                VStack(spacing: 10) {
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
                        .frame(height: 52)
                        .background(Color.white)
                        .cornerRadius(26)
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
                        .frame(height: 52)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(26)
                    }
                    .disabled(displayTracks.isEmpty)

                    // Subtitle (track count) centered below buttons
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
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
        let isSelected = selectedTracks.contains(track.stableId)

        HStack(spacing: 0) {
            // Bulk selection checkbox
            if isBulkMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isSelected ? Color.white : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleSelection(for: track) }
            }

            TrackRowView(
                track: track,
                activeTrackId: activeTrackId,
                isAudioPlaying: isAudioPlaying,
                onTap: {
                    if isBulkMode {
                        toggleSelection(for: track)
                    } else {
                        onTrackTap(track, displayTracks)
                    }
                },
                playlist: playlist,
                showDirectDeleteButton: isEditMode && onDelete != nil,
                onEnterBulkMode: { enterBulkMode(initialSelection: track.stableId) },
                sortOption: selectedSort
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
            if !isBulkMode {
                // Enter bulk mode with this track selected
                enterBulkMode(initialSelection: track.stableId)
            } else if isSelected {
                // In bulk mode, long press on selected track - show playlist sheet
                showAddToPlaylistSheet = true
            } else {
                // In bulk mode, long press on unselected track - select it
                selectedTracks.insert(track.stableId)
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

    // MARK: - Filter Empty State
    @ViewBuilder
    private var filterEmptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text("No Matching Tracks")
                .font(.headline)

            Text("Select filters above to show tracks")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Filter Row
    @ViewBuilder
    private var filterRow: some View {
        if let state = filterState {
            HStack(spacing: 8) {
                // Three filter buttons with equal width (1/3 each)
                HStack(spacing: 8) {
                    // Genre Filter
                    FilterDropdown(
                        title: "Genre",
                        options: availableGenres,
                        selectedOptions: Binding(
                            get: { state.selectedGenres },
                            set: { state.selectedGenres = $0 }
                        ),
                        isAvailable: !availableGenres.isEmpty
                    )
                    .frame(maxWidth: .infinity)

                    // Album Filter
                    FilterDropdown(
                        title: "Album",
                        options: availableAlbums.map { $0.title },
                        selectedOptions: Binding(
                            get: {
                                Set(state.selectedAlbums.compactMap { id in
                                    availableAlbums.first { $0.id == id }?.title
                                })
                            },
                            set: { newTitles in
                                state.selectedAlbums = Set(newTitles.compactMap { title in
                                    availableAlbums.first { $0.title == title }?.id
                                })
                            }
                        ),
                        isAvailable: !availableAlbums.isEmpty
                    )
                    .frame(maxWidth: .infinity)

                    // Rating Filter
                    FilterDropdown(
                        title: "Rating",
                        options: availableRatings.map { TrackFiltering.ratingString($0) },
                        selectedOptions: Binding(
                            get: {
                                Set(state.selectedRatings.map { TrackFiltering.ratingString($0) })
                            },
                            set: { newStrings in
                                state.selectedRatings = Set(newStrings.compactMap { str in
                                    availableRatings.first { TrackFiltering.ratingString($0) == str }
                                })
                            }
                        ),
                        isAvailable: !availableRatings.isEmpty
                    )
                    .frame(maxWidth: .infinity)
                }

                // Close filter button
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        state.toggleFilter()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
        }
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

}

// MARK: - Filter Dropdown Component
private struct FilterDropdown: View {
    let title: String
    let options: [String]
    @Binding var selectedOptions: Set<String>
    var isAvailable: Bool = true
    @State private var isExpanded: Bool = false

    var body: some View {
        Button {
            if isAvailable && !options.isEmpty {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                if !selectedOptions.isEmpty && isAvailable {
                    Text("(\(selectedOptions.count))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 4)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isAvailable && !selectedOptions.isEmpty ? Color.white.opacity(0.25) : Color.white.opacity(0.1))
            )
            .foregroundColor(isAvailable ? .white : .white.opacity(0.4))
        }
        .disabled(!isAvailable || options.isEmpty)
        .popover(isPresented: $isExpanded, arrowEdge: .top) {
            FilterOptionsView(
                title: title,
                options: options,
                selectedOptions: $selectedOptions
            )
            .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Filter Options Popover Content
private struct FilterOptionsView: View {
    let title: String
    let options: [String]
    @Binding var selectedOptions: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if !selectedOptions.isEmpty {
                    Button {
                        selectedOptions.removeAll()
                    } label: {
                        Text("Clear")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Options list
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            toggleOption(option)
                        } label: {
                            HStack {
                                Text(option)
                                    .foregroundColor(.primary)
                                Spacer()
                                if selectedOptions.contains(option) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if option != options.last {
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(minWidth: 200)
    }

    private func toggleOption(_ option: String) {
        if selectedOptions.contains(option) {
            selectedOptions.remove(option)
        } else {
            selectedOptions.insert(option)
        }
    }
}
