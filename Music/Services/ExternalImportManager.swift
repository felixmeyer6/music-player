import Foundation

/// Handles importing music files and folders from the Files app
@MainActor
final class ExternalImportManager {
    static let shared = ExternalImportManager()

    private let libraryIndexer = LibraryIndexer.shared
    private let supportedExtensions: Set<String> = ["mp3", "wav", "m4a", "aac"]

    private init() {}

    func importFiles(urls: [URL]) async -> Int {
        var processedCount = 0

        for url in urls {
            guard !isNetworkURL(url) else {
                print("❌ Rejected network URL: \(url.absoluteString)")
                continue
            }

            guard url.startAccessingSecurityScopedResource() else {
                print("❌ Failed to access security-scoped resource for: \(url.lastPathComponent)")
                continue
            }

            defer {
                url.stopAccessingSecurityScopedResource()
            }

            await processFile(url)
            processedCount += 1
        }

        return processedCount
    }

    func importFolder(_ folderURL: URL) async -> Int {
        guard !isNetworkURL(folderURL) else {
            print("❌ Rejected network URL: \(folderURL.absoluteString)")
            return 0
        }

        guard folderURL.startAccessingSecurityScopedResource() else {
            print("❌ Failed to access security-scoped folder: \(folderURL.lastPathComponent)")
            return 0
        }

        defer {
            folderURL.stopAccessingSecurityScopedResource()
        }

        let musicFiles: [URL]
        do {
            musicFiles = try await enumerateMusicFiles(in: folderURL)
        } catch {
            print("❌ Failed to enumerate folder \(folderURL.lastPathComponent): \(error)")
            return 0
        }

        var processedCount = 0
        for fileURL in musicFiles {
            if fileURL.startAccessingSecurityScopedResource() {
                await processFile(fileURL)
                fileURL.stopAccessingSecurityScopedResource()
                processedCount += 1
            } else {
                await processFile(fileURL)
                processedCount += 1
            }
        }

        return processedCount
    }

    private func processFile(_ url: URL) async {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            await storeBookmarkData(bookmarkData, for: url)
        } catch {
            print("⚠️ Failed to create bookmark for \(url.lastPathComponent): \(error)")
        }

        await libraryIndexer.processExternalFile(url)
        print("✅ Processed external file: \(url.lastPathComponent)")
    }

    private func storeBookmarkData(_ bookmarkData: Data, for url: URL) async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        do {
            var bookmarks: [String: Data] = [:]
            if FileManager.default.fileExists(atPath: bookmarksURL.path),
               let data = try? Data(contentsOf: bookmarksURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] {
                bookmarks = plist
            }

            let stableId: String
            do {
                stableId = try libraryIndexer.generateStableId(for: url)
            } catch {
                stableId = url.path
                print("⚠️ Falling back to path-based bookmark key for \(url.lastPathComponent): \(error)")
            }

            bookmarks[stableId] = bookmarkData

            let plistData = try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .xml, options: 0)
            try plistData.write(to: bookmarksURL)

            print("✅ Stored bookmark for: \(url.lastPathComponent) (key: \(stableId))")
        } catch {
            print("❌ Failed to store bookmark data: \(error)")
        }
    }

    private func enumerateMusicFiles(in folderURL: URL) async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .background).async { [supportedExtensions] in
                do {
                    var results: [URL] = []
                    let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .nameKey]

                    let enumerator = FileManager.default.enumerator(
                        at: folderURL,
                        includingPropertiesForKeys: resourceKeys,
                        options: [.skipsHiddenFiles]
                    )

                    guard let enumerator else {
                        continuation.resume(returning: results)
                        return
                    }

                    for case let fileURL as URL in enumerator {
                        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                        guard resourceValues.isRegularFile == true else { continue }

                        let ext = fileURL.pathExtension.lowercased()
                        if supportedExtensions.contains(ext) {
                            results.append(fileURL)
                        }
                    }

                    continuation.resume(returning: results)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func isNetworkURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "ftp", "sftp"].contains(scheme)
    }
}
