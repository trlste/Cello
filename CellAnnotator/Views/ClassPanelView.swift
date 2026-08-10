//
//  ClassPanelView.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/6.
//


import SwiftUI

struct ClassPanelView: View {
    let store: AnnotationStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddClass = false

    // Mirrors the old Menu's dual behavior.
    private func pickClass(_ id: UUID) {
        print("pickClass — selectedAnnotationID:", store.selectedAnnotationID as Any)
        if store.selectedAnnotationID != nil {
            store.snapshot()
            store.reassignSelected(to: id)
        } else {
            store.activeClassID = id
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.classes) { cls in
                    let isActive = cls.id == store.displayedClassID
                    let isHidden = store.hiddenClassIDs.contains(cls.id)

                    HStack(spacing: 12) {
                        Circle()
                            .fill(cls.color)
                            .frame(width: 16, height: 16)

                        Text(cls.name)
                            .fontWeight(isActive ? .semibold : .regular)

                        if isActive {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(.tint)
                        }

                        Spacer()

                        Text("\(store.annotationCount(for: cls.id))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        Button {
                            store.toggleVisibility(cls.id)
                        } label: {
                            Image(systemName: isHidden ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isHidden ? .secondary : .primary)
                    }
                    .contentShape(Rectangle())           // whole row tappable
                    .onTapGesture { pickClass(cls.id) }
                    .opacity(isHidden ? 0.5 : 1)
                }
            }
            .navigationTitle(store.selectedAnnotationID != nil ? "Reassign Class" : "Classes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddClass = true
                    } label: {
                        Label("Add Class", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddClass) {
                AddClassView(store: store)
            }
        }
    }
}
