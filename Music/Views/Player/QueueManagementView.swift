import SwiftUI

struct QueueManagementView: View {
    @StateObject private var playerEngine = PlayerEngine.shared
    @StateObject private var artworkManager = ArtworkManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draggedTrack: Track?
    @State private var settings = DeleteSettings.load()
    @State private var artistLookup: [Int64: String] = [:]
    
    var body: some View {
        NavigationView {
            ZStack {
                ScreenSpecificBackgroundView(screen: .player)
                
                VStack(spacing: 20) {
                    // Header
                    HStack {
                        Button(Localized.done) {
                            dismiss()
                        }
                        .font(.headline)
                        
                        Spacer()
                        
                        Text(Localized.playingQueue)
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Spacer()
                        
                        // Invisible button for balance
                        Button(Localized.done) {
                            dismiss()
                        }
                        .font(.headline)
                        .opacity(0)
                        .disabled(true)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    
                    if playerEngine.playbackQueue.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 60))
                                .foregroundColor(.secondary)
                            
                            Text(Localized.noSongsInQueue)
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(Array(playerEngine.playbackQueue.enumerated()), id: \.element.stableId) { index, track in
                                QueueTrackRow(
                                    track: track,
                                    index: index,
                                    isCurrentTrack: index == playerEngine.currentIndex,
                                    isAudioPlaying: playerEngine.isPlaying,
                                    isDragging: draggedTrack?.stableId == track.stableId,
                                    artistName: artistLookup[track.artistId ?? -1],
                                    onTap: {
                                        jumpToTrack(at: index)
                                    }
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets())
                                .onLongPressGesture(
                                    minimumDuration: 0.075,
                                    maximumDistance: 10,
                                    pressing: { isPressing in
                                        if isPressing {
                                            draggedTrack = track
                                        } else if draggedTrack?.stableId == track.stableId {
                                            draggedTrack = nil
                                        }
                                    },
                                    perform: {}
                                )
                            }
                            .onMove(perform: moveItems)
                        }
                        .listStyle(PlainListStyle())
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            settings = DeleteSettings.load()
        }
        .onAppear {
            refreshArtistLookup(for: playerEngine.playbackQueue)
        }
        .onChange(of: playerEngine.playbackQueue) { _, newQueue in
            refreshArtistLookup(for: newQueue)
        }
    }

    private func refreshArtistLookup(for queue: [Track]) {
        let artistIds = Set(queue.compactMap { $0.artistId })
        guard !artistIds.isEmpty else {
            artistLookup = [:]
            return
        }
        Task.detached(priority: .userInitiated) {
            let lookup = (try? DatabaseManager.shared.getArtistLookup(for: artistIds)) ?? [:]
            await MainActor.run {
                artistLookup = lookup
            }
        }
    }
    
    private func moveItems(from source: IndexSet, to destination: Int) {
        // Get the source index (should be only one item)
        guard let sourceIndex = source.first else { return }

        // Calculate the actual destination index
        let actualDestination = sourceIndex < destination ? destination - 1 : destination

        // Create new queue with the move applied
        var newQueue = playerEngine.playbackQueue
        let movedTrack = newQueue.remove(at: sourceIndex)
        newQueue.insert(movedTrack, at: actualDestination)

        // Calculate new current index
        var newCurrentIndex = playerEngine.currentIndex
        if sourceIndex == playerEngine.currentIndex {
            // The currently playing track was moved
            newCurrentIndex = actualDestination
        } else if sourceIndex < playerEngine.currentIndex && actualDestination >= playerEngine.currentIndex {
            // Track moved from before current to after current
            newCurrentIndex -= 1
        } else if sourceIndex > playerEngine.currentIndex && actualDestination <= playerEngine.currentIndex {
            // Track moved from after current to before current
            newCurrentIndex += 1
        }

        // Apply changes on main thread
        DispatchQueue.main.async {
            self.playerEngine.playbackQueue = newQueue
            self.playerEngine.currentIndex = newCurrentIndex
        }
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
    let index: Int
    let isCurrentTrack: Bool
    let isAudioPlaying: Bool
    let isDragging: Bool
    let artistName: String?
    let onTap: () -> Void

    @State private var artworkImage: UIImage?
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        HStack(spacing: 12) {
            // Album artwork
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 50, height: 50)
                
                if let image = artworkImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "music.note")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            
            // Track info
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(track.title)
                        .font(.headline)
                        .fontWeight(isCurrentTrack ? .bold : .medium)
                        .foregroundColor(isCurrentTrack ? Color.white : .primary)
                        .lineLimit(1)
                    
                    if isCurrentTrack {
                        let eqKey = "\(isAudioPlaying && isCurrentTrack)-\(track.stableId)"
                        EqualizerBarsExact(
                            color: .white,
                            isActive: isAudioPlaying && isCurrentTrack,
                            isLarge: true,
                            trackId: track.stableId
                        )
                        .id(eqKey)
                        .padding(.leading, 4)
                    }
                }
                
                if let artistName {
                    Text(artistName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Drag indicator only
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isCurrentTrack ? Color.white.opacity(0.15) : Color.clear)
        )
        .opacity(isDragging ? 0.0 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isDragging)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .onAppear {
            loadArtwork()
        }
        .task {
            if artworkImage == nil {
                loadArtwork()
            }
        }
    }
    
    private func loadArtwork() {
        Task {
            artworkImage = await ArtworkManager.shared.getArtwork(for: track)
        }
    }
}
