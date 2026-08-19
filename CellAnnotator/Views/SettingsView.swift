//
//  SettingsView.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/7.
//


import SwiftUI

struct SettingsView: View {
    @Binding var authorInitials: String
    @Binding var freehandSmoothing: Double
    @Environment(\.dismiss) private var dismiss

    private var smoothingLabel: String {
        switch freehandSmoothing {
        case ..<0.01: return "Off"
        case ..<0.26: return "Light"
        case ..<0.56: return "Medium"
        case ..<0.81: return "Strong"
        default: return "Maximum"
        }
    }

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

                Section("Drawing") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Mask smoothing")
                            Spacer()
                            Text(smoothingLabel)
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $freehandSmoothing,
                            in: 0...1,
                            step: 0.05
                        ) {
                            Text("Smoothing of masks to remove jittery hand motions")
                        } minimumValueLabel: {
                            Text("Off")
                                .font(.caption)
                        } maximumValueLabel: {
                            Text("Max")
                                .font(.caption)
                        }
                    }
                    Text("Removes small hand-motion irregularities from newly drawn freehand masks. Existing annotations are not changed.")
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
