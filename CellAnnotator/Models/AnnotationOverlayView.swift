//
//  AnnotationOverlayView.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/5.
//

import UIKit
import SwiftUI

/// CATextLayer only provides horizontal alignment. Offset its drawing rect so
/// the text is visually centered inside the label's fixed-height background.
private final class VerticallyCenteredTextLayer: CATextLayer {
    override func draw(in context: CGContext) {
        let verticalOffset = (bounds.height - fontSize) / 2 - fontSize * 0.1
        context.saveGState()
        context.translateBy(x: 0, y: verticalOffset)
        super.draw(in: context)
        context.restoreGState()
    }
}

final class AnnotationOverlayView: UIView {
    private let store: AnnotationStore
    private let imagePixelSize: CGSize

    // Vector layers avoid allocating a full-resolution bitmap backing store.
    // A conventional draw(_:) view is not viable for whole-slide images: a
    // 25k x 35k transparent overlay alone can require several gigabytes.
    private var normalAnnotationLayers: [CAShapeLayer] = []
    private let selectedAnnotationLayer = CAShapeLayer()
    private let editingAnnotationLayer = CAShapeLayer()
    private let vertexHandlesLayer = CAShapeLayer()
    private let progressLineLayer = CAShapeLayer()
    private let progressVertexLayer = CAShapeLayer()
    private let closeTargetLayer = CAShapeLayer()
    private let measurementLineLayer = CAShapeLayer()
    private let measurementLabelLayer = CATextLayer()
    private let selectedAnnotationLabelLayer = VerticallyCenteredTextLayer()
    private var measurementCalibration: PixelCalibration?
    private var freehandSmoothing: Double
    private var renderedZoomScale: CGFloat = 1

    // In-progress state
    private var freehandPoints: [CGPoint] = []
    private var polygonPoints: [CGPoint] = []
    private var isDrawingFreehand = false
    
    // Screen-space closing radius for polygon mode, in points. ~20pt is a comfortable target.
    private let closeThresholdScreenPoints: CGFloat = 20
    private let freehandCloseScreenPoints: CGFloat = 44   // more forgiving than polygon's 20
    private let freehandTrimScreenPoints: CGFloat = 12   // tail-trim: tight
    private var currentZoom: CGFloat {
        (superview?.superview as? UIScrollView)?.zoomScale ?? 1
    }
    // The proximity radius expressed in image pixels at the current zoom.
    private var closeThresholdInImageSpace: CGFloat {
        closeThresholdScreenPoints / currentZoom
    }
    private var freehandCloseInImageSpace: CGFloat {
        freehandCloseScreenPoints / currentZoom
    }
    private var freehandTrimInImageSpace: CGFloat { freehandTrimScreenPoints / currentZoom }
    
    private var isDraggingSelection = false
    private var lastDragPoint: CGPoint?
    
    private var vertexHitRadiusScreen: CGFloat = 14   // grab tolerance in screen points
    /// Dense contours are freehand strokes in practice. Showing or dragging
    /// every sample point makes them noisy and too easy to deform accidentally.
    private let maximumEditableVertexCount = 60
    private var vertexHitRadiusImage: CGFloat {
        vertexHitRadiusScreen / currentZoom
    }
    private func canEditVertices(of annotation: Annotation) -> Bool {
        annotation.points.count <= maximumEditableVertexCount
    }
    private func effectiveVertexRadius(for annotation: Annotation) -> CGFloat {
        let base = vertexHitRadiusImage
        // Don't let the grab radius dominate small shapes.
        let pts = annotation.points
        guard pts.count > 1 else { return base }
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        let diagonal = hypot(maxX - minX, maxY - minY)
        return min(base, diagonal / 3)
    }
    private var draggingVertexIndex: Int?

    init(
        store: AnnotationStore,
        imagePixelSize: CGSize,
        measurementCalibration: PixelCalibration?,
        freehandSmoothing: Double
    ) {
        self.store = store
        self.imagePixelSize = imagePixelSize
        self.measurementCalibration = measurementCalibration
        self.freehandSmoothing = min(max(freehandSmoothing, 0), 1)
        super.init(frame: CGRect(origin: .zero, size: imagePixelSize))
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = false
        [
            selectedAnnotationLayer,
            editingAnnotationLayer,
            vertexHandlesLayer,
            progressLineLayer,
            closeTargetLayer,
            progressVertexLayer,
            measurementLineLayer
        ].forEach {
            $0.fillColor = nil
            $0.lineCap = .round
            $0.lineJoin = .round
            layer.addSublayer($0)
        }
        measurementLabelLayer.alignmentMode = .center
        measurementLabelLayer.foregroundColor = UIColor.white.cgColor
        measurementLabelLayer.backgroundColor = UIColor.black.withAlphaComponent(0.78).cgColor
        let labelFont = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        measurementLabelLayer.font = CGFont(labelFont.fontName as CFString)
        measurementLabelLayer.cornerRadius = 5
        measurementLabelLayer.isWrapped = false
        measurementLabelLayer.truncationMode = .none
        layer.addSublayer(measurementLabelLayer)

        selectedAnnotationLabelLayer.alignmentMode = .center
        selectedAnnotationLabelLayer.foregroundColor = UIColor.white.cgColor
        selectedAnnotationLabelLayer.backgroundColor = UIColor.systemBlue
            .withAlphaComponent(0.88)
            .cgColor
        let annotationLabelFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
        selectedAnnotationLabelLayer.font = CGFont(annotationLabelFont.fontName as CFString)
        selectedAnnotationLabelLayer.cornerRadius = 5
        selectedAnnotationLabelLayer.isWrapped = false
        selectedAnnotationLabelLayer.truncationMode = .end
        layer.addSublayer(selectedAnnotationLabelLayer)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)] // finger
        addGestureRecognizer(tap)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let allLayers = normalAnnotationLayers + [
            selectedAnnotationLayer,
            editingAnnotationLayer,
            vertexHandlesLayer,
            progressLineLayer,
            progressVertexLayer,
            closeTargetLayer,
            measurementLineLayer
        ]
        allLayers.forEach { $0.frame = bounds }
    }

    // MARK: - Touch handling (Pencil only)
    
    private func handleSelectTouch(at p: CGPoint) {
        if let editID = store.editingVertexAnnotationID,
           let annotation = store.annotations.first(where: { $0.id == editID }),
           !canEditVertices(of: annotation) {
            store.editingVertexAnnotationID = nil
        }

        // Vertices are live ONLY in edit mode.
        if store.editingVertexAnnotationID != nil, let vi = vertexIndex(at: p) {
            store.snapshot()
            draggingVertexIndex = vi
            return
        }
        // Otherwise: drag the whole selected shape, or change selection.
        if let hitID = annotationID(at: p), hitID == store.selectedAnnotationID {
            store.snapshot()
            isDraggingSelection = true
            lastDragPoint = p
        } else {
            store.selectedAnnotationID = annotationID(at: p)   // select or deselect
            store.editingVertexAnnotationID = nil              // reselecting exits edit mode
        }
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pencilTouch(from: touches) else { return }
        let p = touch.location(in: self)

        // Double-tap inside the selected annotation toggles vertex-edit mode.
        if store.activeTool == .select, touch.tapCount == 2 {
            if let hitID = annotationID(at: p),
               hitID == store.selectedAnnotationID,
               let annotation = store.annotations.first(where: { $0.id == hitID }) {
                guard canEditVertices(of: annotation) else {
                    store.editingVertexAnnotationID = nil
                    refresh()
                    return
                }
                // Toggle: enter edit mode, or exit if already editing this one.
                if store.editingVertexAnnotationID == hitID {
                    store.editingVertexAnnotationID = nil
                } else {
                    store.editingVertexAnnotationID = hitID
                }
                refresh()
                return
            }
        }

        switch store.activeTool {
        case .freehand:
            isDrawingFreehand = true
            freehandPoints = [p]
        case .polygon:
            if isNearStart(p, of: polygonPoints) {
                closePolygon()
            } else {
                polygonPoints.append(p)
            }
        case .select:
            handleSelectTouch(at: p)
        case .measure:
            store.beginMeasurement(at: p)
        }
        refresh()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pencilTouch(from: touches) else { return }
        let p = touch.location(in: self)

        switch store.activeTool {
        case .freehand:
            guard isDrawingFreehand else { return }
            let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
            freehandPoints.append(contentsOf: coalesced.map { $0.location(in: self) })
            refresh()

        case .select:
            if store.editingVertexAnnotationID != nil,
               let vi = draggingVertexIndex, let selID = store.selectedAnnotationID {
                // Edit mode: move the grabbed vertex.
                store.moveVertex(annotationID: selID, vertexIndex: vi,
                                 to: p, imageSize: imagePixelSize)
            } else if store.editingVertexAnnotationID == nil,
                      isDraggingSelection, let last = lastDragPoint {
                // Not editing: move the whole shape.
                let delta = CGSize(width: p.x - last.x, height: p.y - last.y)
                store.moveSelected(by: delta, imageSize: imagePixelSize)
                lastDragPoint = p
            }
            refresh()

        case .polygon:
            break
        case .measure:
            store.updateMeasurement(to: p, imageSize: imagePixelSize)
            rebuildMeasurementLayer()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pencilTouch(from: touches) else { return }
        
        if store.activeTool == .select {
            isDraggingSelection = false
            lastDragPoint = nil
            draggingVertexIndex = nil
            return
        }

        if store.activeTool == .measure {
            store.updateMeasurement(
                to: touch.location(in: self),
                imageSize: imagePixelSize
            )
            rebuildMeasurementLayer()
            return
        }

        if store.activeTool == .freehand, isDrawingFreehand {
            isDrawingFreehand = false
            if freehandPoints.count > 1, let start = freehandPoints.first {
                // 1. Trim the tightly-overshooting tail.
                while freehandPoints.count > 3,
                      let last = freehandPoints.last,
                      hypot(last.x - start.x, last.y - start.y) < freehandTrimInImageSpace {
                    freehandPoints.removeLast()
                }

                // 2. Only consider closing if the stroke is meaningfully large.
                let strokeExtent = freehandPoints.map {
                    hypot($0.x - start.x, $0.y - start.y)
                }.max() ?? 0
                let bigEnough = strokeExtent > freehandCloseInImageSpace * 2

                // 3. Close if big enough AND the end returned near the start.
                if bigEnough,
                   let end = freehandPoints.last,
                   hypot(end.x - start.x, end.y - start.y) < freehandCloseInImageSpace {
                    freehandPoints.append(start)
                }

                // 4. Remove high-frequency Pencil wobble before committing.
                // The contour remains closed by Annotation.isClosed, so the
                // smoother can remove a duplicate final copy of the start.
                let committedPoints = smoothedClosedStroke(
                    freehandPoints,
                    strength: freehandSmoothing
                )
                if committedPoints.count >= 3 {
                    store.snapshot()
                    store.add(Annotation(points: committedPoints,
                                         classID: store.activeClassID,
                                         isClosed: true))
                }
            }
            freehandPoints = []
            refresh()
        }
        // Polygon does nothing on touch-end — it accumulates taps until closed.
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if store.activeTool == .measure {
            store.clearMeasurement()
        }
        isDrawingFreehand = false
        freehandPoints = []
        refresh()
    }

    /// Only accept Apple Pencil touches; finger touches fall through to the scroll view.
    private func pencilTouch(from touches: Set<UITouch>) -> UITouch? {
        touches.first { $0.type == .pencil }
    }
    
    private func isNearStart(_ point: CGPoint, of points: [CGPoint]) -> Bool {
        guard let start = points.first, points.count >= 3 else { return false }
        return hypot(point.x - start.x, point.y - start.y) < closeThresholdInImageSpace
    }
    // MARK: - Committing a polygon

    /// Called from the toolbar's "Close polygon" action.
    func closePolygon() {
        guard polygonPoints.count >= 3 else { return }
        store.snapshot()
        store.add(Annotation(points: polygonPoints, classID: store.activeClassID, isClosed: true))
        polygonPoints = []
        refresh()
    }

    func cancelInProgress() {
        polygonPoints = []
        freehandPoints = []
        isDrawingFreehand = false
        refresh()
    }

    func updateMeasurementCalibration(_ calibration: PixelCalibration?) {
        guard measurementCalibration != calibration else { return }
        measurementCalibration = calibration
        rebuildMeasurementLayer()
    }

    func updateFreehandSmoothing(_ smoothing: Double) {
        freehandSmoothing = min(max(smoothing, 0), 1)
    }
    
    /// Returns the id of the topmost annotation hit by an image-space point.
    func annotationID(at imagePoint: CGPoint) -> UUID? {
        // Iterate reversed so the most recently drawn (on top) wins.
        for annotation in store.annotations.reversed() {
            if store.isHidden(annotation.classID) { continue }
            let path = UIBezierPath()
            guard let first = annotation.points.first else { continue }
            path.move(to: first)
            for p in annotation.points.dropFirst() { path.addLine(to: p) }
            path.close()
            if path.contains(imagePoint) { return annotation.id }
        }
        return nil
    }

    // MARK: - Rendering

    /// Rebuilds vector paths after annotation/class state changes. No bitmap is
    /// allocated for the level-0 image bounds.
    func refresh(zoomScale: CGFloat? = nil) {
        renderedZoomScale = max(zoomScale ?? currentZoom, 0.000_001)

        normalAnnotationLayers.forEach { $0.removeFromSuperlayer() }
        normalAnnotationLayers.removeAll()
        selectedAnnotationLayer.path = nil
        editingAnnotationLayer.path = nil

        var normalPaths: [String: CGMutablePath] = [:]
        var normalColors: [String: UIColor] = [:]

        for annotation in store.annotations where !store.isHidden(annotation.classID) {
            let annotationPath = makePath(annotation.points, closed: annotation.isClosed)
            let opacity = CGFloat(store.opacity(for: annotation.classID))
            let color = UIColor(store.color(for: annotation.classID))
                .withAlphaComponent(opacity)
            if annotation.id == store.editingVertexAnnotationID {
                editingAnnotationLayer.path = annotationPath
                editingAnnotationLayer.strokeColor = UIColor.systemBlue
                    .withAlphaComponent(opacity)
                    .cgColor
            } else if annotation.id == store.selectedAnnotationID {
                selectedAnnotationLayer.path = annotationPath
                selectedAnnotationLayer.strokeColor = color.cgColor
            } else {
                let key = annotation.classID?.uuidString ?? "__unclassified__"
                let combined = normalPaths[key] ?? CGMutablePath()
                combined.addPath(annotationPath)
                normalPaths[key] = combined
                normalColors[key] = color
            }
        }

        for key in normalPaths.keys.sorted() {
            guard let path = normalPaths[key] else { continue }
            let shape = CAShapeLayer()
            shape.frame = bounds
            shape.path = path
            shape.fillColor = nil
            shape.strokeColor = normalColors[key]?.cgColor ?? UIColor.yellow.cgColor
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.contentsScale = window?.screen.scale ?? UIScreen.main.scale
            layer.insertSublayer(shape, below: selectedAnnotationLayer)
            normalAnnotationLayers.append(shape)
        }

        updateStrokeWidths()
        rebuildTransientLayers()
        rebuildMeasurementLayer()
        rebuildSelectedAnnotationLabel()
    }

    /// Zoom changes affect only screen-space stroke/handle sizes; the committed
    /// annotation paths remain in level-0 coordinates and are not rebuilt.
    func updateZoomScale(_ zoomScale: CGFloat) {
        let next = max(zoomScale, 0.000_001)
        guard abs(next - renderedZoomScale) > 0.000_001 else { return }
        renderedZoomScale = next
        updateStrokeWidths()
        rebuildTransientLayers()
        rebuildMeasurementLayer()
        rebuildSelectedAnnotationLabel()
    }

    private func updateStrokeWidths() {
        let lineWidth = max(1, 2 / renderedZoomScale)
        normalAnnotationLayers.forEach { $0.lineWidth = lineWidth }
        selectedAnnotationLayer.lineWidth = lineWidth * 2
        editingAnnotationLayer.lineWidth = lineWidth * 2
        progressLineLayer.lineWidth = lineWidth
        closeTargetLayer.lineWidth = max(0.5, 1.5 / renderedZoomScale)
        vertexHandlesLayer.lineWidth = min(max(1.5 / renderedZoomScale, 0.5), 4)
        measurementLineLayer.lineWidth = max(1, 2 / renderedZoomScale)
    }

    private func rebuildTransientLayers() {
        let zoom = renderedZoomScale
        let handles = CGMutablePath()
        if let editID = store.editingVertexAnnotationID,
           let annotation = store.annotations.first(where: { $0.id == editID }),
           canEditVertices(of: annotation) {
            let radius = min(max(5 / zoom, 2), 14)
            for point in annotation.points {
                handles.addEllipse(in: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
            }
        }
        vertexHandlesLayer.path = handles
        vertexHandlesLayer.fillColor = UIColor.white.cgColor
        vertexHandlesLayer.strokeColor = UIColor.systemBlue.cgColor

        let progressPoints = freehandPoints.isEmpty ? polygonPoints : freehandPoints
        progressLineLayer.path = makePath(progressPoints, closed: false)
        progressLineLayer.strokeColor = UIColor.systemGreen.cgColor

        let vertices = CGMutablePath()
        if freehandPoints.isEmpty {
            let radius = 3 / zoom
            for point in polygonPoints {
                vertices.addEllipse(in: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
            }
        }
        progressVertexLayer.path = vertices
        progressVertexLayer.fillColor = UIColor.systemGreen.cgColor
        progressVertexLayer.strokeColor = nil

        let closeTarget = CGMutablePath()
        if polygonPoints.count >= 3, let start = polygonPoints.first {
            let radius = closeThresholdScreenPoints / zoom
            closeTarget.addEllipse(in: CGRect(
                x: start.x - radius,
                y: start.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
        closeTargetLayer.path = closeTarget
        closeTargetLayer.fillColor = nil
        closeTargetLayer.strokeColor = UIColor.systemGreen.cgColor
    }

    private func rebuildMeasurementLayer() {
        // These properties update for every coalesced Pencil event. Prevent
        // Core Animation from interpolating toward stale intermediate frames.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let start = store.measurementStart,
              let end = store.measurementEnd else {
            measurementLineLayer.path = nil
            measurementLabelLayer.string = nil
            measurementLabelLayer.isHidden = true
            return
        }

        let dx = end.x - start.x
        let dy = end.y - start.y
        let pixelLength = hypot(dx, dy)
        guard pixelLength > 0.000_001 else {
            measurementLineLayer.path = nil
            measurementLabelLayer.string = nil
            measurementLabelLayer.isHidden = true
            return
        }

        let zoom = max(renderedZoomScale, 0.000_001)
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)

        // Short perpendicular end caps make the overlay read as a ruler while
        // remaining a constant visual size at every zoom level.
        let normalX = -dy / pixelLength
        let normalY = dx / pixelLength
        let halfCap = 6 / zoom
        for point in [start, end] {
            path.move(to: CGPoint(
                x: point.x - normalX * halfCap,
                y: point.y - normalY * halfCap
            ))
            path.addLine(to: CGPoint(
                x: point.x + normalX * halfCap,
                y: point.y + normalY * halfCap
            ))
        }

        measurementLineLayer.path = path
        measurementLineLayer.strokeColor = UIColor.systemYellow.cgColor
        measurementLineLayer.fillColor = nil
        measurementLineLayer.lineWidth = max(1, 2 / zoom)

        let label: String
        if let calibration = measurementCalibration {
            label = String(
                format: "%.1f µm",
                calibration.lengthInMicrons(from: start, to: end)
            )
        } else {
            label = String(format: "%.1f px • Set scale", Double(pixelLength))
        }

        let width = max(92, CGFloat(label.count) * 7.4 + 18) / zoom
        let height = 26 / zoom
        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        // Keep the readout above the ruler in screen coordinates. Following
        // the line's perpendicular made the label swing as its angle changed.
        let offset = 20 / zoom
        let placeBelow = midpoint.y - offset - height / 2 < 0
        let proposedCenter = CGPoint(
            x: midpoint.x,
            y: midpoint.y + (placeBelow ? offset : -offset)
        )
        let center = CGPoint(
            x: min(max(proposedCenter.x, width / 2), max(width / 2, bounds.width - width / 2)),
            y: min(max(proposedCenter.y, height / 2), max(height / 2, bounds.height - height / 2))
        )

        measurementLabelLayer.string = label
        measurementLabelLayer.fontSize = 13 / zoom
        measurementLabelLayer.cornerRadius = 5 / zoom
        measurementLabelLayer.contentsScale = min(
            (window?.screen.scale ?? UIScreen.main.scale) * zoom,
            8
        )
        measurementLabelLayer.frame = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        measurementLabelLayer.isHidden = false
    }

    private func rebuildSelectedAnnotationLabel() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let selectedID = store.selectedAnnotationID,
              let annotation = store.annotations.first(where: { $0.id == selectedID }),
              !annotation.points.isEmpty,
              !store.isHidden(annotation.classID) else {
            selectedAnnotationLabelLayer.string = nil
            selectedAnnotationLabelLayer.isHidden = true
            return
        }

        let label = store.label(for: annotation)
        let minX = annotation.points.map(\.x).min() ?? 0
        let maxX = annotation.points.map(\.x).max() ?? 0
        let minY = annotation.points.map(\.y).min() ?? 0
        let maxY = annotation.points.map(\.y).max() ?? 0
        let zoom = max(renderedZoomScale, 0.000_001)
        let width = min(180, max(72, CGFloat(label.count) * 7.2 + 18)) / zoom
        let height = 24 / zoom
        // Place the badge at the center of the annotation's bounding box on
        // both axes instead of floating it above or below the contour.
        let proposedCenter = CGPoint(
            x: (minX + maxX) / 2,
            y: (minY + maxY) / 2
        )
        let center = CGPoint(
            x: min(max(proposedCenter.x, width / 2), max(width / 2, bounds.width - width / 2)),
            y: min(max(proposedCenter.y, height / 2), max(height / 2, bounds.height - height / 2))
        )

        selectedAnnotationLabelLayer.string = label
        selectedAnnotationLabelLayer.fontSize = 12 / zoom
        selectedAnnotationLabelLayer.cornerRadius = 5 / zoom
        selectedAnnotationLabelLayer.contentsScale = min(
            (window?.screen.scale ?? UIScreen.main.scale) * zoom,
            8
        )
        selectedAnnotationLabelLayer.frame = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        selectedAnnotationLabelLayer.isHidden = false
    }
    
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard store.activeTool == .select else { return }
        let p = gesture.location(in: self)   // already image-pixel space
        store.selectedAnnotationID = annotationID(at: p)   // nil if tapped empty space
        refresh()
    }

    private func makePath(_ points: [CGPoint], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if closed { path.closeSubpath() }
        return path
    }

    /// Smooths over a screen-space arc-length radius rather than a fixed
    /// number of Pencil samples. Coalesced touches can be extremely dense, so
    /// adjacent-point smoothing alone is nearly invisible on real strokes.
    private func smoothedClosedStroke(
        _ points: [CGPoint],
        strength: Double
    ) -> [CGPoint] {
        guard !points.isEmpty else { return [] }

        var working = points
        if working.count > 1,
           let first = working.first,
           let last = working.last,
           hypot(last.x - first.x, last.y - first.y) < 0.000_001 {
            working.removeLast()
        }

        // Coalesced Pencil events can contain nearly identical neighboring
        // points. Remove only sub-screen duplicates so zoom does not change
        // the perceived smoothing scale.
        let minimumDistance = max(0.15 / currentZoom, 0.000_001)
        var deduplicated: [CGPoint] = []
        deduplicated.reserveCapacity(working.count)
        for point in working {
            if let last = deduplicated.last,
               hypot(point.x - last.x, point.y - last.y) < minimumDistance {
                continue
            }
            deduplicated.append(point)
        }
        working = deduplicated
        if working.count > 1,
           let first = working.first,
           let last = working.last,
           hypot(last.x - first.x, last.y - first.y) < minimumDistance {
            working.removeLast()
        }

        let clampedStrength = min(max(strength, 0), 1)
        guard clampedStrength >= 0.01, working.count >= 5 else {
            return working
        }

        let perimeter = working.indices.reduce(CGFloat.zero) { partial, index in
            let next = working[(index + 1) % working.count]
            return partial + hypot(
                next.x - working[index].x,
                next.y - working[index].y
            )
        }
        guard perimeter > 0 else { return working }

        // Medium smooths across roughly 15 screen points; Maximum uses 38.
        // Cap the radius for very small masks so distinct sides cannot blend.
        let requestedRadius = CGFloat(2 + 36 * clampedStrength)
            / max(currentZoom, 0.000_001)
        let radius = min(requestedRadius, perimeter * 0.18)
        guard radius > 0 else { return working }

        let originalArea = abs(signedArea(of: working))
        let originalCenter = meanPoint(of: working)
        var smoothed = arcLengthGaussianPass(
            working,
            radius: radius,
            sigma: max(radius * 0.45, 0.000_001)
        )

        // Gaussian smoothing rounds inward. Restore the original centroid and
        // enclosed area so smoothing does not systematically shrink cells.
        let smoothedArea = abs(signedArea(of: smoothed))
        let smoothedCenter = meanPoint(of: smoothed)
        let areaScale: CGFloat
        if originalArea > 0.000_001, smoothedArea > 0.000_001 {
            areaScale = min(
                max(CGFloat(sqrt(Double(originalArea / smoothedArea))), 0.8),
                1.25
            )
        } else {
            areaScale = 1
        }
        smoothed = smoothed.map { point in
            CGPoint(
                x: originalCenter.x + (point.x - smoothedCenter.x) * areaScale,
                y: originalCenter.y + (point.y - smoothedCenter.y) * areaScale
            )
        }

        return smoothed.map { point in
            CGPoint(
                x: min(max(point.x, 0), imagePixelSize.width),
                y: min(max(point.y, 0), imagePixelSize.height)
            )
        }
    }

    private func arcLengthGaussianPass(
        _ points: [CGPoint],
        radius: CGFloat,
        sigma: CGFloat
    ) -> [CGPoint] {
        guard points.count >= 3 else { return points }

        return points.indices.map { index in
            var weightedX = points[index].x
            var weightedY = points[index].y
            var totalWeight: CGFloat = 1

            for direction in [-1, 1] {
                var cursor = index
                var distance: CGFloat = 0
                for _ in 1..<points.count {
                    let neighbor = (cursor + direction + points.count) % points.count
                    distance += hypot(
                        points[neighbor].x - points[cursor].x,
                        points[neighbor].y - points[cursor].y
                    )
                    guard distance <= radius else { break }

                    let ratio = Double(distance / sigma)
                    let weight = CGFloat(exp(-0.5 * ratio * ratio))
                    weightedX += points[neighbor].x * weight
                    weightedY += points[neighbor].y * weight
                    totalWeight += weight
                    cursor = neighbor
                }
            }

            return CGPoint(
                x: weightedX / totalWeight,
                y: weightedY / totalWeight
            )
        }
    }

    private func signedArea(of points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        return points.indices.reduce(CGFloat.zero) { area, index in
            let next = points[(index + 1) % points.count]
            return area + points[index].x * next.y - next.x * points[index].y
        } / 2
    }

    private func meanPoint(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(
            x: sum.x / CGFloat(points.count),
            y: sum.y / CGFloat(points.count)
        )
    }
    
    /// If `point` is near a vertex of the selected annotation, returns its index.
    private func vertexIndex(at point: CGPoint) -> Int? {
        guard let selID = store.selectedAnnotationID,
              let annotation = store.annotations.first(where: { $0.id == selID }),
              canEditVertices(of: annotation)
        else { return nil }

        var best: (index: Int, dist: CGFloat)?
        for (i, v) in annotation.points.enumerated() {
            let d = hypot(point.x - v.x, point.y - v.y)
            if d < effectiveVertexRadius(for: annotation) {
                if best == nil || d < best!.dist {
                    best = (i, d)
                }
            }
        }
        return best?.index
    }
}
