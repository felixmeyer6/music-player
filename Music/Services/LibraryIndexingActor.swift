//  Runs heavy library indexing work off the main actor

import Foundation
import AVFoundation

enum LibraryIndexerError: Error {
    case parseTimeout
    case metadataParsingFailed
}

enum IndexingEvent: @unchecked Sendable {
    case started(total: Int)
    case queue(current: String, remaining: [String])
    case progress(processed: Int, total: Int)
    case trackFound(Track)
    case finished(found: Int)
    case error(Error)
}

typealias IndexingEventHandler = @Sendable (IndexingEvent) async -> Void

actor LibraryIndexingActor {
    private let databaseManager = DatabaseManager.shared
    private let stateManager = StateManager.shared
    private let supportedExtensions: Set<String> = ["mp3", "wav", "m4a", "aac"]

    func processMetadataURLs(_ urls: [URL], onEvent: IndexingEventHandler?) async {
        let filtered = urls.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        let total = filtered.count
        if let onEvent {
            await onEvent(.started(total: total))
        }

        guard total > 0 else {
            if let onEvent {
                await onEvent(.finished(found: 0))
            }
            return
        }

        var processedCount = 0
        var foundCount = 0

        for url in filtered {
            if Task.isCancelled { break }

            if let track = await processAudioFile(url) {
                foundCount += 1
                if let onEvent {
                    await onEvent(.trackFound(track))
                }
            }

            processedCount += 1
            if let onEvent {
                await onEvent(.progress(processed: processedCount, total: total))
            }
        }

        if let onEvent {
            await onEvent(.finished(found: foundCount))
        }
    }

    func fallbackToDirectScan(onEvent: IndexingEventHandler?) async {
        var allMusicFiles: [URL] = []

        // First, copy any new files from shared container to Documents
        await copyFilesFromSharedContainer(onEvent: onEvent)

        // Scan iCloud folder if available
        if let iCloudMusicFolderURL = stateManager.getMusicFolderURL() {
            do {
                let iCloudFiles = try await findMusicFiles(in: iCloudMusicFolderURL)
                allMusicFiles.append(contentsOf: iCloudFiles)
            } catch {
                print("⚠️ Failed to scan iCloud folder: \(error)")
            }
        }

        // Scan local Documents folder
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let localFiles = try await findMusicFiles(in: documentsPath)
            allMusicFiles.append(contentsOf: localFiles)
        } catch {
            print("⚠️ Failed to scan local Documents folder: \(error)")
        }

        let totalFiles = allMusicFiles.count

        if let onEvent {
            await onEvent(.started(total: totalFiles))
        }

        guard totalFiles > 0 else {
            print("❌ No music files found in any location")
            if let onEvent {
                await onEvent(.finished(found: 0))
            }
            return
        }

        if let onEvent {
            await onEvent(.queue(current: "", remaining: allMusicFiles.map { $0.lastPathComponent }))
        }

        var foundCount = 0

        for (index, url) in allMusicFiles.enumerated() {
            if Task.isCancelled { break }

            let fileName = url.lastPathComponent
            let isLocalFile = !url.path.contains("Mobile Documents")

            if let onEvent {
                let remaining = Array(allMusicFiles.suffix(from: index + 1).map { $0.lastPathComponent })
                await onEvent(.queue(current: fileName, remaining: remaining))
            }

            // Skip iCloud processing if we're in offline mode due to auth issues
            if !isLocalFile {
                let shouldSkip = await shouldSkipICloudFile()
                if shouldSkip {
                    print("🚫 Skipping iCloud file processing - iCloud authentication required: \(fileName)")
                    continue
                }
            }

            if let track = await processAudioFile(url) {
                foundCount += 1
                if let onEvent {
                    await onEvent(.trackFound(track))
                }
            }

            if let onEvent {
                await onEvent(.progress(processed: index + 1, total: totalFiles))
            }
        }

        if let onEvent {
            await onEvent(.queue(current: "", remaining: []))
            await onEvent(.finished(found: foundCount))
        }
    }

    func scanLocalDocuments(onEvent: IndexingEventHandler?) async {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

        do {
            let musicFiles = try await findMusicFiles(in: documentsPath)
            let totalFiles = musicFiles.count

            if let onEvent {
                await onEvent(.started(total: totalFiles))
            }

            var processedFiles = 0
            var foundCount = 0

            for fileURL in musicFiles {
                if Task.isCancelled { break }

                if let track = await processAudioFile(fileURL) {
                    foundCount += 1
                    if let onEvent {
                        await onEvent(.trackFound(track))
                    }
                }

                processedFiles += 1
                if let onEvent {
                    await onEvent(.progress(processed: processedFiles, total: totalFiles))
                }
            }

            if let onEvent {
                await onEvent(.finished(found: foundCount))
            }

        } catch {
            if let onEvent {
                await onEvent(.error(error))
                await onEvent(.finished(found: 0))
            }
            print("Offline library scan failed: \(error)")
        }
    }

    func processExternalFile(_ fileURL: URL, onEvent: IndexingEventHandler?) async {
        // Reject network URLs
        if isNetworkURL(fileURL) {
            print("❌ Rejected network URL: \(fileURL.absoluteString)")
            return
        }

        if let track = await processAudioFile(fileURL) {
            if let onEvent {
                await onEvent(.trackFound(track))
            }
        }
    }

    func copyFilesFromSharedContainer(onEvent: IndexingEventHandler?) async {
        guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.neofx.music-player") else {
            print("❌ Failed to get shared container URL")
            return
        }

        await processSharedURLs(from: sharedContainer, onEvent: onEvent)
        await processLegacySharedFiles(from: sharedContainer, onEvent: onEvent)
        await processStoredExternalBookmarks(onEvent: onEvent)
    }

    func resolveBookmarkForTrack(_ track: Track) async -> URL? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        guard FileManager.default.fileExists(atPath: bookmarksURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: bookmarksURL)
            guard let bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data],
                  let bookmarkData = bookmarks[track.stableId] else {
                return nil
            }

            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

            if isStale {
                print("⚠️ Bookmark is stale for: \(track.title)")
                return nil
            }

            if track.path != resolvedURL.path {
                try databaseManager.write { db in
                    var updatedTrack = track
                    updatedTrack.path = resolvedURL.path
                    try updatedTrack.update(db)
                }
            }

            return resolvedURL

        } catch {
            print("❌ Failed to resolve bookmark for track \(track.title): \(error)")
            return nil
        }
    }

    nonisolated static func generateStableId(for url: URL) throws -> String {
        StableIdGenerator.fromURL(url)
    }

    // MARK: - Internal helpers

    private func processAudioFile(_ fileURL: URL) async -> Track? {
        do {
            let isLocalFile = !fileURL.path.contains("Mobile Documents")

            if !isLocalFile {
                do {
                    try await CloudDownloadManager.shared.ensureLocal(fileURL)
                } catch {
                    print("⚠️ Failed to ensure iCloud file is local: \(fileURL.lastPathComponent) - \(error)")

                    if let cloudError = error as? CloudDownloadError {
                        switch cloudError {
                        case .authenticationRequired, .accessDenied:
                            print("🔐 Authentication error in LibraryIndexer - switching to offline mode")
                            await MainActor.run {
                                AppCoordinator.shared.handleiCloudAuthenticationError()
                            }
                            return nil
                        default:
                            break
                        }
                    }
                    // Continue processing even if download fails (for other errors)
                }
            }

            let stableId = try Self.generateStableId(for: fileURL)

            let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let fileSize = Int64(resourceValues.fileSize ?? 0)
            let contentModificationTime = resourceValues.contentModificationDate?.timeIntervalSince1970 ?? 0

            if let existing = try databaseManager.getTrack(byStableId: stableId) {
                if existing.path != fileURL.path {
                    try databaseManager.write { db in
                        var updatedTrack = existing
                        updatedTrack.path = fileURL.path
                        updatedTrack.fileSize = fileSize
                        try updatedTrack.update(db)
                    }
                }
                let expectedBars = WaveformProcessing.barsCount(forDurationMs: existing.durationMs)
                let meta = WaveformProcessing.makeMeta(
                    totalBars: expectedBars,
                    fileSize: fileSize,
                    contentModificationTime: contentModificationTime
                )
                if WaveformProcessing.matches(existing.waveformData, meta: meta) {
                    return nil
                }
            }

            let track = try await parseAudioFile(
                at: fileURL,
                stableId: stableId,
                fileSize: fileSize,
                contentModificationTime: contentModificationTime
            )

            try databaseManager.upsertTrack(track)

            await ArtworkManager.shared.cacheArtwork(for: track)

            await checkDownloadStatus(for: fileURL)

            return track

        } catch LibraryIndexerError.parseTimeout {
            print("⏰ Timeout parsing audio file: \(fileURL.lastPathComponent)")
            print("❌ Skipping file due to parsing timeout")
        } catch {
            print("❌ Failed to process local track at \(fileURL.lastPathComponent): \(error)")
            print("❌ Error type: \(type(of: error))")
            print("❌ Error details: \(String(describing: error))")
        }

        return nil
    }

    private func checkDownloadStatus(for fileURL: URL) async {
        do {
            let resourceValues = try fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey])

            if let isUbiquitous = resourceValues.isUbiquitousItem, isUbiquitous {
                if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus {
                    switch downloadStatus {
                    case .notDownloaded:
                        try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                    case .downloaded:
                        break
                    case .current:
                        break
                    default:
                        break
                    }
                }
            }
        } catch {
            print("Failed to check download status for \(fileURL.lastPathComponent): \(error)")
        }
    }

    private func findMusicFiles(in directory: URL) async throws -> [URL] {
        let extensions = supportedExtensions
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .background).async { [extensions] in
                do {
                    var musicFiles: [URL] = []

                    let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
                    let directoryEnumerator = FileManager.default.enumerator(
                        at: directory,
                        includingPropertiesForKeys: resourceKeys,
                        options: [.skipsHiddenFiles]
                    )

                    guard let enumerator = directoryEnumerator else {
                        continuation.resume(returning: musicFiles)
                        return
                    }

                    for case let fileURL as URL in enumerator {
                        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))

                        guard let isRegularFile = resourceValues.isRegularFile, isRegularFile else {
                            continue
                        }

                        let pathExtension = fileURL.pathExtension.lowercased()
                        if extensions.contains(pathExtension) {
                            musicFiles.append(fileURL)
                        }
                    }

                    continuation.resume(returning: musicFiles)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func parseAudioFile(
        at url: URL,
        stableId: String,
        fileSize: Int64,
        contentModificationTime: TimeInterval
    ) async throws -> Track {
        let metadata = try await withThrowingTaskGroup(of: AudioMetadata.self) { group in
            group.addTask {
                return try await AudioMetadataParser.parseMetadata(from: url)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw LibraryIndexerError.parseTimeout
            }

            guard let result = try await group.next() else {
                throw LibraryIndexerError.parseTimeout
            }

            group.cancelAll()
            return result
        }

        let cleanedArtistName = cleanArtistName(metadata.artist ?? Localized.unknownArtist)
        let cleanedGenre = cleanGenre(metadata.genre)

        let artist = try databaseManager.upsertArtist(name: cleanedArtistName)
        let album = try databaseManager.upsertAlbum(name: metadata.album ?? Localized.unknownAlbum)
        let genreRecord: Genre? = if let genreName = cleanedGenre, !genreName.isEmpty {
            try databaseManager.upsertGenre(name: genreName)
        } else {
            nil
        }

        let bars = WaveformProcessing.barsCount(forDurationMs: metadata.durationMs)
        let waveformMeta = WaveformProcessing.makeMeta(
            totalBars: bars,
            fileSize: fileSize,
            contentModificationTime: contentModificationTime
        )
        let waveformData = await Task.detached(priority: .utility) {
            await WaveformProcessing.buildWaveformData(
                for: url,
                totalBars: bars,
                meta: waveformMeta
            )
        }.value

        return Track(
            stableId: stableId,
            albumId: album.id,
            artistId: artist.id,
            genreId: genreRecord?.id,
            genre: cleanedGenre,
            rating: metadata.rating,
            title: metadata.title ?? url.deletingPathExtension().lastPathComponent,
            durationMs: metadata.durationMs,
            sampleRate: metadata.sampleRate,
            bitDepth: metadata.bitDepth,
            channels: metadata.channels,
            path: url.path,
            fileSize: fileSize,
            hasEmbeddedArt: metadata.hasEmbeddedArt,
            waveformData: waveformData
        )
    }

    private func cleanArtistName(_ artistName: String) -> String {
        var cleaned = artistName.trimmingCharacters(in: .whitespacesAndNewlines)

        let suffixesToRemove = [
            " - Topic",
            " Topic",
            "- Topic",
            ", Topic",
            " (Topic)"
        ]

        for suffix in suffixesToRemove {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if cleaned.contains(",") {
            let components = cleaned.components(separatedBy: ",")
            if let firstArtist = components.first?.trimmingCharacters(in: .whitespacesAndNewlines) {
                cleaned = firstArtist
            }
        }

        if let bracketStart = cleaned.firstIndex(of: "[") {
            cleaned = String(cleaned[..<bracketStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned.isEmpty ? Localized.unknownArtist : cleaned
    }

    private func cleanGenre(_ genre: String?) -> String? {
        guard let genre else { return nil }
        let cleaned = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func isNetworkURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "ftp", "sftp"].contains(scheme)
    }

    private func shouldSkipICloudFile() async -> Bool {
        await MainActor.run {
            AppCoordinator.shared.iCloudStatus == .authenticationRequired || !AppCoordinator.shared.isiCloudAvailable
        }
    }

    // MARK: - Shared container processing

    private func processSharedURLs(from sharedContainer: URL, onEvent: IndexingEventHandler?) async {
        let sharedDataURL = sharedContainer.appendingPathComponent("SharedAudioFiles.plist")

        guard FileManager.default.fileExists(atPath: sharedDataURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: sharedDataURL)
            guard let sharedFiles = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Data]] else {
                return
            }

            for fileInfo in sharedFiles {
                guard let bookmarkData = fileInfo["bookmark"],
                      let filenameData = fileInfo["filename"],
                      let filename = String(data: filenameData, encoding: .utf8) else {
                    continue
                }

                do {
                    var isStale = false
                    let url = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

                    if isStale {
                        print("⚠️ Bookmark is stale for: \(filename)")
                        continue
                    }

                    if isNetworkURL(url) {
                        print("❌ Rejected network URL: \(url.absoluteString)")
                        continue
                    }

                    guard url.startAccessingSecurityScopedResource() else {
                        print("❌ Failed to access security-scoped resource for: \(filename)")
                        continue
                    }

                    defer {
                        url.stopAccessingSecurityScopedResource()
                    }

                    await processExternalFile(url, onEvent: onEvent)
                    await storeBookmarkPermanently(bookmarkData, for: url)

                } catch {
                    print("❌ Failed to resolve bookmark for \(filename): \(error)")
                }
            }

            try FileManager.default.removeItem(at: sharedDataURL)

        } catch {
            print("❌ Failed to process shared audio files: \(error)")
        }
    }

    private func processLegacySharedFiles(from sharedContainer: URL, onEvent: IndexingEventHandler?) async {
        let sharedMusicURL = sharedContainer.appendingPathComponent("Documents").appendingPathComponent("Music")
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localMusicURL = documentsURL.appendingPathComponent("Music")

        do {
            try FileManager.default.createDirectory(at: localMusicURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("❌ Failed to create local Music directory: \(error)")
            return
        }

        guard FileManager.default.fileExists(atPath: sharedMusicURL.path) else {
            return
        }

        do {
            let sharedFiles = try FileManager.default.contentsOfDirectory(at: sharedMusicURL, includingPropertiesForKeys: nil)
            let audioFiles = sharedFiles.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "mp3" || ext == "wav"
            }

            for audioFile in audioFiles {
                let localDestination = localMusicURL.appendingPathComponent(audioFile.lastPathComponent)

                if FileManager.default.fileExists(atPath: localDestination.path) {
                    continue
                }

                do {
                    try FileManager.default.copyItem(at: audioFile, to: localDestination)

                    try FileManager.default.removeItem(at: audioFile)

                } catch {
                    print("❌ Failed to copy legacy file \(audioFile.lastPathComponent): \(error)")
                }
            }

        } catch {
            print("❌ Failed to read shared container directory: \(error)")
        }
    }

    private func storeBookmarkPermanently(_ bookmarkData: Data, for url: URL) async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        do {
            var bookmarks: [String: Data] = [:]
            if FileManager.default.fileExists(atPath: bookmarksURL.path) {
                let data = try Data(contentsOf: bookmarksURL)
                if let existingBookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] {
                    bookmarks = existingBookmarks
                }
            }

            let stableId = try Self.generateStableId(for: url)
            bookmarks[stableId] = bookmarkData

            let plistData = try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .xml, options: 0)
            try plistData.write(to: bookmarksURL)
        } catch {
            print("❌ Failed to store permanent bookmark for \(url.lastPathComponent): \(error)")
        }
    }

    private func processStoredExternalBookmarks(onEvent: IndexingEventHandler?) async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        guard FileManager.default.fileExists(atPath: bookmarksURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: bookmarksURL)
            guard let bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] else {
                print("❌ Invalid external bookmarks format")
                return
            }

            for (stableId, bookmarkData) in bookmarks {
                do {
                    var isStale = false
                    let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

                    if isStale {
                        print("⚠️ Bookmark is stale for stableId: \(stableId)")
                        continue
                    }

                    if isNetworkURL(resolvedURL) {
                        print("❌ Rejected network URL: \(resolvedURL.absoluteString)")
                        continue
                    }

                    if let existingTrack = try databaseManager.getTrack(byStableId: stableId) {
                        if existingTrack.path != resolvedURL.path {
                            try databaseManager.write { db in
                                var updatedTrack = existingTrack
                                updatedTrack.path = resolvedURL.path
                                try updatedTrack.update(db)
                            }
                        }
                        continue
                    }

                    guard resolvedURL.startAccessingSecurityScopedResource() else {
                        print("❌ Failed to access security-scoped resource for: \(resolvedURL.lastPathComponent)")
                        continue
                    }

                    defer {
                        resolvedURL.stopAccessingSecurityScopedResource()
                    }

                    await processExternalFile(resolvedURL, onEvent: onEvent)

                } catch {
                    print("❌ Failed to resolve bookmark for stableId \(stableId): \(error)")
                }
            }

        } catch {
            print("❌ Failed to process stored external bookmarks: \(error)")
        }
    }

}
