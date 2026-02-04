//  Shared data models for widget communication

import Foundation
import UIKit
import CoreFoundation

// MARK: - App Group Preferences (Current User)
private final class AppGroupUserDefaults {
    private let appID: CFString
    private let user: CFString = kCFPreferencesCurrentUser
    private let host: CFString = kCFPreferencesCurrentHost

    init?(suiteName: String) {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) != nil else {
            return nil
        }
        self.appID = suiteName as CFString
    }

    func data(forKey key: String) -> Data? {
        guard let value = CFPreferencesCopyValue(key as CFString, appID, user, host) else {
            return nil
        }
        return value as? Data
    }

    func set(_ value: Data, forKey key: String) {
        CFPreferencesSetValue(key as CFString, value as CFData, appID, user, host)
    }

    func removeObject(forKey key: String) {
        CFPreferencesSetValue(key as CFString, nil, appID, user, host)
    }

    @discardableResult
    func synchronize() -> Bool {
        return CFPreferencesAppSynchronize(appID)
    }
}

// MARK: - Widget Track Data
struct WidgetTrackData: Codable {
    let trackId: String
    let title: String
    let artist: String
    let isPlaying: Bool
    let lastUpdated: Date
    let backgroundColorHex: String
    
    init(trackId: String, title: String, artist: String, isPlaying: Bool, backgroundColorHex: String) {
        self.trackId = trackId
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
        self.lastUpdated = Date()
        self.backgroundColorHex = backgroundColorHex
    }
}

// MARK: - Widget Data Manager
final class WidgetDataManager: @unchecked Sendable {
    static let shared = WidgetDataManager()
    
    private let userDefaults: AppGroupUserDefaults?
    private let currentTrackKey = "widget.currentTrack"
    private let artworkFileName = "widget_artwork.jpg"
    
    private init() {
        // Use App Group to share data between app and widget
        userDefaults = AppGroupUserDefaults(suiteName: "group.dev.neofx.music-player")
    }
    
    // MARK: - Track Data (without artwork to avoid 4MB limit)
    
    func saveCurrentTrack(_ data: WidgetTrackData, artworkData: Data? = nil) {
        guard let userDefaults = userDefaults else {
            print("⚠️ Widget: Failed to access shared UserDefaults")
            return
        }
        
        do {
            // Save track data to UserDefaults (small, < 1KB)
            let encoded = try JSONEncoder().encode(data)
            userDefaults.set(encoded, forKey: currentTrackKey)
            userDefaults.synchronize()

            // Save artwork to shared file (can be > 4MB)
            if let artworkData = artworkData {
                saveArtwork(artworkData)
            } else {
                clearArtwork()
            }
        } catch {
            print("❌ Widget: Failed to encode track data - \(error)")
        }
    }
    
    func getCurrentTrack() -> WidgetTrackData? {
        guard let userDefaults = userDefaults else {
            print("⚠️ Widget: Failed to access shared UserDefaults - userDefaults is nil")
            return nil
        }
        
        guard let data = userDefaults.data(forKey: currentTrackKey) else {
            return nil
        }

        do {
            let decoded = try JSONDecoder().decode(WidgetTrackData.self, from: data)
            return decoded
        } catch {
            print("❌ Widget: Failed to decode track data - \(error)")
            print("❌ Widget: Data: \(String(data: data, encoding: .utf8) ?? "unable to decode")")
            return nil
        }
    }
    
    func clearCurrentTrack() {
        userDefaults?.removeObject(forKey: currentTrackKey)
        userDefaults?.synchronize()
        clearArtwork()
    }
    
    // MARK: - Artwork File Storage (avoids 4MB UserDefaults limit)
    
    private func getSharedContainerURL() -> URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.neofx.music-player")
    }
    
    private func saveArtwork(_ data: Data) {
        guard let containerURL = getSharedContainerURL() else {
            print("⚠️ Widget: Failed to get shared container URL")
            return
        }
        
        let fileURL = containerURL.appendingPathComponent(artworkFileName)
        
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("❌ Widget: Failed to save artwork - \(error)")
        }
    }
    
    public func getArtwork() -> Data? {
        guard let containerURL = getSharedContainerURL() else {
            print("⚠️ Widget: Failed to get shared container URL")
            return nil
        }
        
        let fileURL = containerURL.appendingPathComponent(artworkFileName)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: fileURL)
            return data
        } catch {
            print("❌ Widget: Failed to load artwork - \(error)")
            return nil
        }
    }
    
    private func clearArtwork() {
        guard let containerURL = getSharedContainerURL() else { return }
        
        let fileURL = containerURL.appendingPathComponent(artworkFileName)
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

// MARK: - Widget Playlist Data
public struct WidgetPlaylistData: Codable {
    public let id: String
    public let name: String
    public let trackCount: Int
    public let colorHex: String
    public let artworkPaths: [String] // Filenames of artwork files in shared container
    public let customCoverImagePath: String? // Custom user-selected cover image

    public init(id: String, name: String, trackCount: Int, colorHex: String, artworkPaths: [String], customCoverImagePath: String? = nil) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.colorHex = colorHex
        self.artworkPaths = artworkPaths
        self.customCoverImagePath = customCoverImagePath
    }
}

// MARK: - Playlist Data Manager
public final class PlaylistDataManager: @unchecked Sendable {
    public static let shared = PlaylistDataManager()

    private let userDefaults: AppGroupUserDefaults?
    private let playlistsKey = "widget.playlists"

    private init() {
        userDefaults = AppGroupUserDefaults(suiteName: "group.dev.neofx.music-player")
    }

    public func savePlaylists(_ playlists: [WidgetPlaylistData]) {
        guard let userDefaults = userDefaults else {
            print("⚠️ Widget: Failed to access shared UserDefaults for playlists")
            return
        }

        do {
            let encoded = try JSONEncoder().encode(playlists)
            userDefaults.set(encoded, forKey: playlistsKey)
            userDefaults.synchronize()
        } catch {
            print("❌ Widget: Failed to encode playlists - \(error)")
        }
    }

    public func getPlaylists() -> [WidgetPlaylistData] {
        guard let userDefaults = userDefaults else {
            print("⚠️ Widget: Failed to access shared UserDefaults for playlists")
            return []
        }

        guard let data = userDefaults.data(forKey: playlistsKey) else {
            return []
        }

        do {
            let decoded = try JSONDecoder().decode([WidgetPlaylistData].self, from: data)
            return decoded
        } catch {
            print("❌ Widget: Failed to decode playlists - \(error)")
            return []
        }
    }

}
