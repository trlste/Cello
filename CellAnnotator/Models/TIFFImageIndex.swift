//
//  TIFFImageIndex.swift
//  CellAnnotator
//

import CoreGraphics
import Foundation

struct TIFFPlaneCoordinate: Hashable, Sendable {
    let channel: Int
    let z: Int
    let time: Int
    let level: Int
}

struct TIFFChannel: Identifiable, Equatable, Sendable {
    /// Stable index used by the Layers UI.
    let index: Int
    let idString: String?
    let name: String
    let color: UInt32?
    /// Logical C coordinate of the TIFF plane that contains this channel.
    /// Several display channels can share one plane for interleaved RGB data.
    let sourceChannelIndex: Int
    /// Component within an interleaved source plane (R=0, G=1, B=2).
    /// Nil means the source plane itself is a single display channel.
    let sampleIndex: Int?
    let samplesPerPixel: Int

    var id: Int { index }
}

struct TIFFResolution: Identifiable, Equatable, Sendable {
    let level: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let downsampleX: Double
    let downsampleY: Double

    var id: Int { level }
    var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }
}

/// One physical TIFF image file directory, including SubIFDs.
struct TIFFIFD: Identifiable, Equatable, Sendable {
    let offset: UInt64
    let parentOffset: UInt64?
    let topLevelIndex: Int?
    let pixelWidth: Int
    let pixelHeight: Int
    let bitsPerSample: [Int]
    let sampleFormat: Int?
    let samplesPerPixel: Int
    let compression: Int?
    let predictor: Int
    let photometricInterpretation: Int?
    let planarConfiguration: Int?
    let orientation: Int
    let tileWidth: Int?
    let tileHeight: Int?
    let tileOffsets: [UInt64]
    let tileByteCounts: [UInt64]
    let stripCount: Int
    let subIFDOffsets: [UInt64]

    var id: UInt64 { offset }
    var tileCount: Int { min(tileOffsets.count, tileByteCounts.count) }
    var isTiled: Bool { tileWidth != nil && tileHeight != nil && tileCount > 0 }
    var bitDepth: Int? { bitsPerSample.max() }
}

struct TIFFPlane: Identifiable, Equatable, Sendable {
    let coordinate: TIFFPlaneCoordinate
    let ifdOffset: UInt64
    /// ImageIO uses its own flattened page index. It normally corresponds to
    /// top-level IFD order; SubIFDs intentionally remain nil until a decoder
    /// that addresses IFD offsets directly is installed.
    let imageSourceIndex: Int?
    let pixelWidth: Int
    let pixelHeight: Int

    var id: TIFFPlaneCoordinate { coordinate }
}

struct TIFFPixelSize: Equatable, Sendable {
    let x: Double?
    let y: Double?
    let unitX: String?
    let unitY: String?
}

enum PixelCalibrationSource: Equatable, Sendable {
    case omeMetadata
    case manual
}

/// Physical size of one level-0 image pixel, normalized to micrometers.
/// Keeping X and Y separate also makes ruler measurements correct for the
/// uncommon OME image whose pixels are not square.
struct PixelCalibration: Equatable, Sendable {
    let micronsPerPixelX: Double
    let micronsPerPixelY: Double
    let source: PixelCalibrationSource

    var isValid: Bool {
        micronsPerPixelX.isFinite && micronsPerPixelX > 0
            && micronsPerPixelY.isFinite && micronsPerPixelY > 0
    }

    func lengthInMicrons(from start: CGPoint, to end: CGPoint) -> Double {
        let dx = Double(end.x - start.x) * micronsPerPixelX
        let dy = Double(end.y - start.y) * micronsPerPixelY
        return hypot(dx, dy)
    }

    static func manual(micronsPerPixel: Double) -> PixelCalibration? {
        let calibration = PixelCalibration(
            micronsPerPixelX: micronsPerPixel,
            micronsPerPixelY: micronsPerPixel,
            source: .manual
        )
        return calibration.isValid ? calibration : nil
    }

    static func fromOME(_ pixelSize: TIFFPixelSize) -> PixelCalibration? {
        let rawX = positive(pixelSize.x) ?? positive(pixelSize.y)
        let rawY = positive(pixelSize.y) ?? positive(pixelSize.x)
        guard let rawX, let rawY else { return nil }

        // OME's default unit for PhysicalSizeX/Y is micrometers. If only one
        // axis is present, use its value and unit for both axes.
        let unitX = pixelSize.x != nil ? pixelSize.unitX : pixelSize.unitY
        let unitY = pixelSize.y != nil ? pixelSize.unitY : pixelSize.unitX
        guard let scaleX = micronsPerUnit(unitX),
              let scaleY = micronsPerUnit(unitY) else { return nil }

        let calibration = PixelCalibration(
            micronsPerPixelX: rawX * scaleX,
            micronsPerPixelY: rawY * scaleY,
            source: .omeMetadata
        )
        return calibration.isValid ? calibration : nil
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func micronsPerUnit(_ unit: String?) -> Double? {
        guard let unit else { return 1 }
        let normalized = unit
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "μ", with: "µ")

        switch normalized {
        case "µm", "um", "micrometer", "micrometers", "micrometre", "micrometres":
            return 1
        case "nm", "nanometer", "nanometers", "nanometre", "nanometres":
            return 0.001
        case "mm", "millimeter", "millimeters", "millimetre", "millimetres":
            return 1_000
        case "cm", "centimeter", "centimeters", "centimetre", "centimetres":
            return 10_000
        case "m", "meter", "meters", "metre", "metres":
            return 1_000_000
        case "pm", "picometer", "picometers", "picometre", "picometres":
            return 0.000_001
        case "å", "angstrom", "angstroms":
            return 0.000_1
        case "in", "inch", "inches":
            return 25_400
        default:
            return nil
        }
    }
}

enum TIFFByteOrder: Equatable, Sendable {
    case littleEndian
    case bigEndian
}

struct TIFFImageIndex: Sendable {
    let sizeX: Int
    let sizeY: Int
    let sizeZ: Int
    let sizeC: Int
    let sizeT: Int
    let dimensionOrder: String
    let byteOrder: TIFFByteOrder
    let pixelType: String?
    let significantBits: Int?
    let pixelSize: TIFFPixelSize
    let channels: [TIFFChannel]
    let resolutions: [TIFFResolution]
    let ifds: [TIFFIFD]
    let planes: [TIFFPlane]
    let omeXML: String?

    var levelZeroSize: CGSize {
        CGSize(width: sizeX, height: sizeY)
    }

    var bitDepth: Int? {
        significantBits ?? ifds.compactMap(\.bitDepth).max()
    }

    func plane(at coordinate: TIFFPlaneCoordinate) -> TIFFPlane? {
        planes.first { $0.coordinate == coordinate }
    }

    func resolution(level: Int) -> TIFFResolution? {
        resolutions.first { $0.level == level }
    }

    func bestLevel(forLevelZeroPixelsPerOutputPixel desired: Double) -> TIFFResolution {
        let target = max(1, desired)
        return resolutions.min { lhs, rhs in
            let lhsDistance = abs(log(max(lhs.downsampleX, 1) / target))
            let rhsDistance = abs(log(max(rhs.downsampleX, 1) / target))
            return lhsDistance < rhsDistance
        } ?? TIFFResolution(
            level: 0,
            pixelWidth: sizeX,
            pixelHeight: sizeY,
            downsampleX: 1,
            downsampleY: 1
        )
    }

    static func fallback(frames: [TIFFFrame]) -> TIFFImageIndex {
        let largest = frames.max {
            ($0.pixelWidth * $0.pixelHeight) < ($1.pixelWidth * $1.pixelHeight)
        } ?? TIFFFrame(sourceIndex: 0, pixelWidth: 1, pixelHeight: 1, bitsPerSample: nil)

        let sortedSizes = Dictionary(grouping: frames, by: { "\($0.pixelWidth)x\($0.pixelHeight)" })
            .values
            .compactMap(\.first)
            .sorted { ($0.pixelWidth * $0.pixelHeight) > ($1.pixelWidth * $1.pixelHeight) }
        let resolutions = sortedSizes.enumerated().map { level, frame in
            TIFFResolution(
                level: level,
                pixelWidth: frame.pixelWidth,
                pixelHeight: frame.pixelHeight,
                downsampleX: Double(largest.pixelWidth) / Double(frame.pixelWidth),
                downsampleY: Double(largest.pixelHeight) / Double(frame.pixelHeight)
            )
        }
        let channelCount = max(1, frames.filter {
            $0.pixelWidth == largest.pixelWidth && $0.pixelHeight == largest.pixelHeight
        }.count)
        var nextChannelByLevel: [Int: Int] = [:]
        let planes = frames.map { frame in
            let level = resolutions.firstIndex {
                $0.pixelWidth == frame.pixelWidth && $0.pixelHeight == frame.pixelHeight
            } ?? 0
            let channel = channelCount == 1
                ? 0
                : min(nextChannelByLevel[level, default: 0], channelCount - 1)
            nextChannelByLevel[level, default: 0] += 1
            return TIFFPlane(
                coordinate: TIFFPlaneCoordinate(channel: channel, z: 0, time: 0, level: level),
                ifdOffset: UInt64(frame.sourceIndex),
                imageSourceIndex: frame.sourceIndex,
                pixelWidth: frame.pixelWidth,
                pixelHeight: frame.pixelHeight
            )
        }
        return TIFFImageIndex(
            sizeX: largest.pixelWidth,
            sizeY: largest.pixelHeight,
            sizeZ: 1,
            sizeC: channelCount,
            sizeT: 1,
            dimensionOrder: "XYZCT",
            byteOrder: .littleEndian,
            pixelType: nil,
            significantBits: largest.bitsPerSample,
            pixelSize: TIFFPixelSize(x: nil, y: nil, unitX: nil, unitY: nil),
            channels: (0..<channelCount).map {
                TIFFChannel(
                    index: $0,
                    idString: nil,
                    name: "Channel \($0 + 1)",
                    color: nil,
                    sourceChannelIndex: $0,
                    sampleIndex: nil,
                    samplesPerPixel: 1
                )
            },
            resolutions: resolutions,
            ifds: [],
            planes: planes,
            omeXML: nil
        )
    }
}
