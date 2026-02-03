//
//  LibraryIndexer.swift
//  Cosmos Music Player
//
//  Indexes audio files (MP3, WAV, AAC, M4A) in iCloud Drive using NSMetadataQuery
//

import Foundation
import Combine
import AVFoundation

@MainActor
class LibraryIndexer: NSObject, ObservableObject {
    static let shared = LibraryIndexer()

    @Published var isIndexing = false
    @Published var indexingProgress: Double = 0.0
    @Published var tracksFound = 0
    @Published var currentlyProcessing: String = ""
    @Published var queuedFiles: [String] = []

    private let metadataQuery = NSMetadataQuery()
    private let stateManager = StateManager.shared
    private let worker = LibraryIndexingActor()
    private var indexingTask: Task<Void, Never>?
    private var pendingQueryUpdate = false
    private var didDisableUpdates = false

    override init() {
        super.init()
        setupMetadataQuery()
    }

    private func setupMetadataQuery() {
        metadataQuery.delegate = self

        if let musicFolderURL = stateManager.getMusicFolderURL() {
            metadataQuery.searchScopes = [musicFolderURL]
        } else {
            metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        }

        let formats = ["*.mp3", "*.wav", "*.m4a", "*.aac"]
        let formatPredicates = formats.map { format in
            NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, format)
        }
        metadataQuery.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: formatPredicates)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidGatherInitialResults),
            name: NSNotification.Name.NSMetadataQueryDidFinishGathering,
            object: metadataQuery
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate),
            name: NSNotification.Name.NSMetadataQueryDidUpdate,
            object: metadataQuery
        )
    }

    func start() {
        guard !isIndexing else { return }

        CloudDownloadManager.shared.attemptRecovery()

        isIndexing = true
        indexingProgress = 0.0
        tracksFound = 0
        currentlyProcessing = ""
        queuedFiles = []

        Task {
            await copyFilesFromSharedContainer()
        }

        if let musicFolderURL = stateManager.getMusicFolderURL() {
            print("Starting iCloud library indexing in: \(musicFolderURL)")

            if FileManager.default.fileExists(atPath: musicFolderURL.path) {
                do {
                    let contents = try FileManager.default.contentsOfDirectory(at: musicFolderURL, includingPropertiesForKeys: nil)
                    print("Found \(contents.count) items in Music folder:")
                    for item in contents {
                        print("  - \(item.lastPathComponent)")
                    }
                } catch {
                    print("Error listing folder contents: \(error)")
                }
            } else {
                print("Music folder doesn't exist yet")
            }
        } else {
            print("No music folder URL available")
        }

        metadataQuery.start()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            print("Timeout check: resultCount=\(metadataQuery.resultCount), isIndexing=\(isIndexing)")
            if metadataQuery.resultCount == 0 && isIndexing && indexingTask == nil {
                print("NSMetadataQuery timeout - triggering fallback scan")
                runFallbackScan()
            }
        }
    }

    func startOfflineMode() {
        guard !isIndexing else { return }

        isIndexing = true
        indexingProgress = 0.0
        tracksFound = 0
        currentlyProcessing = ""
        queuedFiles = []

        let handler = makeEventHandler()
        indexingTask = Task {
            await worker.scanLocalDocuments(onEvent: handler)
            await MainActor.run {
                self.finalizeIndexingTask()
            }
        }
    }

    func stop() {
        metadataQuery.stop()
        indexingTask?.cancel()
        indexingTask = nil
        isIndexing = false
        currentlyProcessing = ""
        queuedFiles = []
    }

    func switchToOfflineMode() {
        print("🔄 Switching LibraryIndexer to offline mode")
        stop()
        startOfflineMode()
    }

    func processExternalFile(_ fileURL: URL) async {
        let handler = makeEventHandler()
        await worker.processExternalFile(fileURL, onEvent: handler)
    }

    func generateStableId(for url: URL) throws -> String {
        try LibraryIndexingActor.generateStableId(for: url)
    }

    func copyFilesFromSharedContainer() async {
        let handler = makeEventHandler()
        await worker.copyFilesFromSharedContainer(onEvent: handler)
    }

    func resolveBookmarkForTrack(_ track: Track) async -> URL? {
        await worker.resolveBookmarkForTrack(track)
    }

    @objc private func queryDidGatherInitialResults() {
        print("🔍 NSMetadataQuery gathered initial results: \(metadataQuery.resultCount) items")
        for i in 0..<metadataQuery.resultCount {
            if let item = metadataQuery.result(at: i) as? NSMetadataItem,
               let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                print("  Found: \(url.lastPathComponent)")
            }
        }
        processMetadataQueryResults()
    }

    @objc private func queryDidUpdate() {
        processMetadataQueryResults()
    }

    private func processMetadataQueryResults() {
        if indexingTask != nil {
            pendingQueryUpdate = true
            return
        }

        if !didDisableUpdates {
            metadataQuery.disableUpdates()
            didDisableUpdates = true
        }

        let urls: [URL] = (0..<metadataQuery.resultCount).compactMap { index in
            guard let item = metadataQuery.result(at: index) as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else {
                return nil
            }
            return url
        }

        if urls.isEmpty {
            if didDisableUpdates {
                metadataQuery.enableUpdates()
                didDisableUpdates = false
            }
            print("NSMetadataQuery found 0 results, falling back to direct file system scan")
            runFallbackScan()
            return
        }

        runIndexing(for: urls)
    }

    private func runIndexing(for urls: [URL]) {
        let handler = makeEventHandler()
        indexingTask = Task {
            await worker.processMetadataURLs(urls, onEvent: handler)
            await MainActor.run {
                self.finalizeIndexingTask()
            }
        }
    }

    private func runFallbackScan() {
        guard indexingTask == nil else {
            pendingQueryUpdate = true
            return
        }

        let handler = makeEventHandler()
        indexingTask = Task {
            await worker.fallbackToDirectScan(onEvent: handler)
            await MainActor.run {
                self.finalizeIndexingTask()
            }
        }
    }

    private func makeEventHandler() -> IndexingEventHandler {
        return { event in
            await LibraryIndexer.shared.handleEvent(event)
        }
    }

    private func finalizeIndexingTask() {
        indexingTask = nil
        if didDisableUpdates {
            metadataQuery.enableUpdates()
            didDisableUpdates = false
        }
        currentlyProcessing = ""
        queuedFiles = []

        if pendingQueryUpdate {
            pendingQueryUpdate = false
            processMetadataQueryResults()
        }
    }

    private func handleEvent(_ event: IndexingEvent) async {
        switch event {
        case .started:
            isIndexing = true
            indexingProgress = 0.0

        case .queue(let current, let remaining):
            currentlyProcessing = current
            queuedFiles = remaining

        case .progress(let processed, let total):
            if total > 0 {
                indexingProgress = Double(processed) / Double(total)
            } else {
                indexingProgress = 0.0
            }

        case .trackFound(let track):
            tracksFound += 1
            NotificationCenter.default.post(name: NSNotification.Name("TrackFound"), object: track)

        case .finished:
            isIndexing = false
            currentlyProcessing = ""
            queuedFiles = []

        case .error(let error):
            print("⚠️ Library indexing error: \(error)")
        }
    }
}

extension LibraryIndexer: NSMetadataQueryDelegate {
    nonisolated func metadataQuery(_ query: NSMetadataQuery, replacementObjectForResultObject result: NSMetadataItem) -> Any {
        return result
    }
}

struct AudioMetadata {
    let title: String?
    let artist: String?
    let album: String?
    let albumArtist: String?
    let genre: String?
    let trackNumber: Int?
    let discNumber: Int?
    let year: Int?
    /// User rating on a 1–5 scale (derived from POPM for MP3s).
    let rating: Int?
    let durationMs: Int?
    let sampleRate: Int?
    let bitDepth: Int?
    let channels: Int?
    let hasEmbeddedArt: Bool
}

class AudioMetadataParser {
    static func parseMetadata(from url: URL) async throws -> AudioMetadata {
        return try await parseAudioMetadataSync(from: url)
    }
    
    private static func parseAudioMetadataSync(from url: URL) async throws -> AudioMetadata {
        let ext = url.pathExtension.lowercased()

        switch ext {
        // Native AVAudioEngine formats
        case "mp3", "wav", "aac":
            return try await parseNativeFormat(url)

        case "m4a":
            return try await parseAacMetadata(url)

        default:
            throw AudioParseError.unsupportedFormat
        }
    }
    
    // MARK: - Rating (POPM / Popularimeter)

    /// Maps a standard 1–5 star rating to the POPM byte (0–255).
    private static func starsToPopmByte(_ stars: Int) -> UInt8? {
        switch stars {
        case 1: return 1
        case 2: return 64
        case 3: return 128
        case 4: return 196
        case 5: return 255
        default: return nil
        }
    }

    /// Maps a POPM byte (0–255) to the nearest 1–5 star rating.
    private static func popmByteToStars(_ byte: UInt8) -> Int? {
        // POPM 0 typically means "no rating".
        guard byte > 0 else { return nil }

        var bestStars: Int?
        var bestDistance = Int.max

        for stars in 1...5 {
            guard let popm = starsToPopmByte(stars) else { continue }
            let distance = abs(Int(byte) - Int(popm))
            if distance < bestDistance {
                bestDistance = distance
                bestStars = stars
            }
        }

        return bestStars
    }

    /// Extracts a POPM rating and converts it to a 1–5 star rating.
    private static func extractPopmRating(from item: AVMetadataItem) async -> Int? {
        if let data = try? await item.load(.dataValue), !data.isEmpty {
            // POPM payload layout: <email>\0<rating byte><4-byte counter>
            if let nulIndex = data.firstIndex(of: 0), nulIndex < data.index(before: data.endIndex) {
                let ratingIndex = data.index(after: nulIndex)
                let popmByte = data[ratingIndex]
                return popmByteToStars(popmByte)
            }

            // Heuristics for unexpected payload layouts.
            if data.count == 1 {
                return popmByteToStars(data[data.startIndex])
            }
            if data.count > 4 {
                // Prefer the byte right before the 4-byte counter.
                let ratingIndex = data.index(data.endIndex, offsetBy: -5)
                return popmByteToStars(data[ratingIndex])
            }

            return popmByteToStars(data[data.startIndex])
        }

        if let number = try? await item.load(.numberValue) {
            return popmByteToStars(UInt8(clamping: number.intValue))
        }

        if let string = try? await item.load(.stringValue), let intValue = Int(string) {
            return popmByteToStars(UInt8(clamping: intValue))
        }

        return nil
    }
    
    private static func parseMp3MetadataSync(from url: URL) async throws -> AudioMetadata {
        print("📖 Reading MP3 metadata for: \(url.lastPathComponent)")
        
        // Use NSFileCoordinator for iCloud files
        let asset: AVURLAsset = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                var error: NSError?
                let coordinator = NSFileCoordinator()
                
                coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { (readingURL) in
                    // Create fresh URL to avoid stale metadata
                    let freshURL = URL(fileURLWithPath: readingURL.path)
                    print("🔄 Using NSFileCoordinator for MP3: \(freshURL.lastPathComponent)")
                    
                    // Check if file actually exists at path
                    guard FileManager.default.fileExists(atPath: freshURL.path) else {
                        continuation.resume(throwing: AudioParseError.fileNotReadable)
                        return
                    }
                    
                    let asset = AVURLAsset(url: freshURL)
                    print("✅ MP3 AVURLAsset created successfully via NSFileCoordinator")
                    continuation.resume(returning: asset)
                }
                
                if let error = error {
                    print("❌ NSFileCoordinator error for MP3: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
        
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var genre: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var rating: Int?
        var hasEmbeddedArt = false
        
        // Parse ID3 metadata using async API
        do {
            let commonMetadata = try await asset.load(.commonMetadata)
            let allMetadata = try await asset.load(.metadata)
            
            // Parse common metadata
            for item in commonMetadata {
                switch item.commonKey {
                case .commonKeyTitle:
                    title = try? await item.load(.stringValue)
                case .commonKeyArtist:
                    artist = try? await item.load(.stringValue)
                    print("🎤 Found artist in common metadata: \(artist ?? "nil")")
                case .commonKeyAlbumName:
                    album = try? await item.load(.stringValue)
                case .commonKeyCreationDate:
                    if let dateString = try? await item.load(.stringValue) {
                        year = Int(String(dateString.prefix(4)))
                    }
                case .commonKeyArtwork:
                    hasEmbeddedArt = true
                default:
                    break
                }
            }
            
            // Check for additional ID3 tags
            for metadata in allMetadata {
                if let key = metadata.commonKey?.rawValue {
                    switch key {
                    case "albumArtist":
                        albumArtist = try? await metadata.load(.stringValue)
                    case "artist":
                        // Additional check for artist in common key
                        if artist == nil {
                            artist = try? await metadata.load(.stringValue)
                            print("🎤 Found artist in additional common key: \(artist ?? "nil")")
                        }
                    default:
                        break
                    }
                } else if let identifier = metadata.identifier {
                    print("🔍 Checking ID3 tag: \(identifier.rawValue)")
                    switch identifier.rawValue {
                    case "id3/TRCK":
                        if let trackString = try? await metadata.load(.stringValue) {
                            trackNumber = Int(trackString.components(separatedBy: "/").first ?? "")
                        }
                    case "id3/TPOS":
                        if let discString = try? await metadata.load(.stringValue) {
                            discNumber = Int(discString.components(separatedBy: "/").first ?? "")
                        }
                    case "id3/TPE2":
                        albumArtist = try? await metadata.load(.stringValue)
                        print("🎤 Found album artist in TPE2: \(albumArtist ?? "nil")")
                    case "id3/TPE1":
                        // Fallback for main artist if not found in common metadata
                        if artist == nil {
                            artist = try? await metadata.load(.stringValue)
                            print("🎤 Found artist in TPE1: \(artist ?? "nil")")
                        }
                    case "id3/TCON":
                        // Genre
                        if genre == nil {
                            genre = try? await metadata.load(.stringValue)
                        }
                    // Add more ID3 artist tag variations
                    case "id3/TIT2":
                        // Title fallback
                        if title == nil {
                            title = try? await metadata.load(.stringValue)
                        }
                    case "id3/TALB":
                        // Album fallback
                        if album == nil {
                            album = try? await metadata.load(.stringValue)
                        }
                    case "id3/POPM":
                        // Popularimeter (rating) frame: map POPM byte (0–255) to 1–5 stars.
                        if rating == nil {
                            rating = await extractPopmRating(from: metadata)
                            if let rating {
                                print("⭐️ Found POPM rating: \(rating)")
                            }
                        }
                    default:
                        // Fallback: check for non-ID3 genre identifiers (e.g., QuickTime/iTunes).
                        if genre == nil && identifier.rawValue.lowercased().contains("genre") {
                            genre = try? await metadata.load(.stringValue)
                        }
                        // Debug: log unhandled tags that might contain artist info
                        if identifier.rawValue.contains("ART") || identifier.rawValue.contains("TPE") {
                            let value = try? await metadata.load(.stringValue)
                            print("🔍 Unhandled artist-related tag \(identifier.rawValue): \(value ?? "nil")")
                        }
                        break
                    }
                }
            }

            // Secondary pass: check genre across key spaces and identifiers.
            genre = await extractGenre(from: allMetadata, current: genre)
        } catch {
            print("Failed to load asset metadata: \(error)")
        }
        
        // Get actual audio format info
        var sampleRate: Int?
        var channels: Int?
        var durationMs: Int?
        
        // Use AVAudioFile to get precise format info
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            
            sampleRate = Int(format.sampleRate)
            channels = Int(format.channelCount)
            
            // Calculate precise duration
            let totalFrames = audioFile.length
            durationMs = Int((Double(totalFrames) / format.sampleRate) * 1000)
            
        } catch {
            // Fallback to AVAsset for duration if AVAudioFile fails
            do {
                let duration = try await asset.load(.duration)
                if duration.isValid && !duration.isIndefinite {
                    durationMs = Int(CMTimeGetSeconds(duration) * 1000)
                }
            } catch {
                print("Failed to load duration: \(error)")
            }
            
            // Use reasonable defaults for format if we can't determine
            sampleRate = sampleRate ?? 44100
            channels = channels ?? 2
        }
        
        // Fallback to filename parsing if no metadata found
        if title == nil {
            let fileName = url.deletingPathExtension().lastPathComponent
            let components = fileName.components(separatedBy: " - ")
            
            if components.count >= 2 {
                artist = artist ?? components[0].trimmingCharacters(in: .whitespaces)
                title = components[1].trimmingCharacters(in: .whitespaces)
            } else {
                title = fileName
            }
        }
        
        print("🎵 Final MP3 metadata for \(url.lastPathComponent):")
        print("   Title: \(title ?? "nil")")
        print("   Artist: \(artist ?? "nil")")
        print("   Album: \(album ?? "nil")")
        print("   Album Artist: \(albumArtist ?? "nil")")
        print("   Genre: \(genre ?? "nil")")
        
        return AudioMetadata(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            genre: genre,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            rating: rating,
            durationMs: durationMs,
            sampleRate: sampleRate,
            bitDepth: nil, // MP3 is lossy, bit depth doesn't apply
            channels: channels,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }

    private static func parseWavMetadataSync(from url: URL) async throws -> AudioMetadata {
        print("📖 Reading WAV metadata for: \(url.lastPathComponent)")

        // For WAV files, use AVAudioFile to get format info and try AVAsset for metadata
        var sampleRate: Int?
        var channels: Int?
        var bitDepth: Int?
        var durationMs: Int?
        var title: String?
        var artist: String?
        var album: String?
        let albumArtist: String? = nil
        var genre: String?
        let trackNumber: Int? = nil
        let discNumber: Int? = nil
        var year: Int?
        var hasEmbeddedArt = false

        // Get audio format info
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat

            sampleRate = Int(format.sampleRate)
            channels = Int(format.channelCount)

            // Calculate duration
            let totalFrames = audioFile.length
            durationMs = Int((Double(totalFrames) / format.sampleRate) * 1000)

            // Try to get bit depth from format settings
            if let settings = audioFile.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int {
                bitDepth = settings
            }
        } catch {
            print("⚠️ Failed to read WAV audio format: \(error)")
        }

        // Try to get metadata from AVAsset (some WAV files may have ID3 tags or other metadata)
        do {
            let asset = AVURLAsset(url: url)
            let commonMetadata = try await asset.load(.commonMetadata)
            let allMetadata = try await asset.load(.metadata)

            for item in commonMetadata {
                switch item.commonKey {
                case .commonKeyTitle:
                    title = try? await item.load(.stringValue)
                case .commonKeyArtist:
                    artist = try? await item.load(.stringValue)
                case .commonKeyAlbumName:
                    album = try? await item.load(.stringValue)
                case .commonKeyCreationDate:
                    if let dateString = try? await item.load(.stringValue) {
                        year = Int(String(dateString.prefix(4)))
                    }
                case .commonKeyArtwork:
                    hasEmbeddedArt = true
                default:
                    break
                }
            }

            // Secondary pass: check genre across key spaces and identifiers.
            genre = await extractGenre(from: allMetadata, current: genre)
        } catch {
            print("⚠️ Failed to read WAV metadata: \(error)")
        }

        // Fallback to filename parsing if no metadata found
        if title == nil {
            let fileName = url.deletingPathExtension().lastPathComponent
            let components = fileName.components(separatedBy: " - ")

            if components.count >= 2 {
                artist = artist ?? components[0].trimmingCharacters(in: .whitespaces)
                title = components[1].trimmingCharacters(in: .whitespaces)
            } else {
                title = fileName
            }
        }

        // Default values for WAV
        sampleRate = sampleRate ?? 44100
        channels = channels ?? 2
        bitDepth = bitDepth ?? 16

        print("🎵 Final WAV metadata for \(url.lastPathComponent):")
        print("   Title: \(title ?? "nil")")
        print("   Artist: \(artist ?? "nil")")
        print("   Genre: \(genre ?? "nil")")
        print("   Sample Rate: \(sampleRate ?? 0) Hz")
        print("   Channels: \(channels ?? 0)")
        print("   Bit Depth: \(bitDepth ?? 0)")

        return AudioMetadata(
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            genre: genre,
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            rating: nil,
            durationMs: durationMs,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            hasEmbeddedArt: hasEmbeddedArt
        )
    }

    // MARK: - New Format Support Methods

    // Unified parser for native formats (routes to existing parsers)
    private static func parseNativeFormat(_ url: URL) async throws -> AudioMetadata {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "mp3":
            return try await parseMp3MetadataSync(from: url)
        case "wav":
            return try await parseWavMetadataSync(from: url)
        case "aac":
            return try await parseAacMetadata(url)
        default:
            throw AudioParseError.unsupportedFormat
        }
    }

    // Parse AAC metadata using native AVFoundation
    private static func parseAacMetadata(_ url: URL) async throws -> AudioMetadata {
        print("📖 Reading AAC metadata for: \(url.lastPathComponent)")

        // Use similar logic to MP3 parsing since AAC can have similar metadata
        return try await parseMp3MetadataSync(from: url)
    }

    private static func normalizeGenre(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // Handle common ID3 numeric wrapping like "(17)".
        if value.hasPrefix("("), value.hasSuffix(")") {
            let inner = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty {
                value = inner
            }
        }

        return value.isEmpty ? nil : value
    }

    private static func isGenreIdentifier(_ identifier: AVMetadataIdentifier) -> Bool {
        let raw = identifier.rawValue.lowercased()
        // Accept explicit genre identifiers and common key spaces used in audio files.
        if raw.contains("genre") {
            return true
        }
        // ID3 TCON is the canonical genre tag for MP3.
        if raw.contains("/tcon") {
            return true
        }
        return false
    }

    private static func extractGenre(from items: [AVMetadataItem], current: String?) async -> String? {
        var genre = normalizeGenre(current)

        for item in items {
            guard genre == nil else { break }
            guard let identifier = item.identifier else { continue }
            guard isGenreIdentifier(identifier) else { continue }

            let value = try? await item.load(.stringValue)
            genre = normalizeGenre(value)
        }

        return genre
    }

    // Simple artwork detection for supported formats (uses AVAsset)
}

enum AudioParseError: Error {
    case invalidFile
    case unsupportedFormat
    case fileNotReadable
    case fileSizeError
}
