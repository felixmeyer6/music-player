import SwiftUI
import AVKit
import UIKit

struct EqualizerBarsExact: View {
    let color: Color
    let isActive: Bool
    let isLarge: Bool
    let trackId: String?

    private var minH: CGFloat { isLarge ? 2 : 1 }
    private var targetH: [CGFloat] { isLarge ? [4, 12, 8, 16] : [3, 8, 6, 10] }
    private let durations: [Double] = [0.6, 0.8, 0.4, 0.7]

    @State private var kick = false
    @Environment(\.scenePhase) private var scenePhase

    private var restartKey: String { "\(isActive)-\(trackId ?? "")" }

    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(color)
                    .frame(width: isLarge ? 2 : 1.5)
                    .frame(height: isActive && kick ? targetH[i] : minH)
                    .animation(
                        isActive
                        ? .easeInOut(duration: durations[i]).repeatForever(autoreverses: true)
                        : .easeInOut(duration: 0.2),
                        value: kick
                    )
            }
        }
        .frame(width: isLarge ? 12 : 10, height: isLarge ? 20 : 12)
        .id(restartKey)                 // force view identity reset on key change
        .task(id: restartKey) { restart() } // runs on mount and when key changes
        .onChange(of: scenePhase) { p in
            if p == .active { restart() }   // recover after app foregrounding
        }
    }

    private func restart() {
        kick = false
        DispatchQueue.main.async {
            if isActive { kick = true }     // start a fresh repeatForever cycle
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    func mix(with color: Color, by amount: CGFloat) -> Color {
        let t = max(0, min(1, amount))
        let c1 = UIColor(self)
        let c2 = UIColor(color)

        var r1: CGFloat = 0
        var g1: CGFloat = 0
        var b1: CGFloat = 0
        var a1: CGFloat = 0
        var r2: CGFloat = 0
        var g2: CGFloat = 0
        var b2: CGFloat = 0
        var a2: CGFloat = 0

        c1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        c2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)

        return Color(
            .sRGB,
            red: Double(r1 + (r2 - r1) * t),
            green: Double(g1 + (g2 - g1) * t),
            blue: Double(b1 + (b2 - b1) * t),
            opacity: Double(a1 + (a2 - a1) * t)
        )
    }
}
import GRDB

struct PlayerView: View {
    @StateObject private var playerEngine = PlayerEngine.shared
    @StateObject private var artworkManager = ArtworkManager.shared
    @StateObject private var cloudDownloadManager = CloudDownloadManager.shared
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var currentArtwork: UIImage?
    @State private var dragOffset: CGFloat = 0
    @State private var isAnimating = false
    @State private var awaitingNewArtwork = false
    @State private var isArtworkHidden = false
    @State private var suppressDragAnimation = false
    @State private var allTracks: [Track] = []
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var showQueueSheet = false
    @State private var dominantColor: Color = .white
    @State private var isScrubbing = false
    @State private var scrubProgress: Double?
    
    private var currentArtworkKey: String {
        playerEngine.currentTrack?.stableId ?? "none"
    }

    var body: some View {
        ZStack {
            playerBackground
            mainContent
        }
    }

    private var playerBackground: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .player)
            GeometryReader { proxy in
                if let artwork = currentArtwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.08)
                        .rotationEffect(.degrees(2))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: 30)
                        .opacity(0.25)
                        .transition(.opacity)
                        .id(currentArtworkKey)
                }
            }
            .ignoresSafeArea()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: currentArtworkKey)
        .animation(.easeInOut(duration: 0.25), value: dominantColor)
    }

    private var mainContent: some View {
        contentView
            .padding(.vertical)
            .padding(.top, 8)
            .onChange(of: playerEngine.currentTrack) { _, newTrack in
                currentArtwork = nil
                Task {
                    await loadAllArtworks()
                    checkFavoriteStatus()
                }
            }
            .onAppear {
                Task {
                    await loadAllArtworks()
                    await loadTracks()
                    checkFavoriteStatus()
                }
            }
            .sheet(isPresented: $showPlaylistDialog) {
                playlistSheet
            }
            .sheet(isPresented: $showQueueSheet) {
                queueSheet
            }
    }

    private var contentView: some View {
        VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 16 : 20) {
            if let currentTrack = playerEngine.currentTrack {
                artworkSection

                VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 20 : 25) {
                    titleAndArtistSection(track: currentTrack)
                    controlsSection
                }
                .padding(.horizontal, max(16, min(20, UIScreen.main.bounds.width * 0.05)))
            } else {
                emptyStateView
                    .padding(.horizontal, max(16, min(20, UIScreen.main.bounds.width * 0.05)))
            }
        }
    }

    private var playlistSheet: some View {
        Group {
            if let currentTrack = playerEngine.currentTrack {
                PlaylistSelectionView(track: currentTrack)
                    .accentColor(dominantColor)
            }
        }
    }

    private var queueSheet: some View {
        QueueManagementView()
            .accentColor(dominantColor)
    }

    // MARK: - Artwork Section

    private var artworkSection: some View {
        GeometryReader { geometry in
            let maxWidth = min(geometry.size.width, 360)
            let artworkSize = min(maxWidth, geometry.size.height)

            ZStack {
                currentArtworkView(size: artworkSize)
                    .offset(x: dragOffset)
                    .animation(suppressDragAnimation ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: dragOffset)
                    .opacity(isArtworkHidden ? 0 : 1)
                    .animation(.easeInOut(duration: 0.25), value: isArtworkHidden)
                    .transition(.opacity)
                    .id(currentArtworkKey)
                    .animation(.easeInOut(duration: 0.25), value: currentArtworkKey)
                    .onTapGesture {
                        NotificationCenter.default.post(name: NSNotification.Name("MinimizePlayer"), object: nil)
                    }
            }
            .frame(width: artworkSize, height: artworkSize)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .frame(height: min(360, UIScreen.main.bounds.width - 80))
        .frame(maxWidth: .infinity)
        .clipped()
        .shadow(radius: 8)
        .gesture(artworkDragGesture)
    }

    private func currentArtworkView(size: CGFloat) -> some View {
        ZStack {
            if let artwork = currentArtwork {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: size, height: size)
                Image(uiImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if awaitingNewArtwork {
                Color.clear
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: size, height: size)
                Image(systemName: "music.note")
                    .font(.system(size: min(80, size * 0.2)))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var artworkDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if !isAnimating {
                    dragOffset = value.translation.width
                }
            }
            .onEnded { value in
                let threshold: CGFloat = 80
                let velocity = value.predictedEndTranslation.width - value.translation.width

                if value.translation.width > threshold || velocity > 500 {
                    handleSwipeRight()
                } else if value.translation.width < -threshold || velocity < -500 {
                    handleSwipeLeft()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func handleSwipeRight() {
        let currentTrackId = playerEngine.currentTrack?.stableId
        isAnimating = true
        awaitingNewArtwork = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            dragOffset = UIScreen.main.bounds.width
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isArtworkHidden = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Task {
                await playerEngine.previousTrack()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isAnimating = false
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if awaitingNewArtwork && playerEngine.currentTrack?.stableId == currentTrackId {
                withAnimation(.none) {
                    dragOffset = 0
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    isArtworkHidden = false
                }
                awaitingNewArtwork = false
            }
        }
    }

    private func handleSwipeLeft() {
        let currentTrackId = playerEngine.currentTrack?.stableId
        isAnimating = true
        awaitingNewArtwork = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            dragOffset = -UIScreen.main.bounds.width
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isArtworkHidden = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Task {
                await playerEngine.nextTrack()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isAnimating = false
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if awaitingNewArtwork && playerEngine.currentTrack?.stableId == currentTrackId {
                withAnimation(.none) {
                    dragOffset = 0
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    isArtworkHidden = false
                }
                awaitingNewArtwork = false
            }
        }
    }

    // MARK: - Title and Artist Section

    private func titleAndArtistSection(track: Track) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                titleButton(track: track)
                artistButton(track: track)
            }

            Spacer()

            HStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 16 : 20) {
                likeButton
                addToPlaylistButton
            }
        }
        .padding(.horizontal, 8)
    }

    private func titleButton(track: Track) -> some View {
        Group {
            if track.albumId != nil {
                Button(action: {
                    let tracksSnapshot = allTracks
                    Task {
                        // Load album for navigation only when tapped, off the main actor.
                        guard let albumId = track.albumId else { return }
                        let album = try? await Task.detached(priority: .userInitiated) {
                            try DatabaseManager.shared.read { db in
                                try Album.fetchOne(db, key: albumId)
                            }
                        }.value
                        guard let album else { return }
                        let userInfo = ["album": album, "allTracks": tracksSnapshot] as [String : Any]
                        NotificationCenter.default.post(name: NSNotification.Name("NavigateToAlbumFromPlayer"), object: nil, userInfo: userInfo)
                    }
                }) {
                    Text(track.title)
                        .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.primary)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Text(track.title)
                    .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private func artistButton(track: Track) -> some View {
        Group {
            if let artistName = playerEngine.currentArtistName {
                Button(action: {
                    let tracksSnapshot = allTracks
                    Task {
                        // Load artist for navigation only when tapped, off the main actor.
                        guard let artistId = track.artistId else { return }
                        let artist = try? await Task.detached(priority: .userInitiated) {
                            try DatabaseManager.shared.read { db in
                                try Artist.fetchOne(db, key: artistId)
                            }
                        }.value
                        guard let artist else { return }
                        let userInfo = ["artist": artist, "allTracks": tracksSnapshot] as [String : Any]
                        NotificationCenter.default.post(name: NSNotification.Name("NavigateToArtistFromPlayer"), object: nil, userInfo: userInfo)
                    }
                }) {
                    Text(artistName)
                        .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .caption : .subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private var likeButton: some View {
        Button(action: {
            toggleFavorite()
        }) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                .foregroundColor(isFavorite ? dominantColor : .primary)
        }
    }

    private var addToPlaylistButton: some View {
        Button(action: {
            showPlaylistDialog = true
        }) {
            Image(systemName: "plus.circle")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                .foregroundColor(.primary)
        }
    }

    // MARK: - Progress Bar Section

    private var progressBarSection: some View {
        let engineProgress: Double = {
            guard playerEngine.duration > 0 else { return 0 }
            return playerEngine.playbackTime / playerEngine.duration
        }()

        let progressBinding = Binding<Double>(
            get: {
                if isScrubbing, let scrubProgress {
                    return scrubProgress
                }
                return engineProgress
            },
            set: { newProgress in
                guard !playerEngine.isCrossfading else { return }
                isScrubbing = true
                scrubProgress = newProgress
            }
        )

        return VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 12 : 16) {
            WaveformScrubber(
                progress: progressBinding,
                accentColor: dominantColor,
                track: playerEngine.currentTrack,
                onScrubEnd: { finalProgress in
                    guard !playerEngine.isCrossfading else {
                        isScrubbing = false
                        scrubProgress = nil
                        return
                    }
                    guard playerEngine.duration > 0 else {
                        isScrubbing = false
                        scrubProgress = nil
                        return
                    }

                    let newTime = finalProgress * playerEngine.duration
                    Task {
                        await playerEngine.seek(to: newTime)
                        await MainActor.run {
                            isScrubbing = false
                            scrubProgress = nil
                        }
                    }
                }
            )
            .allowsHitTesting(!playerEngine.isCrossfading)
            .frame(height: 36)
            .padding(.vertical, 12)
            .padding(.top, 4)
            .onChange(of: playerEngine.isCrossfading) { _, isCrossfading in
                if isCrossfading {
                    isScrubbing = false
                    scrubProgress = nil
                }
            }

            HStack {
                Text(formatTime(playerEngine.playbackTime))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(formatTime(playerEngine.duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Controls Section

    private var controlsSection: some View {
        VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 20 : 25) {
            playbackControlsView
            progressBarSection
            additionalControlsView
        }
    }

    private var playbackControlsView: some View {
        HStack(spacing: min(35, UIScreen.main.bounds.width * 0.08)) {
            shuffleButton
            previousButton
            playPauseButton
            nextButton
            loopButton
        }
        .padding(.horizontal, min(21, UIScreen.main.bounds.width * 0.055))
        .padding(.vertical, 21)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25))
        .overlay(
            RoundedRectangle(cornerRadius: 25)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    private var shuffleButton: some View {
        Button(action: {
            playerEngine.toggleShuffle()
        }) {
            Image(systemName: playerEngine.isShuffled ? "shuffle.circle.fill" : "shuffle.circle")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                .foregroundColor(playerEngine.isShuffled ? .accentColor : .primary)
        }
    }

    private var previousButton: some View {
        Button(action: {
            Task {
                await playerEngine.previousTrack()
            }
        }) {
            Image(systemName: "backward.fill")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
        }
    }

    private var playPauseButton: some View {
        Button(action: {
            if playerEngine.isPlaying {
                playerEngine.pause()
            } else {
                playerEngine.play()
            }
        }) {
            Image(systemName: playerEngine.isPlaying ? "pause.fill" : "play.fill")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title : .largeTitle)
                .animation(nil, value: playerEngine.isPlaying)
        }
    }

    private var nextButton: some View {
        Button(action: {
            Task {
                await playerEngine.nextTrack()
            }
        }) {
            Image(systemName: "forward.fill")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
        }
    }

    private var loopButton: some View {
        Button(action: {
            playerEngine.cycleLoopMode()
        }) {
            Group {
                if playerEngine.isLoopingSong {
                    Image(systemName: "repeat.1.circle.fill")
                        .foregroundColor(dominantColor)
                } else if playerEngine.isRepeating {
                    Image(systemName: "repeat.circle.fill")
                        .foregroundColor(dominantColor)
                } else {
                    Image(systemName: "repeat.circle")
                        .foregroundColor(.primary)
                }
            }
            .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
        }
    }

    private var additionalControlsView: some View {
        HStack(spacing: 12) {
            queueButton
            airPlayButton
        }
        .padding(.horizontal, 5)
    }

    private var queueButton: some View {
        Button(action: {
            showQueueSheet = true
        }) {
            Image(systemName: "list.bullet")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, minHeight: 30)
                .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    private var airPlayButton: some View {
        Button(action: {
            showAirPlayPicker()
        }) {
            Image(systemName: "airplayaudio")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, minHeight: 25)
                .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }

    private var emptyStateView: some View {
        VStack {
            Image(systemName: "music.note")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text(Localized.noTrackSelected)
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helper Functions
    
    private func loadAllArtworks() async {
        await loadCurrentArtwork()
    }
    
    private func loadCurrentArtwork() async {
        if let track = playerEngine.currentTrack {
            let artwork = await artworkManager.getArtwork(for: track)
            if let artwork = artwork {
                let color = await artwork.dominantColorAsync()
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentArtwork = artwork
                        dominantColor = color
                    }
                    finalizeArtworkPresentation()
                }
            } else {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        currentArtwork = nil
                        dominantColor = .white
                    }
                    finalizeArtworkPresentation()
                }
            }
        } else {
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) {
                    currentArtwork = nil
                    dominantColor = .white
                }
                awaitingNewArtwork = false
                isArtworkHidden = false
            }
        }
    }

    @MainActor
    private func finalizeArtworkPresentation() {
        if awaitingNewArtwork {
            suppressDragAnimation = true
            dragOffset = 0
            withAnimation(.easeInOut(duration: 0.25)) {
                isArtworkHidden = false
            }
            awaitingNewArtwork = false
            DispatchQueue.main.async {
                suppressDragAnimation = false
            }
        } else {
            isArtworkHidden = false
        }
    }
    
    @MainActor
    private func loadTracks() async {
        do {
            allTracks = try appCoordinator.getAllTracks()
            print("✅ Loaded \(allTracks.count) tracks for artist navigation")
        } catch {
            print("❌ Failed to load tracks: \(error)")
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func checkFavoriteStatus() {
        guard let currentTrack = playerEngine.currentTrack else {
            isFavorite = false
            return
        }
        
        do {
            isFavorite = try DatabaseManager.shared.isFavorite(trackStableId: currentTrack.stableId)
        } catch {
            print("Failed to check favorite status: \(error)")
            isFavorite = false
        }
    }
    
    private func toggleFavorite() {
        guard let currentTrack = playerEngine.currentTrack else { return }
        
        do {
            try appCoordinator.toggleFavorite(trackStableId: currentTrack.stableId)
            isFavorite.toggle()
        } catch {
            print("Failed to toggle favorite: \(error)")
        }
    }
    
    private func showAirPlayPicker() {
        let routePickerView = AVRoutePickerView()
        routePickerView.prioritizesVideoDevices = false
        
        // Find the button inside the route picker and simulate a tap
        for subview in routePickerView.subviews {
            if let button = subview as? UIButton {
                button.sendActions(for: .touchUpInside)
                break
            }
        }
    }
}

struct WaveformScrubber: View {
    @Binding var progress: Double
    let accentColor: Color
    let track: Track?
    let onScrubEnd: (Double) -> Void

    var barWidth: CGFloat = 2
    var barSpacing: CGFloat = 1
    var barCornerRadius: CGFloat = 1
    var totalBars: Int = 150

    @State private var isDragging = false
    @State private var dragStartProgress: Double = 0
    @State private var amplitudes: [CGFloat] = []

    private var totalWidth: CGFloat {
        CGFloat(totalBars) * (barWidth + barSpacing)
    }

    private var taskKey: String {
        "\(track?.stableId ?? "none")-\(totalBars)"
    }

    var body: some View {
        GeometryReader { geo in
            let centerOffset = geo.size.width / 2
            let progressOffset = totalWidth * progress

            HStack(spacing: barSpacing) {
                ForEach(0..<totalBars, id: \.self) { i in
                    let isFilled = Double(i) / Double(totalBars) <= progress

                    RoundedRectangle(cornerRadius: barCornerRadius)
                        .fill(
                            isFilled
                            ? accentColor
                            : Color(white: 0.6).mix(with: accentColor, by: 0.1)
                        )
                        .frame(width: barWidth, height: barHeight(for: i) * geo.size.height)
                }
            }
            .frame(height: geo.size.height)
            .offset(x: centerOffset - progressOffset)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            dragStartProgress = progress
                        }
                        let delta = -drag.translation.width / totalWidth
                        progress = max(0, min(1, dragStartProgress + delta))
                    }
                    .onEnded { _ in
                        isDragging = false
                        onScrubEnd(progress)
                    }
            )
        }
        .task(id: taskKey) {
            await loadAmplitudes()
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        if amplitudes.count == totalBars {
            return amplitudes[index]
        }

        // Fallback placeholder while waveform loads or if analysis fails:
        // set bar height to half the configured maximum.
        let minHeight: CGFloat = 0.18
        let heightScale: CGFloat = 2.0
        let maxHeight = minHeight + (1 - minHeight) * heightScale
        return maxHeight * 0.5
    }

    private func loadAmplitudes() async {
        guard let track else {
            await MainActor.run { amplitudes = [] }
            return
        }

        let result = await WaveformAnalyzer.shared.amplitudes(for: track, totalBars: totalBars)
        await MainActor.run {
            amplitudes = result
        }
    }
}

actor WaveformAnalyzer {
    static let shared = WaveformAnalyzer()

    private var cache: [String: [CGFloat]] = [:]

    func amplitudes(for track: Track, totalBars: Int) async -> [CGFloat] {
        let key = "\(track.stableId)-\(totalBars)"
        if let cached = cache[key] {
            return cached
        }

        if let precomputed = decodeWaveformData(track.waveformData, totalBars: totalBars) {
            cache[key] = precomputed
            return precomputed
        }

        let computed = await computeAmplitudes(for: track, totalBars: totalBars)
        cache[key] = computed
        return computed
    }

    private func computeAmplitudes(for track: Track, totalBars: Int) async -> [CGFloat] {
        guard totalBars > 0 else { return [] }

        let url = URL(fileURLWithPath: track.path)

        do {
            let audioFile = try AVAudioFile(forReading: url)
            let totalFrames = max(1, Int(audioFile.length))
            let framesPerBar = max(1, totalFrames / totalBars)
            let channels = Int(audioFile.processingFormat.channelCount)

            var bars = [Float](repeating: 0, count: totalBars)

            let chunkSize = 4096
            audioFile.framePosition = 0

            while Int(audioFile.framePosition) < totalFrames {
                let remaining = totalFrames - Int(audioFile.framePosition)
                let framesToRead = min(chunkSize, remaining)

                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: audioFile.processingFormat,
                    frameCapacity: AVAudioFrameCount(framesToRead)
                ) else {
                    break
                }

                try audioFile.read(into: buffer, frameCount: AVAudioFrameCount(framesToRead))
                let framesRead = Int(buffer.frameLength)
                if framesRead == 0 { break }

                let startFrame = Int(audioFile.framePosition) - framesRead

                for frame in 0..<framesRead {
                    let amplitude = sampleAmplitude(buffer: buffer, frame: frame, channels: channels)
                    let globalFrame = startFrame + frame
                    let barIndex = min(totalBars - 1, globalFrame / framesPerBar)
                    if amplitude > bars[barIndex] {
                        bars[barIndex] = amplitude
                    }
                }
            }

            let maxAmp = bars.max() ?? 0
            if maxAmp > 0 {
                bars = bars.map { $0 / maxAmp }
            }

            return mapToHeights(bars, totalBars: totalBars)
        } catch {
            print("⚠️ Waveform analysis failed for \(track.title): \(error)")
            return []
        }
    }

    private func decodeWaveformData(_ waveformData: String?, totalBars: Int) -> [CGFloat]? {
        guard totalBars > 0, let waveformData, let data = waveformData.data(using: .utf8) else {
            return nil
        }

        struct WaveformPayload: Codable {
            let bars: [Float]
        }

        let decodedBars: [Float]
        if let payload = try? JSONDecoder().decode(WaveformPayload.self, from: data), !payload.bars.isEmpty {
            decodedBars = payload.bars
        } else if let array = try? JSONDecoder().decode([Float].self, from: data), !array.isEmpty {
            decodedBars = array
        } else {
            return nil
        }

        let resampled: [Float]
        if decodedBars.count == totalBars {
            resampled = decodedBars
        } else if decodedBars.count == 1 {
            resampled = Array(repeating: decodedBars[0], count: totalBars)
        } else {
            resampled = (0..<totalBars).map { i in
                let t = Double(i) / Double(max(1, totalBars - 1))
                let idx = Int(round(t * Double(decodedBars.count - 1)))
                return decodedBars[min(max(0, idx), decodedBars.count - 1)]
            }
        }

        let maxAmp = resampled.max() ?? 0
        let normalized = maxAmp > 0 ? resampled.map { $0 / maxAmp } : resampled
        return mapToHeights(normalized, totalBars: totalBars)
    }

    private func mapToHeights(_ bars: [Float], totalBars: Int) -> [CGFloat] {
        guard totalBars > 0 else { return [] }

        // Map to visual heights with a floor so quiet parts remain visible.
        let minHeight: CGFloat = 0.18
        let heightScale: CGFloat = 2.0
        let curveExponent: Float = 0.6
        if bars.count == totalBars {
            return bars.map { value in
                let shaped = powf(max(0, value), curveExponent)
                return minHeight + CGFloat(shaped) * (1 - minHeight) * heightScale
            }
        }

        // Fallback safety if counts don't match.
        return (0..<totalBars).map { i in
            let idx = min(max(0, i), bars.count - 1)
            let shaped = powf(max(0, bars[idx]), curveExponent)
            return minHeight + CGFloat(shaped) * (1 - minHeight) * heightScale
        }
    }

    private func sampleAmplitude(buffer: AVAudioPCMBuffer, frame: Int, channels: Int) -> Float {
        guard channels > 0 else { return 0 }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return 0 }
            var sum: Float = 0
            for ch in 0..<channels {
                sum += abs(data[ch][frame])
            }
            return sum / Float(channels)

        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return 0 }
            let scale = Float(Int16.max)
            var sum: Float = 0
            for ch in 0..<channels {
                sum += abs(Float(data[ch][frame])) / scale
            }
            return sum / Float(channels)

        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return 0 }
            let scale = Float(Int32.max)
            var sum: Float = 0
            for ch in 0..<channels {
                sum += abs(Float(data[ch][frame])) / scale
            }
            return sum / Float(channels)

        default:
            return 0
        }
    }
}

struct MiniPlayerView: View {
    @StateObject private var playerEngine = PlayerEngine.shared
    @StateObject private var artworkManager = ArtworkManager.shared
    @State private var isExpanded = false
    @State private var currentArtwork: UIImage?
    @State private var dragOffset: CGFloat = 0
    @State private var dominantColor: Color = .white
    
    var body: some View {
        Group {
            if playerEngine.currentTrack != nil {
                let halfScreenHeight = UIScreen.main.bounds.height / 2
                let miniPlayerOpacity = max(0, min(1, 1 - ((-dragOffset) / halfScreenHeight)))
                let expandGesture = DragGesture(minimumDistance: 10, coordinateSpace: .local)
                    .onChanged { value in
                        // Only track upward drags to create a seamless lift animation.
                        let translation = value.translation.height
                        if translation < 0 {
                            dragOffset = translation
                        }
                    }
                    .onEnded { value in
                        let translation = value.translation.height
                        let predicted = value.predictedEndTranslation.height
                        let shouldExpand = translation < -50 || predicted < -120
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                            dragOffset = 0
                        }
                        if shouldExpand {
                            isExpanded = true
                        }
                    }

                // Mini player that shows sheet when tapped
                VStack(spacing: 0) {
                    // Mini player content
                    HStack(spacing: 12) {
                        // Album artwork
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 60, height: 60)
                            
                            if let artwork = currentArtwork {
                                Image(uiImage: artwork)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                Image(systemName: "music.note")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        // Track info
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playerEngine.currentTrack?.title ?? "")
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .lineLimit(1)
                            
                            if let artistName = playerEngine.currentArtistName {
                                Text(artistName)
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        
                        Spacer()
                        
                        // Play/Pause button
                        Button(action: {
                            if playerEngine.isPlaying {
                                playerEngine.pause()
                            } else {
                                playerEngine.play()
                            }
                        }) {
                            Image(systemName: playerEngine.isPlaying ? "pause.circle" : "play.circle")
                                .font(.title)
                                .foregroundColor(.primary)
                                .animation(nil, value: playerEngine.isPlaying)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
                    .background(
                        GeometryReader { geometry in
                            let progress = playerEngine.duration > 0 ? playerEngine.playbackTime / playerEngine.duration : 0
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(.systemGray5))
                                Rectangle()
                                    .fill(dominantColor.opacity(0.5))
                                    .frame(width: geometry.size.width * progress)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    )
                    .cornerRadius(12)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .offset(y: dragOffset)
                    .opacity(miniPlayerOpacity)
                    .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.9), value: dragOffset)
                    .gesture(expandGesture)
                    .onTapGesture {
                        isExpanded = true
                    }
                }
                .sheet(isPresented: $isExpanded) {
                    // Full screen player as sheet
                    PlayerView()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                        .interactiveDismissDisabled(false)
                        .accentColor(dominantColor)
                }
                .onChange(of: isExpanded) { _, expanded in
                    if !expanded {
                        dragOffset = 0
                    }
                }
                .task(id: playerEngine.currentTrack?.stableId) {
                    if let track = playerEngine.currentTrack {
                        let artwork = await artworkManager.getArtwork(for: track)
                        await MainActor.run {
                            currentArtwork = artwork
                        }
                        if let artwork = artwork {
                            let color = await artwork.dominantColorAsync()
                            await MainActor.run {
                                dominantColor = color
                            }
                        } else {
                            await MainActor.run {
                                dominantColor = .white
                            }
                        }
                    } else {
                        await MainActor.run {
                            currentArtwork = nil
                            dominantColor = .white
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToArtistFromPlayer"))) { _ in
                    // Minimize the player when artist navigation is requested
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        isExpanded = false
                        dragOffset = 0 // Reset drag offset immediately
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToAlbumFromPlayer"))) { _ in
                    // Minimize the player when album navigation is requested
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        isExpanded = false
                        dragOffset = 0
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MinimizePlayer"))) { _ in
                    // Minimize the player when artwork is tapped
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        isExpanded = false
                        dragOffset = 0
                    }
                }
            }
        }
    }
}


struct TrackRowView: View, @MainActor Equatable {
    // 1. Pass these in instead of observing PlayerEngine
    let track: Track
    let activeTrackId: String?
    let isAudioPlaying: Bool
    
    let onTap: () -> Void
    let playlist: Playlist?
    let showDirectDeleteButton: Bool
    let onEnterBulkMode: (() -> Void)?
    
    @EnvironmentObject private var appCoordinator: AppCoordinator
    
    // Internal state only (does not trigger external redraws)
    @State private var isFavorite = false
    @State private var isPressed = false
    @State private var showPlaylistDialog = false
    @State private var artworkImage: UIImage?
    @State private var showDeleteConfirmation = false

    @State private var accentColor: Color = .white
    
    // 2. Computed property is now based on passed params
    private var isCurrentlyPlaying: Bool {
        activeTrackId == track.stableId
    }
    
    // 3. Equatable Conformance: Prevents redraws when PlayerEngine updates time
    static func == (lhs: TrackRowView, rhs: TrackRowView) -> Bool {
        return lhs.track.stableId == rhs.track.stableId &&
        lhs.activeTrackId == rhs.activeTrackId &&
        lhs.isAudioPlaying == rhs.isAudioPlaying &&
        lhs.isFavorite == rhs.isFavorite &&
        lhs.playlist?.id == rhs.playlist?.id
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Tappable Content Area
            HStack(spacing: 12) {
                // Album artwork thumbnail
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 60, height: 60)
                    
                    if let image = artworkImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                    
                    if isCurrentlyPlaying {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(accentColor, lineWidth: 2)
                            .frame(width: 60, height: 60)
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    if let artistId = track.artistId,
                       let artist = try? DatabaseManager.shared.read({ db in
                           try Artist.fetchOne(db, key: artistId)
                       }) {
                        Text(artist.name)
                            .font(.body)
                            .foregroundColor(isCurrentlyPlaying ? accentColor.opacity(0.8) : .secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                // Equalizer uses passed params
                if isCurrentlyPlaying {
                    let eqKey = "\(isAudioPlaying && isCurrentlyPlaying)-\(activeTrackId ?? "")"
                    
                    EqualizerBarsExact(
                        color: accentColor,
                        isActive: isAudioPlaying && isCurrentlyPlaying,
                        isLarge: true,
                        trackId: activeTrackId
                    )
                    .id(eqKey)
                    .padding(.trailing, 8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onTap()
            }
            
            // MARK: - Menu / Action Area
            if showDirectDeleteButton {
                Button(action: {
                    removeFromPlaylist()
                }) {
                    Image(systemName: "trash")
                        .font(.title2)
                        .foregroundColor(.red)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.red.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 8)
            } else {
                Menu {
                    if let onEnterBulkMode = onEnterBulkMode {
                        Button(action: { onEnterBulkMode() }) {
                            Label(Localized.select, systemImage: "checkmark.circle")
                        }
                    }
                    
                    Button(action: {
                        do {
                            try appCoordinator.toggleFavorite(trackStableId: track.stableId)
                            isFavorite.toggle()
                        } catch { print("Failed to toggle favorite: \(error)") }
                    }) {
                        HStack {
                            Image(systemName: isFavorite ? "heart.slash" : "heart")
                            Text(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs)
                        }
                    }
                    
                    if let artistId = track.artistId,
                       let artist = try? DatabaseManager.shared.read({ db in try Artist.fetchOne(db, key: artistId) }),
                       let allArtistTracks = try? DatabaseManager.shared.read({ db in try Track.filter(Column("artist_id") == artistId).fetchAll(db) }) {
                        NavigationLink(destination: ArtistDetailScreen(artist: artist, allTracks: allArtistTracks)) {
                            Label(Localized.showArtistPage, systemImage: "person.circle")
                        }
                    }
                    
                    Button(action: { showPlaylistDialog = true }) {
                        Label(Localized.addToPlaylistEllipsis, systemImage: "rectangle.stack.badge.plus")
                    }
                    
                    Button(action: { showDeleteConfirmation = true }) {
                        Label(Localized.deleteFile, systemImage: "trash")
                    }
                    .foregroundColor(.red)
                    
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .frame(height: 80)
        .padding(.horizontal, 12)
        .background(
            Group {
                let backgroundOpacity: Double = isPressed ? 0.12 : (isCurrentlyPlaying ? 0.07 : 0.0)
                RoundedRectangle(cornerRadius: 8)
                    .fill(accentColor.opacity(backgroundOpacity))
                    .opacity(backgroundOpacity > 0 ? 1.0 : 0.0)
            }
        )
        .sheet(isPresented: $showPlaylistDialog) {
            PlaylistSelectionView(track: track)
                .accentColor(accentColor)
        }
        .alert(Localized.deleteFile, isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { deleteFile() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(Localized.deleteFileConfirmation(track.title))
        }
        .onAppear {
            isFavorite = (try? appCoordinator.isFavorite(trackStableId: track.stableId)) ?? false
            if artworkImage == nil { loadArtwork() }
        }
    }
    
    private func loadArtwork() {
        Task {
            let image = await ArtworkManager.shared.getArtwork(for: track)
            await MainActor.run {
                artworkImage = image
                if let image {
                    accentColor = image.dominantColor()
                } else {
                    accentColor = .white
                }
            }
        }
    }
    
    private func deleteFile() {
        Task {
            do {
                let url = URL(fileURLWithPath: track.path)
                try FileManager.default.removeItem(at: url)
                try DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            } catch { print("❌ Failed to delete file: \(error)") }
        }
    }
    
    private func removeFromPlaylist() {
        guard let playlist = playlist, let playlistId = playlist.id else { return }
        Task {
            do {
                try appCoordinator.removeFromPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            } catch { print("❌ Failed to remove from playlist: \(error)") }
        }
    }
}

struct WaveformView: View {
    let isPlaying: Bool
    let color: Color
    @State private var waveHeights: [CGFloat] = Array(repeating: 2, count: 6)
    @State private var timer: Timer?
    @State private var animationTrigger = false
    
    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            ForEach(0..<waveHeights.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(color.opacity(0.8))
                    .frame(width: 2, height: waveHeights[index])
                    .animation(
                        .easeInOut(duration: 0.3)
                        .repeatForever(autoreverses: true),
                        value: animationTrigger
                    )
            }
        }
        .onAppear {
            startWaveform()
        }
        .onDisappear {
            stopWaveform()
        }
        .onChange(of: isPlaying) { newValue in
            if newValue {
                startWaveform()
            } else {
                stopWaveform()
            }
        }
    }
    
    private func startWaveform() {
        guard timer == nil && isPlaying else { return }
        
        // Start with animated heights
        updateWaveHeights()
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in
                if isPlaying {
                    updateWaveHeights()
                    animationTrigger.toggle()
                }
            }
        }
    }
    
    private func stopWaveform() {
        timer?.invalidate()
        timer = nil
        
        // Animate to flat line when stopped
        withAnimation(.easeOut(duration: 0.4)) {
            waveHeights = Array(repeating: 2, count: waveHeights.count)
        }
    }
    
    private func updateWaveHeights() {
        guard isPlaying else { return }
        
        let newHeights: [CGFloat] = [
            CGFloat.random(in: 3...12),
            CGFloat.random(in: 6...14),
            CGFloat.random(in: 2...10),
            CGFloat.random(in: 8...16),
            CGFloat.random(in: 4...11),
            CGFloat.random(in: 5...13)
        ]
        
        withAnimation(.easeInOut(duration: 0.3)) {
            waveHeights = newHeights
        }
    }
}
