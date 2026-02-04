//  Manages cleanup of iCloud files that were deleted from iCloud Drive

import Foundation
import SwiftUI
import CryptoKit

@MainActor
class FileCleanupManager: ObservableObject {
    static let shared = FileCleanupManager()
    
    
    private let databaseManager = DatabaseManager.shared
    private let stateManager = StateManager.shared
    
    private init() {}
    
    func checkForOrphanedFiles() async {
        guard let iCloudFolderURL = stateManager.getMusicFolderURL() else {
            return
        }
        
        do {
            // Get all tracks from database
            let allTracks = try databaseManager.getAllTracks()
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            
            var nonExistentFiles: [URL] = []
            
            for track in allTracks {
                let trackURL = URL(fileURLWithPath: track.path)

                // Check if this is an internal file (iCloud/Documents) or external file
                let isInternalFile = trackURL.path.contains(iCloudFolderURL.path) ||
                                   trackURL.path.contains("/Documents/")

                if isInternalFile {
                    // For internal files, simple existence check
                    let fileExists = FileManager.default.fileExists(atPath: trackURL.path)

                    if !fileExists {
                        // Check if this is a local Documents file with an old container path
                        if trackURL.path.contains("/Documents/") && !trackURL.path.contains(iCloudFolderURL.path) {
                            if let rebasedURL = rebaseToCurrentDocuments(trackURL, documentsURL: documentsURL) {
                                // Update the track's path in the database
                                do {
                                    try databaseManager.write { db in
                                        var updatedTrack = track
                                        updatedTrack.path = rebasedURL.path
                                        try updatedTrack.update(db)
                                    }
                                } catch {
                                    print("🧹 ❌ Failed to update path: \(error)")
                                    nonExistentFiles.append(trackURL)
                                }
                            } else {
                                nonExistentFiles.append(trackURL)
                            }
                        } else {
                            nonExistentFiles.append(trackURL)
                        }
                    }
                } else {
                    // For external files (from share/document picker), check if still accessible
                    let isAccessible = await checkExternalFileAccessibility(trackURL, stableId: track.stableId)

                    if isAccessible {
                    } else {
                        nonExistentFiles.append(trackURL)
                    }
                }
            }
            
            // Auto-clean files that don't exist anywhere
            if !nonExistentFiles.isEmpty {
                for fileURL in nonExistentFiles {
                    do {
                        let stableId = generateStableId(for: fileURL)
                        if let track = try databaseManager.getTrack(byStableId: stableId) {
                            try databaseManager.deleteTrack(byStableId: stableId)

                            // Delete cached artwork for this track
                            await deleteArtworkCache(for: stableId)
                        }
                    } catch {
                        print("🧹 Error auto-cleaning file \(fileURL.lastPathComponent): \(error)")
                    }
                }
                
                // Notify UI to refresh since we made database changes
                NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)
            }
        } catch {
            print("🧹 Error checking for orphaned files: \(error)")
        }
    }
    
    private func rebaseToCurrentDocuments(_ trackURL: URL, documentsURL: URL) -> URL? {
        let trackPath = trackURL.path
        if let range = trackPath.range(of: "/Documents/") {
            let relativePath = String(trackPath[range.upperBound...])
            let rebasedURL = documentsURL.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: rebasedURL.path) {
                return rebasedURL
            }
        }

        // Fallbacks for common local layouts
        let filename = trackURL.lastPathComponent
        let musicFolderURL = documentsURL.appendingPathComponent("Music").appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: musicFolderURL.path) {
            return musicFolderURL
        }

        let rootURL = documentsURL.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: rootURL.path) {
            return rootURL
        }

        return nil
    }


    private func checkExternalFileAccessibility(_ fileURL: URL, stableId: String) async -> Bool {
        // First check if file exists at the path
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // File exists at original path, try to access it
            do {
                _ = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                return true
            } catch {
                print("🧹     External file exists but not accessible: \(error)")
                return false
            }
        }

        // File doesn't exist at original path, check if we have bookmark data for it
        return await checkBookmarkAccessibility(for: fileURL, stableId: stableId)
    }

    private func checkBookmarkAccessibility(for fileURL: URL, stableId: String) async -> Bool {
        // Check document picker bookmarks (now using stableId as key)
        if let resolvedURL = await resolveDocumentPickerBookmark(for: stableId) {
            // Bookmark found! Check if file is still accessible
            if resolvedURL.path != fileURL.path {
            }

            // Test if the resolved location is accessible
            let isAccessible = await testFileAccessibility(resolvedURL)
            if isAccessible {
            }
            return isAccessible
        }

        // Check share extension bookmarks (legacy - should be migrated)
        if let resolvedURL = await resolveShareExtensionBookmark(for: stableId) {
            if resolvedURL.path != fileURL.path {
            }
            return await testFileAccessibility(resolvedURL)
        }

        return false
    }

    private func resolveDocumentPickerBookmark(for stableId: String) async -> URL? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        guard FileManager.default.fileExists(atPath: bookmarksURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: bookmarksURL)
            guard let bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data],
                  let bookmarkData = bookmarks[stableId] else {
                return nil
            }

            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

            if isStale {
                return nil
            }
            return resolvedURL
        } catch {
            print("🧹     Failed to resolve document picker bookmark: \(error)")
            return nil
        }
    }

    private func resolveShareExtensionBookmark(for stableId: String) async -> URL? {
        // Share extension bookmarks are now migrated to the main bookmark storage
        // This function is kept for backward compatibility but should not be needed
        return nil
    }

    private func testFileAccessibility(_ fileURL: URL) async -> Bool {
        guard fileURL.startAccessingSecurityScopedResource() else {
            print("🧹     ❌ Failed to start accessing security-scoped resource")
            return false
        }

        defer {
            fileURL.stopAccessingSecurityScopedResource()
        }

        // Check if file exists at the resolved path
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("🧹     ❌ File doesn't exist at resolved bookmark path: \(fileURL.path)")
            return false
        }

        do {
            // Try to get file attributes - this tests basic access permissions
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)

            // For additional verification, try to actually read the file
            // This will catch cases where the file exists but is corrupted or inaccessible
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer {
                do {
                    try fileHandle.close()
                } catch {
                    print("🧹     ⚠️ Error closing file handle: \(error)")
                }
            }

            let data = try fileHandle.read(upToCount: 1024)

            if let data = data, data.count > 0 {
                return true
            } else {
                print("🧹     ❌ External file exists but appears to be empty or unreadable")
                return false
            }
        } catch {
            print("🧹     ❌ External file not accessible or readable via bookmark")
            print("🧹     ❌ Error details: \(error)")
            print("🧹     ❌ Error type: \(type(of: error))")
            return false
        }
    }

    private func generateStableId(for url: URL) -> String {
        // Simple stable ID based only on filename - matches LibraryIndexer
        let filename = url.lastPathComponent
        let digest = SHA256.hash(data: filename.data(using: .utf8) ?? Data())
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Artwork Cache Cleanup

    private func deleteArtworkCache(for stableId: String) async {
        // Note: We don't delete the actual artwork file as other tracks might use it
        // The artwork manager will clean up unused files during cleanupOrphanedArtwork
        // Just notify that we're removing this track's artwork reference
    }
}
