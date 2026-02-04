import SwiftUI
import AVFoundation

@main
struct MusicApp: App {
    @StateObject private var appCoordinator = AppCoordinator.shared
    @StateObject private var toastManager = ToastManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appCoordinator)
                .task {
                    await appCoordinator.initialize()
                    await createiCloudContainerPlaceholder()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.didEnterBackgroundNotification)) { _ in
                    handleDidEnterBackground()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.willEnterForegroundNotification)) { _ in
                    handleWillEnterForeground()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { _ in
                    handleWillResignActive()
                }
                .onOpenURL { url in
                    handleOpenURL(url)
                }
                .onAppear {
                    setupToastWindow()
                }
        }
    }

    private func setupToastWindow() {
        // Create a toast window that sits above all other content including sheets
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }

            let toastWindow = ToastWindow(windowScene: windowScene)
            toastWindow.rootViewController = UIHostingController(rootView: GlobalToastOverlay())
            toastWindow.rootViewController?.view.backgroundColor = .clear
            toastWindow.isHidden = false

            // Keep a reference to prevent deallocation
            ToastWindowHolder.shared.window = toastWindow
        }
    }
    
    private func handleDidEnterBackground() {
        // Stop high-frequency timers when backgrounded
        Task { @MainActor in
            PlayerEngine.shared.stopPlaybackTimer()
        }
    }

    private func handleWillEnterForeground() {
        // Restart timers when foregrounding
        Task { @MainActor in
            if PlayerEngine.shared.isPlaying {
                PlayerEngine.shared.startPlaybackTimer()
            }
        }
    }
    
    private func handleWillResignActive() {
        // Re-assert the session as we background - no mixWithOthers in background
        do {
            let s = AVAudioSession.sharedInstance()
            let appState = appStateSummary()
            let thread = Thread.isMainThread ? "main" : "bg"
            let queue = currentQueueLabel()
            let desiredOptions = describeCategoryOptions([])
            print("🔎 AudioSession setCategory attempt reason=handleWillResignActive desired=\(AVAudioSession.Category.playback.rawValue)/\(AVAudioSession.Mode.default.rawValue) options=\(desiredOptions) appState=\(appState) thread=\(thread) queue=\(queue)")
            do {
                try s.setCategory(.playback, mode: .default, options: []) // no mixWithOthers in bg
            } catch {
                let nsError = error as NSError
                print("❌ Audio session setCategory failed reason=handleWillResignActive (domain: \(nsError.domain), code: \(nsError.code))")
                logAudioSessionState("handleWillResignActive setCategory failed", s)
                let stack = Thread.callStackSymbols.prefix(12).joined(separator: " | ")
                print("🔎 AudioSession setCategory call stack (handleWillResignActive): \(stack)")
                throw error
            }

            print("🔎 AudioSession setActive attempt reason=handleWillResignActive appState=\(appState) thread=\(thread) queue=\(queue)")
            do {
                try s.setActive(true, options: [])
            } catch {
                let nsError = error as NSError
                print("❌ Audio session setActive failed reason=handleWillResignActive (domain: \(nsError.domain), code: \(nsError.code))")
                logAudioSessionState("handleWillResignActive setActive failed", s)
                let stack = Thread.callStackSymbols.prefix(12).joined(separator: " | ")
                print("🔎 AudioSession setActive call stack (handleWillResignActive): \(stack)")
                throw error
            }
        } catch { 
            print("❌ Session keepalive fail:", error) 
        }
    }

    private func describeCategoryOptions(_ options: AVAudioSession.CategoryOptions) -> String {
        if options.isEmpty { return "[]" }
        var parts: [String] = []
        if options.contains(.mixWithOthers) { parts.append("mixWithOthers") }
        if options.contains(.duckOthers) { parts.append("duckOthers") }
        if options.contains(.interruptSpokenAudioAndMixWithOthers) { parts.append("interruptSpokenAudioAndMix") }
        if options.contains(.allowBluetoothHFP) { parts.append("allowBluetoothHFP") }
        if options.contains(.allowBluetoothA2DP) { parts.append("allowBluetoothA2DP") }
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

        print("🔎 AudioSession \(label): category=\(category) mode=\(mode) options=\(options) sr=\(sampleRate)Hz prefSR=\(preferredSampleRate)Hz ioBuffer=\(ioBuffer)s prefIO=\(preferredIOBuffer)s volume=\(outputVolume) otherAudio=\(otherAudio) secondaryShouldSilence=\(shouldSilence) appState=\(appState) thread=\(thread) queue=\(queue) outputs=\(outputs.isEmpty ? "none" : outputs) inputs=\(inputs.isEmpty ? "none" : inputs) availInputs=\(availableInputs) preferredInput=\(preferredInput)")
    }
    
    private func handleOpenURL(_ url: URL) {
        guard url.scheme == "neofx-music" else {
            print("❌ Unknown URL scheme: \(url.scheme ?? "nil")")
            return
        }

        Task { @MainActor in
            switch url.host {
            case "refresh":
                break

            case "playlist":
                // Extract playlist ID from path
                let playlistId = url.pathComponents.dropFirst().joined(separator: "/")

                // Navigate to playlist
                if let playlistIdInt = Int64(playlistId) {
                    do {
                        let playlists = try DatabaseManager.shared.getAllPlaylists()
                        if playlists.contains(where: { $0.id == playlistIdInt }) {
                            // Post notification to navigate to playlist
                            NotificationCenter.default.post(
                                name: NSNotification.Name("NavigateToPlaylist"),
                                object: nil,
                                userInfo: ["playlistId": playlistIdInt]
                            )
                        }
                    } catch {
                        print("❌ Widget: Failed to find playlist: \(error)")
                    }
                }

            default:
                print("⚠️ Unknown URL host: \(url.host ?? "nil")")
            }
        }
    }

    private func createiCloudContainerPlaceholder() async {
        guard let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            print("❌ iCloud Drive not available")
            return
        }
        
        let documentsURL = iCloudURL.appendingPathComponent("Documents")
        let placeholderURL = documentsURL.appendingPathComponent(".neofx_placeholder")
        
        do {
            // Create Documents directory if it doesn't exist
            try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true, attributes: nil)
            
            // Create placeholder file if it doesn't exist
            if !FileManager.default.fileExists(atPath: placeholderURL.path) {
                let placeholderText = "This folder contains music files for Music.\nPlace your MP3 files here to add them to your library."
                try placeholderText.write(to: placeholderURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("❌ Failed to create iCloud Drive placeholder: \(error)")
        }
    }

}
