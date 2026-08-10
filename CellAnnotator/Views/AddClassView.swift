//
//  AddClassView.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/6.
//

import SwiftUI

struct AddClassView: View {
    let store: AnnotationStore
    @Environment(\.dismiss) private var dismiss
    @State private var isSubmitting = false

    @State private var name: String = ""
    @State private var color: Color = .purple

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        store.classes.contains {
            $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !isDuplicate
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Pan-CK", text: $name)
                        .autocorrectionDisabled()
                }

                Section("Color") {
                    ColorPicker("Class color", selection: $color, supportsOpacity: false)
                }

                if isDuplicate && !isSubmitting {
                    Section {
                        Text("A class named \"\(trimmedName)\" already exists.")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("New Class")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let name = trimmedName
                        let chosenColor = color
                        isSubmitting = true
                        store.addClass(name: name, color: chosenColor)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
