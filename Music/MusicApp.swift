//
//  MusicApp.swift
//  Music
//
//  Created by CLQ on 28/08/2025.
//

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
        print("🔍 DIAGNOSTIC - backgroundTimeRemaining:", UIApplication.shared.backgroundTimeRemaining)

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

            // Check for new shared files and refresh library
            await LibraryIndexer.shared.copyFilesFromSharedContainer()

            // Only auto-scan if it's been a long time since last scan
            if !LibraryIndexer.shared.isIndexing {
                let settings = DeleteSettings.load()
                if shouldPerformAutoScan(lastScanDate: settings.lastLibraryScanDate) {
                    print("🔄 Foreground: Starting library scan (been a while since last scan)")
                    LibraryIndexer.shared.start()
                } else {
                    print("⏭️ Foreground: Skipping auto-scan (use manual sync button)")
                }
            }
        }
    }

    private func shouldPerformAutoScan(lastScanDate: Date?) -> Bool {
        // If never scanned before, definitely scan
        guard let lastScanDate = lastScanDate else {
            print("🆕 Never scanned before - will perform scan")
            return true
        }

        // Check if it's been more than 1 hour since last scan
        let hoursSinceLastScan = Date().timeIntervalSince(lastScanDate) / 3600
        let shouldScan = hoursSinceLastScan >= 1.0

        if shouldScan {
            print("⏰ Last scan was \(String(format: "%.1f", hoursSinceLastScan)) hours ago - will scan")
        } else {
            print("⏰ Last scan was \(String(format: "%.1f", hoursSinceLastScan)) hours ago - skipping")
        }

        return shouldScan
    }
    
    private func handleWillResignActive() {
        // Re-assert the session as we background - no mixWithOthers in background
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: []) // no mixWithOthers in bg
            try s.setActive(true, options: [])
            print("🎧 Session keepalive on resign active - success")
        } catch { 
            print("❌ Session keepalive fail:", error) 
        }
    }
    
    private func handleOpenURL(_ url: URL) {
        print("🔗 Received URL: \(url.absoluteString)")

        guard url.scheme == "cosmos-music" else {
            print("❌ Unknown URL scheme: \(url.scheme ?? "nil")")
            return
        }

        Task { @MainActor in
            switch url.host {
            case "refresh":
                print("📁 URL triggered library refresh - this is a manual refresh so always scan")
                await LibraryIndexer.shared.copyFilesFromSharedContainer()
                if !LibraryIndexer.shared.isIndexing {
                    LibraryIndexer.shared.start()
                }

            case "playlist":
                // Extract playlist ID from path
                let playlistId = url.pathComponents.dropFirst().joined(separator: "/")
                print("📋 Widget: Opening playlist - \(playlistId)")

                // Navigate to playlist
                if let playlistIdInt = Int64(playlistId) {
                    do {
                        let playlists = try DatabaseManager.shared.getAllPlaylists()
                        if let playlist = playlists.first(where: { $0.id == playlistIdInt }) {
                            // Post notification to navigate to playlist
                            NotificationCenter.default.post(
                                name: NSNotification.Name("NavigateToPlaylist"),
                                object: nil,
                                userInfo: ["playlistId": playlistIdInt]
                            )
                            print("✅ Widget: Navigating to playlist \(playlist.title)")
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
        let placeholderURL = documentsURL.appendingPathComponent(".cosmos_placeholder")
        
        do {
            // Create Documents directory if it doesn't exist
            try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true, attributes: nil)
            
            // Create placeholder file if it doesn't exist
            if !FileManager.default.fileExists(atPath: placeholderURL.path) {
                let placeholderText = "This folder contains music files for Music.\nPlace your FLAC files here to add them to your library."
                try placeholderText.write(to: placeholderURL, atomically: true, encoding: .utf8)
                print("✅ Created iCloud Drive placeholder file to ensure folder visibility")
            }
        } catch {
            print("❌ Failed to create iCloud Drive placeholder: \(error)")
        }
    }

}
