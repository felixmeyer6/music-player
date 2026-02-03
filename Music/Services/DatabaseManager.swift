//  Database manager for the music library using GRDB

import Foundation
import CryptoKit
@preconcurrency import GRDB

class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private var dbWriter: DatabaseWriter!
    private let maxRetries = 3
    private let retryDelay: UInt64 = 500_000_000 // 0.5 seconds in nanoseconds

    private init() {
        setupDatabaseWithRetry()
    }

    private func setupDatabaseWithRetry() {
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                try setupDatabase()
                print("✅ Database initialized successfully on attempt \(attempt)")
                return
            } catch {
                lastError = error
                print("⚠️ Database setup failed on attempt \(attempt)/\(maxRetries): \(error)")

                if attempt < maxRetries {
                    // Wait before retrying
                    Thread.sleep(forTimeInterval: Double(retryDelay) / 1_000_000_000.0)
                }
            }
        }

        // If all retries failed, try to recover
        if let error = lastError {
            print("❌ Database setup failed after \(maxRetries) attempts. Attempting recovery...")
            attemptDatabaseRecovery(error: error)
        }
    }

    private func setupDatabase() throws {
        let databaseURL = try getDatabaseURL()

        // Use DatabasePool instead of DatabaseQueue to support concurrent reads
        // This is essential for CarPlay and other multi-threaded scenarios
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // Enable foreign key constraints
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        dbWriter = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try createTables()
        try migrateDatabaseIfNeeded()
    }

    private func attemptDatabaseRecovery(error: Error) {
        print("🔧 Attempting database recovery...")

        do {
            let databaseURL = try getDatabaseURL()
            let backupURL = databaseURL.deletingLastPathComponent()
                .appendingPathComponent("cosmos_music_backup_\(Int(Date().timeIntervalSince1970)).db")

            // Try to backup the corrupted database
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                try? FileManager.default.moveItem(at: databaseURL, to: backupURL)
                print("📦 Backed up corrupted database to: \(backupURL.path)")
            }

            // Try to create a fresh database
            try setupDatabase()
            print("✅ Database recovery successful - created fresh database")
        } catch {
            // Last resort: create an in-memory database to prevent crashes
            print("❌ Database recovery failed: \(error)")
            print("⚠️ Creating in-memory database as fallback")

            do {
                var configuration = Configuration()
                configuration.prepareDatabase { db in
                    try db.execute(sql: "PRAGMA foreign_keys = ON")
                }

                // Create in-memory database
                dbWriter = try DatabaseQueue(configuration: configuration)
                try createTables()
                print("✅ In-memory database created successfully")
            } catch {
                // Absolute last resort - this should never happen
                fatalError("Critical error: Unable to initialize any database: \(error)")
            }
        }
    }
    
    private func getDatabaseURL() throws -> URL {
        // Try to use app group container first for shared data (e.g., widgets)
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.neofx.music-player") {
            return containerURL.appendingPathComponent("cosmos_music.db")
        } else {
            // Fallback to documents directory
            let documentsPath = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first!
            return documentsPath.appendingPathComponent("MusicLibrary.sqlite")
        }
    }

    private func stableIdForFilename(_ filename: String) -> String {
        let digest = SHA256.hash(data: filename.data(using: .utf8) ?? Data())
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    private func createTables() throws {
        try dbWriter.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS artist (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL COLLATE NOCASE
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS genre (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE COLLATE NOCASE
                )
            """)
            
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS album (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL COLLATE NOCASE
                )
            """)
            
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS track (
                    id INTEGER PRIMARY KEY,
                    stable_id TEXT NOT NULL UNIQUE,
                    album_id INTEGER REFERENCES album(id) ON DELETE SET NULL,
                    artist_id INTEGER REFERENCES artist(id) ON DELETE SET NULL,
                    genre_id INTEGER REFERENCES genre(id) ON DELETE SET NULL,
                    genre TEXT COLLATE NOCASE,
                    rating INTEGER CHECK (rating BETWEEN 1 AND 5),
                    title TEXT NOT NULL COLLATE NOCASE,
                    duration_ms INTEGER,
                    sample_rate INTEGER,
                    bit_depth INTEGER,
                    channels INTEGER,
                    path TEXT NOT NULL,
                    file_size INTEGER,
                    has_embedded_art INTEGER DEFAULT 0,
                    waveform_data BLOB
                )
            """)
            
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS playlist (
                    id INTEGER PRIMARY KEY,
                    slug TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    last_played_at INTEGER DEFAULT 0
                )
            """)
            
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS playlist_item (
                    playlist_id INTEGER REFERENCES playlist(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    track_stable_id TEXT NOT NULL,
                    PRIMARY KEY (playlist_id, position)
                )
            """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_album ON track(album_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_artist ON track(artist_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_genre_id ON track(genre_id)")
            do {
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_genre ON track(genre)")
            } catch {
                // Column may not exist yet on older databases; migration will handle it.
                print("ℹ️ Database migration: idx_track_genre creation deferred: \(error)")
            }

            // EQ Tables
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS eq_preset (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL UNIQUE,
                    is_built_in INTEGER DEFAULT 0,
                    is_active INTEGER DEFAULT 0,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS eq_band (
                    id INTEGER PRIMARY KEY,
                    preset_id INTEGER NOT NULL REFERENCES eq_preset(id) ON DELETE CASCADE,
                    frequency REAL NOT NULL,
                    gain REAL NOT NULL DEFAULT 0.0,
                    bandwidth REAL NOT NULL DEFAULT 0.5,
                    band_index INTEGER NOT NULL
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS eq_settings (
                    id INTEGER PRIMARY KEY,
                    is_enabled INTEGER DEFAULT 0,
                    active_preset_id INTEGER REFERENCES eq_preset(id) ON DELETE SET NULL,
                    global_gain REAL DEFAULT 0.0,
                    updated_at INTEGER NOT NULL
                )
            """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_eq_band_preset ON eq_band(preset_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_eq_band_index ON eq_band(band_index)")

            // Migration: Add last_played_at column if it doesn't exist
            do {
                try db.execute(sql: """
                    ALTER TABLE playlist ADD COLUMN last_played_at INTEGER DEFAULT 0
                """)
                print("✅ Database: Added last_played_at column to playlist table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: last_played_at column already exists or migration failed: \(error)")
            }

            // Migration: Add preset_type column to eq_preset if it doesn't exist
            do {
                try db.execute(sql: """
                    ALTER TABLE eq_preset ADD COLUMN preset_type TEXT DEFAULT 'imported'
                """)
                print("✅ Database: Added preset_type column to eq_preset table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: preset_type column already exists or migration failed: \(error)")
            }
        }
    }

    private func migrateDatabaseIfNeeded() throws {
        try write { db in
            // Migration: Remove favorites table (feature removed)
            do {
                try db.execute(sql: "DROP TABLE IF EXISTS favorite")
                print("✅ Database: Removed favorite table")
            } catch {
                print("ℹ️ Database migration: favorite table removal failed: \(error)")
            }

            // Migration: Add custom_cover_image_path column to playlist table
            do {
                try db.execute(sql: "ALTER TABLE playlist ADD COLUMN custom_cover_image_path TEXT")
                print("✅ Database: Added custom_cover_image_path column to playlist table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: custom_cover_image_path column already exists or migration failed: \(error)")
            }

            // Migration: Add genre column to track table
            do {
                try db.execute(sql: "ALTER TABLE track ADD COLUMN genre TEXT COLLATE NOCASE")
                print("✅ Database: Added genre column to track table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: genre column already exists or migration failed: \(error)")
            }

            // Migration: Add rating column to track table
            do {
                try db.execute(sql: "ALTER TABLE track ADD COLUMN rating INTEGER CHECK (rating BETWEEN 1 AND 5)")
                print("✅ Database: Added rating column to track table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: rating column already exists or migration failed: \(error)")
            }

            // Migration: Add genre index after ensuring column exists
            do {
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_genre ON track(genre)")
                print("✅ Database: Ensured idx_track_genre exists")
            } catch {
                print("ℹ️ Database migration: idx_track_genre creation failed: \(error)")
            }

            // Migration: Add waveform_data column to track table
            do {
                try db.execute(sql: "ALTER TABLE track ADD COLUMN waveform_data BLOB")
                print("✅ Database: Added waveform_data column to track table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: waveform_data column already exists or migration failed: \(error)")
            }


            // Migration: Deduplicate by filename and migrate stable IDs (one-time, batched)
            do {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS migration_state (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    )
                """)
            } catch {
                print("ℹ️ Database migration: migration_state table creation failed: \(error)")
            }

            let stableIdMigrationKey = "stable_id_filename_v1"
            let migrationState = try? String.fetchOne(
                db,
                sql: "SELECT value FROM migration_state WHERE key = ?",
                arguments: [stableIdMigrationKey]
            )
            let hasRunStableIdMigration = migrationState == "done"

            if hasRunStableIdMigration {
                print("ℹ️ Database: Stable ID migration already completed")
            } else {
                struct TrackMigrationRow {
                    let id: Int64
                    let stableId: String
                    let title: String
                    let filename: String
                    let newStableId: String
                }

                do {
                    let rows = try Row.fetchAll(db, sql: "SELECT id, stable_id, path, title FROM track")
                    if rows.isEmpty {
                        try db.execute(
                            sql: "INSERT OR REPLACE INTO migration_state (key, value) VALUES (?, 'done')",
                            arguments: [stableIdMigrationKey]
                        )
                        print("ℹ️ Database: No tracks found for stable ID migration")
                    } else {
                        var tracks: [TrackMigrationRow] = []
                        tracks.reserveCapacity(rows.count)

                        var groupedByFilename: [String: [TrackMigrationRow]] = [:]

                        for row in rows {
                            guard
                                let id: Int64 = row["id"],
                                let stableId: String = row["stable_id"],
                                let path: String = row["path"],
                                let title: String = row["title"]
                            else {
                                continue
                            }

                            let filename = URL(fileURLWithPath: path).lastPathComponent
                            let newStableId = stableIdForFilename(filename)

                            let entry = TrackMigrationRow(
                                id: id,
                                stableId: stableId,
                                title: title,
                                filename: filename,
                                newStableId: newStableId
                            )

                            tracks.append(entry)
                            groupedByFilename[filename, default: []].append(entry)
                        }

                        var keepIdByFilename: [String: Int64] = [:]
                        keepIdByFilename.reserveCapacity(groupedByFilename.count)

                        var removedCount = 0
                        for (filename, duplicates) in groupedByFilename {
                            guard let keep = duplicates.max(by: { $0.id < $1.id }) else { continue }
                            keepIdByFilename[filename] = keep.id

                            if duplicates.count > 1 {
                                removedCount += duplicates.count - 1
                                print("⚠️ Found \(duplicates.count) tracks with same filename: \(filename)")
                                print("✅ Keeping track ID \(keep.id): \(keep.title)")
                            }
                        }

                        let keptTracks = tracks.filter { track in
                            keepIdByFilename[track.filename] == track.id
                        }

                        let updatedCount = keptTracks.filter { $0.stableId != $0.newStableId }.count
                        let needsDedup = removedCount > 0
                        let needsStableIdUpdate = updatedCount > 0

                        if !needsDedup && !needsStableIdUpdate {
                            print("ℹ️ Database: Stable IDs already filename-based")
                            try db.execute(
                                sql: "INSERT OR REPLACE INTO migration_state (key, value) VALUES (?, 'done')",
                                arguments: [stableIdMigrationKey]
                            )
                        } else {
                            try db.execute(sql: """
                                CREATE TEMP TABLE IF NOT EXISTS temp_track_migration (
                                    id INTEGER PRIMARY KEY,
                                    old_stable_id TEXT NOT NULL,
                                    new_stable_id TEXT NOT NULL,
                                    filename TEXT NOT NULL,
                                    keep_id INTEGER NOT NULL
                                )
                            """)
                            try db.execute(sql: "DELETE FROM temp_track_migration")

                            let batchSize = 500
                            var index = 0
                            while index < tracks.count {
                                let end = min(index + batchSize, tracks.count)
                                let batch = tracks[index..<end]

                                var sql = "INSERT INTO temp_track_migration (id, old_stable_id, new_stable_id, filename, keep_id) VALUES "
                                var arguments: [DatabaseValueConvertible] = []
                                arguments.reserveCapacity(batch.count * 5)

                                var isFirst = true
                                for track in batch {
                                    if !isFirst {
                                        sql.append(",")
                                    }
                                    isFirst = false
                                    sql.append("(?, ?, ?, ?, ?)")
                                    arguments.append(track.id)
                                    arguments.append(track.stableId)
                                    arguments.append(track.newStableId)
                                    arguments.append(track.filename)
                                    arguments.append(keepIdByFilename[track.filename] ?? track.id)
                                }

                                try db.execute(sql: sql, arguments: StatementArguments(arguments))
                                index = end
                            }

                            if needsDedup {
                                try db.execute(sql: """
                                    UPDATE OR IGNORE playlist_item
                                    SET track_stable_id = (
                                        SELECT keep.old_stable_id
                                        FROM temp_track_migration AS map
                                        JOIN temp_track_migration AS keep
                                          ON keep.id = map.keep_id
                                        WHERE map.old_stable_id = playlist_item.track_stable_id
                                          AND map.id != map.keep_id
                                    )
                                    WHERE track_stable_id IN (
                                        SELECT old_stable_id
                                        FROM temp_track_migration
                                        WHERE id != keep_id
                                    )
                                """)

                                try db.execute(sql: """
                                    DELETE FROM playlist_item
                                    WHERE track_stable_id IN (
                                        SELECT old_stable_id
                                        FROM temp_track_migration
                                        WHERE id != keep_id
                                    )
                                """)

                                try db.execute(sql: """
                                    DELETE FROM track
                                    WHERE id IN (
                                        SELECT id
                                        FROM temp_track_migration
                                        WHERE id != keep_id
                                    )
                                """)

                                print("✅ Removed \(removedCount) duplicate tracks by filename")
                            } else {
                                print("ℹ️ No duplicate tracks found by filename")
                            }

                            if needsStableIdUpdate {
                                try db.execute(sql: """
                                    UPDATE track
                                    SET stable_id = (
                                        SELECT new_stable_id
                                        FROM temp_track_migration AS map
                                        WHERE map.id = track.id
                                    )
                                    WHERE id IN (SELECT id FROM temp_track_migration)
                                      AND stable_id != (
                                        SELECT new_stable_id
                                        FROM temp_track_migration AS map
                                        WHERE map.id = track.id
                                    )
                                """)

                                try db.execute(sql: """
                                    UPDATE playlist_item
                                    SET track_stable_id = (
                                        SELECT new_stable_id
                                        FROM temp_track_migration AS map
                                        WHERE map.old_stable_id = playlist_item.track_stable_id
                                    )
                                    WHERE track_stable_id IN (
                                        SELECT old_stable_id
                                        FROM temp_track_migration
                                    )
                                """)

                                print("✅ Database: Migrated \(updatedCount) stable IDs from path-based to filename-based")
                            } else {
                                print("ℹ️ Database: Stable IDs already filename-based")
                            }

                            try db.execute(
                                sql: "INSERT OR REPLACE INTO migration_state (key, value) VALUES (?, 'done')",
                                arguments: [stableIdMigrationKey]
                            )
                        }
                    }
                } catch {
                    print("⚠️ Database migration: Stable ID migration failed: \(error)")
                    // Don't throw - allow app to continue and re-index will handle it
                }
            }

            // Add UNIQUE constraint to stable_id to prevent duplicates
            do {
                try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_track_stable_id ON track(stable_id)")
                print("✅ Database: Created UNIQUE index on track.stable_id")
            } catch {
                print("⚠️ Database migration: Failed to create UNIQUE index on stable_id: \(error)")
            }

            // Migration: Add play_count column to track table
            do {
                try db.execute(sql: "ALTER TABLE track ADD COLUMN play_count INTEGER DEFAULT 0")
                print("✅ Database: Added play_count column to track table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: play_count column already exists or migration failed: \(error)")
            }

            // Migration: Create genre table and populate from existing track.genre values
            do {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS genre (
                        id INTEGER PRIMARY KEY,
                        name TEXT NOT NULL UNIQUE COLLATE NOCASE
                    )
                """)
                print("✅ Database: Created genre table")
            } catch {
                print("ℹ️ Database migration: genre table already exists or migration failed: \(error)")
            }

            // Migration: Add genre_id column to track table
            do {
                try db.execute(sql: "ALTER TABLE track ADD COLUMN genre_id INTEGER REFERENCES genre(id) ON DELETE SET NULL")
                print("✅ Database: Added genre_id column to track table")
            } catch {
                // Column may already exist, which is fine
                print("ℹ️ Database migration: genre_id column already exists or migration failed: \(error)")
            }

            // Migration: Populate genre table from existing track.genre values
            do {
                // Insert distinct genres from tracks into genre table
                try db.execute(sql: """
                    INSERT OR IGNORE INTO genre (name)
                    SELECT DISTINCT genre FROM track
                    WHERE genre IS NOT NULL AND TRIM(genre) <> ''
                """)

                // Update tracks to link to the genre table
                try db.execute(sql: """
                    UPDATE track
                    SET genre_id = (
                        SELECT g.id FROM genre g
                        WHERE LOWER(g.name) = LOWER(track.genre)
                    )
                    WHERE genre IS NOT NULL AND TRIM(genre) <> '' AND genre_id IS NULL
                """)

                let genreCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM genre") ?? 0
                print("✅ Database: Populated genre table with \(genreCount) distinct genres")
            } catch {
                print("⚠️ Database migration: Genre table population failed: \(error)")
            }

            // Create index on genre_id if not exists
            do {
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_track_genre_id ON track(genre_id)")
                print("✅ Database: Created idx_track_genre_id index")
            } catch {
                print("ℹ️ Database migration: idx_track_genre_id creation failed: \(error)")
            }
        }
    }

    func read<T>(_ operation: @escaping (Database) throws -> T) throws -> T {
        return try dbWriter.read(operation)
    }
    
    func write<T>(_ operation: @escaping (Database) throws -> T) throws -> T {
        return try dbWriter.write(operation)
    }
    
    // MARK: - Track operations
    
    func upsertTrack(_ track: Track) throws {
        try write { db in
            // Safety check: Remove any duplicates with the same path but different stable_id
            // This handles edge cases where migration didn't run or failed
            let duplicates = try Track.filter(Column("path") == track.path && Column("stable_id") != track.stableId).fetchAll(db)
            if !duplicates.isEmpty {
                print("⚠️ Found \(duplicates.count) duplicate(s) for path: \(track.path)")
                for duplicate in duplicates {
                    // Transfer playlist items to the new stable_id
                    try db.execute(
                        sql: "UPDATE playlist_item SET track_stable_id = ? WHERE track_stable_id = ?",
                        arguments: [track.stableId, duplicate.stableId]
                    )
                    // Delete the duplicate
                    try Track.filter(Column("id") == duplicate.id).deleteAll(db)
                    print("🗑️ Removed duplicate track with old stable_id: \(duplicate.stableId)")
                }
            }

            try track.save(db)
        }
    }
    
    func getAllTracks() throws -> [Track] {
        return try read { db in
            return try Track.order(Column("id").desc).fetchAll(db)
        }
    }
    
    func getTrack(byStableId stableId: String) throws -> Track? {
        return try read { db in
            return try Track.filter(Column("stable_id") == stableId).fetchOne(db)
        }
    }
    
    // MARK: - Artist operations
    
    func upsertArtist(name: String) throws -> Artist {
        return try write { db in
            if let existing = try Artist.filter(Column("name") == name).fetchOne(db) {
                return existing
            }
            
            let artist = Artist(name: name)
            return try artist.insertAndFetch(db)!
        }
    }
    
    func getAllArtists() throws -> [Artist] {
        return try read { db in
            return try Artist.order(Column("name")).fetchAll(db)
        }
    }

    func searchArtists(query: String, limit: Int = 20) throws -> [Artist] {
        return try read { db in
            let pattern = "%\(query)%"
            return try Artist
                .filter(Column("name").like(pattern))
                .order(Column("name"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Genre operations

    func upsertGenre(name: String) throws -> Genre {
        return try write { db in
            if let existing = try Genre.filter(Column("name").collating(.nocase) == name).fetchOne(db) {
                return existing
            }

            let genre = Genre(name: name)
            return try genre.insertAndFetch(db)!
        }
    }

    func getGenre(byId id: Int64) throws -> Genre? {
        return try read { db in
            return try Genre.filter(Column("id") == id).fetchOne(db)
        }
    }

    // MARK: - Album operations
    
    func upsertAlbum(name: String) throws -> Album {
        return try write { db in
            let normalizedName = self.normalizeAlbumName(name)

            if let existing = try Album
                .filter(Column("name") == normalizedName)
                .fetchOne(db) {
                return existing
            }

            // No existing match found, create new album
            let album = Album(name: normalizedName)
            return try album.insertAndFetch(db)!
        }
    }
    
    private func normalizeAlbumName(_ title: String) -> String {
        var normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove common variations that cause duplicates
        let patternsToRemove = [
            " (Deluxe Edition)",
            " (Deluxe)",
            " (Extended Version)",
            " (Remastered)",
            " [Explicit]",
            " - EP",
            " EP"
        ]
        
        for pattern in patternsToRemove {
            if normalized.hasSuffix(pattern) {
                normalized = String(normalized.dropLast(pattern.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // Remove extra whitespace
        normalized = normalized.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        
        return normalized.isEmpty ? title : normalized
    }
    
    func getAlbumLookup() throws -> [Int64: String] {
        let albums = try getAllAlbums()
        return Dictionary(uniqueKeysWithValues: albums.compactMap { album in
            guard let id = album.id else { return nil }
            return (id, album.name)
        })
    }

    func getAllAlbums() throws -> [Album] {
        return try read { db in
            return try Album.order(Column("name")).fetchAll(db)
        }
    }

    func searchAlbums(query: String, limit: Int = 30) throws -> [Album] {
        return try read { db in
            let pattern = "%\(query)%"
            return try Album
                .filter(Column("name").like(pattern))
                .order(Column("name"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    func getArtist(byId id: Int64) throws -> Artist? {
        return try read { db in
            return try Artist.filter(Column("id") == id).fetchOne(db)
        }
    }

    func getTracksByStableIds(_ stableIds: [String]) throws -> [Track] {
        return try read { db in
            return try Track.filter(stableIds.contains(Column("stable_id"))).order(Column("id").desc).fetchAll(db)
        }
    }

    func getTracksByAlbumId(_ albumId: Int64) throws -> [Track] {
        return try read { db in
            return try Track
                .filter(Column("album_id") == albumId)
                .order(Column("title").collating(.nocase))
                .fetchAll(db)
        }
    }

    func getTracksByArtistId(_ artistId: Int64) throws -> [Track] {
        return try read { db in
            return try Track
                .filter(Column("artist_id") == artistId)
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    func getAllGenreRecords() throws -> [Genre] {
        return try read { db in
            return try Genre.order(Column("name")).fetchAll(db)
        }
    }

    func getTracksByGenre(_ genre: String) throws -> [Track] {
        return try read { db in
            return try Track.fetchAll(
                db,
                sql: """
                    SELECT t.*
                    FROM track t
                    JOIN genre g ON t.genre_id = g.id
                    WHERE LOWER(g.name) = LOWER(?)
                    ORDER BY t.title COLLATE NOCASE
                """,
                arguments: [genre]
            )
        }
    }

    func getFirstTrackByGenre(_ genre: String) throws -> Track? {
        return try read { db in
            try Track.fetchOne(
                db,
                sql: """
                    SELECT t.*
                    FROM track t
                    JOIN genre g ON t.genre_id = g.id
                    WHERE LOWER(g.name) = LOWER(?)
                    ORDER BY t.id
                    LIMIT 1
                """,
                arguments: [genre]
            )
        }
    }

    func deduplicatePlaylistItems() throws {
        print("🔍 Checking for duplicate playlist items...")

        let removedCount = try write { db in
            let playlists = try Playlist.fetchAll(db)
            var totalRemoved = 0

            for playlist in playlists {
                guard let playlistId = playlist.id else { continue }

                // Get all items for this playlist
                let items = try PlaylistItem.filter(Column("playlist_id") == playlistId).fetchAll(db)

                // Group by track path (need to join with track table)
                var seenPaths: Set<String> = [] // paths we've already seen
                var itemsToRemove: [PlaylistItem] = []

                for item in items {
                    // Get the track for this item
                    if let track = try Track.filter(Column("stable_id") == item.trackStableId).fetchOne(db) {
                        if seenPaths.contains(track.path) {
                            // Duplicate found - mark for removal
                            itemsToRemove.append(item)
                            print("⚠️ Playlist '\(playlist.title)': Found duplicate for '\(track.title)' at position \(item.position)")
                        } else {
                            // First occurrence - keep it
                            seenPaths.insert(track.path)
                        }
                    }
                }

                // Remove duplicates
                for item in itemsToRemove {
                    try PlaylistItem
                        .filter(Column("playlist_id") == playlistId && Column("position") == item.position)
                        .deleteAll(db)
                    totalRemoved += 1
                }

                if itemsToRemove.count > 0 {
                    print("✅ Removed \(itemsToRemove.count) duplicate items from playlist '\(playlist.title)'")

                    // Reorder remaining items to fill gaps
                    let remainingItems = try PlaylistItem
                        .filter(Column("playlist_id") == playlistId)
                        .order(Column("position"))
                        .fetchAll(db)

                    for (index, item) in remainingItems.enumerated() {
                        try db.execute(
                            sql: "UPDATE playlist_item SET position = ? WHERE playlist_id = ? AND track_stable_id = ? AND position = ?",
                            arguments: [index, playlistId, item.trackStableId, item.position]
                        )
                    }
                }
            }

            return totalRemoved
        }

        if removedCount > 0 {
            print("✅ Removed \(removedCount) duplicate playlist items across all playlists")
        } else {
            print("✅ No duplicate playlist items found")
        }
    }

    func cleanupOrphanedPlaylistItems() throws {
        print("🧹 Cleaning up orphaned playlist items...")

        // SAFETY CHECK: Verify database is healthy before cleanup
        let trackCount = try read { db in
            try Track.fetchCount(db)
        }

        if trackCount == 0 {
            print("⚠️ SAFETY: Skipping playlist cleanup - no tracks in database (possible database error)")
            print("⚠️ This prevents accidental deletion of all playlist items")
            return
        }

        let deletedCount = try write { db in
            // Get all playlist items
            let allItems = try PlaylistItem.fetchAll(db)
            var orphanedCount = 0

            print("🔍 Checking \(allItems.count) playlist items against \(trackCount) tracks")

            for item in allItems {
                // Check if track still exists
                let trackExists = try Track.filter(Column("stable_id") == item.trackStableId).fetchOne(db) != nil

                if !trackExists {
                    // Remove orphaned item
                    try PlaylistItem
                        .filter(Column("playlist_id") == item.playlistId && Column("track_stable_id") == item.trackStableId)
                        .deleteAll(db)
                    orphanedCount += 1
                    print("🗑️ Removed orphaned playlist item: \(item.trackStableId)")
                }
            }

            return orphanedCount
        }

        if deletedCount > 0 {
            print("✅ Cleaned up \(deletedCount) orphaned playlist items")
        } else {
            print("✅ No orphaned playlist items found")
        }
    }

    func deleteTrack(byStableId stableId: String) throws {
        print("🗃️ Database: Deleting track with stable ID - \(stableId)")
        let deletedCount = try write { db in
            // Remove from playlist items first
            let playlistItemsDeleted = try PlaylistItem.filter(Column("track_stable_id") == stableId).deleteAll(db)
            if playlistItemsDeleted > 0 {
                print("🗑️ Removed track from \(playlistItemsDeleted) playlist position(s)")
            }

            if playlistItemsDeleted > 0 {
                print("🗃️ Database: Removed \(playlistItemsDeleted) playlist entries for track")
            }

            // Delete the track
            return try Track.filter(Column("stable_id") == stableId).deleteAll(db)
        }
        print("🗃️ Database: Deleted \(deletedCount) track(s)")

        // Clean up orphaned albums, artists, and genres after track deletion
        try cleanupOrphanedAlbums()
        try cleanupOrphanedArtists()
        try cleanupOrphanedGenres()
    }

    func cleanupOrphanedAlbums() throws {
        try write { db in
            // Delete albums that have no tracks referencing them
            try db.execute(sql: """
                DELETE FROM album
                WHERE id NOT IN (
                    SELECT DISTINCT album_id
                    FROM track
                    WHERE album_id IS NOT NULL
                )
            """)
        }
    }

    func cleanupOrphanedArtists() throws {
        try write { db in
            // Delete artists that have no tracks referencing them
            try db.execute(sql: """
                DELETE FROM artist
                WHERE id NOT IN (
                    SELECT DISTINCT artist_id
                    FROM track
                    WHERE artist_id IS NOT NULL
                )
            """)
        }
    }

    func cleanupOrphanedGenres() throws {
        try write { db in
            // Delete genres that have no tracks referencing them
            try db.execute(sql: """
                DELETE FROM genre
                WHERE id NOT IN (
                    SELECT DISTINCT genre_id
                    FROM track
                    WHERE genre_id IS NOT NULL
                )
            """)
        }
    }
    
    // MARK: - Playlist operations
    
    func createPlaylist(title: String) throws -> Playlist {
        return try write { db in
            let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
            let now = Int64(Date().timeIntervalSince1970)
            let playlist = Playlist(
                id: nil,
                slug: slug,
                title: title,
                createdAt: now,
                updatedAt: now,
                lastPlayedAt: 0
            )
            return try playlist.insertAndFetch(db)!
        }
    }

    func getAllPlaylists() throws -> [Playlist] {
        return try read { db in
            return try Playlist.order(Column("last_played_at").desc, Column("updated_at").desc).fetchAll(db)
        }
    }

    func searchPlaylists(query: String, limit: Int = 15) throws -> [Playlist] {
        return try read { db in
            let pattern = "%\(query)%"
            return try Playlist
                .filter(Column("title").like(pattern))
                .order(Column("title"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    func searchTracks(query: String, limit: Int = 50) throws -> [Track] {
        return try read { db in
            let pattern = "%\(query)%"
            return try Track
                .filter(Column("title").like(pattern))
                .order(Column("title"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    func addToPlaylist(playlistId: Int64, trackStableId: String) throws {
        print("🎵 Adding track \(trackStableId) to playlist \(playlistId)")
        try write { db in
            // Check if track is already in playlist
            let existingItem = try PlaylistItem
                .filter(Column("playlist_id") == playlistId && Column("track_stable_id") == trackStableId)
                .fetchOne(db)
            
            if existingItem != nil {
                print("⚠️ Track already in playlist")
                return
            }
            
            // Get the next position in the playlist
            let maxPosition = try PlaylistItem
                .filter(Column("playlist_id") == playlistId)
                .select(max(Column("position")))
                .asRequest(of: Int.self)
                .fetchOne(db) ?? 0
            
            let playlistItem = PlaylistItem(playlistId: playlistId, position: maxPosition + 1, trackStableId: trackStableId)
            print("🎵 Creating playlist item with position \(maxPosition + 1)")
            try playlistItem.insert(db)
            let now = Int64(Date().timeIntervalSince1970)
            _ = try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db, Column("updated_at").set(to: now))
            print("✅ Successfully added track to playlist")
        }
    }
    
    func removeFromPlaylist(playlistId: Int64, trackStableId: String) throws {
        try write { db in
            let deletedCount = try PlaylistItem
                .filter(Column("playlist_id") == playlistId && Column("track_stable_id") == trackStableId)
                .deleteAll(db)
            if deletedCount > 0 {
                let now = Int64(Date().timeIntervalSince1970)
                _ = try Playlist
                    .filter(Column("id") == playlistId)
                    .updateAll(db, Column("updated_at").set(to: now))
            }
        }
    }

    func reorderPlaylistItems(playlistId: Int64, from sourceIndex: Int, to destinationIndex: Int) throws {
        print("🔄 Database: Reordering playlist items from \(sourceIndex) to \(destinationIndex)")
        try write { db in
            // Get all playlist items ordered by position
            let items = try PlaylistItem
                .filter(Column("playlist_id") == playlistId)
                .order(Column("position"))
                .fetchAll(db)

            guard sourceIndex >= 0 && sourceIndex < items.count &&
                  destinationIndex >= 0 && destinationIndex < items.count else {
                print("❌ Invalid indices for reordering")
                return
            }

            // Remove the item from the source position
            var mutableItems = items
            let movedItem = mutableItems.remove(at: sourceIndex)

            // Insert at the destination position
            mutableItems.insert(movedItem, at: destinationIndex)

            // Two-phase update to avoid UNIQUE constraint violations:
            // Phase 1: Shift all positions by +10000 (temporary offset)
            print("🔄 Phase 1: Shifting positions to avoid conflicts")
            for (index, item) in mutableItems.enumerated() {
                _ = try PlaylistItem
                    .filter(Column("playlist_id") == playlistId &&
                           Column("track_stable_id") == item.trackStableId)
                    .updateAll(db, Column("position").set(to: index + 10000))
            }

            // Phase 2: Set final positions
            print("🔄 Phase 2: Setting final positions")
            for (index, item) in mutableItems.enumerated() {
                _ = try PlaylistItem
                    .filter(Column("playlist_id") == playlistId &&
                           Column("track_stable_id") == item.trackStableId)
                    .updateAll(db, Column("position").set(to: index))
            }

            print("✅ Successfully reordered playlist items")
        }
    }

    func getPlaylistItems(playlistId: Int64) throws -> [PlaylistItem] {
        return try read { db in
            return try PlaylistItem
                .filter(Column("playlist_id") == playlistId)
                .order(Column("position"))
                .fetchAll(db)
        }
    }
    
    func isTrackInPlaylist(playlistId: Int64, trackStableId: String) throws -> Bool {
        return try read { db in
            return try PlaylistItem
                .filter(Column("playlist_id") == playlistId && Column("track_stable_id") == trackStableId)
                .fetchOne(db) != nil
        }
    }
    
    func deletePlaylist(playlistId: Int64) throws {
        print("🗑️ Database: Deleting playlist with ID - \(playlistId)")
        let deletedCount = try write { db in
            return try Playlist.filter(Column("id") == playlistId).deleteAll(db)
        }
        print("🗑️ Database: Deleted \(deletedCount) playlist(s)")
    }

    func renamePlaylist(playlistId: Int64, newTitle: String) throws {
        print("✏️ Database: Renaming playlist \(playlistId) to '\(newTitle)'")
        let now = Int64(Date().timeIntervalSince1970)
        let updatedCount = try write { db in
            return try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db,
                    Column("title").set(to: newTitle),
                    Column("updated_at").set(to: now)
                )
        }
        print("✏️ Database: Updated \(updatedCount) playlist(s)")
    }

    func updatePlaylistAccessed(playlistId: Int64) throws {
        print("⏰ Database: Updating playlist \(playlistId) last accessed time")
        let now = Int64(Date().timeIntervalSince1970)
        let updatedCount = try write { db in
            return try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db, Column("updated_at").set(to: now))
        }
        print("⏰ Database: Updated \(updatedCount) playlist(s)")
    }
    
    func updatePlaylistLastPlayed(playlistId: Int64) throws {
        print("🎵 Database: Updating playlist \(playlistId) last played time")
        let now = Int64(Date().timeIntervalSince1970)
        let updatedCount = try write { db in
            return try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db, Column("last_played_at").set(to: now))
        }
        print("🎵 Database: Updated \(updatedCount) playlist(s) last played time")
    }

    func updatePlaylistCustomCover(playlistId: Int64, imagePath: String?) throws {
        print("🎨 Database: Updating playlist \(playlistId) custom cover to '\(imagePath ?? "nil")'")
        let now = Int64(Date().timeIntervalSince1970)
        let updatedCount = try write { db in
            return try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db,
                    Column("custom_cover_image_path").set(to: imagePath),
                    Column("updated_at").set(to: now)
                )
        }
        print("🎨 Database: Updated \(updatedCount) playlist(s) custom cover")
    }

    // MARK: - Play Count Operations

    @discardableResult
    func incrementPlayCount(trackStableId: String) throws -> Int {
        try write { db in
            try db.execute(
                sql: "UPDATE track SET play_count = play_count + 1 WHERE stable_id = ?",
                arguments: [trackStableId]
            )
            // Fetch and return the updated play count
            let newCount = try Int.fetchOne(
                db,
                sql: "SELECT play_count FROM track WHERE stable_id = ?",
                arguments: [trackStableId]
            ) ?? 0
            return newCount
        }
    }

    // MARK: - EQ Operations

    func getAllEQPresets() async throws -> [EQPreset] {
        return try read { db in
            return try EQPreset.order(Column("name")).fetchAll(db)
        }
    }

    func getEQPreset(id: Int64) async throws -> EQPreset? {
        return try read { db in
            return try EQPreset.filter(Column("id") == id).fetchOne(db)
        }
    }

    func saveEQPreset(_ preset: EQPreset) async throws -> EQPreset {
        return try write { db in
            return try preset.insertAndFetch(db) ?? preset
        }
    }

    func deleteEQPreset(_ preset: EQPreset) async throws {
        _ = try write { db in
            try preset.delete(db)
        }
    }

    func getBands(for preset: EQPreset) async throws -> [EQBand] {
        guard let presetId = preset.id else { return [] }
        return try read { db in
            return try EQBand
                .filter(Column("preset_id") == presetId)
                .order(Column("band_index"))
                .fetchAll(db)
        }
    }

    func saveEQBand(_ band: EQBand) async throws {
        try write { db in
            try band.save(db)
        }
    }

    func getEQSettings() async throws -> EQSettings? {
        return try read { db in
            return try EQSettings.fetchOne(db)
        }
    }

    func saveEQSettings(_ settings: EQSettings) async throws {
        try write { db in
            // Delete existing settings first (there should only be one row)
            try EQSettings.deleteAll(db)
            try settings.save(db)
        }
    }
}
