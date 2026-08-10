//
//  SettingsView.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/7.
//


import SwiftUI

struct SettingsView: View {
    @Binding var authorInitials: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Author") {
                    TextField("Your initials (e.g. TR)", text: $authorInitials)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
                Section {
                    Text("Initials are added to exported filenames and stored inside each GeoJSON file for provenance.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}