//
//  AnnotationStore.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/5.
//

import SwiftUI
import Observation

enum AnnotationTool: Equatable {
    case freehand
    case polygon
    case select
    case measure
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

    // The ruler is viewer state rather than an annotation: it is not exported,
    // included in Undo, or counted as an unsaved change.
    var measurementStart: CGPoint?
    var measurementEnd: CGPoint?

    var hasMeasurement: Bool {
        measurementStart != nil && measurementEnd != nil
    }
    
    // Classes
    var classes: [AnnotationClass] = AnnotationClass.presets
    var activeClassID: UUID?
    var hiddenClassIDs: Set<UUID> = []
    /// Incremented when an external class/visibility change requires the
    /// UIKit annotation overlay to rebuild its shape layers.
    var annotationDisplayRevision = 0
    private(set) var annotationFocusRevision = 0
    private(set) var requestedAnnotationFocusID: UUID?

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
    func addClass(name: String, color: Color, opacity: Double = 1) {
        let cls = AnnotationClass(name: name, color: color, opacity: opacity)
        classes.append(cls)
        activeClassID = cls.id       // select the newly created class
    }

    func updateClass(id: UUID, name: String, color: Color, opacity: Double) {
        guard let index = classes.firstIndex(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let previous = classes[index]
        classes[index].name = trimmedName
        classes[index].color = color
        classes[index].opacity = min(max(opacity, 0), 1)
        annotationDisplayRevision += 1

        // Name and color are written to exported GeoJSON classifications.
        // Opacity is a viewer-only setting and does not dirty the annotations.
        let exportAppearanceChanged = previous.name != classes[index].name
            || previous.color != classes[index].color
        if exportAppearanceChanged && annotationCount(for: id) > 0 {
            hasUnsavedChanges = true
        }
    }

    func deleteClass(_ classID: UUID) {
        guard classes.contains(where: { $0.id == classID }) else { return }
        let removedAnnotationIDs = Set(
            annotations.lazy.filter { $0.classID == classID }.map(\.id)
        )

        annotations.removeAll { $0.classID == classID }
        classes.removeAll { $0.id == classID }
        hiddenClassIDs.remove(classID)

        if activeClassID == classID {
            activeClassID = classes.first?.id
        }
        if let selectedAnnotationID, removedAnnotationIDs.contains(selectedAnnotationID) {
            self.selectedAnnotationID = nil
            editingVertexAnnotationID = nil
        }

        // Undo snapshots contain annotations but not their class definitions.
        // Purging this class from every snapshot prevents Undo from restoring
        // annotations that would reference a class that no longer exists.
        undoStack = undoStack.map { snapshot in
            snapshot.filter { $0.classID != classID }
        }
        annotationDisplayRevision += 1
        if !removedAnnotationIDs.isEmpty {
            hasUnsavedChanges = true
        }
    }

    func color(for classID: UUID?) -> Color {
        guard let classID, let cls = classes.first(where: { $0.id == classID }) else {
            return .yellow   // fallback for unclassified
        }
        return cls.color
    }

    func opacity(for classID: UUID?) -> Double {
        guard let classID, let cls = classes.first(where: { $0.id == classID }) else {
            return 1
        }
        return cls.opacity
    }

    func reassignSelected(to classID: UUID) {
        guard let selID = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == selID }) else {
            print("reassign — guard failed"); return}
        guard annotations[idx].classID != classID else { return }
        print("reassign — annotation", selID, "from", annotations[idx].classID as Any, "to", classID)
        let newDisplayNumber = nextDisplayNumber(for: classID)
        annotations[idx].classID = classID
        annotations[idx].displayNumber = newDisplayNumber
        annotationDisplayRevision += 1
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

    func beginMeasurement(at point: CGPoint) {
        measurementStart = point
        measurementEnd = point
    }

    func updateMeasurement(to point: CGPoint, imageSize: CGSize) {
        guard measurementStart != nil else { return }
        measurementEnd = CGPoint(
            x: min(max(point.x, 0), imageSize.width),
            y: min(max(point.y, 0), imageSize.height)
        )
    }

    func clearMeasurement() {
        measurementStart = nil
        measurementEnd = nil
    }

    func add(_ annotation: Annotation) {
        var numbered = annotation
        numbered.displayNumber = availableDisplayNumber(
            preferred: annotation.displayNumber,
            classID: annotation.classID
        )
        annotations.append(numbered)
        hasUnsavedChanges = true
    }

    func add(contentsOf newAnnotations: [Annotation]) {
        guard !newAnnotations.isEmpty else { return }
        for annotation in newAnnotations {
            var numbered = annotation
            numbered.displayNumber = availableDisplayNumber(
                preferred: annotation.displayNumber,
                classID: annotation.classID
            )
            annotations.append(numbered)
        }
        hasUnsavedChanges = true
    }

    func label(for annotation: Annotation) -> String {
        let className = annotation.classID.flatMap { classID in
            classes.first(where: { $0.id == classID })?.name
        } ?? "Unclassified"
        return "\(className) \(max(1, annotation.displayNumber))"
    }

    func label(for annotationID: UUID?) -> String? {
        guard let annotationID,
              let annotation = annotations.first(where: { $0.id == annotationID }) else {
            return nil
        }
        return label(for: annotation)
    }

    func selectAnnotation(_ annotationID: UUID, requestFocus: Bool = true) {
        guard let annotation = annotations.first(where: { $0.id == annotationID }) else { return }
        if let classID = annotation.classID {
            hiddenClassIDs.remove(classID)
        }
        activeTool = .select
        selectedAnnotationID = annotationID
        editingVertexAnnotationID = nil
        annotationDisplayRevision += 1

        if requestFocus {
            requestedAnnotationFocusID = annotationID
            annotationFocusRevision &+= 1
        }
    }

    private func nextDisplayNumber(for classID: UUID?) -> Int {
        annotations.lazy
            .filter { $0.classID == classID }
            .map(\.displayNumber)
            .max()
            .map { max(1, $0 + 1) } ?? 1
    }

    private func availableDisplayNumber(preferred: Int, classID: UUID?) -> Int {
        let used = Set(
            annotations.lazy
                .filter { $0.classID == classID }
                .map(\.displayNumber)
        )
        if preferred > 0, !used.contains(preferred) {
            return preferred
        }
        return max(1, (used.max() ?? 0) + 1)
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
        annotationDisplayRevision += 1
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
