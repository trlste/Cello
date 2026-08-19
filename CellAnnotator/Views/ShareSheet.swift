//
//  ShareSheet.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/7.
//

//
//  ShareSheet.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/7.
//


import SwiftUI
import UIKit

/// A single source of truth for presenting the share sheet.
///
/// Keeping the URL and presentation identity in one value prevents SwiftUI
/// from presenting an empty sheet while a separate optional URL is still nil.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    /// Called after the selected activity finishes. `completed` is false when
    /// the person cancels the sheet or the activity fails.
    var completion: ((Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, _ in
            DispatchQueue.main.async {
                completion?(completed)
            }
        }
        return controller
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
