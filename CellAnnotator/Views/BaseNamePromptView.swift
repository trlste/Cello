//
//  BaseNamePromptView.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/6.
//

import SwiftUI

struct BaseNamePromptView: View {
    @Binding var baseName: String
    let scope: PerClassScope
    let classNames: [String]        // the class name(s) to show in the preview
    let onProceed: () -> Void

    @Environment(\.dismiss) private var dismiss

    private func filename(for className: String) -> String {
            let trimmed = baseName.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "\(className).json"
                                   : "\(trimmed)_\(className).json"
        }

    var body: some View {
        NavigationStack {
            Form {
                Section("Base name") {
                    TextField("e.g. slide42", text: $baseName)
                        .autocorrectionDisabled()
                }
                Section(scope == .all && classNames.count > 1 ? "Files to create" : "Preview") {
                    ForEach(classNames, id: \.self) { name in
                        Text(filename(for: name))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(scope == .current ? "Save Current Class" : "Save All Classes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose Folder…") {
                        onProceed()
                        dismiss()
                    }
                }
            }
        }
    }
}
