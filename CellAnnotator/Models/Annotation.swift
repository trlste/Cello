//
//  Annotation.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/5.
//

import SwiftUI   // for CGPoint and, later, Color

struct Annotation: Identifiable {
    let id: UUID
    var points: [CGPoint]      // IMAGE coordinates, not screen
    var classID: UUID?         // which class — nil until step 3
    var isClosed: Bool         // polygon vs. open path
    /// Stable, per-class number used for names such as "Cell 3".
    /// Zero means the store should assign the next available number.
    var displayNumber: Int

    init(
        id: UUID = UUID(),
        points: [CGPoint],
        classID: UUID?,
        isClosed: Bool,
        displayNumber: Int = 0
    ) {
        self.id = id
        self.points = points
        self.classID = classID
        self.isClosed = isClosed
        self.displayNumber = displayNumber
    }
}
