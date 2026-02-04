import Foundation
import CryptoKit

enum StableIdGenerator {
    static func fromURL(_ url: URL) -> String {
        let filename = url.lastPathComponent
        return hash(filename)
    }

    private static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: value.data(using: .utf8) ?? Data())
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}
