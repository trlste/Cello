//
//  GeoJSONConverter.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/6.
//

import SwiftUI

enum GeoJSONConverter {

    // MARK: - Export

    static func featureCollection(from annotations: [Annotation],
                                  store: AnnotationStore) -> FeatureCollection {
        let features = annotations.map { annotation -> Feature in
            // Build the coordinate ring, closing it (first == last).
            var ring = annotation.points.map { [Double($0.x), Double($0.y)] }
            if let first = ring.first, let last = ring.last, first != last {
                ring.append(first)
            }

            // Resolve classification from the store.
            var classification: Classification?
            if let classID = annotation.classID,
               let cls = store.classes.first(where: { $0.id == classID }) {
                classification = Classification(name: cls.name, color: cls.color.rgb255)
            }

            let props = Properties(name: nil,
                                   classification: classification,
                                   isLocked: false,
                                   measurements: [:])
            return Feature(geometry: Geometry(polygonRing: ring), properties: props)
        }
        return FeatureCollection(features: features)
    }

    static func data(from annotations: [Annotation],
                     store: AnnotationStore,
                     metadata: ExportMetadata? = nil) throws -> Data {
        var fc = featureCollection(from: annotations, store: store)
        fc.metadata = metadata
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        return try encoder.encode(fc)
    }
    
    static func metadata(author: String, imageName: String) -> ExportMetadata {
        let formatter = ISO8601DateFormatter()
        return ExportMetadata(
            exportedAt: formatter.string(from: Date()),
            author: author.isEmpty ? nil : author,
            imageName: imageName.isEmpty ? nil : imageName,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
    }

    // MARK: - Import

    static func annotations(from data: Data,
                            store: AnnotationStore) throws -> [Annotation] {
        let fc = try JSONDecoder().decode(FeatureCollection.self, from: data)
        return fc.features.compactMap { feature in
            guard feature.geometry.type == "Polygon",
                  let ring = feature.geometry.coordinates.first else { return nil }

            let points = ring.map { CGPoint(x: $0[0], y: $0[1]) }

            // Match or create the class by name.
            var classID: UUID?
            if let classification = feature.properties.classification {
                classID = resolveClass(classification, in: store)
            }
            return Annotation(points: points, classID: classID, isClosed: true)
        }
    }
    
    /// One GeoJSON Data blob per class that has annotations.
    /// Returns [suggestedFilename: fileData].
    static func dataPerClass(from annotations: [Annotation],
                             store: AnnotationStore,
                             baseName: String = "",
                             metadata: ExportMetadata? = nil) throws -> [String: Data] {
        // Group annotations by classID (nil → "Unclassified").
        let grouped = Dictionary(grouping: annotations) { $0.classID }

        var result: [String: Data] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]

        for (classID, group) in grouped {
            var fc = featureCollection(from: group, store: store)
            fc.metadata = metadata

            // Resolve a filename from the class name.
            let className: String
            if let classID, let cls = store.classes.first(where: { $0.id == classID }) {
                className = cls.name
            } else {
                className = "Unclassified"
            }
            let prefix = sanitizeFilename(baseName)
            let safeName = sanitizeFilename(className)
            let filename = prefix.isEmpty ? "\(safeName).json" : "\(prefix)_\(safeName).json"
            result[filename] = try encoder.encode(fc)
        }
        return result
    }

    /// Strips characters that are illegal or awkward in filenames.
    private static func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "class" : trimmed
    }

    /// Finds a class by name, or creates it from the GeoJSON color if absent.
    private static func resolveClass(_ classification: Classification,
                                     in store: AnnotationStore) -> UUID {
        if let existing = store.classes.first(where: {
            $0.name.caseInsensitiveCompare(classification.name) == .orderedSame
        }) {
            return existing.id
        }
        let color = Color(rgb255: classification.color)
        store.addClass(name: classification.name, color: color)
        return store.classes.last!.id
    }
}
