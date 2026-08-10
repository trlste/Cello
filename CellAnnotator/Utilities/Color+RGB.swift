//
//  Color+RGB.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/6.
//

import SwiftUI
import UIKit

extension Color {
    /// RGB components as 0–255 ints, for QuPath's `color` array.
    var rgb255: [Int] {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Int((r * 255).rounded()),
                Int((g * 255).rounded()),
                Int((b * 255).rounded())]
    }

    init(rgb255: [Int]) {
        guard rgb255.count == 3 else { self = .gray; return }
        self = Color(red: Double(rgb255[0]) / 255,
                     green: Double(rgb255[1]) / 255,
                     blue: Double(rgb255[2]) / 255)
    }
}
