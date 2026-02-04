import Foundation

/// Centralized file I/O actor to keep synchronous file operations off the main thread.
actor FileIO {
    static let shared = FileIO()

    private let fileManager = FileManager.default

    func fileExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func isReadableFile(_ url: URL) -> Bool {
        fileManager.isReadableFile(atPath: url.path)
    }

    func isWritableFile(_ url: URL) -> Bool {
        fileManager.isWritableFile(atPath: url.path)
    }

    func validateAttributes(_ url: URL) throws {
        _ = try fileManager.attributesOfItem(atPath: url.path)
    }

    func resourceValues(_ url: URL, keys: Set<URLResourceKey>) throws -> URLResourceValues {
        try url.resourceValues(forKeys: keys)
    }

    func isUbiquitousItem(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey])
        return values.isUbiquitousItem ?? false
    }

    func ubiquitousItemDownloadingStatus(_ url: URL) throws -> URLUbiquitousItemDownloadingStatus? {
        let values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        return values.ubiquitousItemDownloadingStatus
    }

    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]? = nil) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
    }

    func readData(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }

    func writeDataAtomic(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    func replaceItem(at url: URL, withItemAt tmpURL: URL) throws {
        var resultingURL: NSURL?
        _ = try fileManager.replaceItem(at: url, withItemAt: tmpURL, backupItemName: nil, options: [], resultingItemURL: &resultingURL)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]? = nil) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories, attributes: attributes)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try fileManager.moveItem(at: srcURL, to: dstURL)
    }

    func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try fileManager.copyItem(at: srcURL, to: dstURL)
    }

    func startDownloadingUbiquitousItem(at url: URL) throws {
        try fileManager.startDownloadingUbiquitousItem(at: url)
    }
}
