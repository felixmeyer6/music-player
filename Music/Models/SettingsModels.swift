import Foundation
import SwiftUI
import UIKit

struct DeleteSettings: Codable {
    var minimalistIcons: Bool = false
    var forceDarkMode: Bool = false
    var lastLibraryScanDate: Date? = nil
    var crossfadeEnabled: Bool = false
    var crossfadeDuration: Double = 2.0

    static func load() -> DeleteSettings {
        guard let data = UserDefaults.standard.data(forKey: "DeleteSettings"),
              let settings = try? JSONDecoder().decode(DeleteSettings.self, from: data) else {
            return DeleteSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "DeleteSettings")
        }
    }
}

struct WeightedShuffleSettings: Codable {
    var isEnabled: Bool = false
    var ratingWeights: [Double] = [0.2, 0.4, 0.6, 0.8, 1.0]

    static func load() -> WeightedShuffleSettings {
        guard let data = UserDefaults.standard.data(forKey: "WeightedShuffleSettings"),
              let settings = try? JSONDecoder().decode(WeightedShuffleSettings.self, from: data) else {
            return WeightedShuffleSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "WeightedShuffleSettings")
        }
    }
}

// MARK: - Dominant Color Extraction
extension UIImage {
    func dominantColor() -> Color {
        // Downscale image for faster processing
        let targetSize = CGSize(width: 50, height: 50)
        UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        self.draw(in: CGRect(origin: .zero, size: targetSize))
        guard let scaledImage = UIGraphicsGetImageFromCurrentImageContext(),
              let cgImage = scaledImage.cgImage else {
            return .white
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8

        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return .white
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Collect vibrant colors with their saturation scores
        var colorCandidates: [(hue: CGFloat, saturation: CGFloat, brightness: CGFloat, score: CGFloat)] = []

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * bytesPerPixel
                let r = CGFloat(pixelData[offset]) / 255.0
                let g = CGFloat(pixelData[offset + 1]) / 255.0
                let b = CGFloat(pixelData[offset + 2]) / 255.0

                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 1

                UIColor(red: r, green: g, blue: b, alpha: 1.0)
                    .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

                // Skip very dark, very light, or desaturated colors
                guard saturation > 0.15 && brightness > 0.15 && brightness < 0.95 else { continue }

                // Score based on saturation and how "colorful" it is
                // Prefer saturated colors that aren't too dark or too bright
                let brightnessScore = 1.0 - abs(brightness - 0.6) // Prefer mid-brightness
                let score = saturation * 0.7 + brightnessScore * 0.3

                colorCandidates.append((hue: hue, saturation: saturation, brightness: brightness, score: score))
            }
        }

        // If no vibrant colors found, return white as last resort
        guard !colorCandidates.isEmpty else {
            return .white
        }

        // Group similar hues and find the most vibrant cluster
        // Quantize hues into 12 buckets (like a color wheel)
        var hueBuckets: [Int: [(saturation: CGFloat, brightness: CGFloat, score: CGFloat)]] = [:]

        for candidate in colorCandidates {
            let bucketIndex = Int(candidate.hue * 12) % 12
            if hueBuckets[bucketIndex] == nil {
                hueBuckets[bucketIndex] = []
            }
            hueBuckets[bucketIndex]?.append((candidate.saturation, candidate.brightness, candidate.score))
        }

        // Find the bucket with the highest total score (vibrant and common)
        var bestBucket = -1
        var bestBucketScore: CGFloat = 0

        for (bucket, colors) in hueBuckets {
            let totalScore = colors.reduce(0) { $0 + $1.score }
            // Weight by both total score and count to prefer common vibrant colors
            let weightedScore = totalScore * sqrt(CGFloat(colors.count))
            if weightedScore > bestBucketScore {
                bestBucketScore = weightedScore
                bestBucket = bucket
            }
        }

        guard bestBucket >= 0, let bestColors = hueBuckets[bestBucket] else {
            return .white
        }

        // Get the average of the best bucket's colors
        let avgSaturation = bestColors.reduce(0) { $0 + $1.saturation } / CGFloat(bestColors.count)
        let avgBrightness = bestColors.reduce(0) { $0 + $1.brightness } / CGFloat(bestColors.count)
        let hue = (CGFloat(bestBucket) + 0.5) / 12.0

        // Boost saturation and ensure good visibility
        let finalSaturation = min(avgSaturation * 1.2, 1.0)
        let finalBrightness = max(min(avgBrightness * 1.1, 0.9), 0.5)

        return Color(UIColor(hue: hue, saturation: finalSaturation, brightness: finalBrightness, alpha: 1.0))
    }

    func dominantColorAsync() async -> Color {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let color = self.dominantColor()
                continuation.resume(returning: color)
            }
        }
    }
}
