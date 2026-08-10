//
//  AnnotationOverlayView.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/5.
//

import UIKit
import SwiftUI

final class AnnotationOverlayView: UIView {
    private let store: AnnotationStore
    private let imagePixelSize: CGSize

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
    private var vertexHitRadiusImage: CGFloat {
        vertexHitRadiusScreen / currentZoom
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

    init(store: AnnotationStore, imagePixelSize: CGSize) {
        self.store = store
        self.imagePixelSize = imagePixelSize
        super.init(frame: CGRect(origin: .zero, size: imagePixelSize))
        backgroundColor = .clear
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)] // finger
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Touch handling (Pencil only)
    
    private func handleSelectTouch(at p: CGPoint) {
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
            if let hitID = annotationID(at: p), hitID == store.selectedAnnotationID {
                // Toggle: enter edit mode, or exit if already editing this one.
                if store.editingVertexAnnotationID == hitID {
                    store.editingVertexAnnotationID = nil
                } else {
                    store.editingVertexAnnotationID = hitID
                }
                setNeedsDisplay()
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
        }
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pencilTouch(from: touches) else { return }
        let p = touch.location(in: self)

        switch store.activeTool {
        case .freehand:
            guard isDrawingFreehand else { return }
            let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
            freehandPoints.append(contentsOf: coalesced.map { $0.location(in: self) })
            setNeedsDisplay()

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
            setNeedsDisplay()

        case .polygon:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let _ = pencilTouch(from: touches) else { return }
        
        if store.activeTool == .select {
            isDraggingSelection = false
            lastDragPoint = nil
            draggingVertexIndex = nil
            return
        }

        if store.activeTool == .freehand, isDrawingFreehand {
            isDrawingFreehand = false
            // TODO: thin freehandPoints here later (Douglas–Peucker / distance threshold)
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

                // 4. Commit (stored closed regardless — the append just makes the ring clean).
                store.snapshot()
                store.add(Annotation(points: freehandPoints,
                                     classID: store.activeClassID,
                                     isClosed: true))
            }
            freehandPoints = []
            setNeedsDisplay()
        }
        // Polygon does nothing on touch-end — it accumulates taps until closed.
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        isDrawingFreehand = false
        freehandPoints = []
        setNeedsDisplay()
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
        setNeedsDisplay()
    }

    func cancelInProgress() {
        polygonPoints = []
        freehandPoints = []
        isDrawingFreehand = false
        setNeedsDisplay()
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

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // Line width shrinks as the user zooms in, so it looks constant on screen.
        let zoom = (superview?.superview as? UIScrollView)?.zoomScale ?? 1
        let lineWidth = max(1, 2 / zoom)
        
        print("draw — zoom:", zoom, "lineWidth:", lineWidth,
                  "selected:", store.selectedAnnotationID as Any)

        // Committed annotations
        for annotation in store.annotations {
            if store.isHidden(annotation.classID) { continue }
            let isSelected = annotation.id == store.selectedAnnotationID
            let isEditing = annotation.id == store.editingVertexAnnotationID
            let color: UIColor = isEditing
                ? .systemBlue                                   // edit mode: blue outline
                : UIColor(store.color(for: annotation.classID)) // normal: class color
            strokePath(annotation.points, closed: annotation.isClosed,
                       color: color,
                       width: isSelected ? lineWidth * 2 : lineWidth,
                       in: ctx)
        }
        // Draw grab handles on the selected annotation.
        if let editID = store.editingVertexAnnotationID,
           let annotation = store.annotations.first(where: { $0.id == editID }) {

            // TODO: Freehand warp editing. Dense freehand shapes have too many
            // vertices to expose as individual handles (they overlap into a blob
            // and per-vertex dragging spikes the curve). Replace per-vertex handles
            // for high-count shapes with a "sculpt" interaction: dragging near the
            // boundary pushes nearby points along with a distance falloff, deforming
            // the curve smoothly. Until then, handles are shown only for low-vertex
            // (polygon-like) shapes; dense freehand gets whole-shape drag + delete only.
            if annotation.points.count <= 60 {
                let handleRadius = min(max(5 / zoom, 2), 14)
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.setStrokeColor(UIColor.systemBlue.cgColor)
                ctx.setLineWidth(min(max(1.5 / zoom, 0.5), 4))
                for v in annotation.points {
                    let rect = CGRect(x: v.x - handleRadius, y: v.y - handleRadius,
                                      width: 2 * handleRadius, height: 2 * handleRadius)
                    ctx.fillEllipse(in: rect)
                    ctx.strokeEllipse(in: rect)
                }
            }
        }
        // In-progress freehand
        if !freehandPoints.isEmpty {
            strokePath(freehandPoints, closed: false,
                       color: .systemGreen, width: lineWidth, in: ctx)
        }
        // In-progress polygon (draw vertices + connecting lines)
        if !polygonPoints.isEmpty {
            if polygonPoints.count >= 3, let start = polygonPoints.first {
                ctx.setStrokeColor(UIColor.systemGreen.cgColor)
                ctx.setLineWidth(1.5 / zoom)
                let r = closeThresholdInImageSpace
                ctx.strokeEllipse(in: CGRect(x: start.x - r, y: start.y - r,
                                             width: 2 * r, height: 2 * r))
            }
            strokePath(polygonPoints, closed: false,
                       color: .systemGreen, width: lineWidth, in: ctx)
            for pt in polygonPoints {
                ctx.setFillColor(UIColor.systemGreen.cgColor)
                ctx.fillEllipse(in: CGRect(x: pt.x - 3/zoom, y: pt.y - 3/zoom,
                                           width: 6/zoom, height: 6/zoom))
            }
        }
    }
    
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard store.activeTool == .select else { return }
        let p = gesture.location(in: self)   // already image-pixel space
        store.selectedAnnotationID = annotationID(at: p)   // nil if tapped empty space
        setNeedsDisplay()
    }

    private func strokePath(_ points: [CGPoint], closed: Bool,
                            color: UIColor, width: CGFloat, in ctx: CGContext) {
        guard let first = points.first else { return }
        let path = UIBezierPath()
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        if closed { path.close() }
        color.setStroke()
        path.lineWidth = width
        path.stroke()
    }
    
    /// If `point` is near a vertex of the selected annotation, returns its index.
    private func vertexIndex(at point: CGPoint) -> Int? {
        guard let selID = store.selectedAnnotationID,
              let annotation = store.annotations.first(where: { $0.id == selID })
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
