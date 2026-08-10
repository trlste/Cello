//
//  AnnotationStore.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/5.
//

import SwiftUI
import Observation

enum AnnotationTool {
    case freehand
    case polygon
    case select
}

@Observable
final class AnnotationStore {
    var annotations: [Annotation] = []
    var activeTool: AnnotationTool = .freehand {
        didSet {
            if activeTool != .select {
                selectedAnnotationID = nil
                editingVertexAnnotationID = nil   // leaving select mode exits edit mode
            }
        }
    }
    var closePolygonRequest: Int = 0
    
    // Classes
    var classes: [AnnotationClass] = AnnotationClass.presets
    var activeClassID: UUID?
    var hiddenClassIDs: Set<UUID> = []

    // Selection (for reassigning an existing annotation)
    var selectedAnnotationID: UUID?
    
    var hasUnsavedChanges = false
    
    private var undoStack: [[Annotation]] = []
    private let maxUndoDepth = 50
    
    var canUndo: Bool { !undoStack.isEmpty }
    
    var editingVertexAnnotationID: UUID?   // non-nil = vertex-edit mode for this annotation
    
    var displayedClassID: UUID? {
        if let selID = selectedAnnotationID,
           let sel = annotations.first(where: { $0.id == selID }) {
            return sel.classID
        }
        return activeClassID
    }
    
    init() {
        activeClassID = classes.first?.id   // start with a class selected
    }
    
    func snapshot() {
        undoStack.append(annotations)
        if undoStack.count > maxUndoDepth {
            undoStack.removeFirst()      // cap memory; drop oldest
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        annotations = previous
        selectedAnnotationID = nil       // selection may point at a now-gone annotation
        editingVertexAnnotationID = nil
        hasUnsavedChanges = true
    }
    
    // Class management
    func addClass(name: String, color: Color) {
        let cls = AnnotationClass(name: name, color: color)
        classes.append(cls)
        activeClassID = cls.id       // select the newly created class
    }

    func color(for classID: UUID?) -> Color {
        guard let classID, let cls = classes.first(where: { $0.id == classID }) else {
            return .yellow   // fallback for unclassified
        }
        return cls.color
    }

    func reassignSelected(to classID: UUID) {
        guard let selID = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == selID }) else {
            print("reassign — guard failed"); return}
        print("reassign — annotation", selID, "from", annotations[idx].classID as Any, "to", classID)
        annotations[idx].classID = classID
        hasUnsavedChanges = true
    }
    func deleteSelected() {
        guard let selID = selectedAnnotationID else { return }
        annotations.removeAll { $0.id == selID }
        selectedAnnotationID = nil
        editingVertexAnnotationID = nil
        hasUnsavedChanges = true
    }

    /// Moves the selected annotation by a delta in image-pixel space.
    func moveSelected(by delta: CGSize, imageSize: CGSize) {
        guard let selID = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == selID }) else { return }

        let pts = annotations[idx].points
        guard !pts.isEmpty else { return }

        // Current bounding box.
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!

        // Clamp delta so the box can't leave [0, imageSize].
        let clampedDX = max(-minX, min(delta.width,  imageSize.width  - maxX))
        let clampedDY = max(-minY, min(delta.height, imageSize.height - maxY))

        annotations[idx].points = pts.map {
            CGPoint(x: $0.x + clampedDX, y: $0.y + clampedDY)
        }
        hasUnsavedChanges = true
    }
    
    func moveVertex(annotationID: UUID, vertexIndex: Int,
                    to point: CGPoint, imageSize: CGSize) {
        guard let idx = annotations.firstIndex(where: { $0.id == annotationID }),
              annotations[idx].points.indices.contains(vertexIndex) else { return }
        // Clamp the vertex to image bounds.
        let clamped = CGPoint(x: min(max(point.x, 0), imageSize.width),
                              y: min(max(point.y, 0), imageSize.height))
        annotations[idx].points[vertexIndex] = clamped
        hasUnsavedChanges = true
    }
    
    func requestClosePolygon() {
            closePolygonRequest += 1
    }

    func add(_ annotation: Annotation) {
        annotations.append(annotation)
        hasUnsavedChanges = true
    }

    func removeLast() {
        if !annotations.isEmpty {
            annotations.removeLast()
            hasUnsavedChanges = true
        }
    }

    func clear() {
        annotations.removeAll()
        hasUnsavedChanges = true
    }
    
    func clearHistory() {
        undoStack.removeAll()
        // redoStack.removeAll()
    }
    
    func toggleVisibility(_ classID: UUID) {
        if hiddenClassIDs.contains(classID) {
            hiddenClassIDs.remove(classID)
        } else {
            hiddenClassIDs.insert(classID)
            // If the selected/editing annotation belongs to the now-hidden class, deselect.
            if let selID = selectedAnnotationID,
               let sel = annotations.first(where: { $0.id == selID }),
               sel.classID == classID {
                selectedAnnotationID = nil
                editingVertexAnnotationID = nil
            }
        }
    }

    func isHidden(_ classID: UUID?) -> Bool {
        guard let classID else { return false }   // unclassified always visible
        return hiddenClassIDs.contains(classID)
    }

    /// Count of annotations in a class — handy for the panel.
    func annotationCount(for classID: UUID) -> Int {
        annotations.filter { $0.classID == classID }.count
    }
}
