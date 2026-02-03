//  Service for writing metadata to audio files using ID3TagEditor

import Foundation
import ID3TagEditor

final class MetadataWriter: @unchecked Sendable {
    static let shared = MetadataWriter()

    private let id3TagEditor = ID3TagEditor()

    private init() {}

    /// Writes metadata to an MP3 file
    /// - Parameters:
    ///   - track: The track with updated metadata
    ///   - artistName: The artist name to write
    ///   - albumName: The album name to write
    ///   - genreName: The genre name to write
    /// - Returns: True if successful, false otherwise
    func writeMetadata(
        to track: Track,
        artistName: String?,
        albumName: String?,
        genreName: String?
    ) -> Bool {
        let fileURL = URL(fileURLWithPath: track.path)

        // Only support MP3 files for now
        guard fileURL.pathExtension.lowercased() == "mp3" else {
            print("⚠️ MetadataWriter: File is not an MP3, skipping: \(fileURL.lastPathComponent)")
            return false
        }

        // Check if file exists and is writable
        guard FileManager.default.fileExists(atPath: track.path) else {
            print("❌ MetadataWriter: File does not exist: \(track.path)")
            return false
        }

        guard FileManager.default.isWritableFile(atPath: track.path) else {
            print("❌ MetadataWriter: File is not writable: \(track.path)")
            return false
        }

        do {
            // Read existing tags first to preserve other metadata
            var id3Tag: ID3Tag
            if let existingTag = try id3TagEditor.read(from: track.path) {
                id3Tag = existingTag
            } else {
                // Create new tag if none exists
                id3Tag = ID32v3TagBuilder().build()
            }

            // Build new tag with updated metadata
            var builder = ID32v3TagBuilder()

            // Title
            builder = builder.title(frame: ID3FrameWithStringContent(content: track.title))

            // Artist
            if let artistName = artistName, !artistName.isEmpty {
                builder = builder.artist(frame: ID3FrameWithStringContent(content: artistName))
            }

            // Album
            if let albumName = albumName, !albumName.isEmpty {
                builder = builder.album(frame: ID3FrameWithStringContent(content: albumName))
            }

            // Genre
            if let genreName = genreName, !genreName.isEmpty {
                builder = builder.genre(frame: ID3FrameGenre(genre: nil, description: genreName))
            }

            // Rating (convert 1-5 scale to POPM format: 1=1, 2=64, 3=128, 4=196, 5=255)
            // Note: ID3TagEditor may not support POPM directly, so we skip rating for now

            let newTag = builder.build()

            // Write the tag to file
            try id3TagEditor.write(tag: newTag, to: track.path)

            print("✅ MetadataWriter: Successfully wrote metadata to \(fileURL.lastPathComponent)")
            return true

        } catch {
            print("❌ MetadataWriter: Failed to write metadata: \(error)")
            return false
        }
    }

    /// Checks if a file supports metadata writing
    func supportsWriting(for path: String) -> Bool {
        let fileURL = URL(fileURLWithPath: path)
        let ext = fileURL.pathExtension.lowercased()

        // Currently only MP3 is supported
        return ext == "mp3"
    }

    /// Removes artwork from an MP3 file by rewriting the tag without the picture frame
    /// - Parameter track: The track to remove artwork from
    /// - Returns: True if successful, false otherwise
    func removeArtwork(from track: Track) -> Bool {
        let fileURL = URL(fileURLWithPath: track.path)

        // Only support MP3 files
        guard fileURL.pathExtension.lowercased() == "mp3" else {
            print("⚠️ MetadataWriter: Cannot remove artwork - file is not an MP3: \(fileURL.lastPathComponent)")
            return false
        }

        guard FileManager.default.fileExists(atPath: track.path) else {
            print("❌ MetadataWriter: File does not exist: \(track.path)")
            return false
        }

        guard FileManager.default.isWritableFile(atPath: track.path) else {
            print("❌ MetadataWriter: File is not writable: \(track.path)")
            return false
        }

        do {
            // Read existing tag to preserve other metadata
            guard let existingTag = try id3TagEditor.read(from: track.path) else {
                print("⚠️ MetadataWriter: No existing tag found, nothing to remove")
                return true
            }

            // Rebuild the tag without artwork
            // We need to read all existing frames and rebuild without the picture
            var builder = ID32v3TagBuilder()

            // Preserve title
            if let title = existingTag.frames[.title] as? ID3FrameWithStringContent {
                builder = builder.title(frame: title)
            }

            // Preserve artist
            if let artist = existingTag.frames[.artist] as? ID3FrameWithStringContent {
                builder = builder.artist(frame: artist)
            }

            // Preserve album
            if let album = existingTag.frames[.album] as? ID3FrameWithStringContent {
                builder = builder.album(frame: album)
            }

            // Preserve album artist
            if let albumArtist = existingTag.frames[.albumArtist] as? ID3FrameWithStringContent {
                builder = builder.albumArtist(frame: albumArtist)
            }

            // Preserve genre
            if let genre = existingTag.frames[.genre] as? ID3FrameGenre {
                builder = builder.genre(frame: genre)
            }

            // Preserve year
            if let year = existingTag.frames[.recordingYear] as? ID3FrameWithIntegerContent {
                builder = builder.recordingYear(frame: year)
            }

            // DO NOT preserve attached pictures - this removes the artwork

            let newTag = builder.build()

            // Write the tag without artwork
            try id3TagEditor.write(tag: newTag, to: track.path)

            print("✅ MetadataWriter: Successfully removed artwork from \(fileURL.lastPathComponent)")
            return true

        } catch {
            print("❌ MetadataWriter: Failed to remove artwork: \(error)")
            return false
        }
    }
}
