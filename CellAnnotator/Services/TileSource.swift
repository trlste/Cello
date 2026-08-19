//
//  TileSource.swift
//  CellAnnotator
//

import CoreGraphics
import CoreImage
import Compression
import Foundation
import ImageIO

protocol TileSource: AnyObject, Sendable {
    var index: TIFFImageIndex { get }
    var preferredTileSize: Int { get }

    func bestAvailableLevel(
        forLevelZeroPixelsPerOutputPixel desired: Double,
        channels: [Int],
        z: Int,
        time: Int
    ) -> TIFFResolution

    /// `pixelRect` is expressed in pixels of `coordinate.level`, never in TIFF
    /// page numbers or byte offsets.
    func tile(
        at coordinate: TIFFPlaneCoordinate,
        pixelRect: CGRect
    ) async throws -> CGImage
}

enum TileSourceError: LocalizedError {
    case missingPlane(TIFFPlaneCoordinate)
    case unsupportedSubIFD(TIFFPlaneCoordinate)
    case decodeFailed
    case emptyRegion

    var errorDescription: String? {
        switch self {
        case .missingPlane: return "The requested channel/Z/time/level plane is not present."
        case .unsupportedSubIFD: return "This TIFF plane uses a tile format that is not supported yet."
        case .decodeFailed: return "The requested TIFF tile could not be decoded."
        case .emptyRegion: return "The requested tile does not intersect the image."
        }
    }
}

/// Hybrid tile backend. Tiled, integer TIFF planes are decoded directly from
/// their compressed tile byte ranges. Small ordinary pages retain a bounded
/// ImageIO fallback; WSI-sized pages are never materialized just to crop them.
final class ImageIOTileSource: TileSource, @unchecked Sendable {
    let index: TIFFImageIndex
    let preferredTileSize: Int

    private let resource: SecurityScopedTIFFResource
    private let ifdByOffset: [UInt64: TIFFIFD]
    private let cache = NSCache<TileCacheKey, CGImageBox>()
    /// Two serial actor lanes bound decompression concurrency while preserving
    /// Swift task cancellation. Unlike OperationQueue jobs, cancelled requests
    /// waiting for a lane can exit before touching the TIFF file.
    private let decodeLanes = [TileDecodeLane(), TileDecodeLane()]

    init(resource: SecurityScopedTIFFResource, index: TIFFImageIndex) {
        self.resource = resource
        self.index = index
        ifdByOffset = Dictionary(uniqueKeysWithValues: index.ifds.map { ($0.offset, $0) })
        preferredTileSize = index.ifds.compactMap { ifd in
            guard ifd.isTiled, let width = ifd.tileWidth, let height = ifd.tileHeight else {
                return nil
            }
            return max(128, min(512, min(width, height)))
        }.min() ?? 512
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 384
    }

    func bestAvailableLevel(
        forLevelZeroPixelsPerOutputPixel desired: Double,
        channels: [Int],
        z: Int,
        time: Int
    ) -> TIFFResolution {
        let requestedChannels = channels.isEmpty ? [0] : channels
        let available = index.resolutions.filter { resolution in
            requestedChannels.allSatisfy { channel in
                guard let plane = index.plane(at: TIFFPlaneCoordinate(
                    channel: channel, z: z, time: time, level: resolution.level
                )) else { return false }
                let boundedImageIOFallback = plane.imageSourceIndex != nil
                    && plane.pixelWidth * plane.pixelHeight <= 40_000_000
                return boundedImageIOFallback || directlyDecodableIFD(for: plane) != nil
            }
        }
        let candidates = available.isEmpty ? [index.resolutions.first].compactMap { $0 } : available
        let target = max(1, desired)
        // Never select a level that contains fewer source pixels than the
        // display can show. Among sufficiently detailed levels, use the
        // coarsest one to minimize decoding work. This produces predictable
        // transitions at the actual pyramid downsample boundaries while the
        // user zooms in.
        let sufficientlyDetailed = candidates.filter {
            max($0.downsampleX, $0.downsampleY) <= target
        }
        return sufficientlyDetailed.max {
            max($0.downsampleX, $0.downsampleY) < max($1.downsampleX, $1.downsampleY)
        } ?? candidates.min {
            max($0.downsampleX, $0.downsampleY) < max($1.downsampleX, $1.downsampleY)
        } ?? index.bestLevel(forLevelZeroPixelsPerOutputPixel: desired)
    }

    func tile(at coordinate: TIFFPlaneCoordinate, pixelRect: CGRect) async throws -> CGImage {
        try Task.checkCancellation()
        let integralRect = pixelRect.integral
        let key = TileCacheKey(coordinate: coordinate, rect: integralRect)
        if let cached = cache.object(forKey: key)?.image { return cached }

        // Spatially distribute neighboring requests across two serial lanes.
        // Obsolete zoom requests retain their cancellation state while waiting
        // and are rejected by the lane before expensive decompression begins.
        let tileX = Int(integralRect.minX) / max(1, preferredTileSize)
        let tileY = Int(integralRect.minY) / max(1, preferredTileSize)
        let laneIndex = (coordinate.channel + coordinate.level + tileX + tileY) & 1
        let decoded = try await decodeLanes[laneIndex].run { [self] in
            try decode(coordinate: coordinate, rect: integralRect)
        }
        let image = decoded.image
        let cost = image.bytesPerRow * image.height
        cache.setObject(decoded, forKey: key, cost: cost)
        try Task.checkCancellation()
        return image
    }

    private func decode(coordinate: TIFFPlaneCoordinate, rect: CGRect) throws -> CGImage {
        guard let plane = index.plane(at: coordinate) else {
            throw TileSourceError.missingPlane(coordinate)
        }
        if let ifd = directlyDecodableIFD(for: plane) {
            return try DirectTIFFTileDecoder.decodeRegion(
                url: resource.url,
                ifd: ifd,
                byteOrder: index.byteOrder,
                rect: rect
            )
        }
        guard let sourceIndex = plane.imageSourceIndex else {
            throw TileSourceError.unsupportedSubIFD(coordinate)
        }
        // ImageIO materializes the complete page before CGImage cropping. Do
        // not allow that fallback for WSI-sized pages.
        guard plane.pixelWidth * plane.pixelHeight <= 40_000_000 else {
            throw TileSourceError.unsupportedSubIFD(coordinate)
        }
        guard let source = CGImageSourceCreateWithURL(resource.url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary),
              let page = CGImageSourceCreateImageAtIndex(source, sourceIndex, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary) else {
            throw TileSourceError.decodeFailed
        }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(page.width), height: CGFloat(page.height))
        let clipped = rect.intersection(bounds).integral
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            throw TileSourceError.emptyRegion
        }
        guard let cropped = page.cropping(to: clipped) else {
            throw TileSourceError.decodeFailed
        }
        return cropped
    }

    private func directlyDecodableIFD(for plane: TIFFPlane) -> TIFFIFD? {
        guard let ifd = ifdByOffset[plane.ifdOffset],
              DirectTIFFTileDecoder.canDecode(ifd) else { return nil }
        return ifd
    }
}

/// A synchronous decode section isolated behind an actor. Calls queue at the
/// actor boundary, where cancellation can be observed before they start. Once
/// decompression has begun it runs to completion, but at most two such sections
/// can exist for one document.
private actor TileDecodeLane {
    func run(
        _ operation: @Sendable () throws -> CGImage
    ) throws -> CGImageBox {
        try Task.checkCancellation()
        return try autoreleasepool {
            CGImageBox(try operation())
        }
    }
}

private enum DirectTIFFTileDecoder {
    static func canDecode(_ ifd: TIFFIFD) -> Bool {
        guard ifd.isTiled,
              ifd.orientation == 1,
              (ifd.planarConfiguration ?? 1) == 1,
              (ifd.sampleFormat ?? 1) == 1,
              ifd.predictor == 1 || ifd.predictor == 2,
              (ifd.compression ?? 1) == 1
                || ifd.compression == 5
                || ifd.compression == 8
                || ifd.compression == 32946,
              ifd.samplesPerPixel == 1 || ifd.samplesPerPixel == 3 else {
            return false
        }
        let bits = ifd.bitsPerSample.isEmpty ? [8] : ifd.bitsPerSample
        return bits.allSatisfy { $0 == bits[0] }
            && (bits[0] == 8 || bits[0] == 16)
    }

    static func decodeRegion(
        url: URL,
        ifd: TIFFIFD,
        byteOrder: TIFFByteOrder,
        rect: CGRect
    ) throws -> CGImage {
        guard canDecode(ifd),
              let tileWidth = ifd.tileWidth,
              let tileHeight = ifd.tileHeight else {
            throw TileSourceError.decodeFailed
        }
        let bounds = CGRect(x: 0, y: 0, width: ifd.pixelWidth, height: ifd.pixelHeight)
        let clipped = rect.integral.intersection(bounds).integral
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            throw TileSourceError.emptyRegion
        }

        let bitsPerSample = ifd.bitsPerSample.first ?? 8
        let bytesPerSample = bitsPerSample / 8
        let samplesPerPixel = ifd.samplesPerPixel
        let bytesPerPixel = bytesPerSample * samplesPerPixel
        let outputWidth = Int(clipped.width)
        let outputHeight = Int(clipped.height)
        let outputBytesPerRow = outputWidth * bytesPerPixel
        var output = Data(count: outputBytesPerRow * outputHeight)
        let tilesAcross = (ifd.pixelWidth + tileWidth - 1) / tileWidth
        let firstColumn = Int(clipped.minX) / tileWidth
        let lastColumn = (Int(clipped.maxX) - 1) / tileWidth
        let firstRow = Int(clipped.minY) / tileHeight
        let lastRow = (Int(clipped.maxY) - 1) / tileHeight

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        for tileRow in firstRow...lastRow {
            for tileColumn in firstColumn...lastColumn {
                let tileIndex = tileRow * tilesAcross + tileColumn
                guard ifd.tileOffsets.indices.contains(tileIndex),
                      ifd.tileByteCounts.indices.contains(tileIndex),
                      ifd.tileByteCounts[tileIndex] <= UInt64(Int.max) else {
                    throw TileSourceError.decodeFailed
                }
                let compressedCount = Int(ifd.tileByteCounts[tileIndex])
                try handle.seek(toOffset: ifd.tileOffsets[tileIndex])
                guard let compressed = try handle.read(upToCount: compressedCount),
                      compressed.count == compressedCount else {
                    throw TileSourceError.decodeFailed
                }

                let decodedByteCount = tileWidth * tileHeight * bytesPerPixel
                var tile = try decompress(
                    compressed,
                    compression: ifd.compression ?? 1,
                    expectedByteCount: decodedByteCount
                )
                if ifd.predictor == 2 {
                    reverseHorizontalPredictor(
                        in: &tile,
                        width: tileWidth,
                        height: tileHeight,
                        samplesPerPixel: samplesPerPixel,
                        bitsPerSample: bitsPerSample,
                        byteOrder: byteOrder
                    )
                }
                if ifd.photometricInterpretation == 0 {
                    invertGrayscale(
                        in: &tile,
                        bitsPerSample: bitsPerSample,
                        byteOrder: byteOrder
                    )
                }

                let tileBounds = CGRect(
                    x: tileColumn * tileWidth,
                    y: tileRow * tileHeight,
                    width: tileWidth,
                    height: tileHeight
                )
                let overlap = clipped.intersection(tileBounds).integral
                guard !overlap.isNull else { continue }
                let copyWidthBytes = Int(overlap.width) * bytesPerPixel
                let sourceX = Int(overlap.minX - tileBounds.minX)
                let sourceY = Int(overlap.minY - tileBounds.minY)
                let destinationX = Int(overlap.minX - clipped.minX)
                let destinationY = Int(overlap.minY - clipped.minY)

                output.withUnsafeMutableBytes { destinationBytes in
                    tile.withUnsafeBytes { sourceBytes in
                        for row in 0..<Int(overlap.height) {
                            let sourceOffset = ((sourceY + row) * tileWidth + sourceX) * bytesPerPixel
                            let destinationOffset = (destinationY + row) * outputBytesPerRow
                                + destinationX * bytesPerPixel
                            let sourceSlice = UnsafeRawBufferPointer(
                                rebasing: sourceBytes[sourceOffset..<(sourceOffset + copyWidthBytes)]
                            )
                            let destinationSlice = UnsafeMutableRawBufferPointer(
                                rebasing: destinationBytes[destinationOffset..<(destinationOffset + copyWidthBytes)]
                            )
                            destinationSlice.copyMemory(from: sourceSlice)
                        }
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: output as CFData) else {
            throw TileSourceError.decodeFailed
        }
        let colorSpace = samplesPerPixel == 1
            ? CGColorSpaceCreateDeviceGray()
            : CGColorSpaceCreateDeviceRGB()
        var bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        if bitsPerSample == 16 {
            bitmapInfo.insert(byteOrder == .littleEndian ? .byteOrder16Little : .byteOrder16Big)
        }
        guard let image = CGImage(
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: bitsPerSample,
            bitsPerPixel: bitsPerSample * samplesPerPixel,
            bytesPerRow: outputBytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw TileSourceError.decodeFailed
        }
        return image
    }

    private static func decompress(
        _ compressed: Data,
        compression: Int,
        expectedByteCount: Int
    ) throws -> Data {
        guard expectedByteCount > 0 else { throw TileSourceError.decodeFailed }
        switch compression {
        case 1:
            guard compressed.count >= expectedByteCount else {
                throw TileSourceError.decodeFailed
            }
            return Data(compressed.prefix(expectedByteCount))
        case 5:
            return try decompressTIFFLZW(
                compressed,
                expectedByteCount: expectedByteCount
            )
        case 8, 32946:
            break
        default:
            throw TileSourceError.decodeFailed
        }

        var decoded = Data(count: expectedByteCount)
        let written = decoded.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    expectedByteCount,
                    sourceBase,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedByteCount else { throw TileSourceError.decodeFailed }
        return decoded
    }

    /// Decodes the TIFF 6.0 LZW variant. TIFF packs codes most-significant-bit
    /// first and uses the "early change" rule: the code width increases one
    /// entry before the dictionary reaches the next power of two.
    private static func decompressTIFFLZW(
        _ compressed: Data,
        expectedByteCount: Int
    ) throws -> Data {
        let clearCode = 256
        let endOfInformationCode = 257
        let firstDictionaryCode = 258
        let maximumCodeCount = 4096

        // Prefix/suffix storage keeps the decoder bounded to a few small
        // fixed-size arrays instead of retaining thousands of expanded byte
        // strings for every concurrently decoded tile.
        var prefixes = [Int](repeating: -1, count: maximumCodeCount)
        var suffixes = [UInt8](repeating: 0, count: maximumCodeCount)
        for code in 0..<256 { suffixes[code] = UInt8(code) }

        func expand(_ code: Int, nextCode: Int) throws -> [UInt8] {
            guard code >= 0, code < nextCode else { throw TileSourceError.decodeFailed }
            var reversed: [UInt8] = []
            reversed.reserveCapacity(64)
            var current = code
            var visited = 0
            while current >= 256 {
                guard current < nextCode,
                      prefixes[current] >= 0,
                      visited < maximumCodeCount else {
                    throw TileSourceError.decodeFailed
                }
                reversed.append(suffixes[current])
                current = prefixes[current]
                visited += 1
            }
            reversed.append(UInt8(current))
            return Array(reversed.reversed())
        }

        var reader = MSBBitReader(data: compressed)
        var codeWidth = 9
        var nextCode = firstDictionaryCode
        var previousCode: Int?
        var output: [UInt8] = []
        output.reserveCapacity(expectedByteCount)

        while output.count < expectedByteCount,
              let code = reader.readBits(count: codeWidth) {
            if code == clearCode {
                codeWidth = 9
                nextCode = firstDictionaryCode
                previousCode = nil
                continue
            }
            if code == endOfInformationCode { break }

            let entry: [UInt8]
            if code < nextCode {
                entry = try expand(code, nextCode: nextCode)
            } else if code == nextCode,
                      let previousCode {
                let previous = try expand(previousCode, nextCode: nextCode)
                guard let first = previous.first else {
                    throw TileSourceError.decodeFailed
                }
                entry = previous + [first]
            } else {
                throw TileSourceError.decodeFailed
            }

            output.append(contentsOf: entry)

            if let previousCode,
               let first = entry.first,
               nextCode < maximumCodeCount {
                prefixes[nextCode] = previousCode
                suffixes[nextCode] = first
                nextCode += 1
                if codeWidth < 12, nextCode == (1 << codeWidth) - 1 {
                    codeWidth += 1
                }
            }
            previousCode = code
        }

        guard output.count >= expectedByteCount else {
            throw TileSourceError.decodeFailed
        }
        return Data(output.prefix(expectedByteCount))
    }

    private struct MSBBitReader {
        let bytes: [UInt8]
        var bitOffset = 0

        init(data: Data) {
            bytes = Array(data)
        }

        mutating func readBits(count: Int) -> Int? {
            guard count > 0, bitOffset + count <= bytes.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                let byteIndex = bitOffset / 8
                let bitIndex = 7 - (bitOffset % 8)
                value = (value << 1) | Int((bytes[byteIndex] >> bitIndex) & 1)
                bitOffset += 1
            }
            return value
        }
    }

    private static func reverseHorizontalPredictor(
        in data: inout Data,
        width: Int,
        height: Int,
        samplesPerPixel: Int,
        bitsPerSample: Int,
        byteOrder: TIFFByteOrder
    ) {
        data.withUnsafeMutableBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            if bitsPerSample == 8 {
                let rowSamples = width * samplesPerPixel
                for row in 0..<height {
                    let rowStart = row * rowSamples
                    for sample in samplesPerPixel..<rowSamples {
                        bytes[rowStart + sample] = bytes[rowStart + sample]
                            &+ bytes[rowStart + sample - samplesPerPixel]
                    }
                }
                return
            }

            let rowBytes = width * samplesPerPixel * 2
            for row in 0..<height {
                let rowStart = row * rowBytes
                for sample in samplesPerPixel..<(width * samplesPerPixel) {
                    let position = rowStart + sample * 2
                    let previousPosition = position - samplesPerPixel * 2
                    let value = readUInt16(bytes, at: position, byteOrder: byteOrder)
                    let previous = readUInt16(bytes, at: previousPosition, byteOrder: byteOrder)
                    writeUInt16(value &+ previous, to: bytes, at: position, byteOrder: byteOrder)
                }
            }
        }
    }

    private static func invertGrayscale(
        in data: inout Data,
        bitsPerSample: Int,
        byteOrder: TIFFByteOrder
    ) {
        data.withUnsafeMutableBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            if bitsPerSample == 8 {
                for index in bytes.indices { bytes[index] = 255 &- bytes[index] }
                return
            }
            for position in stride(from: 0, to: bytes.count, by: 2) {
                let value = readUInt16(bytes, at: position, byteOrder: byteOrder)
                writeUInt16(UInt16.max &- value, to: bytes, at: position, byteOrder: byteOrder)
            }
        }
    }

    private static func readUInt16(
        _ bytes: UnsafeMutableBufferPointer<UInt8>,
        at position: Int,
        byteOrder: TIFFByteOrder
    ) -> UInt16 {
        let first = UInt16(bytes[position])
        let second = UInt16(bytes[position + 1])
        return byteOrder == .littleEndian
            ? first | (second << 8)
            : (first << 8) | second
    }

    private static func writeUInt16(
        _ value: UInt16,
        to bytes: UnsafeMutableBufferPointer<UInt8>,
        at position: Int,
        byteOrder: TIFFByteOrder
    ) {
        if byteOrder == .littleEndian {
            bytes[position] = UInt8(value & 0xff)
            bytes[position + 1] = UInt8(value >> 8)
        } else {
            bytes[position] = UInt8(value >> 8)
            bytes[position + 1] = UInt8(value & 0xff)
        }
    }
}

actor TileCompositor {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func compositeTile(
        source: TileSource,
        level: Int,
        z: Int,
        time: Int,
        pixelRect: CGRect,
        settings: [ChannelDisplaySettings]
    ) async throws -> CGImage {
        try Task.checkCancellation()
        let visible = settings.filter(\.isVisible)
        let extent = CGRect(origin: .zero, size: pixelRect.size)
        var output = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: extent)

        for setting in visible {
            // Slider movement creates a new display revision and cancels work
            // for the old one. Multi-channel composites must observe that
            // cancellation between source planes instead of finishing every
            // channel for a tile whose result will be discarded.
            try Task.checkCancellation()
            let coordinate = TIFFPlaneCoordinate(
                channel: setting.sourceChannelIndex,
                z: z,
                time: time,
                level: level
            )
            let image = try await source.tile(at: coordinate, pixelRect: pixelRect)
            try Task.checkCancellation()
            var channelImage = CIImage(cgImage: image).cropped(to: extent)
            let preserveRGB = setting.sampleIndex == nil
                && (source.index.channels.first?.samplesPerPixel ?? 1) > 1
            channelImage = adjusted(
                channelImage,
                setting: setting,
                preserveRGB: preserveRGB
            )
            output = channelImage.applyingFilter(
                "CIAdditionCompositing",
                parameters: [kCIInputBackgroundImageKey: output]
            ).cropped(to: extent)
        }

        try Task.checkCancellation()
        guard let rendered = context.createCGImage(output, from: extent) else {
            throw TileSourceError.decodeFailed
        }
        return rendered
    }

    private func adjusted(
        _ input: CIImage,
        setting: ChannelDisplaySettings,
        preserveRGB: Bool
    ) -> CIImage {
        var input = input
        if let sampleIndex = setting.sampleIndex {
            input = extractingSample(sampleIndex, from: input)
        }
        let range = max(0.000_001, setting.whitePoint - setting.blackPoint)
        let scale = 1 / range
        var image = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(scale), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: CGFloat(-setting.blackPoint * scale),
                                         y: CGFloat(-setting.blackPoint * scale),
                                         z: CGFloat(-setting.blackPoint * scale),
                                         w: 0)
        ])
        image = image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
        ])
        image = image.applyingFilter("CIGammaAdjust", parameters: [
            "inputPower": 1 / max(0.05, setting.gamma)
        ])

        if preserveRGB {
            let opacity = CGFloat(setting.opacity)
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: opacity, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: opacity, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: opacity, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])
        }

        let color = setting.color
        let opacity = setting.opacity
        let luminance = (red: 0.299, green: 0.587, blue: 0.114)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(luminance.red * color.red * opacity),
                                      y: CGFloat(luminance.green * color.red * opacity),
                                      z: CGFloat(luminance.blue * color.red * opacity), w: 0),
            "inputGVector": CIVector(x: CGFloat(luminance.red * color.green * opacity),
                                      y: CGFloat(luminance.green * color.green * opacity),
                                      z: CGFloat(luminance.blue * color.green * opacity), w: 0),
            "inputBVector": CIVector(x: CGFloat(luminance.red * color.blue * opacity),
                                      y: CGFloat(luminance.green * color.blue * opacity),
                                      z: CGFloat(luminance.blue * color.blue * opacity), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }

    private func extractingSample(_ sampleIndex: Int, from input: CIImage) -> CIImage {
        let component: CIVector
        switch sampleIndex {
        case 0: component = CIVector(x: 1, y: 0, z: 0, w: 0)
        case 1: component = CIVector(x: 0, y: 1, z: 0, w: 0)
        case 2: component = CIVector(x: 0, y: 0, z: 1, w: 0)
        default: component = CIVector(x: 0, y: 0, z: 0, w: 1)
        }
        return input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": component,
            "inputGVector": component,
            "inputBVector": component,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }
}

private final class TileCacheKey: NSObject {
    let coordinate: TIFFPlaneCoordinate
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(coordinate: TIFFPlaneCoordinate, rect: CGRect) {
        self.coordinate = coordinate
        x = Int(rect.minX)
        y = Int(rect.minY)
        width = Int(rect.width)
        height = Int(rect.height)
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(coordinate)
        hasher.combine(x)
        hasher.combine(y)
        hasher.combine(width)
        hasher.combine(height)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TileCacheKey else { return false }
        return coordinate == other.coordinate && x == other.x && y == other.y
            && width == other.width && height == other.height
    }
}

private final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
