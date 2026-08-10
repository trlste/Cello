//
//  GeoJSON.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/6.
//

import Foundation

struct FeatureCollection: Codable {
    let type: String
    var features: [Feature]
    var metadata: ExportMetadata?          // ← new, optional

    init(features: [Feature], metadata: ExportMetadata? = nil) {
        self.type = "FeatureCollection"
        self.features = features
        self.metadata = metadata
    }
}


struct Feature: Codable {
    let type: String
    var geometry: Geometry
    var properties: Properties
    init(geometry: Geometry, properties: Properties) {
        self.type = "Feature"; self.geometry = geometry; self.properties = properties
    }
}

struct Geometry: Codable {
    let type: String                 // "Polygon"
    // Polygon coordinates: array of rings, each ring an array of [x, y] pairs.
    var coordinates: [[[Double]]]
    init(polygonRing ring: [[Double]]) {
        self.type = "Polygon"; self.coordinates = [ring]
    }
}

struct Properties: Codable {
    var name: String?
    var classification: Classification?
    var isLocked: Bool
    var measurements: [String: Double]
}

struct Classification: Codable {
    var name: String
    var color: [Int]                 // [r, g, b]
}

struct ExportMetadata: Codable {
    var exportedAt: String       // ISO 8601 timestamp
    var author: String?          // initials
    var imageName: String?       // which image these annotate
    var appVersion: String?
}
