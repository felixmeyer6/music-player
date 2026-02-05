//  Manages album artwork extraction and caching

import Foundation
import UIKit
import SwiftUI
import AVFoundation
import CryptoKit

@MainActor
class ArtworkManager: ObservableObject {
    static let shared = ArtworkManager()
    private nonisolated static let ioQueue = DispatchQueue(label: "com.musicplayer.artwork-io", qos: .utility)

    // Memory cache for quick access
    private var memoryCache: [String: UIImage] = [:]
    private var dominantColorCache: [String: Color] = [:]
    private var dominantColorTasks: [String: Task<Color, Never>] = [:]

    // Persistent disk cache directory (stores raw artwork bytes)
    private let diskCacheURL: URL

    // Mapping file URL (maps track.stableId -> artwork hash)
    private let mappingFileURL: URL

    // In-memory mapping cache
    private var artworkMapping: [String: String] = [:]

    private init() {
        // Create artwork cache directory
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        diskCacheURL = documentsURL.appendingPathComponent("ArtworkCache", isDirectory: true)
        mappingFileURL = documentsURL.appendingPathComponent("ArtworkMapping.plist")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        // Load mapping
        loadMapping()

    }

    private func loadMapping() {
        guard FileManager.default.fileExists(atPath: mappingFileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: mappingFileURL)
            if let mapping = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] {
                artworkMapping = mapping
            }
        } catch {
            print("⚠️ Failed to load artwork mapping: \(error)")
        }
    }

    private func saveMapping() {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: artworkMapping, format: .xml, options: 0)
            try data.write(to: mappingFileURL, options: .atomic)
        } catch {
            print("⚠️ Failed to save artwork mapping: \(error)")
        }
    }

    func clearCache() {
        memoryCache.removeAll()
        dominantColorCache.removeAll()
        for task in dominantColorTasks.values {
            task.cancel()
        }
        dominantColorTasks.removeAll()
    }

    func clearDiskCache() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil)
            for file in files {
                try FileManager.default.removeItem(at: file)
            }
            memoryCache.removeAll()
            dominantColorCache.removeAll()
            for task in dominantColorTasks.values {
                task.cancel()
            }
            dominantColorTasks.removeAll()
            artworkMapping.removeAll()
            saveMapping()
        } catch {
            print("❌ Failed to clear disk cache: \(error)")
        }
    }

    func forceRefreshArtwork(for track: Track) async -> UIImage? {
        // Remove from memory cache and mapping to force re-extraction
        memoryCache.removeValue(forKey: track.stableId)
        dominantColorCache.removeValue(forKey: track.stableId)
        dominantColorTasks[track.stableId]?.cancel()
        dominantColorTasks.removeValue(forKey: track.stableId)

        // Note: We don't delete the actual artwork file as other tracks might use it
        // Just remove the mapping for this track
        artworkMapping.removeValue(forKey: track.stableId)
        saveMapping()

        return await getArtwork(for: track)
    }

    /// Pre-process and cache artwork during library indexing (background operation)
    func cacheArtwork(for track: Track) async {
        // Skip if already mapped (already has cached artwork)
        if artworkMapping[track.stableId] != nil {
            return
        }

        // Extract raw artwork bytes from the audio file
        if let artworkData = await extractArtworkData(from: URL(fileURLWithPath: track.path)) {
            // Save to disk cache (will deduplicate automatically)
            await saveToDiskCache(data: artworkData, stableId: track.stableId)
        }
    }

    func getArtwork(for track: Track) async -> UIImage? {
        // 1. Check memory cache first (fastest)
        if let cachedImage = memoryCache[track.stableId] {
            return cachedImage
        }

        // 2. Check disk cache (fast)
        if let diskImage = await loadFromDiskCache(stableId: track.stableId) {
            // Store in memory cache for next time
            memoryCache[track.stableId] = diskImage
            return diskImage
        }

        // 3. Extract from audio file and cache (slow - should be rare after indexing)
        if let artworkData = await extractArtworkData(from: URL(fileURLWithPath: track.path)),
           let image = UIImage(data: artworkData) {
            // Store in both caches
            memoryCache[track.stableId] = image
            await saveToDiskCache(data: artworkData, stableId: track.stableId)
            return image
        }

        return nil
    }

    func getDominantColor(for track: Track, artwork: UIImage? = nil) async -> Color {
        if let cachedColor = dominantColorCache[track.stableId] {
            return cachedColor
        }

        if let existingTask = dominantColorTasks[track.stableId] {
            return await existingTask.value
        }

        let image: UIImage?
        if let artwork {
            image = artwork
        } else {
            image = await getArtwork(for: track)
        }
        guard let image else { return .white }

        let task = Task { await image.dominantColorAsync() }
        dominantColorTasks[track.stableId] = task

        let color = await task.value
        dominantColorTasks.removeValue(forKey: track.stableId)
        dominantColorCache[track.stableId] = color
        return color
    }

    // MARK: - Disk Cache Management

    private nonisolated func loadFromDiskCache(stableId: String) async -> UIImage? {
        // Get artwork hash from mapping
        guard let artworkHash = await getArtworkHash(for: stableId) else {
            return nil
        }

        let rawFile = diskCacheURL.appendingPathComponent("\(artworkHash).artwork")
        let pngFile = diskCacheURL.appendingPathComponent("\(artworkHash).png")
        let jpgFile = diskCacheURL.appendingPathComponent("\(artworkHash).jpg")
        return await withCheckedContinuation { continuation in
            ArtworkManager.ioQueue.async {
                let fileURL: URL?
                if FileManager.default.fileExists(atPath: rawFile.path) {
                    fileURL = rawFile
                } else if FileManager.default.fileExists(atPath: pngFile.path) {
                    fileURL = pngFile
                } else if FileManager.default.fileExists(atPath: jpgFile.path) {
                    fileURL = jpgFile
                } else {
                    fileURL = nil
                }

                guard let fileURL else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    let data = try Data(contentsOf: fileURL)
                    continuation.resume(returning: UIImage(data: data))
                } catch {
                    print("❌ Failed to load artwork from disk: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func getArtworkHash(for stableId: String) async -> String? {
        return artworkMapping[stableId]
    }

    private nonisolated func saveToDiskCache(data: Data, stableId: String) async {
        let cacheURL = diskCacheURL
        let hashString: String? = await withCheckedContinuation { continuation in
            ArtworkManager.ioQueue.async {
                // Compute hash of artwork data to deduplicate
                let artworkHash = SHA256.hash(data: data)
                let hashString = artworkHash.compactMap { String(format: "%02x", $0) }.joined()

                let diskFile = cacheURL.appendingPathComponent("\(hashString).artwork")

                // Check if artwork already exists
                if FileManager.default.fileExists(atPath: diskFile.path) {
                    continuation.resume(returning: hashString)
                    return
                }

                // Save new artwork file
                do {
                    try data.write(to: diskFile, options: .atomic)
                    continuation.resume(returning: hashString)
                } catch {
                    print("❌ Failed to save artwork to disk: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }

        guard let hashString else { return }
        await updateMapping(stableId: stableId, artworkHash: hashString)
    }

    private func updateMapping(stableId: String, artworkHash: String) async {
        artworkMapping[stableId] = artworkHash
        saveMapping()
    }

    /// Clean up artwork files for tracks that no longer exist
    func cleanupOrphanedArtwork(validStableIds: Set<String>) async {
        // First, clean up mapping entries for deleted tracks
        var removedMappings = 0
        for stableId in artworkMapping.keys {
            if !validStableIds.contains(stableId) {
                artworkMapping.removeValue(forKey: stableId)
                removedMappings += 1
            }
        }

        if removedMappings > 0 {
            saveMapping()
        }

        // Build set of artwork hashes still in use
        let usedHashes = Set(artworkMapping.values)

        // Clean up artwork files that are no longer referenced
        do {
            let files = try FileManager.default.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: nil)
            var removedCount = 0

            for fileURL in files {
                let artworkHash = fileURL.deletingPathExtension().lastPathComponent
                if !usedHashes.contains(artworkHash) {
                    try FileManager.default.removeItem(at: fileURL)
                    removedCount += 1
                }
            }

        } catch {
            print("❌ Failed to cleanup orphaned artwork: \(error)")
        }
    }
    
    private nonisolated func extractArtworkData(from url: URL) async -> Data? {
        let ext = url.pathExtension.lowercased()

        if ext == "mp3" {
            return await extractMp3ArtworkData(from: url)
        } else if ext == "m4a" || ext == "mp4" || ext == "aac" {
            return await extractM4AArtworkData(from: url)
        }

        return nil
    }
    
    private nonisolated func extractMp3ArtworkData(from url: URL) async -> Data? {
        return await withCheckedContinuation { continuation in
            Task {
                let asset = AVURLAsset(url: url)
                
                do {
                    let metadata = try await asset.load(.commonMetadata)
                    
                    for item in metadata {
                        if item.commonKey == .commonKeyArtwork {
                            do {
                                if let data = try await item.load(.dataValue) {
                                    continuation.resume(returning: data)
                                    return
                                }
                            } catch {
                                print("Failed to load artwork data: \(error)")
                            }
                        }
                    }
                    
                    continuation.resume(returning: nil)
                } catch {
                    print("Failed to load MP3 metadata: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    // MARK: - M4A/AAC Artwork Extraction

    private nonisolated func extractM4AArtworkData(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let commonMetadata = try? await asset.load(.commonMetadata) else { return nil }

        for item in commonMetadata {
            if item.commonKey == .commonKeyArtwork,
               let data = try? await item.load(.dataValue) {
                return data
            }
        }

        print("⚠️ No artwork found in M4A file: \(url.lastPathComponent)")
        return nil
    }
}
