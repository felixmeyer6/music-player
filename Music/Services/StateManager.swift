//  Manages JSON state files for playlists in iCloud Drive

import Foundation

class StateManager: @unchecked Sendable {
    static let shared = StateManager()
    
    private var iCloudContainerURL: URL?
    
    private init() {
        // Only set if iCloud is available
        if FileManager.default.ubiquityIdentityToken != nil {
            iCloudContainerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)
        }
    }
    
    private func getAppFolderURL() -> URL? {
        guard let containerURL = iCloudContainerURL else { return nil }
        return containerURL.appendingPathComponent("Documents", isDirectory: true)
    }
    
    func createAppFolderIfNeeded() throws {
        guard let appFolderURL = getAppFolderURL() else {
            throw StateManagerError.iCloudNotAvailable
        }
        
        if !FileManager.default.fileExists(atPath: appFolderURL.path) {
            try FileManager.default.createDirectory(at: appFolderURL, 
                                                 withIntermediateDirectories: true, 
                                                 attributes: nil)
        }
    }
    
    // MARK: - Playlists
    
    func savePlaylist(_ playlist: PlaylistState) throws {
        // Always save to local Documents first (survives app reinstall)
        try savePlaylistToLocalDocuments(playlist)
        
        // Also try to save to iCloud Drive if available
        do {
            try createAppFolderIfNeeded()
            guard let appFolderURL = getAppFolderURL() else {
                print("⚠️ iCloud not available, playlist saved locally only")
                return
            }
            
            let playlistsFolder = appFolderURL.appendingPathComponent("playlists", isDirectory: true)
            if !FileManager.default.fileExists(atPath: playlistsFolder.path) {
                try FileManager.default.createDirectory(at: playlistsFolder, 
                                                     withIntermediateDirectories: true, 
                                                     attributes: nil)
            }
            
            let playlistURL = playlistsFolder.appendingPathComponent("playlist-\(playlist.slug).json")
            try saveJSONAtomically(playlist, to: playlistURL)
            print("✅ Playlist saved to both local and iCloud")
        } catch {
            print("⚠️ Failed to save playlist to iCloud, but local save succeeded: \(error)")
        }
    }
    
    private func savePlaylistToLocalDocuments(_ playlist: PlaylistState) throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlaylistsFolder = documentsURL.appendingPathComponent("cosmos-playlists", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: localPlaylistsFolder.path) {
            try FileManager.default.createDirectory(at: localPlaylistsFolder, 
                                                 withIntermediateDirectories: true, 
                                                 attributes: nil)
        }
        
        let localPlaylistURL = localPlaylistsFolder.appendingPathComponent("playlist-\(playlist.slug).json")
        try saveJSONAtomically(playlist, to: localPlaylistURL)
        print("📱 Playlist saved locally to: \(localPlaylistURL.path)")
    }
    
    func loadPlaylist(slug: String) throws -> PlaylistState? {
        guard let appFolderURL = getAppFolderURL() else {
            throw StateManagerError.iCloudNotAvailable
        }

        let playlistsFolder = appFolderURL.appendingPathComponent("playlists", isDirectory: true)
        let playlistURL = playlistsFolder.appendingPathComponent("playlist-\(slug).json")

        guard FileManager.default.fileExists(atPath: playlistURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: playlistURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let playlist = try decoder.decode(PlaylistState.self, from: data)
            return playlist
        } catch {
            print("⚠️ Failed to load playlist '\(slug)': \(error)")
            // Try to load from local backup
            if let localPlaylist = try? loadPlaylistFromLocalDocuments(slug: slug) {
                print("✅ Recovered playlist '\(slug)' from local backup")
                return localPlaylist
            }
            print("❌ Unable to recover playlist '\(slug)' from local backup")
            throw error
        }
    }

    private func loadPlaylistFromLocalDocuments(slug: String) throws -> PlaylistState? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlaylistsFolder = documentsURL.appendingPathComponent("cosmos-playlists", isDirectory: true)
        let localPlaylistURL = localPlaylistsFolder.appendingPathComponent("playlist-\(slug).json")

        guard FileManager.default.fileExists(atPath: localPlaylistURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: localPlaylistURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PlaylistState.self, from: data)
    }
    
    func getAllPlaylists() throws -> [PlaylistState] {
        guard let appFolderURL = getAppFolderURL() else {
            throw StateManagerError.iCloudNotAvailable
        }
        
        let playlistsFolder = appFolderURL.appendingPathComponent("playlists", isDirectory: true)
        
        guard FileManager.default.fileExists(atPath: playlistsFolder.path) else {
            return []
        }
        
        let playlistFiles = try FileManager.default.contentsOfDirectory(at: playlistsFolder, 
                                                                       includingPropertiesForKeys: nil)
        
        var playlists: [PlaylistState] = []
        var corruptedFiles: [URL] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for fileURL in playlistFiles where fileURL.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: fileURL)
                let playlist = try decoder.decode(PlaylistState.self, from: data)
                playlists.append(playlist)
            } catch {
                // Check for authentication errors
                if let nsError = error as NSError? {
                    if nsError.domain == NSPOSIXErrorDomain && nsError.code == 81 {
                        print("🔐 Authentication required for playlist file: \(fileURL.lastPathComponent)")
                        throw StateManagerError.iCloudNotAvailable
                    }
                }
                print("⚠️ Failed to read playlist file \(fileURL.lastPathComponent): \(error)")

                // Try to recover from local backup
                let slug = fileURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "playlist-", with: "")
                if let recoveredPlaylist = try? loadPlaylistFromLocalDocuments(slug: slug) {
                    print("✅ Recovered playlist from local backup: \(slug)")
                    playlists.append(recoveredPlaylist)
                    // Try to repair cloud file
                    try? savePlaylist(recoveredPlaylist)
                } else {
                    corruptedFiles.append(fileURL)
                    print("❌ Unable to recover playlist: \(fileURL.lastPathComponent)")
                }
            }
        }

        // Move corrupted files to a quarantine folder
        if !corruptedFiles.isEmpty {
            try? quarantineCorruptedFiles(corruptedFiles, in: playlistsFolder)
        }

        return playlists.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func quarantineCorruptedFiles(_ files: [URL], in folder: URL) throws {
        let quarantineFolder = folder.appendingPathComponent("corrupted", isDirectory: true)

        if !FileManager.default.fileExists(atPath: quarantineFolder.path) {
            try FileManager.default.createDirectory(at: quarantineFolder,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
        }

        for file in files {
            let destination = quarantineFolder.appendingPathComponent(file.lastPathComponent)
            try? FileManager.default.moveItem(at: file, to: destination)
            print("🗄️ Moved corrupted file to quarantine: \(file.lastPathComponent)")
        }
    }
    
    func deletePlaylist(slug: String) throws {
        // Delete from local Documents first
        try deletePlaylistFromLocalDocuments(slug: slug)
        
        // Also try to delete from iCloud Drive if available
        do {
            guard let appFolderURL = getAppFolderURL() else {
                print("⚠️ iCloud not available, playlist deleted locally only")
                return
            }
            
            let playlistsFolder = appFolderURL.appendingPathComponent("playlists", isDirectory: true)
            let playlistURL = playlistsFolder.appendingPathComponent("playlist-\(slug).json")
            
            if FileManager.default.fileExists(atPath: playlistURL.path) {
                try FileManager.default.removeItem(at: playlistURL)
                print("☁️ Playlist deleted from iCloud: \(playlistURL.path)")
            }
        } catch {
            print("⚠️ Failed to delete playlist from iCloud, but local delete succeeded: \(error)")
        }
    }
    
    private func deletePlaylistFromLocalDocuments(slug: String) throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlaylistsFolder = documentsURL.appendingPathComponent("cosmos-playlists", isDirectory: true)
        let localPlaylistURL = localPlaylistsFolder.appendingPathComponent("playlist-\(slug).json")
        
        if FileManager.default.fileExists(atPath: localPlaylistURL.path) {
            try FileManager.default.removeItem(at: localPlaylistURL)
            print("📱 Playlist deleted locally: \(localPlaylistURL.path)")
        }
    }
    
    // MARK: - Helper methods
    
    private func saveJSONAtomically<T: Codable>(_ object: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(object)
        
        let tempURL = url.appendingPathExtension("tmp")
        try data.write(to: tempURL)
        _ = try FileManager.default.replaceItem(at: url, withItemAt: tempURL, 
                                              backupItemName: nil, options: [], 
                                              resultingItemURL: nil)
    }
    
    func getMusicFolderURL() -> URL? {
        return getAppFolderURL()
    }
}

// MARK: - Player State Persistence

struct PlayerState: Codable {
    let currentTrackStableId: String?
    let playbackTime: TimeInterval
    let isPlaying: Bool
    let queueTrackIds: [String]
    let currentIndex: Int
    let isRepeating: Bool
    let isShuffled: Bool
    let isLoopingSong: Bool
    let originalQueueTrackIds: [String]
    let lastSavedAt: Date
}

extension StateManager {
    func savePlayerState(_ playerState: PlayerState) throws {
        print("💾 StateManager: Saving player state - track: \(playerState.currentTrackStableId ?? "nil"), time: \(playerState.playbackTime)")
        
        // Always save to local Documents first (survives app reinstall)
        try savePlayerStateToLocalDocuments(playerState)
        
        // Also try to save to iCloud Drive if available
        do {
            try createAppFolderIfNeeded()
            guard let appFolderURL = getAppFolderURL() else {
                print("⚠️ iCloud not available, player state saved locally only")
                return
            }
            
            let playerStateURL = appFolderURL.appendingPathComponent("player-state.json")
            try saveJSONAtomically(playerState, to: playerStateURL)
            print("✅ Player state saved to both local and iCloud")
        } catch {
            print("⚠️ Failed to save player state to iCloud, but local save succeeded: \(error)")
        }
    }
    
    private func savePlayerStateToLocalDocuments(_ playerState: PlayerState) throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlayerStateURL = documentsURL.appendingPathComponent("cosmos-player-state.json")
        try saveJSONAtomically(playerState, to: localPlayerStateURL)
        print("📱 Player state saved locally to: \(localPlayerStateURL.path)")
    }
    
    func loadPlayerState() throws -> PlayerState? {
        print("📂 StateManager: Loading player state...")
        
        // Try loading from local Documents first (survives app reinstall)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlayerStateURL = documentsURL.appendingPathComponent("cosmos-player-state.json")
        
        print("📂 StateManager: Checking local player state at: \(localPlayerStateURL.path)")
        
        if FileManager.default.fileExists(atPath: localPlayerStateURL.path) {
            do {
                let data = try Data(contentsOf: localPlayerStateURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let playerState = try decoder.decode(PlayerState.self, from: data)
                print("📱 Loaded player state from local storage - track: \(playerState.currentTrackStableId ?? "nil"), time: \(playerState.playbackTime)")
                return playerState
            } catch {
                print("⚠️ Failed to load local player state: \(error)")
            }
        } else {
            print("📂 StateManager: Local player state file does not exist")
        }
        
        // Fallback to iCloud Drive if local doesn't exist
        guard let appFolderURL = getAppFolderURL() else {
            print("📭 No player state found (neither local nor iCloud)")
            return nil
        }
        
        let playerStateURL = appFolderURL.appendingPathComponent("player-state.json")
        print("📂 StateManager: Checking iCloud player state at: \(playerStateURL.path)")
        
        guard FileManager.default.fileExists(atPath: playerStateURL.path) else {
            print("📭 No iCloud player state file found")
            return nil
        }
        
        do {
            // Check if this is an iCloud file and ensure it's downloaded
            let resourceValues = try playerStateURL.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            
            if let isUbiquitous = resourceValues.isUbiquitousItem, isUbiquitous {
                print("☁️ iCloud player state file detected, checking download status...")
                
                if let downloadingStatus = resourceValues.ubiquitousItemDownloadingStatus {
                    print("📊 iCloud player state download status: \(downloadingStatus)")
                    
                    if downloadingStatus == .notDownloaded {
                        print("🔽 iCloud player state file needs downloading, starting download...")
                        try FileManager.default.startDownloadingUbiquitousItem(at: playerStateURL)
                        
                        // Wait a moment for download to start
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                }
            }
            
            // Use NSFileCoordinator for proper iCloud file access
            var coordinatorError: NSError?
            var data: Data?
            
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: playerStateURL, options: .withoutChanges, error: &coordinatorError) { (url) in
                do {
                    data = try Data(contentsOf: url)
                    print("☁️ Successfully read player state from iCloud via NSFileCoordinator")
                } catch {
                    print("❌ Failed to read iCloud player state via coordinator: \(error)")
                }
            }
            
            if let coordinatorError = coordinatorError {
                print("❌ NSFileCoordinator error: \(coordinatorError)")
                return nil
            }
            
            guard let playerStateData = data else {
                print("❌ No data read from iCloud player state file")
                return nil
            }
            
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let playerState = try decoder.decode(PlayerState.self, from: playerStateData)
            print("☁️ Loaded player state from iCloud - track: \(playerState.currentTrackStableId ?? "nil"), time: \(playerState.playbackTime)")
            return playerState
        } catch {
            print("❌ Failed to load player state from iCloud: \(error)")
            return nil
        }
    }
}

enum StateManagerError: Error {
    case iCloudNotAvailable
}
