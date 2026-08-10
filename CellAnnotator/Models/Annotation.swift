//
//  Annotation.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/5.
//

import SwiftUI   // for CGPoint and, later, Color

struct Annotation: Identifiable {
    let id = UUID()
    var points: [CGPoint]      // IMAGE coordinates, not screen
    var classID: UUID?         // which class — nil until step 3
    var isClosed: Bool         // polygon vs. open path
}
