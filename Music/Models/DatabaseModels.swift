//  Database models for the music library

import Foundation
@preconcurrency import GRDB

struct Artist: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var name: String

    static let databaseTableName = "artist"
}

struct Genre: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var name: String

    static let databaseTableName = "genre"
}

struct Album: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var name: String

    static let databaseTableName = "album"
}

struct Track: Codable, FetchableRecord, PersistableRecord, Equatable {
    var id: Int64?
    var stableId: String
    var albumId: Int64?
    var artistId: Int64?
    var genreId: Int64?
    var genre: String?
    /// User rating on a 1–5 scale (stored as POPM for MP3s).
    var rating: Int?
    var title: String
    var trackNo: Int?
    var discNo: Int?
    var durationMs: Int?
    var sampleRate: Int?
    var bitDepth: Int?
    var channels: Int?
    var path: String
    var fileSize: Int64?
    var hasEmbeddedArt: Bool = false
    var waveformData: Data?
    var playCount: Int = 0

    static let databaseTableName = "track"

    enum CodingKeys: String, CodingKey {
        case id, title, path, genre, rating
        case stableId = "stable_id"
        case albumId = "album_id"
        case artistId = "artist_id"
        case genreId = "genre_id"
        case trackNo = "track_no"
        case discNo = "disc_no"
        case durationMs = "duration_ms"
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
        case channels, fileSize = "file_size"
        case hasEmbeddedArt = "has_embedded_art"
        case waveformData = "waveform_data"
        case playCount = "play_count"
    }
}

struct Playlist: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var slug: String
    var title: String
    var createdAt: Int64
    var updatedAt: Int64
    var lastPlayedAt: Int64
    var customCoverImagePath: String? // Custom user-selected cover image

    static let databaseTableName = "playlist"

    enum CodingKeys: String, CodingKey {
        case id, slug, title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastPlayedAt = "last_played_at"
        case customCoverImagePath = "custom_cover_image_path"
    }
}

struct PlaylistItem: Codable, FetchableRecord, PersistableRecord {
    var playlistId: Int64
    var position: Int
    var trackStableId: String

    static let databaseTableName = "playlist_item"

    enum CodingKeys: String, CodingKey {
        case position
        case playlistId = "playlist_id"
        case trackStableId = "track_stable_id"
    }
}

// MARK: - Graphic EQ Models

enum EQPresetType: String, Codable {
    case imported = "imported"    // Imported GraphicEQ with variable bands
    case manual = "manual"        // Manual EQ (6-band editor)
}

struct EQPreset: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var name: String
    var isBuiltIn: Bool
    var isActive: Bool
    var presetType: EQPresetType
    var createdAt: Int64
    var updatedAt: Int64

    static let databaseTableName = "eq_preset"

    enum CodingKeys: String, CodingKey {
        case id, name
        case isBuiltIn = "is_built_in"
        case isActive = "is_active"
        case presetType = "preset_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct EQBand: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var presetId: Int64
    var frequency: Double
    var gain: Double
    var bandwidth: Double
    var bandIndex: Int

    static let databaseTableName = "eq_band"

    enum CodingKeys: String, CodingKey {
        case id, frequency, gain, bandwidth
        case presetId = "preset_id"
        case bandIndex = "band_index"
    }
}

struct EQSettings: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var isEnabled: Bool
    var activePresetId: Int64?
    var globalGain: Double
    var updatedAt: Int64

    static let databaseTableName = "eq_settings"

    enum CodingKeys: String, CodingKey {
        case id
        case isEnabled = "is_enabled"
        case activePresetId = "active_preset_id"
        case globalGain = "global_gain"
        case updatedAt = "updated_at"
    }
}
