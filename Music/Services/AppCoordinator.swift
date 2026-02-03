//
//  AppCoordinator.swift
//  Cosmos Music Player
//
//  Main app coordinator that manages all services
//

import Foundation
import Combine
import UIKit
import AVFoundation
import WidgetKit

enum iCloudStatus: Equatable {
    case available
    case notSignedIn
    case containerUnavailable
    case offline
    case authenticationRequired
    case error(Error)
    
    static func == (lhs: iCloudStatus, rhs: iCloudStatus) -> Bool {
        switch (lhs, rhs) {
        case (.available, .available),
             (.notSignedIn, .notSignedIn),
             (.containerUnavailable, .containerUnavailable),
             (.offline, .offline),
             (.authenticationRequired, .authenticationRequired):
            return true
        case (.error, .error):
            return true
        default:
            return false
        }
    }
}

@MainActor
class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()
    
    @Published var isInitialized = false
    @Published var initializationError: Error?
    @Published var isiCloudAvailable = false
    @Published var iCloudStatus: iCloudStatus = .offline

    @Published var showSyncAlert = false
    
    let databaseManager = DatabaseManager.shared
    let stateManager = StateManager.shared
    let libraryIndexer = LibraryIndexer.shared
    let playerEngine = PlayerEngine.shared
    let cloudDownloadManager = CloudDownloadManager.shared
    let fileCleanupManager = FileCleanupManager.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupBindings()
    }
    
    func initialize() async {
        print("🚀 AppCoordinator.initialize() started")

        // Check iCloud status
        let status = await checkiCloudStatus()
        iCloudStatus = status

        // Notify CloudDownloadManager about status change
        NotificationCenter.default.post(name: NSNotification.Name("iCloudAuthStatusChanged"), object: nil)

        // Check if we should auto-scan based on last scan date
        var settings = DeleteSettings.load()
        print("📅 Current lastLibraryScanDate: \(settings.lastLibraryScanDate?.description ?? "nil")")
        let shouldAutoScan = shouldPerformAutoScan(lastScanDate: settings.lastLibraryScanDate)

        if shouldAutoScan {
            print("🔄 App launched after long time - starting automatic library scan")
        } else {
            print("⏭️ Recent app launch - skipping automatic scan (use manual sync button)")
        }

        switch status {
        case .available:
            isiCloudAvailable = true
            await forceiCloudFolderCreation()

            // Only auto-scan if it's been a while or never scanned
            if shouldAutoScan {
                await startLibraryIndexing()
                settings.lastLibraryScanDate = Date()
                settings.save()
            }
            print("App initialized with iCloud sync")

        case .notSignedIn:
            isiCloudAvailable = false
            initializationError = AppCoordinatorError.iCloudNotSignedIn
            // Still initialize in local mode for functionality
            if shouldAutoScan {
                await startOfflineLibraryIndexing()
                settings.lastLibraryScanDate = Date()
                settings.save()
            }
            print("App initialized in local mode - iCloud not signed in")

        case .containerUnavailable, .error(_):
            isiCloudAvailable = false
            initializationError = AppCoordinatorError.iCloudContainerInaccessible
            // Still initialize in local mode for functionality
            if shouldAutoScan {
                await startOfflineLibraryIndexing()
                settings.lastLibraryScanDate = Date()
                settings.save()
            }
            print("App initialized in local mode - iCloud container unavailable")

        case .authenticationRequired:
            isiCloudAvailable = false
            showSyncAlert = true
            if shouldAutoScan {
                await startOfflineLibraryIndexing()
                settings.lastLibraryScanDate = Date()
                settings.save()
            }
            print("App initialized in local mode - iCloud authentication required")

        case .offline:
            isiCloudAvailable = false
            // No error - this is true offline mode
            if shouldAutoScan {
                await startOfflineLibraryIndexing()
                settings.lastLibraryScanDate = Date()
                settings.save()
            }
            print("App initialized in offline mode")
        }

        // Restore UI state only to show user what was playing without interrupting other apps
        Task {
            await playerEngine.restoreUIStateOnly()
        }

        isInitialized = true
    }

    private func shouldPerformAutoScan(lastScanDate: Date?) -> Bool {
        // If never scanned before, definitely scan
        guard let lastScanDate = lastScanDate else {
            print("🆕 Never scanned before - will perform scan")
            return true
        }

        // Check if it's been more than 1 hour since last scan
        // This prevents scanning when app was just backgrounded/resumed
        let hoursSinceLastScan = Date().timeIntervalSince(lastScanDate) / 3600
        let shouldScan = hoursSinceLastScan >= 1.0

        if shouldScan {
            print("⏰ Last scan was \(String(format: "%.1f", hoursSinceLastScan)) hours ago - will scan")
        } else {
            print("⏰ Last scan was \(String(format: "%.1f", hoursSinceLastScan)) hours ago - skipping")
        }

        return shouldScan
    }
    
    private func checkiCloudStatus() async -> iCloudStatus {
        // Check if user is signed into iCloud
        guard FileManager.default.ubiquityIdentityToken != nil else {
            return .notSignedIn
        }
        
        // Check if we can get the container URL
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return .containerUnavailable
        }
        
        // Check if we can actually access the container
        do {
            let resourceValues = try containerURL.resourceValues(forKeys: [.isUbiquitousItemKey])
            if resourceValues.isUbiquitousItem != true {
                return .containerUnavailable
            }
        } catch {
            return .error(error)
        }
        
        print("NSUbiquitousContainers:",
              Bundle.main.object(forInfoDictionaryKey: "NSUbiquitousContainers") ?? "nil")
        
        // Try to create the app folder
        do {
            let appFolderURL = containerURL.appendingPathComponent("Music", isDirectory: true)
            
            if !FileManager.default.fileExists(atPath: appFolderURL.path) {
                try FileManager.default.createDirectory(at: appFolderURL, 
                                                     withIntermediateDirectories: true, 
                                                     attributes: nil)
            }
            
            print("iCloud container set up at: \(appFolderURL)")
            return .available
        } catch {
            return .error(error)
        }
    }
    
    private func startLibraryIndexing() async {
        libraryIndexer.start()
    }
    
    private func startOfflineLibraryIndexing() async {
        // In offline mode, we don't use NSMetadataQuery (iCloud specific)
        // Instead, we scan the app's Documents directory for music files
        libraryIndexer.startOfflineMode()
    }
    
    private func setupBindings() {
        libraryIndexer.$isIndexing
            .sink { [weak self] isIndexing in
                if !isIndexing {
                    Task { @MainActor in
                        await self?.onIndexingCompleted()
                    }
                }
            }
            .store(in: &cancellables)

        // Listen for background color changes to update widget theme
        NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))
            .sink { [weak self] _ in
                Task { @MainActor in
                    print("🎨 Background color changed - updating widget theme")
                    // Update playlist widget colors
                    self?.syncPlaylistsToCloud()
                    // Update now playing widget color
                    self?.playerEngine.updateWidgetData()
                }
            }
            .store(in: &cancellables)
    }
    
    func handleiCloudAuthenticationError() {
        guard iCloudStatus != .authenticationRequired else { return }
        
        iCloudStatus = .authenticationRequired
        isiCloudAvailable = false
        showSyncAlert = true
        
        // Stop any ongoing iCloud operations
        libraryIndexer.switchToOfflineMode()
        
        // Notify CloudDownloadManager about status change
        NotificationCenter.default.post(name: NSNotification.Name("iCloudAuthStatusChanged"), object: nil)
        
        
        print("🔐 iCloud authentication error detected - switched to offline mode")
    }
    
    private func onIndexingCompleted() async {
        // Restore playlists from iCloud after indexing is complete
        await restorePlaylistsFromiCloud()

        // Verify and fix any database relationship issues
        await verifyDatabaseRelationships()

        // Try playlist restoration again after relationships are fixed
        await retryPlaylistRestoration()

        // Deduplicate playlist items (fixes playlists with duplicate entries)
        do {
            try databaseManager.deduplicatePlaylistItems()
        } catch {
            print("⚠️ Failed to deduplicate playlist items: \(error)")
        }

        // Clean up orphaned playlist items
        do {
            try databaseManager.cleanupOrphanedPlaylistItems()
        } catch {
            print("⚠️ Failed to cleanup orphaned playlist items: \(error)")
        }

        // Mark initial indexing as complete
        hasCompletedInitialIndexing = true
        print("✅ Initial indexing completed - playlist sync enabled")

        // Update widget with playlists
        syncPlaylistsToCloud()

        // Check for orphaned files after sync completes
        print("🔄 AppCoordinator: Starting orphaned files check...")
        await fileCleanupManager.checkForOrphanedFiles()
        print("🔄 AppCoordinator: Orphaned files check completed")
    }
    
    private func forceiCloudFolderCreation() async {
        do {
            try stateManager.createAppFolderIfNeeded()
            if let folderURL = stateManager.getMusicFolderURL() {
                print("🏗️ iCloud folder created/verified at: \(folderURL)")
                
                // Create test files to trigger iCloud Drive visibility (as per research)
                let tempFile = folderURL.appendingPathComponent(".cosmos-placeholder")
                let testFile = folderURL.appendingPathComponent("Welcome.txt")
                
                let tempContent = "Music folder - you can delete this file"
                let welcomeContent = "Welcome to Music!\n\nYou can add your MP3 music files directly to this folder in the Files app.\n\nThe app will automatically detect and index any music files you add here.\n\nEnjoy your music!"
                
                try tempContent.write(to: tempFile, atomically: true, encoding: .utf8)
                try welcomeContent.write(to: testFile, atomically: true, encoding: .utf8)
                print("📄 Created placeholder and welcome files to ensure folder visibility")
            }
        } catch {
            print("⚠️ Failed to create iCloud folder: \(error)")
        }
    }
    
    private func restorePlaylistsFromiCloud() async {
        // Skip if iCloud is not available or authentication required
        guard isiCloudAvailable && iCloudStatus == .available else {
            print("⚠️ Skipping playlist restoration - iCloud not available or authentication required")
            return
        }
        
        do {
            print("🔄 Starting playlist restoration from iCloud...")
            let playlistStates = try stateManager.getAllPlaylists()
            print("📂 Found \(playlistStates.count) playlists in iCloud storage")
            
            for playlistState in playlistStates {
                // Check if playlist already exists in database
                let existingPlaylists = try databaseManager.getAllPlaylists()

                if let existingPlaylist = existingPlaylists.first(where: { $0.slug == playlistState.slug }) {
                    // Playlist exists - sync tracks from cloud to database
                    print("🔄 Syncing existing playlist from cloud: \(playlistState.title)")

                    guard let playlistId = existingPlaylist.id else { continue }

                    // Get current tracks in database
                    let currentItems = try databaseManager.getPlaylistItems(playlistId: playlistId)
                    let currentTrackIds = Set(currentItems.map { $0.trackStableId })
                    let cloudTrackIds = Set(playlistState.items.map { $0.trackId })

                    // Only add tracks that are in cloud but not in database
                    // This prevents removing tracks user added locally
                    let tracksToAdd = cloudTrackIds.subtracting(currentTrackIds)

                    if !tracksToAdd.isEmpty {
                        print("➕ Adding \(tracksToAdd.count) missing tracks from cloud to '\(playlistState.title)'")
                        for trackId in tracksToAdd {
                            // Check if track exists in database
                            if let _ = try databaseManager.getTrack(byStableId: trackId) {
                                try databaseManager.addToPlaylist(playlistId: playlistId, trackStableId: trackId)
                                print("✅ Added track to playlist: \(trackId)")
                            } else {
                                print("⚠️ Track not found in database: \(trackId)")
                            }
                        }
                    } else {
                        print("✅ Playlist '\(playlistState.title)' is already in sync")
                    }
                } else {
                    // Playlist doesn't exist - create it
                    print("➕ Restoring new playlist: \(playlistState.title)")
                    let playlist = try databaseManager.createPlaylist(title: playlistState.title)

                    // Add tracks to playlist if they exist in the database
                    guard let playlistId = playlist.id else { continue }

                    for item in playlistState.items {
                        // Check if track exists in database
                        if let _ = try databaseManager.getTrack(byStableId: item.trackId) {
                            try databaseManager.addToPlaylist(playlistId: playlistId, trackStableId: item.trackId)
                            print("✅ Added track to playlist: \(item.trackId)")
                        } else {
                            print("⚠️ Track not found in database: \(item.trackId)")
                        }
                    }
                }
            }
            print("✅ Playlist restoration completed")
        } catch {
            print("❌ Failed to restore playlists from iCloud: \(error)")
            
            // Check if this is an authentication error
            if let stateError = error as? StateManagerError, stateError == .iCloudNotAvailable {
                print("🔐 StateManager authentication error - switching to offline mode")
                handleiCloudAuthenticationError()
            }
        }
    }
    
    private func verifyDatabaseRelationships() async {
        do {
            print("🔍 Verifying database relationships...")
            let tracks = try databaseManager.getAllTracks()
            let albums = try databaseManager.getAllAlbums()
            let artists = try databaseManager.getAllArtists()
            
            print("📊 Database stats - Tracks: \(tracks.count), Albums: \(albums.count), Artists: \(artists.count)")
            
            // Simple verification - just report what we have
            var tracksWithoutArtist = 0
            var tracksWithoutAlbum = 0
            var invalidArtistRefs = 0
            var invalidAlbumRefs = 0
            
            for track in tracks {
                // Check artist relationship
                if let artistId = track.artistId {
                    let artistExists = artists.contains { $0.id == artistId }
                    if !artistExists {
                        invalidArtistRefs += 1
                        print("⚠️ Track '\(track.title)' references non-existent artist ID: \(artistId)")
                    }
                } else {
                    tracksWithoutArtist += 1
                    print("⚠️ Track '\(track.title)' has no artist ID")
                }
                
                // Check album relationship  
                if let albumId = track.albumId {
                    let albumExists = albums.contains { $0.id == albumId }
                    if !albumExists {
                        invalidAlbumRefs += 1
                        print("⚠️ Track '\(track.title)' references non-existent album ID: \(albumId)")
                    }
                } else {
                    tracksWithoutAlbum += 1
                    print("⚠️ Track '\(track.title)' has no album ID")
                }
            }
            
            print("🔍 Verification complete:")
            print("   - Tracks without artist: \(tracksWithoutArtist)")
            print("   - Tracks without album: \(tracksWithoutAlbum)")
            print("   - Invalid artist refs: \(invalidArtistRefs)")
            print("   - Invalid album refs: \(invalidAlbumRefs)")
            
        } catch {
            print("❌ Failed to verify database relationships: \(error)")
        }
    }
    
    private func retryPlaylistRestoration() async {
        // Skip if iCloud is not available or authentication required
        guard isiCloudAvailable && iCloudStatus == .available else {
            print("⚠️ Skipping retry playlist restoration - iCloud not available or authentication required")
            return
        }
        
        do {
            print("🔄 Retrying playlist restoration after database fixes...")
            let playlistStates = try stateManager.getAllPlaylists()
            let existingPlaylists = try databaseManager.getAllPlaylists()
            
            for playlistState in playlistStates {
                if let existingPlaylist = existingPlaylists.first(where: { $0.slug == playlistState.slug }),
                   let playlistId = existingPlaylist.id {
                    
                    // Check if playlist is empty and try to restore tracks
                    let currentItems = try databaseManager.getPlaylistItems(playlistId: playlistId)
                    if currentItems.isEmpty {
                        print("🔄 Playlist '\(playlistState.title)' is empty, attempting to restore tracks...")
                        
                        for item in playlistState.items {
                            if let _ = try databaseManager.getTrack(byStableId: item.trackId) {
                                try databaseManager.addToPlaylist(playlistId: playlistId, trackStableId: item.trackId)
                                print("✅ Added track to playlist after fix: \(item.trackId)")
                            } else {
                                print("⚠️ Track still not found after fixes: \(item.trackId)")
                            }
                        }
                    } else {
                        print("⚡ Playlist '\(playlistState.title)' already has \(currentItems.count) items")
                    }
                }
            }
            print("✅ Playlist restoration retry completed")
        } catch {
            print("❌ Failed to retry playlist restoration: \(error)")
            
            // Check if this is an authentication error
            if let stateError = error as? StateManagerError, stateError == .iCloudNotAvailable {
                print("🔐 StateManager authentication error in retry - switching to offline mode")
                handleiCloudAuthenticationError()
            }
        }
    }
    
    
    // MARK: - Public API
    
    func getAllTracks() throws -> [Track] {
        return try databaseManager.getAllTracks()
    }
    
    func manualSync() async {
        print("🔄 Manual sync triggered - attempting library indexing")
        
        // Check if we're already indexing
        if libraryIndexer.isIndexing {
            print("⚠️ Library indexing already in progress - skipping manual sync")
            return
        }
        
        // For manual sync, always attempt to re-index to catch new files
        print("📋 Performing manual sync - user requested fresh library scan")
        await startLibraryIndexing()
    }
    
    func getAllAlbums() throws -> [Album] {
        return try databaseManager.getAllAlbums()
    }
    
    // MARK: - Playlist operations
    
    func addToPlaylist(playlistId: Int64, trackStableId: String, syncToCloud: Bool = true) throws {
        try databaseManager.addToPlaylist(playlistId: playlistId, trackStableId: trackStableId)
        if syncToCloud {
            syncPlaylistsToCloud()
        }
    }
    
    func removeFromPlaylist(playlistId: Int64, trackStableId: String, showToast: Bool = true, syncToCloud: Bool = true) throws {
        // Get playlist name before removing
        var playlistName: String?
        if showToast {
            let playlists = try databaseManager.getAllPlaylists()
            playlistName = playlists.first(where: { $0.id == playlistId })?.title
        }

        try databaseManager.removeFromPlaylist(playlistId: playlistId, trackStableId: trackStableId)
        if syncToCloud {
            syncPlaylistsToCloud()
        }

        // Post notification to show removal toast
        if showToast, let name = playlistName {
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowRemovedFromPlaylistToast"),
                object: nil,
                userInfo: ["playlistName": name]
            )
        }
    }

    func reorderPlaylistItems(playlistId: Int64, from sourceIndex: Int, to destinationIndex: Int) throws {
        try databaseManager.reorderPlaylistItems(playlistId: playlistId, from: sourceIndex, to: destinationIndex)
        syncPlaylistsToCloud()
    }

    func createPlaylist(title: String) throws -> Playlist {
        let playlist = try databaseManager.createPlaylist(title: title)
        syncPlaylistsToCloud()
        return playlist
    }

    func isTrackInPlaylist(playlistId: Int64, trackStableId: String) throws -> Bool {
        return try databaseManager.isTrackInPlaylist(playlistId: playlistId, trackStableId: trackStableId)
    }
    
    func deletePlaylist(playlistId: Int64) throws {
        // Get playlist info before deleting from database
        let playlists = try databaseManager.getAllPlaylists()
        guard let playlist = playlists.first(where: { $0.id == playlistId }) else {
            throw AppCoordinatorError.playlistNotFound
        }
        
        let playlistSlug = playlist.slug
        
        // Delete from database
        try databaseManager.deletePlaylist(playlistId: playlistId)
        
        // Delete from iCloud and local storage
        try stateManager.deletePlaylist(slug: playlistSlug)
        
        print("✅ Playlist '\(playlist.title)' deleted from database and cloud storage")
    }

    func renamePlaylist(playlistId: Int64, newTitle: String) throws {
        try databaseManager.renamePlaylist(playlistId: playlistId, newTitle: newTitle)
        print("✅ Playlist renamed to '\(newTitle)'")
    }

    func updatePlaylistAccessed(playlistId: Int64) throws {
        try databaseManager.updatePlaylistAccessed(playlistId: playlistId)
    }
    
    func updatePlaylistLastPlayed(playlistId: Int64) throws {
        try databaseManager.updatePlaylistLastPlayed(playlistId: playlistId)
        // Update widget to show most recently played playlists
        syncPlaylistsToCloud()
    }
    
    private var isSyncingPlaylists = false
    private var hasCompletedInitialIndexing = false

    /// Public entry point for triggering a playlist sync after batch operations.
    func triggerPlaylistSync() {
        syncPlaylistsToCloud()
    }

    private func syncPlaylistsToCloud() {
        // Prevent concurrent sync operations (check on MainActor before dispatching)
        guard !isSyncingPlaylists else {
            print("⏭️ Skipping playlist sync - already in progress")
            return
        }

        // Safety: Don't sync until initial indexing is complete
        guard hasCompletedInitialIndexing else {
            print("⏳ Skipping playlist sync - waiting for initial indexing to complete")
            return
        }

        isSyncingPlaylists = true

        // Use a regular Task to inherit @MainActor context, ensuring @Published
        // mutations and widget updates stay on the main thread. GRDB handles its
        // own internal threading so DB reads won't block the UI.
        Task {
            var syncedPlaylists: [Playlist] = []
            do {
                let playlists = try databaseManager.getAllPlaylists()
                syncedPlaylists = playlists

                for playlist in playlists {
                    guard let playlistId = playlist.id else { continue }

                    let dbPlaylistItems = try databaseManager.getPlaylistItems(playlistId: playlistId)

                    var validItems: [(String, Date)] = []
                    for item in dbPlaylistItems {
                        if let _ = try? databaseManager.getTrack(byStableId: item.trackStableId) {
                            validItems.append((item.trackStableId, Date()))
                        } else {
                            print("⚠️ Skipping orphaned track in playlist '\(playlist.title)': \(item.trackStableId)")
                        }
                    }
                    let stateItems = validItems

                    if stateItems.isEmpty {
                        if let existingCloudPlaylist = try? stateManager.loadPlaylist(slug: playlist.slug),
                           !existingCloudPlaylist.items.isEmpty {
                            print("⚠️ Skipping sync for '\(playlist.title)' - database is empty but cloud has \(existingCloudPlaylist.items.count) tracks")
                            continue
                        }
                    }

                    let playlistState = PlaylistState(
                        slug: playlist.slug,
                        title: playlist.title,
                        createdAt: Date(timeIntervalSince1970: TimeInterval(playlist.createdAt)),
                        items: stateItems
                    )
                    try stateManager.savePlaylist(playlistState)
                }
                print("✅ Playlists synced to iCloud with \(playlists.count) playlists")

            } catch {
                print("❌ Failed to sync playlists to iCloud: \(error)")
            }

            await finishPlaylistSync(playlists: syncedPlaylists)
        }
    }

    /// Called from background sync task to reset state and update widgets on MainActor.
    fileprivate func finishPlaylistSync(playlists: [Playlist]) async {
        isSyncingPlaylists = false
        await updateWidgetPlaylists(playlists: playlists)
    }

    private func updateWidgetPlaylists(playlists: [Playlist]) async {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.dev.neofx.music-player"
        ) else {
            print("⚠️ Widget: Failed to get shared container URL")
            return
        }

        // Sort playlists by most recently played (lastPlayedAt descending)
        let sortedPlaylists = playlists.sorted { playlist1, playlist2 in
            return playlist1.lastPlayedAt > playlist2.lastPlayedAt
        }

        // Show only the top 3 most recently played playlists
        let playlistsToShow = Array(sortedPlaylists.prefix(3))
        print("📊 Widget: Showing top 3 most recently played playlists out of \(playlists.count) total")

        var widgetPlaylists: [WidgetPlaylistData] = []

        for playlist in playlistsToShow {
            guard let playlistId = playlist.id else { continue }

            do {
                // Get playlist items IN ORDER (same as app displays)
                let playlistItems = try databaseManager.getPlaylistItems(playlistId: playlistId)

                // Preserve playlist order by fetching tracks one by one
                var orderedTracks: [Track] = []
                for item in playlistItems {
                    if let track = try databaseManager.getTrack(byStableId: item.trackStableId) {
                        orderedTracks.append(track)
                    }
                }

                // Get first 4 tracks for artwork mashup (in correct playlist order)
                let artworkTracks = Array(orderedTracks.prefix(4))
                var artworkPaths: [String] = []

                // Save artwork for each track
                for (index, track) in artworkTracks.enumerated() {
                    if let artwork = await ArtworkManager.shared.getArtwork(for: track),
                       let artworkData = artwork.jpegData(compressionQuality: 0.8) {
                        let filename = "playlist_\(playlistId)_\(index).jpg"
                        let fileURL = containerURL.appendingPathComponent(filename)

                        try? artworkData.write(to: fileURL, options: .atomic)
                        artworkPaths.append(filename)
                        print("✅ Widget: Saved artwork '\(track.title)' for playlist '\(playlist.title)' tile \(index)")
                    }
                }

                // Get theme color from settings
                let settings = DeleteSettings.load()
                let colorHex = settings.backgroundColorChoice.rawValue

                let widgetPlaylist = WidgetPlaylistData(
                    id: String(playlistId),
                    name: playlist.title,
                    trackCount: orderedTracks.count,
                    colorHex: colorHex,
                    artworkPaths: artworkPaths,
                    customCoverImagePath: playlist.customCoverImagePath
                )
                widgetPlaylists.append(widgetPlaylist)

            } catch {
                print("❌ Failed to process playlist \(playlist.title): \(error)")
            }
        }

        PlaylistDataManager.shared.savePlaylists(widgetPlaylists)
        print("✅ Widget playlist data updated with \(widgetPlaylists.count) playlists")

        // Force widget to reload immediately
        WidgetCenter.shared.reloadAllTimelines()
        print("🔄 Widget timeline reload triggered")
    }
    
    func playTrack(_ track: Track, queue: [Track] = []) async {
        await playerEngine.playTrack(track, queue: queue)
    }
}

enum AppCoordinatorError: Error {
    case iCloudNotSignedIn
    case iCloudContainerInaccessible
    case playlistNotFound

    var localizedDescription: String {
        switch self {
        case .iCloudNotSignedIn:
            return "Please sign in to iCloud to use this app. Go to Settings > [Your Name] > iCloud and enable iCloud Drive."
        case .iCloudContainerInaccessible:
            return "Cannot access iCloud Drive. Please check your internet connection and iCloud Drive settings."
        case .playlistNotFound:
            return "Playlist not found."
        }
    }
}
