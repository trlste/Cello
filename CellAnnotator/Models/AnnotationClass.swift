//
//  AnnotationClass.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/6.
//

import SwiftUI

struct AnnotationClass: Identifiable, Equatable {
    let id: UUID
    var name: String
    var color: Color

    init(id: UUID = UUID(), name: String, color: Color) {
        self.id = id
        self.name = name
        self.color = color
    }
}

extension AnnotationClass {
    /// IF defaults, seeded on first launch.
    /// TODO: Change this after implementing presets.
    static let presets: [AnnotationClass] = [
        AnnotationClass(name: "Nuclei",      color: .blue),
        AnnotationClass(name: "Membrane",     color: .red)
    ]
}
