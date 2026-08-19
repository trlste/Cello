//
//  TiledImageView.swift
//  CellAnnotator
//

import UIKit

enum TileRenderPhase: Equatable {
    case idle
    case rendering
    case failed
}

struct TileRenderStatus: Equatable {
    let phase: TileRenderPhase
    let readyVisibleTiles: Int
    let requestedVisibleTiles: Int
    let message: String?

    static let idle = TileRenderStatus(
        phase: .idle,
        readyVisibleTiles: 0,
        requestedVisibleTiles: 0,
        message: nil
    )

    var progress: Double {
        guard requestedVisibleTiles > 0 else { return 1 }
        return min(1, Double(readyVisibleTiles) / Double(requestedVisibleTiles))
    }
}

/// Displays channel-composited logical tiles. Its bounds always remain
/// level-0 pixels.
///
/// The raw ImageIO overview is intentionally not displayed here: it does not
/// respect channel visibility or display adjustments. During a pyramid-level
/// change, tiles from the previous level remain as a channel-correct fallback
/// until the replacement tiles for the visible region have arrived.
@MainActor
final class TiledImageView: UIView {
    /// Identifies the source samples that are allowed to contribute to the
    /// rendered image. Display-only changes (black/white point, gamma,
    /// opacity, or pseudocolor) do not change this signature.
    private struct ChannelCompositionKey: Hashable {
        let channelIndex: Int
        let sourceChannelIndex: Int
        let sampleIndex: Int?
    }

    private struct TileKey: Hashable {
        let level: Int
        let column: Int
        let row: Int
        let displayRevision: Int

        var position: TilePosition {
            TilePosition(level: level, column: column, row: row)
        }
    }

    /// Identifies a tile's spatial location independently of the display
    /// revision that produced its pixels.
    private struct TilePosition: Hashable {
        let level: Int
        let column: Int
        let row: Int
    }

    private let source: TileSource
    private let compositor = TileCompositor()
    private var tileLayers: [TileKey: CALayer] = [:]
    private var tileTasks: [TileKey: Task<Void, Never>] = [:]
    private var tileTaskIDs: [TileKey: UUID] = [:]
    private var currentNeededKeys: Set<TileKey> = []
    private var currentVisibleKeys: Set<TileKey> = []
    private var failedTileMessages: [TileKey: String] = [:]
    private var lastReportedStatus = TileRenderStatus.idle
    private var currentLevelZeroRetentionRect = CGRect.null
    private var currentLevel: Int?
    private var currentDisplayRevision = -1
    private var currentChannelComposition: [ChannelCompositionKey] = []
    private var currentZ = 0
    private var currentTime = 0

    var onRenderStatusChange: ((TileRenderStatus) -> Void)? {
        didSet { publishRenderStatus() }
    }

    init(document: TIFFDocument) {
        source = document.tileSource
        super.init(frame: CGRect(origin: .zero, size: document.pixelSize))
        clipsToBounds = true
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit {
        tileTasks.values.forEach { $0.cancel() }
    }

    func updateVisibleRegion(
        _ levelZeroRect: CGRect,
        zoomScale: CGFloat,
        screenScale: CGFloat,
        settings: [ChannelDisplaySettings],
        displayRevision: Int,
        z: Int = 0,
        time: Int = 0
    ) {
        guard levelZeroRect.width > 0, levelZeroRect.height > 0 else { return }
        let visibleChannels = Array(Set(
            settings.filter(\.isVisible).map(\.sourceChannelIndex)
        ))
        let channelComposition = settings
            .filter(\.isVisible)
            .map {
                ChannelCompositionKey(
                    channelIndex: $0.channelIndex,
                    sourceChannelIndex: $0.sourceChannelIndex,
                    sampleIndex: $0.sampleIndex
                )
            }
        let levelZeroPixelsPerOutputPixel = Double(
            1 / max(zoomScale * screenScale, 0.000_001)
        )
        let resolution = source.bestAvailableLevel(
            forLevelZeroPixelsPerOutputPixel: levelZeroPixelsPerOutputPixel,
            channels: visibleChannels,
            z: z,
            time: time
        )

        let displayChanged = currentDisplayRevision != displayRevision
        let levelChanged = currentLevel != resolution.level
        let channelCompositionChanged = currentChannelComposition != channelComposition
        let planeChanged = currentZ != z || currentTime != time
        let previousComposition = Set(currentChannelComposition)
        let nextComposition = Set(channelComposition)
        let onlyAddsVisibleChannels = previousComposition.isSubset(of: nextComposition)

        if planeChanged || (channelCompositionChanged && !onlyAddsVisibleChannels) {
            // A removed channel or a different Z/T plane must disappear
            // immediately. In contrast, adding a channel can safely retain the
            // old subset composite underneath until its replacement arrives.
            clearTiles()
        } else if displayChanged || levelChanged || channelCompositionChanged {
            // Display adjustments, added channels, and pyramid-level changes
            // all have compatible fallback pixels. Cancel obsolete requests,
            // but do not delete their completed layers.
            cancelTileTasks()
        }
        currentLevel = resolution.level
        currentDisplayRevision = displayRevision
        currentChannelComposition = channelComposition
        currentZ = z
        currentTime = time

        let tileSize = source.preferredTileSize
        let levelRect = CGRect(
            x: levelZeroRect.minX / CGFloat(resolution.downsampleX),
            y: levelZeroRect.minY / CGFloat(resolution.downsampleY),
            width: levelZeroRect.width / CGFloat(resolution.downsampleX),
            height: levelZeroRect.height / CGFloat(resolution.downsampleY)
        )
        // Decode beyond the viewport so a pinch or short pan does not expose
        // black gaps before the next scroll callback can enqueue work.
        let padded = levelRect.insetBy(
            dx: -CGFloat(tileSize * 2),
            dy: -CGFloat(tileSize * 2)
        )
            .intersection(CGRect(x: 0, y: 0,
                                 width: CGFloat(resolution.pixelWidth),
                                 height: CGFloat(resolution.pixelHeight)))
        guard !padded.isNull else { return }

        let levelBounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(resolution.pixelWidth),
            height: CGFloat(resolution.pixelHeight)
        )
        let visibleLevelRect = levelRect.intersection(levelBounds)
        currentVisibleKeys = tileKeys(
            intersecting: visibleLevelRect,
            level: resolution.level,
            displayRevision: displayRevision,
            tileSize: tileSize
        )

        currentLevelZeroRetentionRect = levelZeroRect.insetBy(
            dx: -CGFloat(tileSize * 4) * CGFloat(resolution.downsampleX),
            dy: -CGFloat(tileSize * 4) * CGFloat(resolution.downsampleY)
        ).intersection(bounds)

        let firstColumn = max(0, Int(floor(padded.minX / CGFloat(tileSize))))
        let lastColumn = max(firstColumn, Int(floor(max(0, padded.maxX - 1) / CGFloat(tileSize))))
        let firstRow = max(0, Int(floor(padded.minY / CGFloat(tileSize))))
        let lastRow = max(firstRow, Int(floor(max(0, padded.maxY - 1) / CGFloat(tileSize))))
        var needed = Set<TileKey>()
        var requests: [(key: TileKey, pixelRect: CGRect)] = []

        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn {
                let key = TileKey(
                    level: resolution.level,
                    column: column,
                    row: row,
                    displayRevision: displayRevision
                )
                needed.insert(key)
                let origin = CGPoint(
                    x: CGFloat(column * tileSize),
                    y: CGFloat(row * tileSize)
                )
                let pixelRect = CGRect(
                    x: origin.x,
                    y: origin.y,
                    width: CGFloat(min(tileSize, resolution.pixelWidth - Int(origin.x))),
                    height: CGFloat(min(tileSize, resolution.pixelHeight - Int(origin.y)))
                )
                requests.append((key: key, pixelRect: pixelRect))
            }
        }

        // Publish the complete generation before starting any Task. A source
        // cache hit can resume immediately; launching first allowed it to beat
        // this assignment and be incorrectly rejected as an obsolete tile.
        currentNeededKeys = needed
        for key in Array(failedTileMessages.keys) where !needed.contains(key) {
            failedTileMessages.removeValue(forKey: key)
        }
        // Current-generation tiles must render over retained lower-resolution
        // and previous-adjustment fallbacks, regardless of insertion order.
        for (key, tileLayer) in tileLayers {
            tileLayer.zPosition = needed.contains(key) ? 2 : 0
        }
        for key in Set(tileTasks.keys).subtracting(needed) {
            tileTasks.removeValue(forKey: key)?.cancel()
            tileTaskIDs.removeValue(forKey: key)
        }
        pruneStaleLayers()
        publishRenderStatus()
        for request in requests {
            guard tileLayers[request.key] == nil,
                  tileTasks[request.key] == nil,
                  failedTileMessages[request.key] == nil else { continue }
            requestTile(
                key: request.key,
                pixelRect: request.pixelRect,
                resolution: resolution,
                settings: settings,
                z: z,
                time: time
            )
        }
    }

    private func requestTile(
        key: TileKey,
        pixelRect: CGRect,
        resolution: TIFFResolution,
        settings: [ChannelDisplaySettings],
        z: Int,
        time: Int
    ) {
        let requestID = UUID()
        tileTaskIDs[key] = requestID
        tileTasks[key] = Task { [weak self] in
            guard let self else { return }
            defer {
                if tileTaskIDs[key] == requestID {
                    tileTasks.removeValue(forKey: key)
                    tileTaskIDs.removeValue(forKey: key)
                }
            }
            for attempt in 0..<2 {
                do {
                    let image = try await compositor.compositeTile(
                        source: source,
                        level: resolution.level,
                        z: z,
                        time: time,
                        pixelRect: pixelRect,
                        settings: settings
                    )
                    try Task.checkCancellation()
                    guard currentLevel == key.level,
                          currentDisplayRevision == key.displayRevision,
                          currentNeededKeys.contains(key) else { return }

                    let tileLayer = CALayer()
                    tileLayer.contents = image
                    tileLayer.contentsGravity = .resize
                    tileLayer.magnificationFilter = .linear
                    tileLayer.minificationFilter = .linear
                    tileLayer.zPosition = 2
                    tileLayer.frame = CGRect(
                        x: pixelRect.minX * CGFloat(resolution.downsampleX),
                        y: pixelRect.minY * CGFloat(resolution.downsampleY),
                        width: pixelRect.width * CGFloat(resolution.downsampleX),
                        height: pixelRect.height * CGFloat(resolution.downsampleY)
                    )
                    layer.addSublayer(tileLayer)
                    tileLayers[key] = tileLayer
                    failedTileMessages.removeValue(forKey: key)
                    pruneStaleLayers()
                    publishRenderStatus()
                    return
                } catch is CancellationError {
                    return
                } catch {
                    // A transient file-provider/read failure should not leave a
                    // permanent hole. Retry once while retaining any previous
                    // channel-correct layer underneath.
                    if attempt == 0 {
                        try? await Task.sleep(for: .milliseconds(80))
                    } else {
                        if currentNeededKeys.contains(key) {
                            failedTileMessages[key] = error.localizedDescription
                            publishRenderStatus()
                        }
                        return
                    }
                }
            }
        }
    }

    private func pruneStaleLayers() {
        // Same-level adjustment/channel-addition tiles replace their matching
        // old tile individually. Different pyramid levels do not share a grid,
        // so retain one well-covered fallback level beneath the current one.
        let readyPositions = Set(
            currentNeededKeys.compactMap { tileLayers[$0] == nil ? nil : $0.position }
        )
        for key in Set(tileLayers.keys).subtracting(currentNeededKeys) {
            let position = key.position
            guard let tileLayer = tileLayers[key] else { continue }
            let isOutsideRetention = !tileLayer.frame.intersects(currentLevelZeroRetentionRect)
            let hasCurrentReplacement = key.level == currentLevel
                && key.displayRevision != currentDisplayRevision
                && readyPositions.contains(position)
            if isOutsideRetention || hasCurrentReplacement {
                tileLayers.removeValue(forKey: key)?.removeFromSuperlayer()
            } else {
                tileLayer.zPosition = key.level == currentLevel ? 1 : 0
            }
        }

        // Bound retained image memory without selecting a fallback merely by
        // recency. During a fast pinch, the immediately previous level may be
        // only partially populated; keep the non-current level with the most
        // viewport coverage instead.
        let countsByFallbackLevel = tileLayers.keys.reduce(into: [Int: Int]()) { counts, key in
            guard key.level != currentLevel else { return }
            counts[key.level, default: 0] += 1
        }
        let bestFallbackLevel = countsByFallbackLevel.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            guard let currentLevel else { return lhs.key < rhs.key }
            return abs(lhs.key - currentLevel) > abs(rhs.key - currentLevel)
        }?.key
        for key in Set(tileLayers.keys)
        where key.level != currentLevel && key.level != bestFallbackLevel {
            tileLayers.removeValue(forKey: key)?.removeFromSuperlayer()
        }
    }

    private func cancelTileTasks() {
        tileTasks.values.forEach { $0.cancel() }
        tileTasks.removeAll()
        tileTaskIDs.removeAll()
    }

    private func clearTiles() {
        cancelTileTasks()
        tileLayers.values.forEach { $0.removeFromSuperlayer() }
        tileLayers.removeAll()
        currentNeededKeys.removeAll()
        currentVisibleKeys.removeAll()
        failedTileMessages.removeAll()
        currentLevelZeroRetentionRect = .null
        publishRenderStatus()
    }

    private func tileKeys(
        intersecting rect: CGRect,
        level: Int,
        displayRevision: Int,
        tileSize: Int
    ) -> Set<TileKey> {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return [] }
        let firstColumn = max(0, Int(floor(rect.minX / CGFloat(tileSize))))
        let lastColumn = max(
            firstColumn,
            Int(floor(max(0, rect.maxX - 1) / CGFloat(tileSize)))
        )
        let firstRow = max(0, Int(floor(rect.minY / CGFloat(tileSize))))
        let lastRow = max(
            firstRow,
            Int(floor(max(0, rect.maxY - 1) / CGFloat(tileSize)))
        )
        return Set((firstRow...lastRow).flatMap { row in
            (firstColumn...lastColumn).map { column in
                TileKey(
                    level: level,
                    column: column,
                    row: row,
                    displayRevision: displayRevision
                )
            }
        })
    }

    private func publishRenderStatus() {
        let requested = currentVisibleKeys.count
        guard requested > 0 else {
            report(.idle)
            return
        }

        let ready = currentVisibleKeys.reduce(into: 0) { count, key in
            if tileLayers[key] != nil { count += 1 }
        }
        let visibleFailures = currentVisibleKeys.compactMap { key in
            failedTileMessages[key]
        }
        if let firstFailure = visibleFailures.first {
            let suffix = visibleFailures.count == 1
                ? ""
                : " (\(visibleFailures.count) visible tiles failed)"
            report(TileRenderStatus(
                phase: .failed,
                readyVisibleTiles: ready,
                requestedVisibleTiles: requested,
                message: firstFailure + suffix
            ))
        } else if ready < requested {
            report(TileRenderStatus(
                phase: .rendering,
                readyVisibleTiles: ready,
                requestedVisibleTiles: requested,
                message: nil
            ))
        } else {
            report(.idle)
        }
    }

    private func report(_ status: TileRenderStatus) {
        guard status != lastReportedStatus else { return }
        lastReportedStatus = status
        onRenderStatusChange?(status)
    }
}
