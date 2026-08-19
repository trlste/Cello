//
//  ImageLoader.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/5.
//

import SwiftUI
import ImageIO
import UniformTypeIdentifiers

enum ImageLoader {
    private struct PreparedTIFF: Sendable {
        let resource: SecurityScopedTIFFResource
        let frames: [TIFFFrame]
        let imageIndex: TIFFImageIndex
    }

    enum LoadError: LocalizedError {
        case accessDenied
        case decodeFailed
        case invalidDimensions

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Couldn't access the file. Try loading it again."
            case .decodeFailed:
                return "Could not decode this TIFF. Its compression or pixel format may not be supported."
            case .invalidDimensions:
                return "The TIFF does not report a valid image size."
            }
        }
    }
    
    @MainActor
    static func loadFromBundle(_ name: String, ext: String = "tif") throws -> TIFFDocument {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw LoadError.decodeFailed
        }
        return makeDocument(try prepare(from: url, requireSecurityScope: false))
    }

    /// Opening and indexing a multi-gigabyte OME-TIFF must not run in the file
    /// importer's main-actor callback. Only the lightweight document/UI objects
    /// are created on the main actor after metadata preparation completes.
    @MainActor
    static func load(from url: URL) async throws -> TIFFDocument {
        let prepared = try await Task.detached(priority: .userInitiated) {
            try prepare(from: url, requireSecurityScope: true)
        }.value
        return makeDocument(prepared)
    }

    private static func prepare(
        from url: URL,
        requireSecurityScope: Bool
    ) throws -> PreparedTIFF {
        let resource = try SecurityScopedTIFFResource(
            url: url,
            requireSecurityScope: requireSecurityScope
        )

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw LoadError.decodeFailed
        }

        let frames = frameMetadata(from: source)
        guard let largest = frames.max(by: {
            ($0.pixelWidth * $0.pixelHeight) < ($1.pixelWidth * $1.pixelHeight)
        }), largest.pixelWidth > 0, largest.pixelHeight > 0 else {
            throw LoadError.invalidDimensions
        }

        // Binary TIFF indexing is independent of ImageIO's page numbering and
        // includes SubIFDs that ImageIO may not expose as frames. Preserve the
        // broad ordinary-TIFF fallback if metadata indexing encounters an
        // uncommon vendor extension.
        let imageIndex = (try? TIFFIndexBuilder.build(
            url: url,
            imageSourceFrames: frames
        )) ?? TIFFImageIndex.fallback(frames: frames)
        return PreparedTIFF(resource: resource, frames: frames, imageIndex: imageIndex)
    }

    @MainActor
    private static func makeDocument(_ prepared: PreparedTIFF) -> TIFFDocument {
        // A page decoded by ImageIO is not guaranteed to represent the active
        // channel selection. Keep only a negligible placeholder here; the
        // tiled renderer supplies both the initial fit-level image and every
        // higher-resolution view through the same channel-aware compositor.
        let overview = makeBlackPlaceholder()
        let tileSource = ImageIOTileSource(
            resource: prepared.resource,
            index: prepared.imageIndex
        )
        return TIFFDocument(
            resource: prepared.resource,
            pixelSize: prepared.imageIndex.levelZeroSize,
            frames: prepared.frames,
            overviewImage: overview,
            imageIndex: prepared.imageIndex,
            tileSource: tileSource
        )
    }

    private static func frameMetadata(from source: CGImageSource) -> [TIFFFrame] {
        (0..<CGImageSourceGetCount(source)).compactMap { index in
            guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source, index, nil
            ) as? [CFString: Any],
                  let width = integerValue(properties[kCGImagePropertyPixelWidth]),
                  let height = integerValue(properties[kCGImagePropertyPixelHeight]) else {
                return nil
            }

            let depth = integerValue(properties[kCGImagePropertyDepth])
            return TIFFFrame(
                sourceIndex: index,
                pixelWidth: width,
                pixelHeight: height,
                bitsPerSample: depth
            )
        }
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let integer = value as? Int { return integer }
        return nil
    }

    @MainActor
    private static func makeBlackPlaceholder() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}
