//  Audio playback engine using AVAudioEngine

import Foundation
@preconcurrency import AVFAudio
import AVFoundation
import Combine
import MediaPlayer
import UIKit
import GRDB
import WidgetKit

@MainActor
class PlayerEngine: NSObject, ObservableObject {
    static let shared = PlayerEngine()
    
    @Published var currentTrack: Track?
    @Published var currentArtistName: String?
    @Published var isPlaying = false
    @Published var playbackTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackState: PlaybackState = .stopped
    @Published var playbackQueue: [Track] = []
    @Published var currentIndex = 0
    @Published var isRepeating = false
    @Published var isShuffled = false
    @Published var isLoopingSong = false
    @Published private(set) var isCrossfading = false
    
    private var originalQueue: [Track] = []
    
    // Generation token to prevent stale completion handlers from firing
    private var scheduleGeneration: UInt64 = 0
    
    private var seekTimeOffset: TimeInterval = 0
    private var lastSampleRate: Double = 0
    
    private lazy var audioEngine = AVAudioEngine()
    private lazy var playerNode = AVAudioPlayerNode()
    private lazy var secondaryPlayerNode = AVAudioPlayerNode()
    private lazy var crossfadeMixerNode = AVAudioMixerNode()
    private var audioFile: AVAudioFile?
    private var playbackTimer: Timer?

    // Gapless playback support
    private var nextAudioFile: AVAudioFile?
    private var nextTrack: Track?
    private var isPreloadingNext = false
    private var gaplessScheduled = false

    // EQ integration
    let eqManager = EQManager.shared
    
    private var isLoadingTrack = false
    private var currentLoadTask: Task<Void, Error>?
    private var hasRestoredState = false
    private var hasSetupAudioEngine = false
    private var hasSetupAudioSession = false
    private var hasSetupRemoteCommands = false
    private nonisolated(unsafe) var hasSetupAudioSessionNotifications = false
    private var lastRemoteCommandAt: TimeInterval = 0
    private var lastRemoteCommandKind = ""
    
    // Artwork caching
    private var cachedArtwork: MPMediaItemArtwork?
    private var cachedArtworkTrackId: String?

    // Artist name caching to avoid repeated database lookups
    private var cachedArtistName: String?
    private var cachedArtistTrackId: String?
    
    // Security-scoped resource tracking for external files
    private var activeSecurityScopedURLs: [URL] = []
    private var currentTrackURL: URL?
    
    private let databaseManager = DatabaseManager.shared
    private let cloudDownloadManager = CloudDownloadManager.shared
    
    // Enhanced Control Center synchronization (replaces MPNowPlayingSession approach)
    
    // System volume integration
    private var volumeObservation: NSKeyValueObservation?

    // Tiny fades to avoid clicks/pops on start/stop/seek/skip.
    private let clickFadeDuration: TimeInterval = 0.02
    private let clickFadeSteps: Int = 6
    private var fadeGeneration: UInt64 = 0

    // Crossfade state
    private var isPrimaryActive = true
    private var crossfadeGeneration: UInt64 = 0
    
    enum PlaybackState {
        case stopped
        case playing
        case paused
        case loading
    }
    
    private override init() {
        super.init()
        // Don't set up audio engine immediately - defer until first playback
        // setupAudioEngine()
        // Don't set up audio session immediately - defer until first playback
        // setupAudioSession()
        // Don't set up audio session notifications immediately - defer until first playback
        // setupAudioSessionNotifications()
        // Don't set up remote commands immediately - defer until first playback
        // setupRemoteCommands()
        // Don't set up volume control immediately - wait until we actually need it
        // setupBasicVolumeControl()
        setupMetadataUpdateListener()
    }

    private func setupMetadataUpdateListener() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TrackMetadataUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let userInfo = notification.userInfo,
                  let updatedTrack = userInfo["track"] as? Track else { return }
            let artistName = userInfo["artistName"] as? String
            Task { @MainActor in
                self.handleTrackMetadataUpdate(track: updatedTrack, artistName: artistName)
            }
        }
    }

    private func handleTrackMetadataUpdate(track updatedTrack: Track, artistName: String?) {
        // Update current track if it matches
        if currentTrack?.stableId == updatedTrack.stableId {
            currentTrack = updatedTrack

            // Update artist name if provided
            if let artistName = artistName {
                currentArtistName = artistName
                cachedArtistName = artistName
                cachedArtistTrackId = updatedTrack.stableId
            }

            // Update Now Playing info
            updateNowPlayingInfoEnhanced()
        }

        // Update track in queue if present
        if let index = playbackQueue.firstIndex(where: { $0.stableId == updatedTrack.stableId }) {
            playbackQueue[index] = updatedTrack
        }
        if let index = originalQueue.firstIndex(where: { $0.stableId == updatedTrack.stableId }) {
            originalQueue[index] = updatedTrack
        }
    }

    private func ensureAudioEngineSetup(with format: AVAudioFormat? = nil) {
        if !hasSetupAudioEngine {
            hasSetupAudioEngine = true
            setupAudioEngine(with: format)
            if let format = format {
                lastSampleRate = format.sampleRate
            }
        } else if let format = format {
            // Check if sample rate has changed - if so, force reconfiguration
            if abs(format.sampleRate - lastSampleRate) > 0.1 {
                reconfigureAudioEngineForNewFormat(format)
                lastSampleRate = format.sampleRate
                
                // Reset timing state completely when sample rate changes
                seekTimeOffset = 0
                playbackTime = 0
                // Stop and restart playback timer to ensure proper timing with new sample rate
                stopPlaybackTimer()
                if isPlaying {
                    startPlaybackTimer()
                }
            }
        }
    }
    
    private func reconfigureAudioEngineForNewFormat(_ format: AVAudioFormat) {
        // Force reconfiguration for new sample rate - stop engine if needed
        let wasRunning = audioEngine.isRunning
        if wasRunning {
            audioEngine.stop()
        }
        // Disconnect all nodes to rebuild the graph
        audioEngine.disconnectNodeInput(audioEngine.mainMixerNode)
        audioEngine.disconnectNodeInput(playerNode)
        audioEngine.disconnectNodeInput(secondaryPlayerNode)
        audioEngine.disconnectNodeInput(crossfadeMixerNode)
        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.disconnectNodeOutput(secondaryPlayerNode)
        audioEngine.disconnectNodeOutput(crossfadeMixerNode)
        // Reconnect players into a shared mixer, then EQ into the main mixer.
        audioEngine.connect(playerNode, to: crossfadeMixerNode, format: format)
        audioEngine.connect(secondaryPlayerNode, to: crossfadeMixerNode, format: format)
        // Reconnect with EQ: playerNode -> EQ -> mainMixerNode
        eqManager.insertEQIntoAudioGraph(between: crossfadeMixerNode, and: audioEngine.mainMixerNode, format: format)
        audioEngine.prepare()
        // Restart engine if it was running
        if wasRunning {
            do {
                try audioEngine.start()
            } catch {
                print("❌ Failed to restart audio engine: \(error)")
            }
        }
    }
    
    private func setupAudioEngine(with format: AVAudioFormat? = nil) {
        audioEngine.attach(playerNode)
        audioEngine.attach(secondaryPlayerNode)
        audioEngine.attach(crossfadeMixerNode)
        // Set up EQ manager with the audio engine
        eqManager.setAudioEngine(audioEngine)
        // Connect both players into a shared mixer, then EQ into the main mixer.
        audioEngine.connect(playerNode, to: crossfadeMixerNode, format: format)
        audioEngine.connect(secondaryPlayerNode, to: crossfadeMixerNode, format: format)
        eqManager.insertEQIntoAudioGraph(between: crossfadeMixerNode, and: audioEngine.mainMixerNode, format: format)
        audioEngine.connect(audioEngine.mainMixerNode,
                            to: audioEngine.outputNode,
                            format: audioEngine.mainMixerNode.outputFormat(forBus: 0))
        // CRITICAL: Prepare the engine to guarantee render loop activity
        audioEngine.prepare()
        // Don't start the engine here - wait until we actually need to play
    }
    
    
    private func ensureAudioSessionSetup() {
        guard !hasSetupAudioSession else { return }
        hasSetupAudioSession = true
        
        do {
            try setupAudioSessionCategory(reason: "ensureAudioSessionSetup")
        } catch {
            print("Failed to setup audio session category: \(error)")
            logAudioSessionState("ensureAudioSessionSetup failed")
            // Continue anyway - we'll try to handle this when actually playing
        }
    }
    
    private func ensureAudioSessionNotificationsSetup() {
        guard !hasSetupAudioSessionNotifications else { return }
        hasSetupAudioSessionNotifications = true
        setupAudioSessionNotifications()
    }
    
    private func setupAudioSessionNotifications() {
        // Handle audio session interruptions (calls, other apps, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        // Handle route changes (headphones disconnected, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        
        // CRITICAL for iOS 18: Listen for media services reset
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
        
        // Listen for memory pressure warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            // Save current playback position before interruption
            let savedPosition = playbackTime
            
            if isPlaying {
                pause()
            }
            
            // IMPORTANT: Don't stop the audio engine during interruption
            // Stopping it can invalidate the audioFile and cause position loss
            // The system will handle the interruption, we just need to pause
            
            // Restore the saved position (pause() may have updated it)
            playbackTime = savedPosition
            
        case .ended:
            // Check if we should resume playback
            let shouldResume: Bool
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                shouldResume = options.contains(.shouldResume)
            } else {
                shouldResume = false
            }
            
            // Only auto-resume if the system tells us to after an interruption
            // Don't auto-resume for user-initiated interruptions (like audio messages)
            if shouldResume && playbackState == .paused {
                play()
            } else {
                // Ensure playback state is correct but keep position saved
                isPlaying = false
                playbackState = .paused
                updateNowPlayingInfoEnhanced()
            }
            
        @unknown default:
            break
        }
    }
    
    @objc private func handleAudioSessionRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .oldDeviceUnavailable:
            // Headphones were unplugged or similar
            if isPlaying {
                pause()
            }
        default:
            break
        }
    }
    
    @objc private func handleMediaServicesReset(_ notification: Notification) {
        Task { @MainActor in
            // Stop current playback
            let wasPlaying = isPlaying
            let currentTime = playbackTime
            let currentTrackCopy = currentTrack
            
            // Clean up current audio engine and nodes
            await cleanupAudioEngineForReset()
            
            // Recreate audio engine and nodes
            recreateAudioEngine()
            
            // Restore playback if needed
            if let track = currentTrackCopy {
                await loadTrack(track, preservePlaybackTime: true)
                if wasPlaying {
                    playbackTime = currentTime
                    play()
                }
            }
        }
    }
    
    @objc private func handleMemoryWarning(_ notification: Notification) {
        print("⚠️ Memory warning received - cleaning up audio resources")
        
        Task { @MainActor in
            // Clear cached artwork to free memory
            cachedArtwork = nil
            cachedArtworkTrackId = nil
            
            // If not currently playing, stop audio engine to free resources
            if !isPlaying {
                audioEngine.stop()
            }
            
            // Force garbage collection of any retained buffers
            playerNode.stop()
            secondaryPlayerNode.stop()
            
        }
    }
    
    private func setupBasicVolumeControl() {
        // Ensure audio session is ready before observing output volume
        ensureAudioSessionSetup()

        // Initial sync on main
        DispatchQueue.main.async { [weak self] in
            self?.syncWithSystemVolume()
        }

        // Observe system volume changes instead of polling
        volumeObservation?.invalidate()
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, change in
            guard let self else { return }
            let newVolume = change.newValue ?? session.outputVolume
            Task { @MainActor in
                self.updateAudioEngineVolume(to: newVolume)
            }
        }
    }
    
    private func syncWithSystemVolume() {
        // Only sync if audio session has been set up
        guard hasSetupAudioSession else {
            return
        }
        
        let systemVolume = AVAudioSession.sharedInstance().outputVolume
        updateAudioEngineVolume(to: systemVolume)
    }
    
    private func updateAudioEngineVolume(to volume: Float) {
        audioEngine.mainMixerNode.outputVolume = volume
    }

    private func currentSystemVolume() -> Float {
        AVAudioSession.sharedInstance().outputVolume
    }

    private func fadeMainMixer(
        to targetVolume: Float,
        duration: TimeInterval,
        steps: Int = 6,
        completion: (() -> Void)? = nil
    ) {
        let clampedSteps = max(1, steps)
        let startVolume = audioEngine.mainMixerNode.outputVolume

        guard duration > 0, clampedSteps > 1 else {
            audioEngine.mainMixerNode.outputVolume = targetVolume
            completion?()
            return
        }

        fadeGeneration &+= 1
        let generation = fadeGeneration

        for step in 1...clampedSteps {
            let progress = Float(step) / Float(clampedSteps)
            let delay = duration * Double(step) / Double(clampedSteps)
            let volume = startVolume + (targetVolume - startVolume) * progress

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.fadeGeneration == generation else { return }
                self.audioEngine.mainMixerNode.outputVolume = volume
                if step == clampedSteps {
                    completion?()
                }
            }
        }
    }

    private func fadeOutForClickAvoidance() async {
        await withCheckedContinuation { continuation in
            fadeMainMixer(
                to: 0,
                duration: clickFadeDuration,
                steps: clickFadeSteps
            ) {
                continuation.resume()
            }
        }
    }

    private func restoreMixerVolumeAfterFade() {
        updateAudioEngineVolume(to: currentSystemVolume())
    }

    private var activePlayerNode: AVAudioPlayerNode {
        isPrimaryActive ? playerNode : secondaryPlayerNode
    }

    private var inactivePlayerNode: AVAudioPlayerNode {
        isPrimaryActive ? secondaryPlayerNode : playerNode
    }

    private func swapActivePlayerNode() {
        isPrimaryActive.toggle()
    }

    private func crossfadeConfiguration() -> (enabled: Bool, duration: TimeInterval) {
        let settings = DeleteSettings.load()
        let duration = min(max(settings.crossfadeDuration, 0.1), 12.0)
        return (settings.crossfadeEnabled, duration)
    }

    private func fadePlayerNode(
        _ node: AVAudioPlayerNode,
        to targetVolume: Float,
        duration: TimeInterval,
        steps: Int,
        generation: UInt64,
        completion: (() -> Void)? = nil
    ) {
        let clampedSteps = max(1, steps)
        let startVolume = node.volume

        guard duration > 0, clampedSteps > 1 else {
            node.volume = targetVolume
            completion?()
            return
        }

        for step in 1...clampedSteps {
            let progress = Float(step) / Float(clampedSteps)
            let delay = duration * Double(step) / Double(clampedSteps)
            let volume = startVolume + (targetVolume - startVolume) * progress

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.crossfadeGeneration == generation else { return }
                node.volume = volume
                if step == clampedSteps {
                    completion?()
                }
            }
        }
    }
    
    private func ensureRemoteCommandsSetup() {
        guard !hasSetupRemoteCommands else { return }
        hasSetupRemoteCommands = true
        setupRemoteCommands()
    }

    private func shouldHandleRemoteCommand(_ kind: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let window: TimeInterval = 0.25
        let grouped = Set(["play", "pause", "toggle"])
        if now - lastRemoteCommandAt < window,
           grouped.contains(kind),
           grouped.contains(lastRemoteCommandKind) {
            return false
        }
        lastRemoteCommandAt = now
        lastRemoteCommandKind = kind
        return true
    }
    
    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        
        // Play command handler - will be called from Control Center
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldHandleRemoteCommand("play") else { return }
                self.play()
            }
            return .success
        }
        
        // Pause command handler - will be called from Control Center
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldHandleRemoteCommand("pause") else { return }
                self.pause(fromControlCenter: true)
            }
            return .success
        }
        
        cc.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                let shouldAutoplay = self?.isPlaying ?? false
                await self?.nextTrack(autoplay: shouldAutoplay)
            }
            return .success
        }
        
        cc.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                let shouldAutoplay = self?.isPlaying ?? false
                await self?.previousTrack(autoplay: shouldAutoplay)
            }
            return .success
        }
        
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            
            // Perform seek synchronously for CarPlay
            let positionTime = e.positionTime
            
            Task { @MainActor in
                await self.seek(to: positionTime)
            }
            
            return .success
        }
        
        // Toggle play/pause command (for headphone button and other accessories)
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shouldHandleRemoteCommand("toggle") else { return }
                if self.isPlaying {
                    self.pause(fromControlCenter: true)
                } else {
                    self.play()
                }
            }
            return .success
        }
        
        // Enable all commands initially
        cc.playCommand.isEnabled = true
        cc.pauseCommand.isEnabled = true
        cc.nextTrackCommand.isEnabled = true
        cc.previousTrackCommand.isEnabled = true
        cc.changePlaybackPositionCommand.isEnabled = true
        cc.togglePlayPauseCommand.isEnabled = true
        
        // Enable seeking in CarPlay
        cc.changePlaybackPositionCommand.isEnabled = true
    }
    
    // MARK: - Widget Integration

    func updateWidgetData() {
        guard let track = currentTrack else {
            WidgetDataManager.shared.clearCurrentTrack()
            return
        }
        
        Task { @MainActor in
            // Get artwork
            let artwork = await ArtworkManager.shared.getArtwork(for: track)
            let artworkData = artwork?.pngData()

            // Get artist name
            let artistName: String
            if let artistId = track.artistId,
               let artist = try? DatabaseManager.shared.read({ db in
                   try Artist.fetchOne(db, key: artistId)
               }) {
                artistName = artist.name
            } else {
                artistName = Localized.unknownArtist
            }

            // Use a consistent widget background color
            let colorHex = "FFFFFF"

            let widgetData = WidgetTrackData(
                trackId: track.stableId,
                title: track.title,
                artist: artistName,
                isPlaying: isPlaying,
                backgroundColorHex: colorHex
            )

            WidgetDataManager.shared.saveCurrentTrack(widgetData, artworkData: artworkData)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    
    
    // Enhanced manual approach with better Control Center synchronization
    private func updateNowPlayingInfoEnhanced() {
        guard let track = currentTrack else {
            // Clear Now Playing info if no track
            DispatchQueue.main.async {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
            return
        }
        
        // Use live node timing only while actively playing to prevent scrub bar drift when paused.
        var currentTime = playbackTime
        if isPlaying,
           let audioFile = audioFile,
           hasSetupAudioEngine,
           audioEngine.isRunning,
           let nodeTime = activePlayerNode.lastRenderTime,
           let playerTime = activePlayerNode.playerTime(forNodeTime: nodeTime) {
            let nodePlaybackTime = Double(playerTime.sampleTime) / audioFile.processingFormat.sampleRate
            currentTime = seekTimeOffset + nodePlaybackTime
        }
        
        // Create comprehensive Now Playing info
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: playbackQueue.count
        ]
        
        // Add queue position
        if playbackQueue.indices.contains(currentIndex) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex
        }
        
        // Add artist name from cache (avoids repeated database lookups)
        if let artistName = getCachedArtistName(for: track) {
            info[MPMediaItemPropertyArtist] = artistName
        }
        
        // Add cached artwork
        if let cachedArtwork = cachedArtwork, cachedArtworkTrackId == track.stableId {
            info[MPMediaItemPropertyArtwork] = cachedArtwork
        } else {
            print("⚠️ No cached artwork available for: \(track.title) (cached: \(cachedArtwork != nil), trackId match: \(cachedArtworkTrackId == track.stableId))")
        }
        
        // Update with explicit synchronization
        DispatchQueue.main.async {
            // Update Now Playing Info
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            
            // Trigger CarPlay Now Playing button update
            #if os(iOS) && !targetEnvironment(macCatalyst)
            MPNowPlayingInfoCenter.default().playbackState = self.isPlaying ? .playing : .paused
            #endif
            
            // Notify CarPlay delegate of state change
            NotificationCenter.default.post(name: NSNotification.Name("PlayerStateChanged"), object: nil)
        }
        
        // Load artwork asynchronously if needed (ArtworkManager handles caching/extraction)
        if cachedArtworkTrackId != track.stableId {
            Task {
                await loadAndCacheArtwork(track: track)
            }
        }
    }

    /// Get cached artist name, loading from DB only if not cached for this track
    private func getCachedArtistName(for track: Track) -> String? {
        // Return cached value if it's for the current track
        if cachedArtistTrackId == track.stableId, let name = cachedArtistName {
            return name
        }

        // Load from database and cache
        guard let artistId = track.artistId else { return nil }

        do {
            if let artist = try databaseManager.read({ db in
                try Artist.fetchOne(db, key: artistId)
            }) {
                cachedArtistName = artist.name
                cachedArtistTrackId = track.stableId
                return artist.name
            }
        } catch {
            print("Failed to fetch artist: \(error)")
        }
        return nil
    }

    // MARK: - Audio Session Management
    
    private func audioRouteSummary(_ session: AVAudioSession) -> String {
        let outputs = session.currentRoute.outputs
        guard !outputs.isEmpty else { return "none" }
        return outputs.map { "\($0.portType.rawValue) (\($0.portName))" }.joined(separator: ", ")
    }

    private func describeCategoryOptions(_ options: AVAudioSession.CategoryOptions) -> String {
        if options.isEmpty { return "[]" }
        var parts: [String] = []
        if options.contains(.mixWithOthers) { parts.append("mixWithOthers") }
        if options.contains(.duckOthers) { parts.append("duckOthers") }
        if options.contains(.interruptSpokenAudioAndMixWithOthers) { parts.append("interruptSpokenAudioAndMix") }
        if options.contains(.allowAirPlay) { parts.append("allowAirPlay") }
        if options.contains(.defaultToSpeaker) { parts.append("defaultToSpeaker") }
        if #available(iOS 14.5, *) {
            if options.contains(.overrideMutedMicrophoneInterruption) { parts.append("overrideMutedMicInterruption") }
        }
        return "[\(parts.joined(separator: ","))]"
    }

    private func appStateSummary() -> String {
        switch UIApplication.shared.applicationState {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }

    private func currentQueueLabel() -> String {
        let label = String(cString: __dispatch_queue_get_label(nil), encoding: .utf8)
        return label ?? "unknown"
    }

    private func logAudioSessionState(_ label: String, _ session: AVAudioSession = .sharedInstance()) {
        let outputs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue) (\($0.portName)) [\($0.uid)]" }
            .joined(separator: ", ")
        let inputs = session.currentRoute.inputs
            .map { "\($0.portType.rawValue) (\($0.portName)) [\($0.uid)]" }
            .joined(separator: ", ")
        let availableInputs = session.availableInputs?
            .map { "\($0.portType.rawValue) (\($0.portName)) [\($0.uid)]" }
            .joined(separator: ", ") ?? "none"
        let preferredInput = session.preferredInput
            .map { "\($0.portType.rawValue) (\($0.portName)) [\($0.uid)]" } ?? "none"

        let category = session.category.rawValue
        let mode = session.mode.rawValue
        let options = describeCategoryOptions(session.categoryOptions)
        let sampleRate = String(format: "%.0f", session.sampleRate)
        let ioBuffer = String(format: "%.3f", session.ioBufferDuration)
        let preferredSampleRate = String(format: "%.0f", session.preferredSampleRate)
        let preferredIOBuffer = String(format: "%.3f", session.preferredIOBufferDuration)
        let outputVolume = String(format: "%.2f", session.outputVolume)
        let otherAudio = session.isOtherAudioPlaying
        let shouldSilence = session.secondaryAudioShouldBeSilencedHint
        let appState = appStateSummary()
        let thread = Thread.isMainThread ? "main" : "bg"
        let queue = currentQueueLabel()
    }
    
    private func setupAudioSessionCategory(reason: String) throws {
        let s = AVAudioSession.sharedInstance()
        
        // Playback-only app: no mic usage, so no Bluetooth/AirPlay options needed.
        // Avoid setting options to prevent paramErr (-50) on some Bluetooth routes.
        let options: AVAudioSession.CategoryOptions = []
        let desiredCategory = AVAudioSession.Category.playback
        let desiredMode = AVAudioSession.Mode.default
        let desiredOptions = describeCategoryOptions(options)
        let appState = appStateSummary()
        let thread = Thread.isMainThread ? "main" : "bg"
        let queue = currentQueueLabel()

        do {
            try s.setCategory(desiredCategory, mode: desiredMode, options: options)
        } catch {
            let nsError = error as NSError
            print("❌ Audio session setCategory failed reason=\(reason) (domain: \(nsError.domain), code: \(nsError.code), desired: \(desiredCategory.rawValue)/\(desiredMode.rawValue) options=\(desiredOptions), route: \(audioRouteSummary(s)))")
            logAudioSessionState("setCategory failed (\(reason))", s)
            let stack = Thread.callStackSymbols.prefix(12).joined(separator: " | ")
            throw error
        }
        
        // iOS 18 Fix: Set preferred I/O buffer duration
        do {
            try s.setPreferredIOBufferDuration(0.050) // 50ms buffer - more stable under load
        } catch {
            let nsError = error as NSError
            print("⚠️ Preferred I/O buffer duration rejected (domain: \(nsError.domain), code: \(nsError.code), requested: 0.05s, route: \(audioRouteSummary(s)))")
            logAudioSessionState("preferred IO buffer rejected", s)
        }
    }
    
    private func activateAudioSession() throws {
        let s = AVAudioSession.sharedInstance()

        // Set category first if needed
        try setupAudioSessionCategory(reason: "activateAudioSession")
        
        // Always try to activate (iOS manages the actual state)
        let appState = appStateSummary()
        let thread = Thread.isMainThread ? "main" : "bg"
        let queue = currentQueueLabel()
        do {
            try s.setActive(true, options: [])
        } catch {
            let nsError = error as NSError
            print("❌ Audio session setActive failed reason=activateAudioSession (domain: \(nsError.domain), code: \(nsError.code), route: \(audioRouteSummary(s)))")
            logAudioSessionState("activateAudioSession setActive failed", s)
            let stack = Thread.callStackSymbols.prefix(12).joined(separator: " | ")
            throw error
        }
        print("⏲️ Audio buffer: \(s.ioBufferDuration)s")
        
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    func deactivateAudioSessionIfIdle(reason: String) {
        guard !isPlaying else { return }
        guard UIApplication.shared.applicationState == .background else { return }

        let s = AVAudioSession.sharedInstance()
        let appState = appStateSummary()
        let thread = Thread.isMainThread ? "main" : "bg"
        let queue = currentQueueLabel()

        do {
            try s.setActive(false, options: [.notifyOthersOnDeactivation])
            UIApplication.shared.endReceivingRemoteControlEvents()
        } catch {
            let nsError = error as NSError
            print("❌ Audio session setActive(false) failed reason=\(reason) (domain: \(nsError.domain), code: \(nsError.code), route: \(audioRouteSummary(s)))")
            logAudioSessionState("deactivateAudioSessionIfIdle failed", s)
            let stack = Thread.callStackSymbols.prefix(12).joined(separator: " | ")
        }
    }
    
    // MARK: - iOS 18 Audio Engine Reset Management
    
    private func cleanupAudioEngineForReset() async {
        // Stop all audio activity
        playerNode.stop()
        secondaryPlayerNode.stop()
        audioEngine.stop()
        
        // Remove all connections
        audioEngine.detach(playerNode)
        audioEngine.detach(secondaryPlayerNode)
        audioEngine.detach(crossfadeMixerNode)
        
        // Clear any scheduled buffers
        playerNode.reset()
        secondaryPlayerNode.reset()
    }
    
    private func recreateAudioEngine() {
        // Create fresh instances
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        secondaryPlayerNode = AVAudioPlayerNode()
        crossfadeMixerNode = AVAudioMixerNode()
        // Set up the graph again with EQ
        audioEngine.attach(playerNode)
        audioEngine.attach(secondaryPlayerNode)
        audioEngine.attach(crossfadeMixerNode)
        eqManager.setAudioEngine(audioEngine)
        audioEngine.connect(playerNode, to: crossfadeMixerNode, format: nil)
        audioEngine.connect(secondaryPlayerNode, to: crossfadeMixerNode, format: nil)
        eqManager.insertEQIntoAudioGraph(between: crossfadeMixerNode, and: audioEngine.mainMixerNode, format: nil)
        // Reset flags
        hasSetupAudioEngine = false
        hasSetupAudioSession = false
        hasSetupRemoteCommands = false
        hasSetupAudioSessionNotifications = false
        isPrimaryActive = true
        isCrossfading = false
    }
    
    
    
    // MARK: - Playback Control

    private func stopAccessingSecurityScopedResources(except keepURL: URL? = nil) {
        activeSecurityScopedURLs = activeSecurityScopedURLs.filter { url in
            if let keepURL, url == keepURL {
                return true
            }
            url.stopAccessingSecurityScopedResource()
            return false
        }
    }

    private func resolveTrackURL(_ track: Track, stopPreviousScopes: Bool) async throws -> URL {
        if stopPreviousScopes {
            stopAccessingSecurityScopedResources()
            currentTrackURL = nil
        }

        if let resolvedURL = await LibraryIndexer.shared.resolveBookmarkForTrack(track) {
            guard resolvedURL.startAccessingSecurityScopedResource() else {
                print("❌ Failed to start accessing security-scoped resource")
                throw PlayerError.fileNotFound
            }
            if !activeSecurityScopedURLs.contains(resolvedURL) {
                activeSecurityScopedURLs.append(resolvedURL)
            }
            return resolvedURL
        }

        return URL(fileURLWithPath: track.path)
    }

    private func loadAudioFile(for track: Track, stopPreviousScopes: Bool) async throws -> (file: AVAudioFile, url: URL) {
        let url = try await resolveTrackURL(track, stopPreviousScopes: stopPreviousScopes)

        try await cloudDownloadManager.ensureLocal(url)

        // Remove file protection to prevent background stalls
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none],
                                               ofItemAtPath: url.path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlayerError.fileNotFound
        }

        let file = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let audioFile = try AVAudioFile(forReading: url)
                    continuation.resume(returning: audioFile)
                } catch {
                    print("❌ Failed to load AVAudioFile: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }

        return (file, url)
    }

    func loadTrack(_ track: Track, preservePlaybackTime: Bool = false) async {
        // Cancel any ongoing load operation
        currentLoadTask?.cancel()

        // Prevent concurrent loading
        guard !isLoadingTrack else {
            print("⚠️ Already loading track, skipping: \(track.title)")
            return
        }

        isLoadingTrack = true

        // Stop current playback and clean up
        await cleanupCurrentPlayback(resetTime: !preservePlaybackTime)

        // Reset timing state when loading a new track to ensure clean state for new sample rate
        if !preservePlaybackTime {
            seekTimeOffset = 0
            playbackTime = 0
        }

        // Clear cached artwork when loading new track
        cachedArtwork = nil
        cachedArtworkTrackId = nil


        currentTrack = track
        currentArtistName = getCachedArtistName(for: track)
        playbackState = .loading

        // Volume control is initialized on first playback

        do {
            let loaded = try await loadAudioFile(for: track, stopPreviousScopes: true)
            audioFile = loaded.file
            currentTrackURL = loaded.url

            guard let audioFile = audioFile else {
                throw PlayerError.invalidAudioFile
            }

            duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

            // Ensure audio engine is setup for playback
            ensureAudioEngineSetup(with: audioFile.processingFormat)

            if !preservePlaybackTime {
                playbackTime = 0
            }

            await configureAudioSession(for: audioFile.processingFormat)

            // Ensure remote commands are set up for Control Center
            ensureRemoteCommandsSetup()
            
            // Force immediate Control Center update with new track info and reset timing
            updateNowPlayingInfoEnhanced()
            
            playbackState = .stopped
            isLoadingTrack = false
            
        } catch {
            print("Failed to load track: \(error)")
            playbackState = .stopped
            isLoadingTrack = false
            audioFile = nil
        }
    }
    
    func play() {
        // If no audio file is loaded but we have a current track, load it first
        if audioFile == nil && currentTrack != nil && !isLoadingTrack {
            Task {
                // If state was already restored but audioFile is nil (e.g., after interruption),
                // we need to reload the current track with preserved position
                if hasRestoredState {
                    let savedPosition = playbackTime
                    await loadTrack(currentTrack!, preservePlaybackTime: true)
                    
                    // Restore position after reload
                    if savedPosition > 0 {
                        await seek(to: savedPosition)
                    }
                } else {
                    // First-time state restoration
                    await ensurePlayerStateRestored()
                }
                
                // After loading, try to play again
                DispatchQueue.main.async {
                    self.play()
                }
            }
            return
        }
        
        guard let audioFile = audioFile,
              playbackState != .loading,
              !isLoadingTrack else {
            print("⚠️ Cannot play: audioFile=\(audioFile != nil), state=\(playbackState), loading=\(isLoadingTrack)")
            return
        }
        
        // Set up audio engine only when needed (FIRST) with file's format
        // For new tracks, always ensure proper format configuration
        ensureAudioEngineSetup(with: audioFile.processingFormat)
        
        // Ensure basic audio session setup first
        ensureAudioSessionSetup()
        
        // CRITICAL: Activate audio session BEFORE starting engine (iOS 18 fix)
        do {
            try activateAudioSession()
        } catch {
            print("❌ Session activate failed: \(error)")
            logAudioSessionState("activateAudioSession failed")
            // Try to continue anyway - might still work
        }
        
        if playbackState == .paused {
            // When resuming from pause, we need to re-schedule audio from the correct position
            // instead of just continuing the engine, because the timing may have drifted
            cancelPendingCompletions()
            activePlayerNode.stop()
            inactivePlayerNode.stop()
            activePlayerNode.volume = 1.0
            inactivePlayerNode.volume = 0.0
            crossfadeGeneration &+= 1
            isCrossfading = false
            
            // Re-schedule from the stored pause position
            // Note: audioFile is already unwrapped from the guard statement above
            
            // CRITICAL: Update seekTimeOffset to match the resume position
            // This ensures time calculation (seekTimeOffset + nodePlaybackTime) is correct
            seekTimeOffset = playbackTime
            
            let framePosition = AVAudioFramePosition(playbackTime * audioFile.processingFormat.sampleRate)
            
            // IMPORTANT: Ensure audio engine is running BEFORE scheduling
            do {
                if !audioEngine.isRunning {
                    try audioEngine.start()
                }
            } catch {
                print("❌ Failed to start audio engine when resuming: \(error)")
                return
            }
            
            scheduleSegment(on: activePlayerNode, from: framePosition, file: audioFile)

            // Tiny fade-in to avoid a click on resume.
            let targetVolume = currentSystemVolume()
            audioEngine.mainMixerNode.outputVolume = 0
            activePlayerNode.play()
            fadeMainMixer(to: targetVolume, duration: clickFadeDuration, steps: clickFadeSteps)
            isPlaying = true
            playbackState = .playing
            startPlaybackTimer()
            
            // Update Now Playing info with enhanced approach
            updateNowPlayingInfoEnhanced()
            updateWidgetData()
            return
        }
        
        cancelPendingCompletions()
        activePlayerNode.stop()
        inactivePlayerNode.stop()
        activePlayerNode.volume = 1.0
        inactivePlayerNode.volume = 0.0
        crossfadeGeneration &+= 1
        isCrossfading = false
        
        // Check if the file length is reasonable
        guard audioFile.length > 0 && audioFile.length < 1_000_000_000 else {
            print("❌ Invalid audio file length: \(audioFile.length)")
            return
        }
        
        // IMPORTANT: Ensure audio engine is running BEFORE scheduling
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                print("❌ Failed to start audio engine: \(error)")
                return
            }
        }
        
        // Preserve current seek offset and playback time when resuming
        let currentPosition = playbackTime
        let startFrame = AVAudioFramePosition(currentPosition * audioFile.processingFormat.sampleRate)
        
        // Schedule appropriate segment based on current position
        if startFrame > 0 && startFrame < audioFile.length {
            // Continue from current position
            seekTimeOffset = currentPosition
            scheduleSegment(on: activePlayerNode, from: startFrame, file: audioFile)
        } else {
            // Start from beginning - but only reset if we're actually at the beginning
            if playbackTime > 1.0 {
                // We're not actually at the beginning, so preserve current position
                let startFrame2 = AVAudioFramePosition(playbackTime * audioFile.processingFormat.sampleRate)
                seekTimeOffset = playbackTime
                scheduleSegment(on: activePlayerNode, from: startFrame2, file: audioFile)
            } else {
                // Actually starting from beginning
                seekTimeOffset = 0
                playbackTime = 0
                scheduleSegment(on: activePlayerNode, from: 0, file: audioFile)
            }
        }
        
        // Set up audio session notifications only when needed
        ensureAudioSessionNotificationsSetup()
        
        // Set up remote commands only when needed
        ensureRemoteCommandsSetup()
        
        // Set up volume control if not already done
        if volumeObservation == nil {
            setupBasicVolumeControl()
        }

        // Tiny fade-in to avoid a click on start.
        let targetVolume = currentSystemVolume()
        audioEngine.mainMixerNode.outputVolume = 0
        activePlayerNode.play()
        fadeMainMixer(to: targetVolume, duration: clickFadeDuration, steps: clickFadeSteps)
        isPlaying = true
        playbackState = .playing
        startPlaybackTimer()
        
        // Update Now Playing info with enhanced approach
        updateNowPlayingInfoEnhanced()
        updateWidgetData()
    }
    
    func pause(fromControlCenter: Bool = false) {
        // Capture current playback position before pausing
        if let audioFile = audioFile,
           let nodeTime = activePlayerNode.lastRenderTime,
           let playerTime = activePlayerNode.playerTime(forNodeTime: nodeTime) {
            let nodePlaybackTime = Double(playerTime.sampleTime) / audioFile.processingFormat.sampleRate
            let currentPosition = seekTimeOffset + nodePlaybackTime

            // Store the exact pause position
            playbackTime = currentPosition
            seekTimeOffset = currentPosition
        }
        
        // Use a tiny fade-out before pausing to avoid clicks/pops.
        fadeMainMixer(to: 0, duration: clickFadeDuration, steps: clickFadeSteps) { [weak self] in
            guard let self else { return }
            self.audioEngine.pause()
            self.inactivePlayerNode.stop()
            self.inactivePlayerNode.volume = 0.0
            self.activePlayerNode.volume = 1.0
            self.crossfadeGeneration &+= 1
            self.isCrossfading = false
            self.restoreMixerVolumeAfterFade()
        }
        
        // Update state
        isPlaying = false
        playbackState = .paused
        stopPlaybackTimer()

        // Update Now Playing info with enhanced approach
        updateNowPlayingInfoEnhanced()
        updateWidgetData()
        
        // Save state when pausing
        savePlayerState()
        
        deactivateAudioSessionIfIdle(reason: "pauseInBackground")
    }
    
    @inline(__always)
    private func cancelPendingCompletions() {
        scheduleGeneration &+= 1
    }
    
    func stop() {
        cancelPendingCompletions()
        fadeMainMixer(to: 0, duration: clickFadeDuration, steps: clickFadeSteps) { [weak self] in
            guard let self else { return }
            self.playerNode.stop()
            self.secondaryPlayerNode.stop()
            self.playerNode.volume = 1.0
            self.secondaryPlayerNode.volume = 0.0
            self.isPrimaryActive = true
            self.crossfadeGeneration &+= 1
            self.isCrossfading = false
            self.restoreMixerVolumeAfterFade()
        }
        isPlaying = false
        playbackState = .stopped
        playbackTime = 0
        
        // Stop accessing any security-scoped resources.
        stopAccessingSecurityScopedResources()
        currentTrackURL = nil
        stopPlaybackTimer()
        
        // Update Now Playing info to show stopped state (but keep track info)
        updateNowPlayingInfoEnhanced()
        
        // Don't clear remote commands during track transitions - keep Control Center connected
        // Remote commands should only be cleared when the app is truly shutting down
        
        // Deactivate audio session only when idle in background per Apple guidance.
        
        // Save state when stopping
        savePlayerState()
        
        deactivateAudioSessionIfIdle(reason: "stopInBackground")
    }
    
    private func cleanupCurrentPlayback(resetTime: Bool = false) async {
        // Stop accessing security-scoped resources unless we are mid-crossfade.
        if !isCrossfading {
            stopAccessingSecurityScopedResources()
            currentTrackURL = nil
        }

        // Stop timer first
        stopPlaybackTimer()

        // Tiny fade-out before stopping to avoid clicks on track transitions.
        if !isCrossfading && (isPlaying || activePlayerNode.isPlaying || inactivePlayerNode.isPlaying) {
            await fadeOutForClickAvoidance()
        }

        // Stop both player nodes and reset their volumes.
        playerNode.stop()
        secondaryPlayerNode.stop()
        playerNode.volume = 1.0
        secondaryPlayerNode.volume = 0.0
        isPrimaryActive = true
        crossfadeGeneration &+= 1
        isCrossfading = false
        restoreMixerVolumeAfterFade()

        // NEVER deactivate session during cleanup - this causes 30-second suspension on iOS 18

        // Reset state
        isPlaying = false
        if resetTime { playbackTime = 0 }

        // Keep audio engine running for next playback
        // Don't stop the engine here as it causes the error message
    }

    func seek(to time: TimeInterval) async {
        // If no audio file is loaded but we have a current track, load it first
        if audioFile == nil && currentTrack != nil && !isLoadingTrack {
            await ensurePlayerStateRestored()
        }
        
        guard let audioFile = audioFile,
              !isLoadingTrack else {
            print("⚠️ Cannot seek: audioFile=\(audioFile != nil), loading=\(isLoadingTrack)")
            return
        }
        
        let framePosition = AVAudioFramePosition(time * audioFile.processingFormat.sampleRate)
        let wasPlaying = isPlaying
        
        // Ensure framePosition is valid
        guard framePosition >= 0 && framePosition < audioFile.length else {
            print("❌ Invalid seek position: \(framePosition), file length: \(audioFile.length)")
            return
        }
        
        // Ensure audio engine is set up before seeking with file's format
        ensureAudioEngineSetup(with: audioFile.processingFormat)
        
        // Ensure audio engine is running before scheduling
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                print("❌ Failed to start audio engine during seek: \(error)")
                return
            }
        }

        if wasPlaying && (isPlaying || activePlayerNode.isPlaying || inactivePlayerNode.isPlaying) {
            await fadeOutForClickAvoidance()
        }

        cancelPendingCompletions()
        activePlayerNode.stop()
        inactivePlayerNode.stop()
        activePlayerNode.volume = 1.0
        inactivePlayerNode.volume = 0.0
        crossfadeGeneration &+= 1
        isCrossfading = false
        
        scheduleSegment(on: activePlayerNode, from: framePosition, file: audioFile)
        
        // Update seek offset and playback time
        seekTimeOffset = time
        playbackTime = time
        
        if wasPlaying {
            let targetVolume = currentSystemVolume()
            audioEngine.mainMixerNode.outputVolume = 0
            activePlayerNode.play()
            fadeMainMixer(to: targetVolume, duration: clickFadeDuration, steps: clickFadeSteps)
            isPlaying = true
            playbackState = .playing
            startPlaybackTimer()
            
            // Update Now Playing info after seek
            updateNowPlayingInfoEnhanced()
        } else {
            // Update position even when paused
            updateNowPlayingInfoEnhanced()
        }
        
    }
    
    // MARK: - Audio Scheduling Helper
    
    private func scheduleSegment(on node: AVAudioPlayerNode, from startFrame: AVAudioFramePosition, file: AVAudioFile) {
        // Safety check: Ensure audio engine is running
        guard audioEngine.isRunning else {
            print("❌ Cannot schedule segment: audio engine is not running")
            return
        }
        
        // Validate startFrame is within bounds
        guard startFrame >= 0 && startFrame < file.length else {
            print("❌ Invalid startFrame: \(startFrame), file length: \(file.length)")
            return
        }
        
        let remaining = file.length - startFrame
        guard remaining > 0 else {
            print("❌ No remaining frames to schedule: startFrame=\(startFrame), length=\(file.length)")
            return
        }
        
        // Validate that frameCount doesn't overflow AVAudioFrameCount
        guard remaining <= AVAudioFrameCount.max else {
            print("❌ Remaining frames exceed AVAudioFrameCount.max: \(remaining)")
            return
        }
        
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        let nodeID = ObjectIdentifier(node)

        node.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(remaining),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.scheduleGeneration == generation else { return }
                guard ObjectIdentifier(self.activePlayerNode) == nodeID else { return }
                guard self.isPlaying, !self.isCrossfading else { return }
                await self.handleTrackEnd()
            }
        }

    }
    
    // MARK: - Index Normalization Helper
    
    private func normalizeIndexAndTrack() {
        if playbackQueue.isEmpty {
            currentIndex = 0
            currentTrack = nil
            currentArtistName = nil
            return
        }
        
        if let ct = currentTrack,
           let idx = playbackQueue.firstIndex(where: { $0.stableId == ct.stableId }) {
            currentIndex = idx
        } else {
            currentIndex = max(0, min(currentIndex, playbackQueue.count - 1))
            let track = playbackQueue[currentIndex]
            currentTrack = track
            currentArtistName = getCachedArtistName(for: track)
        }
    }
    
    // MARK: - Queue Management
    
    func shuffleAndPlay(_ tracks: [Track], beforePlay: (() async -> Void)? = nil) async {
        guard !tracks.isEmpty else { return }

        let settings = WeightedShuffleSettings.load()

        var kept: [Track]
        if settings.isEnabled {
            kept = tracks.filter { track in
                guard let rating = track.rating, rating >= 1, rating <= 5 else {
                    return true // unrated tracks always included
                }
                let probability = settings.ratingWeights[rating - 1]
                return Double.random(in: 0..<1.0) < probability
            }
            if kept.isEmpty { kept = tracks }
        } else {
            kept = tracks
        }

        let startIndex = Int.random(in: 0..<kept.count)
        let startTrack = kept[startIndex]
        var shuffled = kept
        shuffled.remove(at: startIndex)
        shuffled.shuffle()
        shuffled.insert(startTrack, at: 0)

        await beforePlay?()
        await playTrack(startTrack, queue: shuffled)
    }

    func playTrack(_ track: Track, queue: [Track] = []) async {
        // An explicit play request should not trigger state restoration, which can
        // race and overwrite the intended track/queue.
        hasRestoredState = true

        let previousTrack = currentTrack

        playbackQueue = queue.isEmpty ? [track] : queue

        // Defensive: ensure the requested track exists in the queue. If it doesn't,
        // we anchor it at the front so normalization can't silently fall back to index 0.
        if playbackQueue.firstIndex(where: { $0.stableId == track.stableId }) == nil {
            print("⚠️ Requested track not found in queue, inserting at front: \(track.title)")
            playbackQueue.insert(track, at: 0)
        }

        // Save original queue for shuffle functionality
        originalQueue = playbackQueue

        let targetIndex = playbackQueue.firstIndex(where: { $0.stableId == track.stableId }) ?? 0

        // Increment play count immediately when a track is requested to play
        incrementPlayCount(for: track)

        // If we're already playing something else, try to crossfade instead of hard switching.
        if isPlaying, audioFile != nil, previousTrack?.stableId != track.stableId {
            let config = crossfadeConfiguration()
            if config.enabled {
                let didCrossfade = await crossfadeToTrack(at: targetIndex, duration: config.duration, reason: "play track")
                if didCrossfade { return }
            }
        }

        currentIndex = targetIndex

        // Explicitly set the current track to ensure UI synchronization
        currentTrack = track
        currentArtistName = getCachedArtistName(for: track)

        normalizeIndexAndTrack()

        await loadTrack(track)

        // Auto-play immediately after loading completes
        DispatchQueue.main.async { [weak self] in
            self?.play()
        }
    }

    private func incrementPlayCount(for track: Track) {
        Task {
            do {
                let newPlayCount = try DatabaseManager.shared.incrementPlayCount(trackStableId: track.stableId)

                // Update currentTrack if it's the same track
                await MainActor.run {
                    if self.currentTrack?.stableId == track.stableId {
                        self.currentTrack?.playCount = newPlayCount
                    }
                    // Post notification for other views
                    NotificationCenter.default.post(
                        name: NSNotification.Name("TrackPlayCountUpdated"),
                        object: nil,
                        userInfo: ["stableId": track.stableId, "playCount": newPlayCount]
                    )
                }
            } catch {
                print("⚠️ Failed to increment play count: \(error)")
            }
        }
    }

    func nextTrack(autoplay: Bool? = nil) async {
        guard !playbackQueue.isEmpty, !isLoadingTrack else { return }
        normalizeIndexAndTrack()
        let shouldAutoplay = autoplay ?? isPlaying

        let nextIndex = (currentIndex + 1) % playbackQueue.count
        let nextTrackToPlay = playbackQueue[nextIndex]

        // Increment play count for the next track
        incrementPlayCount(for: nextTrackToPlay)

        if shouldAutoplay, audioFile != nil {
            let config = crossfadeConfiguration()
            if config.enabled {
                let didCrossfade = await crossfadeToTrack(at: nextIndex, duration: config.duration, reason: "skip next")
                if didCrossfade { return }
            }
        }

        currentIndex = nextIndex
        await loadTrack(nextTrackToPlay, preservePlaybackTime: false)

        if shouldAutoplay {
            DispatchQueue.main.async { [weak self] in
                self?.play()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cancelPendingCompletions()
                self.playerNode.stop()
                self.secondaryPlayerNode.stop()
                self.playerNode.volume = 1.0
                self.secondaryPlayerNode.volume = 0.0
                self.isPrimaryActive = true
                self.isCrossfading = false
                self.isPlaying = false
                self.playbackState = .paused
                self.seekTimeOffset = 0
                self.playbackTime = 0
                self.updateNowPlayingInfoEnhanced()
                self.updateWidgetData()
            }
        }
    }
    
    func previousTrack(autoplay: Bool? = nil) async {
        guard !playbackQueue.isEmpty, !isLoadingTrack else { return }
        normalizeIndexAndTrack()

        let wasPlaying = autoplay ?? isPlaying

        let prevIndex = currentIndex > 0 ? currentIndex - 1 : playbackQueue.count - 1
        let prevTrackToPlay = playbackQueue[prevIndex]

        // Increment play count for the previous track
        incrementPlayCount(for: prevTrackToPlay)

        if wasPlaying, audioFile != nil {
            let config = crossfadeConfiguration()
            if config.enabled {
                let didCrossfade = await crossfadeToTrack(at: prevIndex, duration: config.duration, reason: "skip previous")
                if didCrossfade { return }
            }
        }

        currentIndex = prevIndex
        await loadTrack(prevTrackToPlay, preservePlaybackTime: false)

        if wasPlaying {
            await MainActor.run {
                play()
            }
        } else {
            await MainActor.run {
                cancelPendingCompletions()
                playerNode.stop()
                secondaryPlayerNode.stop()
                playerNode.volume = 1.0
                secondaryPlayerNode.volume = 0.0
                isPrimaryActive = true
                isCrossfading = false
                isPlaying = false
                playbackState = .paused
                seekTimeOffset = 0
                playbackTime = 0
                updateNowPlayingInfoEnhanced()
                updateWidgetData()
            }
        }
    }
    
    func addToQueue(_ track: Track) {
        playbackQueue.append(track)
    }
    
    func insertNext(_ track: Track) {
        let insertIndex = currentIndex + 1
        playbackQueue.insert(track, at: min(insertIndex, playbackQueue.count))
    }
    
    func cycleLoopMode() {
        if !isRepeating && !isLoopingSong {
            // Off → Queue Loop
            isRepeating = true
            isLoopingSong = false
        } else if isRepeating && !isLoopingSong {
            // Queue Loop → Track Loop
            isRepeating = false
            isLoopingSong = true
        } else {
            // Track Loop → Off
            isRepeating = false
            isLoopingSong = false
        }
    }
    
    func toggleShuffle() {
        isShuffled.toggle()
        
        if isShuffled {
            // Save original order and shuffle the queue
            originalQueue = playbackQueue
            shuffleQueue()
        } else {
            // Restore original order
            restoreOriginalQueue()
        }
        
        normalizeIndexAndTrack()
    }
    
    private func shuffleQueue() {
        guard !playbackQueue.isEmpty else { return }
        normalizeIndexAndTrack()
        let anchor = playbackQueue[currentIndex]
        var rest = playbackQueue
        rest.remove(at: currentIndex)
        rest.shuffle()
        playbackQueue = [anchor] + rest
        currentIndex = 0
    }
    
    private func restoreOriginalQueue() {
        guard !originalQueue.isEmpty else { return }
        
        // Find current track in original queue
        if let currentTrack = self.currentTrack,
           let originalIndex = originalQueue.firstIndex(where: { $0.stableId == currentTrack.stableId }) {
            playbackQueue = originalQueue
            currentIndex = originalIndex
        }
        
        normalizeIndexAndTrack()
    }
    
    // MARK: - Audio Session Configuration

    private var lastConfiguredNativeSampleRate: Double = 0

    private func configureAudioSession(for format: AVAudioFormat) async {
        let targetSampleRate = Double(currentTrack?.sampleRate ?? Int(format.sampleRate))

        // Skip reconfiguration if sample rate hasn't changed
        if abs(lastConfiguredNativeSampleRate - targetSampleRate) < 1.0 {
            return
        }

        let session = AVAudioSession.sharedInstance()
        
        // Ensure the session category is set before applying preferences.
        do {
            try setupAudioSessionCategory(reason: "configureAudioSession targetSR=\(targetSampleRate)")
        } catch {
            let nsError = error as NSError
            print("❌ Audio session category setup failed before sample rate config (domain: \(nsError.domain), code: \(nsError.code), route: \(audioRouteSummary(session)))")
            logAudioSessionState("pre-sample-rate category setup failed", session)
            return
        }
        
        // If we're already effectively at this rate, avoid poking SessionCore again.
        if abs(session.sampleRate - targetSampleRate) < 1.0 {
            lastConfiguredNativeSampleRate = session.sampleRate
            return
        }
        
        do {
            try session.setPreferredSampleRate(targetSampleRate)
        } catch {
            let nsError = error as NSError
            // Common CoreAudio paramErr (-50) can surface here on unsupported routes/rates.
            print("⚠️ Preferred sample rate rejected (domain: \(nsError.domain), code: \(nsError.code), requested: \(targetSampleRate)Hz, route: \(audioRouteSummary(session))) - keeping \(session.sampleRate)Hz")
            logAudioSessionState("preferred sample rate rejected", session)
            let stack = Thread.callStackSymbols.prefix(12).joined(separator: " | ")
            // Avoid retry spam on the same unsupported rate.
            lastConfiguredNativeSampleRate = session.sampleRate
            return
        }
        
        
        lastConfiguredNativeSampleRate = targetSampleRate
    }
    
    // MARK: - Timer and Updates
    
    func startPlaybackTimer() {
        stopPlaybackTimer()
        
        // Use a modest interval with tolerance to reduce wakeups.
        let interval: TimeInterval = 0.25
        playbackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updatePlaybackTime()
            }
        }
        playbackTimer?.tolerance = interval * 0.5
    }

    private func nextIndexForAutoAdvance() -> Int? {
        guard !playbackQueue.isEmpty else { return nil }
        if isLoopingSong { return nil }
        if currentIndex < playbackQueue.count - 1 {
            return currentIndex + 1
        }
        if isRepeating {
            return 0
        }
        return nil
    }

    private func crossfadeSteps(for duration: TimeInterval) -> Int {
        let base = max(6, Int(duration / 0.03))
        return min(base, 60)
    }

    private func crossfadeToTrack(at index: Int, duration requestedDuration: TimeInterval, reason: String) async -> Bool {
        guard !isCrossfading, !isLoadingTrack else { return false }
        guard playbackQueue.indices.contains(index) else { return false }
        guard let currentFile = audioFile else { return false }

        let config = crossfadeConfiguration()
        guard config.enabled else { return false }

        let remainingTime = max(0.0, duration - playbackTime)
        let effectiveDuration = min(requestedDuration, config.duration, max(0.05, remainingTime))

        guard effectiveDuration >= 0.05 else { return false }

        let nextTrack = playbackQueue[index]
        let oldURL = currentTrackURL
        let oldTrack = currentTrack
        let oldArtistName = currentArtistName
        let oldIndex = currentIndex

        do {
            let loaded = try await loadAudioFile(for: nextTrack, stopPreviousScopes: false)
            let nextFile = loaded.file
            let nextURL = loaded.url

            let currentRate = currentFile.processingFormat.sampleRate
            let nextRate = nextFile.processingFormat.sampleRate
            if abs(currentRate - nextRate) > 1.0 {
                print("⚠️ Skipping crossfade due to sample-rate mismatch: \(currentRate)Hz → \(nextRate)Hz")
                stopAccessingSecurityScopedResources(except: oldURL)
                return false
            }

            ensureAudioEngineSetup(with: nextFile.processingFormat)
            ensureAudioSessionSetup()

            if !audioEngine.isRunning {
                try audioEngine.start()
            }

            crossfadeGeneration &+= 1
            let generation = crossfadeGeneration
            isCrossfading = true

            let fromNode = activePlayerNode
            let toNode = inactivePlayerNode

            // Update UI/metadata first, then perform the audio crossfade.
            currentTrack = nextTrack
            currentArtistName = getCachedArtistName(for: nextTrack)
            currentIndex = index
            // Reset time-related UI state immediately so the scrub bar starts at 0
            // while the audio crossfade completes on the old active node.
            seekTimeOffset = 0
            playbackTime = 0
            duration = Double(nextFile.length) / nextFile.processingFormat.sampleRate
            updateNowPlayingInfoEnhanced()
            updateWidgetData()

            toNode.stop()
            toNode.reset()
            toNode.volume = 0.0
            fromNode.volume = 1.0

            scheduleSegment(on: toNode, from: 0, file: nextFile)
            toNode.play()

            let steps = crossfadeSteps(for: effectiveDuration)

            fadePlayerNode(fromNode, to: 0.0, duration: effectiveDuration, steps: steps, generation: generation)
            fadePlayerNode(toNode, to: 1.0, duration: effectiveDuration, steps: steps, generation: generation) { [weak self] in
                guard let self, self.crossfadeGeneration == generation else { return }

                fromNode.stop()
                fromNode.volume = 0.0

                self.swapActivePlayerNode()
                self.audioFile = nextFile
                self.seekTimeOffset = 0
                self.playbackTime = 0
                self.duration = Double(nextFile.length) / nextFile.processingFormat.sampleRate
                self.currentTrackURL = nextURL
                self.isPlaying = true
                self.playbackState = .playing
                self.isCrossfading = false

                self.stopAccessingSecurityScopedResources(except: nextURL)

                self.updateNowPlayingInfoEnhanced()
                self.updateWidgetData()
            }

            return true
        } catch {
            print("❌ Crossfade failed: \(error)")
            stopAccessingSecurityScopedResources(except: oldURL)
            currentTrack = oldTrack
            currentArtistName = oldArtistName
            currentIndex = oldIndex
            updateNowPlayingInfoEnhanced()
            updateWidgetData()
            isCrossfading = false
            return false
        }
    }
    
    private func updatePlaybackTime() async {
        // During crossfade the active node/audioFile still belong to the old track.
        // Avoid updating playbackTime from the old node so the new track's scrub bar
        // does not "resume" from the previous position.
        if isCrossfading { return }
        guard let audioFile = audioFile,
              let nodeTime = activePlayerNode.lastRenderTime,
              let playerTime = activePlayerNode.playerTime(forNodeTime: nodeTime) else {
            return
        }
        
        // Add seek offset to handle scheduleSegment from non-zero positions
        // playerTime.sampleTime is in the file's sample rate, so use file rate for calculation
        let nodePlaybackTime = Double(playerTime.sampleTime) / audioFile.processingFormat.sampleRate
        let calculatedTime = seekTimeOffset + nodePlaybackTime
        let remainingTime = max(0.0, duration - calculatedTime)
        
        // Only update playback time if we're actually playing (prevents drift during pause/resume)
        if isPlaying {
            playbackTime = calculatedTime
        }

        // Trigger crossfade slightly before the end of the track.
        if isPlaying, !isCrossfading, let nextIndex = nextIndexForAutoAdvance() {
            let config = crossfadeConfiguration()
            if config.enabled, remainingTime <= config.duration + 0.05, remainingTime > 0.05 {
                let requested = min(config.duration, remainingTime)
                _ = await crossfadeToTrack(at: nextIndex, duration: requested, reason: "track end")
            }
        }
        
        // Control Center updates are event-driven (play/pause/seek/track change),
        // so avoid periodic updates here to reduce energy/IPC overhead.
    }
    
    private func handleTrackEnd() async {
        guard !isLoadingTrack else { return }
        guard !isCrossfading else { return }

        if let nextIndex = nextIndexForAutoAdvance() {
            let nextTrackToPlay = playbackQueue[nextIndex]
            incrementPlayCount(for: nextTrackToPlay)

            let config = crossfadeConfiguration()
            if config.enabled, isPlaying {
                let didCrossfade = await crossfadeToTrack(at: nextIndex, duration: config.duration, reason: "track end fallback")
                if didCrossfade { return }
            }

            currentIndex = nextIndex
            await loadTrack(nextTrackToPlay, preservePlaybackTime: false)
            play()
            return
        }

        stop()
    }
    
    
    func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
    
    // MARK: - Now Playing Info
    
    private func loadAndCacheArtwork(track: Track) async {
        guard let image = await ArtworkManager.shared.getArtwork(for: track) else {
            return
        }

        let artwork = createNowPlayingArtwork(from: image)
        cachedArtwork = artwork
        cachedArtworkTrackId = track.stableId

        updateNowPlayingInfoWithCachedArtwork()
    }

    private nonisolated func createNowPlayingArtwork(from image: UIImage) -> MPMediaItemArtwork {
        // Crop to square if width is significantly larger than height
        let processedImage = cropToSquareIfNeeded(image: image)

        // Use 500x500 to avoid upscaling most artworks
        let targetSize = CGSize(width: 500, height: 500)
        return MPMediaItemArtwork(boundsSize: targetSize) { size in
            // Resize image to requested size
            return self.resizeImage(processedImage, to: size)
        }
    }
    
    private func updateNowPlayingInfoWithCachedArtwork() {
        guard let track = currentTrack,
              let cachedArtwork = cachedArtwork,
              cachedArtworkTrackId == track.stableId else { return }

        // Get current now playing info and add artwork
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowPlayingInfo[MPMediaItemPropertyArtwork] = cachedArtwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private nonisolated func cropToSquareIfNeeded(image: UIImage) -> UIImage {
        let width = image.size.width
        let height = image.size.height
        
        // If the image is already square or taller than wide, return as-is
        if width <= height {
            return image
        }
        
        // If width is more than 20% larger than height, crop to square
        let aspectRatio = width / height
        if aspectRatio > 1.2 {
            // Calculate the square size (use height as the dimension)
            let squareSize = height
            
            // Calculate the crop rect (center the crop horizontally)
            let xOffset = (width - squareSize) / 2
            let cropRect = CGRect(x: xOffset, y: 0, width: squareSize, height: squareSize)
            
            // Perform the crop
            guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
                print("⚠️ Failed to crop image, returning original")
                return image
            }
            
            return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
        }
        
        // Return original if aspect ratio is acceptable
        return image
    }
    
    private nonisolated func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - State Persistence
    
    func savePlayerState() {
        guard let currentTrack = currentTrack else {
            return
        }
        
        let playerState: [String: Any] = [
            "currentTrackStableId": currentTrack.stableId,
            "playbackTime": playbackTime,
            "isPlaying": false, // Always save as paused to prevent auto-play on launch
            "queueTrackIds": playbackQueue.map { $0.stableId },
            "currentIndex": currentIndex,
            "isRepeating": isRepeating,
            "isShuffled": isShuffled,
            "isLoopingSong": isLoopingSong,
            "originalQueueTrackIds": originalQueue.map { $0.stableId },
            "lastSavedAt": Date()
        ]
        
        UserDefaults.standard.set(playerState, forKey: "MusicPlayerState")
        UserDefaults.standard.synchronize()
    }
    
    private func ensurePlayerStateRestored() async {
        guard !hasRestoredState else { return }
        hasRestoredState = true
        
        // Only load the audio file if we have a current track from UI restoration
        if let currentTrack = currentTrack {
            let savedPosition = playbackTime // Save the position before loadTrack
            await loadTrack(currentTrack, preservePlaybackTime: true)
            
            // Restore the playback position after loading (if position was saved)
            if savedPosition > 0 {
                await seek(to: savedPosition)
            }
        }
    }
    
    func restoreUIStateOnly() async {
        guard let playerStateDict = UserDefaults.standard.dictionary(forKey: "MusicPlayerState") else {
            return
        }
        
        guard let lastSavedAt = playerStateDict["lastSavedAt"] as? Date else {
            print("🚫 Invalid saved state format")
            return
        }
        
        // Don't restore if the saved state is too old (more than 7 days)
        let daysSinceLastSave = Date().timeIntervalSince(lastSavedAt) / (24 * 60 * 60)
        if daysSinceLastSave > 7 {
            print("⏰ Saved state is too old (\(Int(daysSinceLastSave)) days), skipping restore")
            return
        }
        
        // Find the current track by stable ID
        guard let currentTrackStableId = playerStateDict["currentTrackStableId"] as? String else {
            print("🚫 No current track in saved state")
            return
        }
        
        do {
            let track = try DatabaseManager.shared.read { db in
                try Track.filter(Column("stable_id") == currentTrackStableId).fetchOne(db)
            }
            
            guard let restoredTrack = track else {
                print("🚫 Could not find saved track with ID: \(currentTrackStableId)")
                return
            }
            
            // Restore queue by finding tracks with stable IDs
            let queueTrackIds = playerStateDict["queueTrackIds"] as? [String] ?? []
            let originalQueueTrackIds = playerStateDict["originalQueueTrackIds"] as? [String] ?? []
            
            let queueTracks = try DatabaseManager.shared.read { db in
                try queueTrackIds.compactMap { stableId in
                    try Track.filter(Column("stable_id") == stableId).fetchOne(db)
                }
            }
            
            let originalQueueTracks = try DatabaseManager.shared.read { db in
                try originalQueueTrackIds.compactMap { stableId in
                    try Track.filter(Column("stable_id") == stableId).fetchOne(db)
                }
            }
            
            // Restore UI state only - no audio loading
            await MainActor.run {
                self.playbackQueue = queueTracks.isEmpty ? [restoredTrack] : queueTracks
                self.originalQueue = originalQueueTracks.isEmpty ? [restoredTrack] : originalQueueTracks
                
                let savedIndex = playerStateDict["currentIndex"] as? Int ?? 0
                self.currentIndex = max(0, min(savedIndex, self.playbackQueue.count - 1))
                
                self.isRepeating = playerStateDict["isRepeating"] as? Bool ?? false
                self.isShuffled = playerStateDict["isShuffled"] as? Bool ?? false
                self.isLoopingSong = playerStateDict["isLoopingSong"] as? Bool ?? false
                self.currentTrack = restoredTrack
                
                // Validate restored state consistency
                if self.isLoopingSong && self.playbackQueue.count == 1 {
                } else if self.isLoopingSong {
                }
                
                // Additional validation for shuffle state
                if !self.isShuffled {
                    // When not shuffled, ensure currentIndex points to the actual currentTrack
                    if let currentTrack = self.currentTrack,
                       self.currentIndex < self.playbackQueue.count,
                       self.playbackQueue[self.currentIndex].stableId != currentTrack.stableId {
                        // Find the correct index for the current track
                        if let correctIndex = self.playbackQueue.firstIndex(where: { $0.stableId == currentTrack.stableId }) {
                            print("⚠️ Fixed currentIndex from \(self.currentIndex) to \(correctIndex) for non-shuffled queue")
                            self.currentIndex = correctIndex
                        } else {
                            print("⚠️ Current track not found in queue, resetting to index 0")
                            self.currentIndex = 0
                        }
                    }
                }
                
                // Set saved position for UI display
                let savedTime = playerStateDict["playbackTime"] as? TimeInterval ?? 0
                self.playbackTime = savedTime
                
                // Set duration from track metadata for UI display
                if let durationMs = restoredTrack.durationMs {
                    self.duration = Double(durationMs) / 1000.0 // Convert ms to seconds
                } else {
                    self.duration = 0
                }
                
                // Set playback state to stopped so it doesn't show as playing
                self.playbackState = .stopped
                self.isPlaying = false

                // Normalize index and track after restoration
                self.normalizeIndexAndTrack()
            }
            
        } catch {
            print("❌ Failed to restore UI state: \(error)")
        }
    }
    
}
enum PlayerError: Error {
    case fileNotFound
    case invalidAudioFile
}
