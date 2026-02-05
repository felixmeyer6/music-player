import SwiftUI

struct QueueManagementView: View {
    @StateObject private var playerEngine = PlayerEngine.shared
    @StateObject private var artworkManager = ArtworkManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var settings = DeleteSettings.load()
    @State private var artistLookup: [Int64: String] = [:]
    @State private var lastArtistIds: Set<Int64> = []
    @State private var queueRows: [QueueRowItem] = []
    private let sheetBackground = Color(hex: "181818")
    
    var body: some View {
        NavigationView {
            ZStack {
                sheetBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    if playerEngine.playbackQueue.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            
                            Text(Localized.noSongsInQueue)
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal)
                    } else {
                        List {
                            ForEach(Array(queueRows.enumerated()), id: \.element.id) { index, item in
                                let track = item.track
                                QueueTrackRow(
                                    track: track,
                                    isCurrentTrack: index == playerEngine.currentIndex,
                                    activeTrackId: playerEngine.currentTrack?.stableId,
                                    isAudioPlaying: playerEngine.isPlaying,
                                    artistName: artistLookup[track.artistId ?? -1],
                                    onTap: {
                                        jumpToTrack(at: index)
                                    }
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets())
                            }
                            .onMove(perform: moveItems)
                        }
                        .listStyle(PlainListStyle())
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                        .contentMargins(.vertical, 6, for: .scrollContent)
                        .environment(\.editMode, .constant(.active))
                        .background(sheetBackground)
                    }
                }
            }
            .navigationTitle(Localized.playingQueue)
            .navigationBarTitleDisplayMode(.inline)
            // Match Add to Playlist sheet styling.
            .toolbarBackground(sheetBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .tint(.white)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(Localized.playingQueue)
                        .font(.headline)
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel(Localized.done)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            settings = DeleteSettings.load()
        }
        .onAppear {
            refreshArtistLookup(for: playerEngine.playbackQueue)
            syncQueueRows(with: playerEngine.playbackQueue)
        }
        .onChange(of: playerEngine.playbackQueue) { _, newQueue in
            refreshArtistLookup(for: newQueue)
            syncQueueRows(with: newQueue)
        }
    }

    private func syncQueueRows(with queue: [Track]) {
        guard !queue.isEmpty else {
            queueRows = []
            return
        }

        if queueRows.count == queue.count {
            let sameOrder = zip(queueRows, queue).allSatisfy { row, track in
                row.track.stableId == track.stableId
            }
            if sameOrder {
                for index in queue.indices {
                    queueRows[index].track = queue[index]
                }
                return
            }
        }

        queueRows = queue.map { QueueRowItem(track: $0) }
    }

    private func refreshArtistLookup(for queue: [Track]) {
        let artistIds = Set(queue.compactMap { $0.artistId })
        guard artistIds != lastArtistIds else { return }
        lastArtistIds = artistIds
        guard !artistIds.isEmpty else {
            artistLookup = [:]
            return
        }
        Task.detached(priority: .userInitiated) {
            let lookup = (try? DatabaseManager.shared.getArtistLookup(for: artistIds)) ?? [:]
            await MainActor.run {
                guard lastArtistIds == artistIds else { return }
                artistLookup = lookup
            }
        }
    }
    
    private func moveItems(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }

        let currentTrackId = playerEngine.currentTrack?.stableId
        let oldCurrentIndex = playerEngine.currentIndex
        var indexMap = Array(0..<queueRows.count)
        indexMap.move(fromOffsets: source, toOffset: destination)

        queueRows.move(fromOffsets: source, toOffset: destination)
        let newQueue = queueRows.map { $0.track }

        let newCurrentIndex: Int
        if let idx = indexMap.firstIndex(of: oldCurrentIndex) {
            newCurrentIndex = idx
        } else if let currentTrackId,
                  let idx = newQueue.firstIndex(where: { $0.stableId == currentTrackId }) {
            newCurrentIndex = idx
        } else {
            newCurrentIndex = max(0, min(playerEngine.currentIndex, newQueue.count - 1))
        }

        playerEngine.playbackQueue = newQueue
        playerEngine.currentIndex = newCurrentIndex
    }

    private func jumpToTrack(at index: Int) {
        guard index >= 0 && index < playerEngine.playbackQueue.count else { return }

        Task {
            playerEngine.currentIndex = index
            let track = playerEngine.playbackQueue[index]
            await playerEngine.loadTrack(track, preservePlaybackTime: false)

            // Start playback
            DispatchQueue.main.async {
                self.playerEngine.play()
            }
        }
    }
}

struct QueueTrackRow: View {
    let track: Track
    let isCurrentTrack: Bool
    let activeTrackId: String?
    let isAudioPlaying: Bool
    let artistName: String?
    let onTap: () -> Void
    
    var body: some View {
        TrackRowView(
            track: track,
            activeTrackId: activeTrackId,
            isAudioPlaying: isAudioPlaying,
            artistName: artistName,
            albumName: nil,
            onTap: onTap,
            playlist: nil,
            showDirectDeleteButton: false,
            onDelete: nil,
            onEnterBulkMode: nil,
            sortOption: nil
        )
        .equatable()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

private struct QueueRowItem: Identifiable {
    let id: UUID = UUID()
    var track: Track
}
