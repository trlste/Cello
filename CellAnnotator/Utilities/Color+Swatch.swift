//
//  Color+Swatch.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/6.
//

import SwiftUI
import UIKit

extension Color {
    /// A small filled-circle swatch as a UIImage — survives Menu's icon tinting.
    func swatch(diameter: CGFloat = 16) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiColor = UIColor(self)
        return renderer.image { ctx in
            uiColor.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
        .withRenderingMode(.alwaysOriginal)   // <- key: don't let the menu re-tint it
    }
}
