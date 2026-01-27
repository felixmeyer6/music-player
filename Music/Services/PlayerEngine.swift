//  PlayerEngine.swift
//  Cosmos Music Player
//
//  Audio playback engine using AVAudioEngine for high-resolution FLAC playback
//
import Foundation
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
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var hasSetupRemoteCommands = false
    private nonisolated(unsafe) var hasSetupAudioSessionNotifications = false
    private var backgroundCheckTimer: Timer?
    
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
    private var silentPlayer: AVAudioPlayer?
    private var pausedSilentPlayer: AVAudioPlayer?
    private nonisolated(unsafe) var volumeCheckTimer: Timer?
    private var lastKnownVolume: Float = -1
    private var isUserChangingVolume = false
    private var lastVolumeChangeTime: Date = Date()
    private var rapidChangeDetected = false

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
        setupPeriodicStateSaving()
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
                print("📊 Sample rate changed from \(lastSampleRate)Hz to \(format.sampleRate)Hz - forcing reconfiguration")
                reconfigureAudioEngineForNewFormat(format)
                lastSampleRate = format.sampleRate
                
                // Reset timing state completely when sample rate changes
                seekTimeOffset = 0
                playbackTime = 0
                lastControlCenterUpdate = 0
                
                // Stop and restart playback timer to ensure proper timing with new sample rate
                stopPlaybackTimer()
                if isPlaying {
                    startPlaybackTimer()
                }
                print("🔄 Reset timing state and timer for new sample rate")
            }
        }
    }
    
    private func reconfigureAudioEngineForNewFormat(_ format: AVAudioFormat) {
        // Force reconfiguration for new sample rate - stop engine if needed
        let wasRunning = audioEngine.isRunning
        if wasRunning {
            audioEngine.stop()
            print("🛑 Stopped audio engine for reconfiguration")
        }
        print("🔧 Reconfiguring audio engine for new format: \(format.sampleRate)Hz")
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
        print("✅ Audio engine reconfigured with EQ for sample rate: \(format.sampleRate)Hz")
        // Restart engine if it was running
        if wasRunning {
            do {
                try audioEngine.start()
                print("▶️ Restarted audio engine after reconfiguration")
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
        print("✅ Audio engine configured and prepared with EQ integration, format: \(format?.description ?? "auto")")
    }
    
    
    private func ensureAudioSessionSetup() {
        guard !hasSetupAudioSession else { return }
        hasSetupAudioSession = true
        
        do {
            try setupAudioSessionCategory()
        } catch {
            print("Failed to setup audio session category: \(error)")
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
            print("🚫 Audio session interruption began - pausing playback")
            // Save current playback position before interruption
            let savedPosition = playbackTime
            let wasPlaying = isPlaying
            
            if isPlaying {
                pause()
            }
            
            // IMPORTANT: Don't stop the audio engine during interruption
            // Stopping it can invalidate the audioFile and cause position loss
            // The system will handle the interruption, we just need to pause
            print("⏸️ Keeping audio engine in paused state during interruption")
            
            // Restore the saved position (pause() may have updated it)
            playbackTime = savedPosition
            print("💾 Saved playback position: \(savedPosition)s (was playing: \(wasPlaying))")
            
        case .ended:
            print("✅ Audio session interruption ended")
            print("💾 Will restore to position: \(playbackTime)s when playback resumes")
            
            // Check if we should resume playback
            let shouldResume: Bool
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                shouldResume = options.contains(.shouldResume)
                print("🔍 Interruption options: shouldResume = \(shouldResume)")
            } else {
                shouldResume = false
                print("🔍 No interruption options - will not auto-resume")
            }
            
            // Only auto-resume if the system tells us to after an interruption
            // Don't auto-resume for user-initiated interruptions (like audio messages)
            if shouldResume && playbackState == .paused {
                print("▶️ Auto-resuming playback after interruption")
                play()
            } else {
                print("⏸️ Not auto-resuming - user must manually resume")
                
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
            print("🎧 Audio device disconnected - pausing playback")
            if isPlaying {
                pause()
            }
        default:
            break
        }
    }
    
    @objc private func handleMediaServicesReset(_ notification: Notification) {
        print("🔄 Media services were reset - need to recreate audio engine and nodes")
        
        Task { @MainActor in
            // Stop current playback
            let wasPlaying = isPlaying
            let currentTime = playbackTime
            let currentTrackCopy = currentTrack
            
            // Clean up current audio engine and nodes
            await cleanupAudioEngineForReset()
            
            // Recreate audio engine and nodes
            recreateAudioEngine()
            
            // Reactivate audio session after reset
            try? activateAudioSession()
            
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
                print("🛑 Stopped audio engine due to memory pressure")
            }
            
            // Force garbage collection of any retained buffers
            playerNode.stop()
            secondaryPlayerNode.stop()
            
            print("🧹 Cleaned up audio resources due to memory warning")
        }
    }
    
    private func setupBasicVolumeControl() {
        print("🎛️ Setting up basic volume control...")
        
        // Delay the initial sync slightly to ensure audio session is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.syncWithSystemVolume()
        }
        
        // Start monitoring system volume changes
        startVolumeTimer()
        
        print("✅ Basic volume control enabled")
    }
    
    private func setupSilentPlayer() {
        // Create a silent audio file to play (required for accurate volume monitoring)
        guard let silenceURL = Bundle.main.url(forResource: "silence", withExtension: "mp3") else {
            // If no silence file, create one programmatically
            createSilenceFile()
            return
        }
        
        do {
            silentPlayer = try AVAudioPlayer(contentsOf: silenceURL)
            silentPlayer?.volume = 0.0
            silentPlayer?.numberOfLoops = -1  // Loop indefinitely
            silentPlayer?.prepareToPlay()
            print("🔇 Silent player created for volume monitoring")
        } catch {
            print("❌ Failed to create silent player: \(error)")
            createSilenceFile()
        }
    }
    
    private func createSilenceFile() {
        // Generate a tiny bit of silence programmatically
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        
        // Buffer is already silent (zero-filled by default)
        
        do {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("silence.caf")
            let audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            try audioFile.write(from: buffer)
            
            silentPlayer = try AVAudioPlayer(contentsOf: tempURL)
            silentPlayer?.volume = 0.01  // Very low but not zero
            silentPlayer?.numberOfLoops = -1
            silentPlayer?.prepareToPlay()
            print("🔇 Generated silent player for volume monitoring")
        } catch {
            print("❌ Failed to create programmatic silence: \(error)")
        }
    }
    
    private func syncWithSystemVolume() {
        // Only sync if audio session has been set up
        guard hasSetupAudioSession else {
            print("🔊 Deferring volume sync until audio session is set up")
            return
        }
        
        let systemVolume = AVAudioSession.sharedInstance().outputVolume
        print("🔊 Syncing with system volume: \(Int(systemVolume * 100))%")
        updateAudioEngineVolume(to: systemVolume)
        
        // Set the baseline for timer-based monitoring
        lastKnownVolume = systemVolume
        
        // Don't start silent playback here - only when we actually need volume monitoring during playback
        // silentPlayer?.play() - removed to prevent interrupting other apps on launch
    }
    
    // Removed MPVolumeView methods - using native system volume HUD instead
    
    private func setupVolumeMonitoring() {
        // Monitor system volume notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVolumeNotification),
            name: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"),
            object: nil
        )
        
        // Also monitor AVAudioSession outputVolume
        let session = AVAudioSession.sharedInstance()
        session.addObserver(self, forKeyPath: "outputVolume", options: [.new], context: nil)
        
        // Start timer-based volume checking as fallback
        startVolumeTimer()
        
        print("📢 Volume monitoring enabled with timer fallback")
    }
    
    private func startVolumeTimer() {
        volumeCheckTimer?.invalidate()
        volumeCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkVolumeChange()
            }
        }
        print("⏰ Volume check timer started (200ms intervals)")
    }
    
    private func checkVolumeChange() {
        // Only check volume if audio session has been set up
        guard hasSetupAudioSession else { return }
        
        let currentVolume = AVAudioSession.sharedInstance().outputVolume
        
        if lastKnownVolume != currentVolume {
            if lastKnownVolume >= 0 {
                // Simply sync audio engine to system volume
                audioEngine.mainMixerNode.outputVolume = currentVolume
            }
            lastKnownVolume = currentVolume
        }
    }
    
    @objc private func handleVolumeNotification(_ notification: Notification) {
        print("📢 Received volume notification: \(notification.name)")
        print("📢 Notification userInfo: \(notification.userInfo ?? [:])")
        
        if let volume = notification.userInfo?["AVSystemController_AudioVolumeNotificationParameter"] as? Float {
            print("🔊 Volume notification: \(Int(volume * 100))%")
            updateAudioEngineVolume(to: volume)
        } else {
            print("⚠️ No volume parameter in notification")
        }
    }
    
    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        print("📢 KVO observer called for keyPath: \(keyPath ?? "nil")")
        print("📢 Change: \(change ?? [:])")
        
        if keyPath == "outputVolume" {
            if let volume = change?[.newKey] as? Float {
                print("🔊 AVAudioSession volume changed: \(Int(volume * 100))%")
                Task { @MainActor in
                    updateAudioEngineVolume(to: volume)
                }
            } else {
                print("⚠️ No volume value in KVO change")
            }
        }
    }
    
    private func updateAudioEngineVolume(to volume: Float) {
        audioEngine.mainMixerNode.outputVolume = volume
        print("🔊 Audio engine volume updated to: \(Int(volume * 100))%")
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
    
    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        
        // Play command handler - will be called from Control Center
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                print("🎛️ Play command from Control Center")
                self?.play()
            }
            return .success
        }
        
        // Pause command handler - will be called from Control Center
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                print("🎛️ Pause command from Control Center")
                self?.pause(fromControlCenter: true)
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
            print("🎯 CarPlay seek request to: \(positionTime)s")
            
            Task { @MainActor in
                await self.seek(to: positionTime)
                print("✅ Seek completed to: \(positionTime)s")
            }
            
            return .success
        }
        
        // Toggle play/pause command (for headphone button and other accessories)
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == true {
                    self?.pause(fromControlCenter: true)
                } else {
                    self?.play()
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
        print("✅ CarPlay seek command enabled")
    }
    
    // MARK: - Widget Integration

    func updateWidgetData() {
        guard let track = currentTrack else {
            WidgetDataManager.shared.clearCurrentTrack()
            return
        }
        
        Task {
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
            
            // Get theme color (white)
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
                print("🎛️ Cleared Control Center - no track loaded")
            }
            return
        }
        
        // Get accurate current time from node for Control Center synchronization
        var currentTime = playbackTime
        if let audioFile = audioFile,
           hasSetupAudioEngine && audioEngine.isRunning,
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
        
        // Add track number
        if let trackNo = track.trackNo {
            info[MPMediaItemPropertyAlbumTrackNumber] = trackNo
        }
        
        // Add cached artwork
        if let cachedArtwork = cachedArtwork, cachedArtworkTrackId == track.stableId {
            info[MPMediaItemPropertyArtwork] = cachedArtwork
            print("🎨 Added cached artwork to Now Playing info for: \(track.title)")
        } else {
            print("⚠️ No cached artwork available for: \(track.title) (cached: \(cachedArtwork != nil), trackId match: \(cachedArtworkTrackId == track.stableId))")
        }
        
        // Update with explicit synchronization
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Update Now Playing Info
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            
            // Trigger CarPlay Now Playing button update
            #if os(iOS) && !targetEnvironment(macCatalyst)
            MPNowPlayingInfoCenter.default().playbackState = self.isPlaying ? .playing : .paused
            #endif
            
            // Notify CarPlay delegate of state change
            NotificationCenter.default.post(name: NSNotification.Name("PlayerStateChanged"), object: nil)
            
            print("🎛️ Enhanced Control Center update - playing: \(self.isPlaying)")
            print("🎛️ Title: \(track.title), Time: \(currentTime)")
        }
        
        // Load artwork asynchronously if needed (try regardless of hasEmbeddedArt flag)
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
    
    private func setupAudioSessionCategory() throws {
        let s = AVAudioSession.sharedInstance()
        
        // For background audio, avoid mixWithOthers - be the primary audio app
        let options: AVAudioSession.CategoryOptions = [.allowAirPlay, .allowBluetoothA2DP]
        
        try s.setCategory(.playback, mode: .default, options: options)
        
        // iOS 18 Fix: Set preferred I/O buffer duration
        try s.setPreferredIOBufferDuration(0.023) // 23ms buffer - good balance for iOS 18
        
        print("🎧 Audio session category configured for primary playback (no mixWithOthers)")
    }
    
    private func activateAudioSession() throws {
        let s = AVAudioSession.sharedInstance()
        
        print("🎧 Audio session state - Category: \(s.category), Other audio: \(s.isOtherAudioPlaying)")
        
        // Set category first if needed
        try setupAudioSessionCategory()
        
        // Always try to activate (iOS manages the actual state)
        try s.setActive(true, options: [])
        print("🎧 Audio session activation attempted successfully")
        
        UIApplication.shared.beginReceivingRemoteControlEvents()
        print("🎧 Remote control events enabled")
    }
    
    // MARK: - iOS 18 Audio Engine Reset Management
    
    private func cleanupAudioEngineForReset() async {
        print("🧹 Cleaning up audio engine for reset")
        
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
        
        print("✅ Audio engine cleanup complete")
    }
    
    private func recreateAudioEngine() {
        print("🔄 Recreating audio engine and nodes")
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
        print("✅ Audio engine recreated successfully with EQ")
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
            print("📍 Using resolved bookmark location: \(resolvedURL.path)")
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
                    print("🎵 Loading audio file: \(url.lastPathComponent)")
                    let audioFile = try AVAudioFile(forReading: url)
                    print("✅ AVAudioFile loaded successfully: \(url.lastPathComponent)")
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
        // Determine actual format from file extension
        let url = URL(fileURLWithPath: track.path)
        let fileExtension = url.pathExtension.lowercased()
        print("📀 loadTrack called for: \(track.title) (format: \(fileExtension))")

        // Cancel any ongoing load operation
        currentLoadTask?.cancel()

        // Prevent concurrent loading
        guard !isLoadingTrack else {
            print("⚠️ Already loading track, skipping: \(track.title)")
            return
        }

        isLoadingTrack = true
        print("🔄 Starting load process for: \(track.title)")

        // Stop current playback and clean up
        await cleanupCurrentPlayback(resetTime: !preservePlaybackTime)

        // Reset timing state when loading a new track to ensure clean state for new sample rate
        if !preservePlaybackTime {
            seekTimeOffset = 0
            playbackTime = 0
            lastControlCenterUpdate = 0
        }

        // Clear cached artwork when loading new track
        cachedArtwork = nil
        cachedArtworkTrackId = nil


        currentTrack = track
        currentArtistName = getCachedArtistName(for: track)
        playbackState = .loading

        // Volume control already set up in init

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
            lastControlCenterUpdate = 0
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
        print("▶️ play() called - state: \(playbackState), loading: \(isLoadingTrack)")

        // If no audio file is loaded but we have a current track, load it first
        if audioFile == nil && currentTrack != nil && !isLoadingTrack {
            Task {
                // If state was already restored but audioFile is nil (e.g., after interruption),
                // we need to reload the current track with preserved position
                if hasRestoredState {
                    print("🔄 Reloading track after interruption, preserving position: \(playbackTime)s")
                    let savedPosition = playbackTime
                    await loadTrack(currentTrack!, preservePlaybackTime: true)
                    
                    // Restore position after reload
                    if savedPosition > 0 {
                        await seek(to: savedPosition)
                        print("✅ Restored position after reload: \(savedPosition)s")
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
            // Try to continue anyway - might still work
        }
        
        if playbackState == .paused {
            print("▶️ Resuming from pause at position: \(playbackTime)s")
            
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
                    print("✅ Started audio engine before scheduling (resume)")
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
            
            // End paused state monitoring and start regular playing monitoring
            stopSilentPlaybackForPause()
            endBackgroundMonitoring()
            startBackgroundMonitoring()
            
            print("✅ Resumed playback from position: \(playbackTime)s")
            
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
        
        print("🔊 Audio format - Sample Rate: \(audioFile.processingFormat.sampleRate), Channels: \(audioFile.processingFormat.channelCount)")
        print("🔊 Audio file length: \(audioFile.length) frames")
        
        // Check if the file length is reasonable
        guard audioFile.length > 0 && audioFile.length < 1_000_000_000 else {
            print("❌ Invalid audio file length: \(audioFile.length)")
            return
        }
        
        // IMPORTANT: Ensure audio engine is running BEFORE scheduling
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                print("✅ Audio engine started before scheduling")
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
            print("✅ Resuming playback from \(currentPosition)s (frame: \(startFrame))")
        } else {
            // Start from beginning - but only reset if we're actually at the beginning
            if playbackTime > 1.0 {
                // We're not actually at the beginning, so preserve current position
                let startFrame2 = AVAudioFramePosition(playbackTime * audioFile.processingFormat.sampleRate)
                seekTimeOffset = playbackTime
                scheduleSegment(on: activePlayerNode, from: startFrame2, file: audioFile)
                print("✅ Resuming playback from current position: \(playbackTime)s")
            } else {
                // Actually starting from beginning
                seekTimeOffset = 0
                playbackTime = 0
                scheduleSegment(on: activePlayerNode, from: 0, file: audioFile)
                print("✅ Starting playback from beginning")
            }
        }
        
        print("✅ Audio segment scheduled successfully")
        
        // Set up audio session notifications only when needed
        ensureAudioSessionNotificationsSetup()
        
        // Set up remote commands only when needed
        ensureRemoteCommandsSetup()
        
        // Set up volume control if not already done
        if volumeCheckTimer == nil {
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
        
        print("✅ Playback started and control center claimed")
    }
    
    func pause(fromControlCenter: Bool = false) {
        print("⏸️ pause() called")

        // Capture current playback position before pausing
        if let audioFile = audioFile,
           let nodeTime = activePlayerNode.lastRenderTime,
           let playerTime = activePlayerNode.playerTime(forNodeTime: nodeTime) {
            let nodePlaybackTime = Double(playerTime.sampleTime) / audioFile.processingFormat.sampleRate
            let currentPosition = seekTimeOffset + nodePlaybackTime
            
            print("🔄 Pausing at position: \(currentPosition)s (from Control Center: \(fromControlCenter))")
            
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
        
        print("🔄 Paused audio engine - stored position: \(playbackTime)s")
        
        // Update Now Playing info with enhanced approach
        updateNowPlayingInfoEnhanced()
        updateWidgetData()
        
        // Ensure no silent playback is running while paused to keep Control Center state accurate
        stopSilentPlaybackForPause()
        
        // Save state when pausing
        savePlayerState()
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
        print("🔓 Stopped accessing security-scoped resources on stop")
        stopPlaybackTimer()
        
        // Stop all background monitoring and silent playback
        stopSilentPlaybackForPause()
        endBackgroundMonitoring()
        
        // Update Now Playing info to show stopped state (but keep track info)
        updateNowPlayingInfoEnhanced()
        
        // Don't clear remote commands during track transitions - keep Control Center connected
        // Remote commands should only be cleared when the app is truly shutting down
        print("🎛️ Keeping remote commands connected for Control Center")
        
        // Don't deactivate audio session during track transitions - keep Control Center connected
        // Audio session should stay active to maintain Control Center connection
        // Only deactivate when the app is truly backgrounded or user explicitly stops playback
        print("🎧 Keeping audio session active to maintain Control Center connection")
        
        // Save state when stopping
        savePlayerState()
    }
    
    private func cleanupCurrentPlayback(resetTime: Bool = false) async {
        print("🧹 Cleaning up current playback")

        // Stop accessing security-scoped resources unless we are mid-crossfade.
        if !isCrossfading {
            stopAccessingSecurityScopedResources()
            currentTrackURL = nil
            print("🔓 Stopped accessing security-scoped resources during cleanup")
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
        print("⏪ seek(to: \(time)) called")

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
        
        print("🔍 Seeking to: \(time)s (frame: \(framePosition))")
        
        // Ensure audio engine is set up before seeking with file's format
        ensureAudioEngineSetup(with: audioFile.processingFormat)
        
        // Ensure audio engine is running before scheduling
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                print("✅ Started audio engine before scheduling (seek)")
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
        
        print("✅ Seek completed")
    }
    
    private func startSilentPlaybackForPause() {
        // Create a very quiet, looping audio player to maintain background execution
        guard pausedSilentPlayer == nil else {
            if pausedSilentPlayer?.isPlaying == false {
                pausedSilentPlayer?.play()
            }
            return
        }
        
        do {
            // Create a tiny silent buffer programmatically
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)! // 0.1 seconds at 44.1kHz
            buffer.frameLength = 4410
            
            // Buffer is already silent (zero-filled by default)
            
            // Write to temporary file
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("pause_silence.caf")
            let audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            try audioFile.write(from: buffer)
            
            // Create player with very low volume
            pausedSilentPlayer = try AVAudioPlayer(contentsOf: tempURL)
            pausedSilentPlayer?.volume = 0.001  // Nearly silent
            pausedSilentPlayer?.numberOfLoops = -1  // Loop indefinitely
            pausedSilentPlayer?.prepareToPlay()
            pausedSilentPlayer?.play()
            
            print("🔇 Started silent playback to maintain background execution during pause")
            
        } catch {
            print("❌ Failed to create silent player for pause: \(error)")
            // Fallback to the original method
            maintainAudioSessionForBackground()
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
        
        // Schedule segment with error handling
        do {
            // Schedule WITHOUT any completion handler
            node.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: AVAudioFrameCount(remaining),
                at: nil,
                completionHandler: nil
            )
            
            print("✅ Successfully scheduled segment: startFrame=\(startFrame), frameCount=\(remaining)")
            
            // Start background monitoring when we schedule a segment
            startBackgroundMonitoring()
        } catch {
            print("❌ Failed to schedule audio segment: \(error)")
            print("❌ Details - startFrame: \(startFrame), remaining: \(remaining), file length: \(file.length)")
        }
    }
    private func startBackgroundMonitoring() {
        // Only create a background task if we don't already have one
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                print("🚨 Background task expiring during playback")
                Task { @MainActor in
                    self?.endBackgroundMonitoring()
                }
            }
        }

        // Start a timer that works in background
        backgroundCheckTimer?.invalidate()
        backgroundCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkIfTrackEnded()
            }
        }
    }
    
    private func endBackgroundMonitoring() {
        backgroundCheckTimer?.invalidate()
        backgroundCheckTimer = nil
        
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
    
    private func stopSilentPlaybackForPause() {
        pausedSilentPlayer?.stop()
        pausedSilentPlayer = nil
        print("🔇 Stopped silent playback for pause")
    }
    
    private func maintainAudioSessionForBackground() {
        // Keep the audio session active to prevent app termination
        Task { @MainActor in
            do {
                let session = AVAudioSession.sharedInstance()

                // Only maintain session if we're not already active
                guard !session.isOtherAudioPlaying else {
                    print("🎧 Other audio playing, not maintaining session")
                    return
                }

                // Don't change category if already correct - this prevents the error
                if session.category != .playback {
                    try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
                }

                // Only activate if not already active
                if !session.secondaryAudioShouldBeSilencedHint {
                    try session.setActive(true, options: [])
                    print("🎧 Audio session maintained during pause to prevent termination")
                } else {
                    print("🎧 Audio session already active during pause")
                }

            } catch {
                print("❌ Failed to maintain audio session during pause: \(error)")
                // Don't try to maintain session if it fails - let the app handle it naturally
            }
        }
    }
    
    private func checkIfTrackEnded() async {
        // Check if audio has finished playing
        guard isPlaying else { return }
        guard !isCrossfading else { return }

        // Check if player node has stopped naturally (reached end)
        if !activePlayerNode.isPlaying && audioFile != nil {
            // Track has ended
            await handleTrackEnd()
            return
        }

        // Alternative check: position-based
        if let audioFile = audioFile {
            if let nodeTime = activePlayerNode.lastRenderTime,
               let playerTime = activePlayerNode.playerTime(forNodeTime: nodeTime) {
                let nodePlaybackTime = Double(playerTime.sampleTime) / audioFile.processingFormat.sampleRate
                let currentTime = seekTimeOffset + nodePlaybackTime

                if currentTime >= duration - 0.2 && duration > 0 {
                    // Track is ending
                    isPlaying = false // Prevent multiple triggers
                    await handleTrackEnd()
                }
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
    
    func playTrack(_ track: Track, queue: [Track] = []) async {
        print("🎵 Playing track: \(track.title)")
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
    
    func nextTrack(autoplay: Bool? = nil) async {
        guard !playbackQueue.isEmpty, !isLoadingTrack else { return }
        normalizeIndexAndTrack()
        let shouldAutoplay = autoplay ?? isPlaying

        let nextIndex = (currentIndex + 1) % playbackQueue.count

        if shouldAutoplay, audioFile != nil {
            let config = crossfadeConfiguration()
            if config.enabled {
                let didCrossfade = await crossfadeToTrack(at: nextIndex, duration: config.duration, reason: "skip next")
                if didCrossfade { return }
            }
        }

        currentIndex = nextIndex
        let next = playbackQueue[currentIndex]
        await loadTrack(next, preservePlaybackTime: false)

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

        if wasPlaying, audioFile != nil {
            let config = crossfadeConfiguration()
            if config.enabled {
                let didCrossfade = await crossfadeToTrack(at: prevIndex, duration: config.duration, reason: "skip previous")
                if didCrossfade { return }
            }
        }

        currentIndex = prevIndex
        let prev = playbackQueue[currentIndex]
        await loadTrack(prev, preservePlaybackTime: false)

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
            print("🔁 Queue loop mode: ON")
        } else if isRepeating && !isLoopingSong {
            // Queue Loop → Track Loop
            isRepeating = false
            isLoopingSong = true
            print("🔂 Track loop mode: ON")
        } else {
            // Track Loop → Off
            isRepeating = false
            isLoopingSong = false
            print("🚫 Loop mode: OFF")
        }
    }
    
    func toggleShuffle() {
        isShuffled.toggle()
        print("🔀 Shuffle mode: \(isShuffled ? "ON" : "OFF")")
        
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
        
        print("🔀 Queue shuffled, current track remains at index 0")
    }
    
    private func restoreOriginalQueue() {
        guard !originalQueue.isEmpty else { return }
        
        // Find current track in original queue
        if let currentTrack = self.currentTrack,
           let originalIndex = originalQueue.firstIndex(where: { $0.stableId == currentTrack.stableId }) {
            playbackQueue = originalQueue
            currentIndex = originalIndex
            print("🔀 Original queue restored, current track at index \(originalIndex)")
        }
        
        normalizeIndexAndTrack()
    }
    
    // MARK: - Audio Session Configuration

    private var lastConfiguredNativeSampleRate: Double = 0

    private func configureAudioSession(for format: AVAudioFormat) async {
        let targetSampleRate = Double(currentTrack?.sampleRate ?? Int(format.sampleRate))

        // Skip reconfiguration if sample rate hasn't changed
        if abs(lastConfiguredNativeSampleRate - targetSampleRate) < 1.0 {
            print("🔄 Skipping audio session config - sample rate unchanged (\(targetSampleRate)Hz)")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            
            // Ensure the session is in a sane, active state before applying preferences.
            try setupAudioSessionCategory()
            try session.setActive(true, options: [])
            
            // If we're already effectively at this rate, avoid poking SessionCore again.
            if abs(session.sampleRate - targetSampleRate) < 1.0 {
                lastConfiguredNativeSampleRate = session.sampleRate
                print("✅ Audio session already at desired sample rate: \(session.sampleRate)Hz")
                return
            }
            
            do {
                try session.setPreferredSampleRate(targetSampleRate)
                // Re-activate to encourage the system to apply the new preference promptly.
                try session.setActive(true, options: [])
                lastConfiguredNativeSampleRate = targetSampleRate
                print("✅ Audio session configured - Preferred: \(targetSampleRate)Hz, Actual: \(session.sampleRate)Hz")
            } catch {
                let nsError = error as NSError
                // Common CoreAudio paramErr (-50) can surface here on unsupported routes/rates.
                print("⚠️ Preferred sample rate rejected (domain: \(nsError.domain), code: \(nsError.code)) - keeping \(session.sampleRate)Hz")
                // Avoid retry spam on the same unsupported rate.
                lastConfiguredNativeSampleRate = session.sampleRate
            }
        } catch {
            let nsError = error as NSError
            print("❌ Failed to configure audio session (domain: \(nsError.domain), code: \(nsError.code)): \(error)")
        }
    }
    
    // MARK: - Timer and Updates
    
    func startPlaybackTimer() {
        stopPlaybackTimer()
        
        // Keep 0.1s interval for accurate timing
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.updatePlaybackTime()
            }
        }
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
            try? activateAudioSession()

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
            lastControlCenterUpdate = 0
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
            print("🔀 Crossfading (\(reason)) over \(String(format: "%.2f", effectiveDuration))s to: \(nextTrack.title)")

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
    
    private var lastControlCenterUpdate: TimeInterval = 0
    
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
        
        // Remove this duplicate detection - it's handled by checkIfTrackEnded()
        /* DELETE THIS BLOCK:
         if isPlaying && playbackTime >= duration - 0.1 && duration > 0 {
         isPlaying = false
         await handleTrackEnd()
         }
         */
        
        // Update Control Center more frequently for better synchronization - every 0.5 seconds instead of 2 seconds
        // This ensures smooth time display in Control Center regardless of sample rate changes
        if abs(playbackTime - lastControlCenterUpdate) >= 0.5 {
            lastControlCenterUpdate = playbackTime
            updateNowPlayingInfoEnhanced()
        }
    }
    
    private func handleTrackEnd() async {
        guard !isLoadingTrack else { return }
        guard !isCrossfading else { return }
        
        if isLoopingSong, let t = currentTrack {
            await loadTrack(t)
            play()
            return
        }
        
        if let nextIndex = nextIndexForAutoAdvance() {
            let config = crossfadeConfiguration()
            if config.enabled, isPlaying {
                let didCrossfade = await crossfadeToTrack(at: nextIndex, duration: config.duration, reason: "track end fallback")
                if didCrossfade { return }
            }

            currentIndex = nextIndex
            let next = playbackQueue[currentIndex]
            await loadTrack(next, preservePlaybackTime: false)
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
        guard track.hasEmbeddedArt else { return }

        do {
            // Ensure file is local first
            let url = URL(fileURLWithPath: track.path)
            try await cloudDownloadManager.ensureLocal(url)

            // Load artwork using NSFileCoordinator with proper async handling
            let artwork = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MPMediaItemArtwork?, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    var coordinatorError: NSError?
                    let coordinator = NSFileCoordinator()

                    coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { (readingURL) in
                        do {
                            let freshURL = URL(fileURLWithPath: readingURL.path)
                            print("🎵 Loading artwork from: \(freshURL.lastPathComponent)")

                            // Check if file actually exists at path
                            guard FileManager.default.fileExists(atPath: freshURL.path) else {
                                print("❌ Artwork file not found at path: \(freshURL.path)")
                                continuation.resume(returning: nil)
                                return
                            }

                            // Handle different file formats for artwork extraction
                            let fileExtension = freshURL.pathExtension.lowercased()

                            if fileExtension == "flac" {
                                // First try with AVAsset (works for some FLAC files)
                                if let artwork = self.loadArtworkFromAVAsset(url: freshURL) {
                                    print("✅ Loaded FLAC artwork via AVAsset")
                                    continuation.resume(returning: artwork)
                                    return
                                }

                                // If AVAsset fails, try direct FLAC metadata reading
                                if let artwork = self.loadArtworkFromFLACMetadata(url: freshURL) {
                                    print("✅ Loaded FLAC artwork via direct metadata reading")
                                    continuation.resume(returning: artwork)
                                    return
                                }

                                print("⚠️ No artwork found in FLAC file: \(freshURL.lastPathComponent)")
                                continuation.resume(returning: nil)
                            } else {
                                // For MP3/M4A files, use AVAsset
                                if let artwork = self.loadArtworkFromAVAsset(url: freshURL) {
                                    print("✅ Loaded artwork via AVAsset for: \(freshURL.lastPathComponent)")
                                    continuation.resume(returning: artwork)
                                } else {
                                    print("⚠️ No artwork found in file: \(freshURL.lastPathComponent)")
                                    continuation.resume(returning: nil)
                                }
                            }
                            
                        }
                    }
                    
                    if let error = coordinatorError {
                        print("❌ NSFileCoordinator error loading artwork: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            // Cache the artwork and update now playing info
            await MainActor.run {
                if let artwork = artwork {
                    // Cache the artwork
                    self.cachedArtwork = artwork
                    self.cachedArtworkTrackId = track.stableId
                    
                    // Update now playing info with cached artwork
                    self.updateNowPlayingInfoWithCachedArtwork()
                    print("🎨 Cached and updated artwork for: \(track.title)")
                } else {
                    print("🎨 No artwork to cache for: \(track.title)")
                }
            }
            
        } catch {
            print("❌ Failed to load artwork for caching: \(error)")
        }
    }
    
    private nonisolated func loadArtworkFromAVAsset(url: URL) -> MPMediaItemArtwork? {
        do {
            let asset = AVAsset(url: url)
            
            // Use synchronous metadata loading for compatibility
            let commonMetadata = asset.commonMetadata
            
            for metadataItem in commonMetadata {
                if metadataItem.commonKey == .commonKeyArtwork,
                   let data = metadataItem.dataValue,
                   let originalImage = UIImage(data: data) {
                    
                    print("🎨 Found artwork in AVAsset metadata (size: \(Int(originalImage.size.width))x\(Int(originalImage.size.height)))")
                    
                    // Crop to square if width is significantly larger than height
                    let processedImage = self.cropToSquareIfNeeded(image: originalImage)
                    
                    // Use large size for CarPlay - 1024x1024 recommended
                    let targetSize = CGSize(width: 1024, height: 1024)
                    let artwork = MPMediaItemArtwork(boundsSize: targetSize) { size in
                        // Resize image to requested size
                        return self.resizeImage(processedImage, to: size)
                    }
                    
                    return artwork
                }
            }
            
            print("⚠️ No artwork found in AVAsset metadata")
            return nil
            
        }
    }
    
    private nonisolated func loadArtworkFromFLACMetadata(url: URL) -> MPMediaItemArtwork? {
        do {
            // Read FLAC file directly to extract embedded artwork
            let data = try Data(contentsOf: url)
            
            // Look for FLAC PICTURE metadata block
            if let artwork = extractFLACPictureBlock(from: data) {
                print("🎨 Found artwork in FLAC PICTURE block")
                
                let processedImage = self.cropToSquareIfNeeded(image: artwork)
                
                let mpArtwork = MPMediaItemArtwork(boundsSize: processedImage.size) { size in
                    return processedImage
                }
                
                return mpArtwork
            }
            
            print("⚠️ No PICTURE block found in FLAC file")
            return nil
            
        } catch {
            print("❌ Direct FLAC metadata reading failed: \(error)")
            return nil
        }
    }
    
    private nonisolated func extractFLACPictureBlock(from data: Data) -> UIImage? {
        // FLAC file format: 4-byte signature "fLaC" followed by metadata blocks
        
        guard data.count > 4 else { return nil }
        
        // Check for FLAC signature
        let signature = data.subdata(in: 0..<4)
        guard signature == Data([0x66, 0x4C, 0x61, 0x43]) else { // "fLaC"
            print("⚠️ Invalid FLAC signature")
            return nil
        }
        
        var offset = 4
        
        // Parse metadata blocks
        while offset < data.count - 4 {
            // Read metadata block header (4 bytes)
            let blockHeader = data.subdata(in: offset..<(offset + 4))
            
            let isLastBlock = (blockHeader[0] & 0x80) != 0
            let blockType = blockHeader[0] & 0x7F
            
            // Block length (24-bit big-endian)
            let blockLength = Int(blockHeader[1]) << 16 | Int(blockHeader[2]) << 8 | Int(blockHeader[3])
            
            offset += 4
            
            // Check if this is a PICTURE block (type 6)
            if blockType == 6 {
                print("🖼️ Found FLAC PICTURE block at offset \(offset), length: \(blockLength)")
                
                guard offset + blockLength <= data.count else {
                    print("❌ PICTURE block extends beyond file")
                    break
                }
                
                let pictureBlockData = data.subdata(in: offset..<(offset + blockLength))
                
                if let image = parseFLACPictureBlock(data: pictureBlockData) {
                    return image
                }
            }
            
            // Move to next block
            offset += blockLength
            
            if isLastBlock {
                break
            }
        }
        
        return nil
    }
    
    private nonisolated func parseFLACPictureBlock(data: Data) -> UIImage? {
        guard data.count >= 32 else { return nil }
        
        var offset = 0
        
        // Picture type (4 bytes) - skip
        offset += 4
        
        // MIME type length (4 bytes, big-endian)
        let mimeTypeLength = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        offset += 4
        
        guard offset + mimeTypeLength <= data.count else { return nil }
        
        // MIME type string - skip
        offset += mimeTypeLength
        
        // Description length (4 bytes, big-endian)
        guard offset + 4 <= data.count else { return nil }
        let descriptionLength = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        offset += 4
        
        // Description string - skip
        offset += descriptionLength
        
        // Width (4 bytes) - skip
        offset += 4
        // Height (4 bytes) - skip
        offset += 4
        // Color depth (4 bytes) - skip
        offset += 4
        // Number of colors (4 bytes) - skip
        offset += 4
        
        // Picture data length (4 bytes, big-endian)
        guard offset + 4 <= data.count else { return nil }
        let pictureDataLength = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        offset += 4
        
        // Picture data
        guard offset + pictureDataLength <= data.count else { return nil }
        let pictureData = data.subdata(in: offset..<(offset + pictureDataLength))
        
        // Create UIImage from picture data
        return UIImage(data: pictureData)
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

    private nonisolated func convertUIImageToMPMediaItemArtwork(_ image: UIImage) -> MPMediaItemArtwork? {
        return MPMediaItemArtwork(boundsSize: image.size) { _ in
            return image
        }
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
            print("🖼️ Cropping wide artwork (aspect ratio: \(String(format: "%.2f", aspectRatio))) to square")
            
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
            print("🚫 No current track to save state for")
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
        
        UserDefaults.standard.set(playerState, forKey: "CosmosPlayerState")
        UserDefaults.standard.synchronize()
        print("✅ Player state saved to UserDefaults (offline, per-device)")
    }
    
    private func ensurePlayerStateRestored() async {
        guard !hasRestoredState else { return }
        hasRestoredState = true
        
        // Only load the audio file if we have a current track from UI restoration
        if let currentTrack = currentTrack {
            print("🔄 Loading audio for restored track: \(currentTrack.title)")
            let savedPosition = playbackTime // Save the position before loadTrack
            await loadTrack(currentTrack, preservePlaybackTime: true)
            
            // Restore the playback position after loading (if position was saved)
            if savedPosition > 0 {
                print("🔄 Seeking to restored position: \(savedPosition)s")
                await seek(to: savedPosition)
                print("✅ Restored position: \(savedPosition)s")
            }
        }
    }
    
    func restoreUIStateOnly() async {
        guard let playerStateDict = UserDefaults.standard.dictionary(forKey: "CosmosPlayerState") else {
            print("📭 No saved player state found in UserDefaults")
            return
        }
        
        guard let lastSavedAt = playerStateDict["lastSavedAt"] as? Date else {
            print("🚫 Invalid saved state format")
            return
        }
        
        print("🔄 Restoring UI state only from \(lastSavedAt)")
        
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
                    print("✅ Loop track mode validated with single track queue")
                } else if self.isLoopingSong {
                    print("⚠️ Loop track mode with multi-track queue - this is fine")
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
                
                print("✅ UI state restored - track: \(restoredTrack.title), position: \(savedTime)s, duration: \(self.duration)s (no audio loaded)")
                
                // Normalize index and track after restoration
                self.normalizeIndexAndTrack()
            }
            
        } catch {
            print("❌ Failed to restore UI state: \(error)")
        }
    }
    
    func restorePlayerState() async {
        guard let playerStateDict = UserDefaults.standard.dictionary(forKey: "CosmosPlayerState") else {
            print("📭 No saved player state found in UserDefaults")
            return
        }
        
        guard let lastSavedAt = playerStateDict["lastSavedAt"] as? Date else {
            print("🚫 Invalid saved state format")
            return
        }
        
        print("🔄 Restoring player state from \(lastSavedAt)")
        
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
            
            // Restore player state
            await MainActor.run {
                self.playbackQueue = queueTracks.isEmpty ? [restoredTrack] : queueTracks
                self.originalQueue = originalQueueTracks.isEmpty ? [restoredTrack] : originalQueueTracks
                
                let savedIndex = playerStateDict["currentIndex"] as? Int ?? 0
                self.currentIndex = max(0, min(savedIndex, self.playbackQueue.count - 1))
                
                self.isRepeating = playerStateDict["isRepeating"] as? Bool ?? false
                self.isShuffled = playerStateDict["isShuffled"] as? Bool ?? false
                self.isLoopingSong = playerStateDict["isLoopingSong"] as? Bool ?? false
                self.currentTrack = restoredTrack
                
                print("✅ Restored state: queue=\(self.playbackQueue.count) tracks, index=\(self.currentIndex), loop=\(self.isLoopingSong)")
                
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
            }
            
            await MainActor.run { self.normalizeIndexAndTrack() }
            
            await MainActor.run {
                // Set saved position before loading track
                let savedTime = playerStateDict["playbackTime"] as? TimeInterval ?? 0
                self.playbackTime = savedTime
            }
            
            // Load the track and preserve the saved position
            await loadTrack(restoredTrack, preservePlaybackTime: true)
            
            // Seek to the saved position after loading
            let savedTime = playerStateDict["playbackTime"] as? TimeInterval ?? 0
            if savedTime > 0 {
                await seek(to: savedTime)
                print("🔄 Seeked to restored position: \(savedTime)s")
            }
            
            print("✅ Player state restored from UserDefaults - track: \(restoredTrack.title), position: \(savedTime)s")
            
        } catch {
            print("❌ Failed to restore player state: \(error)")
        }
    }
    
    private func setupPeriodicStateSaving() {
        // Save state every 30 seconds while playing, and on important events
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == true && self?.currentTrack != nil {
                    self?.savePlayerState()
                }
            }
        }
    }
    
    deinit {
        // Note: Cannot access main actor properties or methods in deinit
        // State saving is handled by app lifecycle notifications instead
        
        NotificationCenter.default.removeObserver(self)
        volumeCheckTimer?.invalidate()
        
        
        // Remove KVO observer only if it was set up
        if hasSetupAudioSessionNotifications {
            AVAudioSession.sharedInstance().removeObserver(self, forKeyPath: "outputVolume")
        }
    }
}
enum PlayerError: Error {
    case fileNotFound
    case invalidAudioFile
    case audioEngineError
    case configurationError
}
