//
//  TIFFDocument.swift
//  CellAnnotator
//

import Foundation
import ImageIO
import Observation
import UIKit

/// Metadata for one image that ImageIO exposes from a TIFF container.
///
/// A frame may ultimately represent a channel, a Z/T plane, or a pyramid
/// resolution. We deliberately do not guess that meaning here; OME metadata
/// will provide that mapping in the next layer of the reader.
struct TIFFFrame: Identifiable, Equatable, Sendable {
    let sourceIndex: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let bitsPerSample: Int?

    var id: Int { sourceIndex }
    var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }
}

/// Keeps a security-scoped file available for the complete lifetime of an
/// open document. This is required once rendering becomes on-demand: ending
/// access immediately after import would make later tile reads unreliable.
final class SecurityScopedTIFFResource: @unchecked Sendable {
    let url: URL
    private let isAccessing: Bool

    init(url: URL, requireSecurityScope: Bool) throws {
        self.url = url
        if requireSecurityScope {
            guard url.startAccessingSecurityScopedResource() else {
                throw ImageLoader.LoadError.accessDenied
            }
            isAccessing = true
        } else {
            isAccessing = false
        }
    }

    deinit {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

/// The image-side state for one open TIFF.
///
/// `overviewImage` is intentionally allowed to be much smaller than
/// `pixelSize`. The viewer stretches it across a full-resolution coordinate
/// space, so GeoJSON and Pencil annotations remain expressed in source pixels.
/// High-resolution tiles can later replace portions of the overview without
/// changing annotation geometry or the SwiftUI workflow.
@Observable
final class TIFFDocument: Identifiable {
    let id = UUID()
    let resource: SecurityScopedTIFFResource
    let pixelSize: CGSize
    let frames: [TIFFFrame]
    let overviewImage: UIImage
    let imageIndex: TIFFImageIndex
    let tileSource: TileSource
    let embeddedPixelCalibration: PixelCalibration?
    var channelSettings: [ChannelDisplaySettings]
    private(set) var measurementCalibration: PixelCalibration?
    private(set) var selectedZ = 0
    private(set) var selectedTime = 0
    private(set) var displayRevision = 0

    init(
        resource: SecurityScopedTIFFResource,
        pixelSize: CGSize,
        frames: [TIFFFrame],
        overviewImage: UIImage,
        imageIndex: TIFFImageIndex,
        tileSource: TileSource
    ) {
        self.resource = resource
        self.pixelSize = pixelSize
        self.frames = frames
        self.overviewImage = overviewImage
        self.imageIndex = imageIndex
        self.tileSource = tileSource
        let embeddedCalibration = PixelCalibration.fromOME(imageIndex.pixelSize)
        self.embeddedPixelCalibration = embeddedCalibration
        self.measurementCalibration = embeddedCalibration
        self.channelSettings = ChannelDisplaySettings.defaults(for: imageIndex.channels)
    }

    func setManualMeasurementCalibration(micronsPerPixel: Double) {
        measurementCalibration = PixelCalibration.manual(micronsPerPixel: micronsPerPixel)
    }

    func restoreEmbeddedMeasurementCalibration() {
        measurementCalibration = embeddedPixelCalibration
    }

    func updateChannelSettings(at index: Int, _ update: (inout ChannelDisplaySettings) -> Void) {
        guard channelSettings.indices.contains(index) else { return }
        update(&channelSettings[index])
        displayRevision &+= 1
    }

    /// Restores only the controls owned by the Layers panel. Display
    /// adjustments are intentionally preserved.
    func resetLayerSettings() {
        let defaults = ChannelDisplaySettings.defaults(for: imageIndex.channels)
        for index in channelSettings.indices where defaults.indices.contains(index) {
            channelSettings[index].isVisible = defaults[index].isVisible
            channelSettings[index].color = defaults[index].color
        }
        displayRevision &+= 1
    }

    /// Restores contrast/gamma/opacity for channels that are currently shown.
    /// Hidden channels keep their saved adjustments until they are shown again.
    func resetVisibleChannelAdjustments() {
        let defaults = ChannelDisplaySettings.defaults(for: imageIndex.channels)
        for index in channelSettings.indices
        where channelSettings[index].isVisible && defaults.indices.contains(index) {
            channelSettings[index].blackPoint = defaults[index].blackPoint
            channelSettings[index].whitePoint = defaults[index].whitePoint
            channelSettings[index].gamma = defaults[index].gamma
            channelSettings[index].opacity = defaults[index].opacity
        }
        displayRevision &+= 1
    }

    func selectPlane(z: Int? = nil, time: Int? = nil) {
        let nextZ = min(max(0, z ?? selectedZ), max(0, imageIndex.sizeZ - 1))
        let nextTime = min(max(0, time ?? selectedTime), max(0, imageIndex.sizeT - 1))
        guard nextZ != selectedZ || nextTime != selectedTime else { return }
        selectedZ = nextZ
        selectedTime = nextTime
        displayRevision &+= 1
    }

    /// Distinct sizes exposed by ImageIO, largest first. Repeated sizes are
    /// retained as one resolution because they commonly represent channels.
    var exposedResolutions: [CGSize] {
        var seen = Set<String>()
        return frames
            .sorted { ($0.pixelWidth * $0.pixelHeight) > ($1.pixelWidth * $1.pixelHeight) }
            .compactMap { frame in
                let key = "\(frame.pixelWidth)x\(frame.pixelHeight)"
                guard seen.insert(key).inserted else { return nil }
                return frame.pixelSize
            }
    }

    var hasMultipleExposedResolutions: Bool {
        exposedResolutions.count > 1
    }
}
