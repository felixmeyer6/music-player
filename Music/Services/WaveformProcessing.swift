import Foundation
import AVFoundation
import Accelerate

enum WaveformProcessing {
    static let barsPerMinute = 50
    private static let blobMagic: [UInt8] = [0x57, 0x46, 0x42, 0x31] // "WFB1"
    private static let blobVersion: UInt8 = 1
    private static let headerSize = 32
    private static let analysisVersion = 4

    struct Meta: Equatable {
        let totalBars: Int
        let fileSize: Int64
        let contentModificationTime: TimeInterval
        let version: Int
    }

    struct DecodedPayload {
        let bars: [Float]
        let meta: Meta
    }

    static func barsCount(forDurationMs ms: Int?) -> Int {
        guard let ms, ms > 0 else { return 50 }
        let minutes = Double(ms) / 60_000.0
        return max(20, Int(ceil(minutes * Double(barsPerMinute))))
    }

    static func makeMeta(totalBars: Int, fileSize: Int64, contentModificationTime: TimeInterval) -> Meta {
        Meta(
            totalBars: totalBars,
            fileSize: fileSize,
            contentModificationTime: contentModificationTime,
            version: analysisVersion
        )
    }

    static func matches(_ waveformData: Data?, meta: Meta) -> Bool {
        guard let waveformData,
              let decodedMeta = decodeBinaryPayload(from: waveformData)?.meta else {
            return false
        }

        guard decodedMeta.totalBars == meta.totalBars,
              decodedMeta.fileSize == meta.fileSize,
              decodedMeta.version == meta.version else {
            return false
        }

        return abs(decodedMeta.contentModificationTime - meta.contentModificationTime) < 1.0
    }

    static func decodeBars(from waveformData: Data?, totalBars: Int) -> [Float]? {
        guard totalBars > 0, let waveformData else { return nil }
        guard let decoded = decodeWaveformPayload(from: waveformData) else { return nil }

        let resampled = resampleBars(decoded.bars, totalBars: totalBars)
        guard !resampled.isEmpty else { return nil }
        return normalizeBars(resampled)
    }

    static func decodePayload(from waveformData: Data?) -> DecodedPayload? {
        guard let waveformData else { return nil }
        return decodeWaveformPayload(from: waveformData)
    }

    static func encode(meta: Meta, bars: [Float]) -> Data? {
        guard !bars.isEmpty else { return nil }
        let quantized = quantizeBars(bars)
        guard !quantized.isEmpty else { return nil }

        var data = Data(capacity: headerSize + quantized.count)
        data.append(contentsOf: blobMagic)
        data.append(blobVersion)
        data.append(contentsOf: [0, 0, 0])
        data.appendUInt32(UInt32(meta.totalBars))
        data.appendInt64(meta.fileSize)
        data.appendDouble(meta.contentModificationTime)
        data.appendUInt32(UInt32(meta.version))
        data.append(contentsOf: quantized)
        return data
    }

    static func buildWaveformData(for url: URL, totalBars: Int, meta: Meta) async -> Data? {
        guard totalBars > 0 else { return nil }

        let bars = await analyzeWaveformBars(for: url, totalBars: totalBars)
        guard !bars.isEmpty else { return nil }

        let alignedBars = bars.count == totalBars ? bars : resampleBars(bars, totalBars: totalBars)
        return encode(meta: meta, bars: alignedBars)
    }

    static func analyzeWaveformBars(for url: URL, totalBars: Int) async -> [Float] {
        guard totalBars > 0 else { return [] }

        let asset = AVURLAsset(url: url)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            return []
        }

        let duration = try? await asset.load(.duration)
        let durationSeconds = duration.map { CMTimeGetSeconds($0) } ?? 0
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return []
        }

        let decodeSampleRate: Double = 11_025
        let estimatedFrames = max(1, Int(durationSeconds * decodeSampleRate))
        let framesPerBar = max(1, estimatedFrames / totalBars)

        let targetSampleCount = max(totalBars * 32, 1024)
        let stride = max(1, estimatedFrames / targetSampleCount)

        do {
            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: decodeSampleRate,
                AVLinearPCMIsBigEndianKey: false
            ]

            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false

            guard reader.canAdd(output) else { return [] }
            reader.add(output)

            guard reader.startReading() else { return [] }

            var barPeaks = [Float](repeating: 0, count: totalBars)
            var runningFrameIndex = 0

            while reader.status == .reading {
                guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

                var totalLength = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(
                    blockBuffer,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &totalLength,
                    dataPointerOut: &dataPointer
                )

                guard status == kCMBlockBufferNoErr,
                      let dataPointer else { continue }

                let sampleCount = totalLength / MemoryLayout<Float>.size
                if sampleCount == 0 { continue }

                let floatPointer = dataPointer.withMemoryRebound(to: Float.self, capacity: sampleCount) { $0 }
                var absSamples = [Float](repeating: 0, count: sampleCount)
                vDSP_vabs(floatPointer, 1, &absSamples, 1, vDSP_Length(sampleCount))

                var idx = 0
                while idx < sampleCount {
                    let globalFrame = runningFrameIndex + idx
                    let barIndex = min(totalBars - 1, globalFrame / framesPerBar)
                    let value = absSamples[idx]
                    if value > barPeaks[barIndex] {
                        barPeaks[barIndex] = value
                    }
                    idx += stride
                }

                runningFrameIndex += sampleCount
            }

            if reader.status == .failed {
                print("⚠️ AVAssetReader failed for \(url.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error")")
                return []
            }

            return normalizeBars(barPeaks)
        } catch {
            print("⚠️ Waveform analysis failed for \(url.lastPathComponent): \(error)")
            return []
        }
    }

    static func normalizeBars(_ bars: [Float]) -> [Float] {
        let maxAmp = bars.max() ?? 0
        if maxAmp > 0 {
            return bars.map { $0 / maxAmp }
        }
        return bars
    }

    static func resampleBars(_ bars: [Float], totalBars: Int) -> [Float] {
        guard totalBars > 0 else { return [] }
        guard !bars.isEmpty else { return [] }
        if bars.count == totalBars { return bars }
        if bars.count == 1 {
            return Array(repeating: bars[0], count: totalBars)
        }

        return (0..<totalBars).map { i in
            let t = Double(i) / Double(max(1, totalBars - 1))
            let idx = Int(round(t * Double(bars.count - 1)))
            return bars[min(max(0, idx), bars.count - 1)]
        }
    }

    private static func decodeWaveformPayload(from waveformData: Data) -> DecodedPayload? {
        guard let decoded = decodeBinaryPayload(from: waveformData) else { return nil }
        return DecodedPayload(bars: decoded.bars, meta: decoded.meta)
    }

    private static func decodeBinaryPayload(from waveformData: Data) -> (meta: Meta, bars: [Float])? {
        guard waveformData.count >= headerSize else { return nil }
        guard waveformData.prefix(4).elementsEqual(blobMagic) else { return nil }
        let versionByte = waveformData[4]
        guard versionByte == blobVersion else { return nil }

        guard let totalBars = readUInt32(from: waveformData, offset: 8),
              let fileSize = readInt64(from: waveformData, offset: 12),
              let modificationTime = readDouble(from: waveformData, offset: 20),
              let analysisVersionValue = readUInt32(from: waveformData, offset: 28) else {
            return nil
        }

        let barsData = waveformData.suffix(from: headerSize)
        guard !barsData.isEmpty else { return nil }

        let bars = barsData.map { Float($0) / 255.0 }
        let meta = Meta(
            totalBars: Int(totalBars),
            fileSize: fileSize,
            contentModificationTime: modificationTime,
            version: Int(analysisVersionValue)
        )

        return (meta: meta, bars: bars)
    }

    private static func quantizeBars(_ bars: [Float]) -> [UInt8] {
        bars.map { value in
            let clamped = min(max(value, 0), 1)
            return UInt8((clamped * 255).rounded())
        }
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[offset + i]) << (8 * i)
        }
        return value
    }

    private static func readUInt64(from data: Data, offset: Int) -> UInt64? {
        guard offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[offset + i]) << (8 * i)
        }
        return value
    }

    private static func readInt64(from data: Data, offset: Int) -> Int64? {
        guard let value = readUInt64(from: data, offset: offset) else { return nil }
        return Int64(bitPattern: value)
    }

    private static func readDouble(from data: Data, offset: Int) -> Double? {
        guard let value = readUInt64(from: data, offset: offset) else { return nil }
        return Double(bitPattern: value)
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(contentsOf: buffer)
        }
    }

    mutating func appendInt64(_ value: Int64) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(contentsOf: buffer)
        }
    }

    mutating func appendDouble(_ value: Double) {
        var littleEndian = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(contentsOf: buffer)
        }
    }
}
