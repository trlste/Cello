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
    @State private var classToEdit: AnnotationClass?
    @State private var classPendingDeletion: AnnotationClass?
    @State private var renamingClassID: UUID?
    @State private var draftClassName = ""
    @State private var renameError: String?
    @FocusState private var focusedClassNameID: UUID?

    private var isShowingDeleteConfirmation: Binding<Bool> {
        Binding(
            get: { classPendingDeletion != nil },
            set: { isPresented in
                if !isPresented { classPendingDeletion = nil }
            }
        )
    }

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

    private func colorBinding(for classID: UUID) -> Binding<Color> {
        Binding(
            get: {
                store.classes.first(where: { $0.id == classID })?.color ?? .gray
            },
            set: { newColor in
                guard let cls = store.classes.first(where: { $0.id == classID }) else { return }
                store.updateClass(
                    id: classID,
                    name: cls.name,
                    color: newColor,
                    opacity: cls.opacity
                )
            }
        )
    }

    private func beginRenaming(_ cls: AnnotationClass) {
        renamingClassID = cls.id
        draftClassName = cls.name
        renameError = nil
        Task { @MainActor in
            focusedClassNameID = cls.id
        }
    }

    private func cancelRenaming() {
        renamingClassID = nil
        focusedClassNameID = nil
        renameError = nil
    }

    private func commitRename(for classID: UUID) {
        guard let cls = store.classes.first(where: { $0.id == classID }) else {
            cancelRenaming()
            return
        }
        let trimmedName = draftClassName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            renameError = "Class name cannot be empty."
            focusedClassNameID = classID
            return
        }
        guard !store.classes.contains(where: {
            $0.id != classID && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }) else {
            renameError = "A class named \"\(trimmedName)\" already exists."
            focusedClassNameID = classID
            return
        }

        store.updateClass(
            id: classID,
            name: trimmedName,
            color: cls.color,
            opacity: cls.opacity
        )
        cancelRenaming()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.classes) { cls in
                        let isActive = cls.id == store.displayedClassID
                        let isHidden = store.hiddenClassIDs.contains(cls.id)

                        HStack(spacing: 12) {
                            ColorPicker(
                                "Color for \(cls.name)",
                                selection: colorBinding(for: cls.id),
                                supportsOpacity: false
                            )
                            .labelsHidden()
                            .fixedSize()

                            VStack(alignment: .leading, spacing: 2) {
                                if renamingClassID == cls.id {
                                    HStack(spacing: 6) {
                                        TextField("Class name", text: $draftClassName)
                                            .textFieldStyle(.roundedBorder)
                                            .autocorrectionDisabled()
                                            .focused($focusedClassNameID, equals: cls.id)
                                            .submitLabel(.done)
                                            .onSubmit { commitRename(for: cls.id) }

                                        Button {
                                            commitRename(for: cls.id)
                                        } label: {
                                            Image(systemName: "checkmark.circle.fill")
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.tint)
                                        .accessibilityLabel("Save class name")

                                        Button {
                                            cancelRenaming()
                                        } label: {
                                            Image(systemName: "xmark.circle")
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("Cancel renaming")
                                    }

                                    if let renameError {
                                        Text(renameError)
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                    }
                                } else {
                                    Text(cls.name)
                                        .fontWeight(isActive ? .semibold : .regular)
                                        .onTapGesture(count: 2) {
                                            beginRenaming(cls)
                                        }
                                        .accessibilityHint("Double-tap to rename")
                                }
                                if cls.opacity < 0.999 {
                                    Text("\(Int((cls.opacity * 100).rounded()))% opacity")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

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

                            Menu {
                                Button {
                                    classToEdit = cls
                                } label: {
                                    Label("Edit Class", systemImage: "pencil")
                                }

                                Button(role: .destructive) {
                                    classPendingDeletion = cls
                                } label: {
                                    Label("Delete Class", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("More options for \(cls.name)")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { pickClass(cls.id) }
                        .opacity(isHidden ? 0.5 : 1)
                    }
                } footer: {
                    Text("Tap a color swatch to change it. Double-tap a class name to rename it.")
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
            .sheet(item: $classToEdit) { cls in
                EditClassView(store: store, annotationClass: cls)
            }
            .alert(
                "Delete Class?",
                isPresented: isShowingDeleteConfirmation,
                presenting: classPendingDeletion
            ) { cls in
                Button("Delete Class and Annotations", role: .destructive) {
                    store.deleteClass(cls.id)
                    classPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    classPendingDeletion = nil
                }
            } message: { cls in
                let count = store.annotationCount(for: cls.id)
                if count == 1 {
                    Text("This permanently deletes \"\(cls.name)\" and its 1 annotation.")
                } else {
                    Text("This permanently deletes \"\(cls.name)\" and its \(count) annotations.")
                }
            }
        }
    }
}

private struct EditClassView: View {
    let store: AnnotationStore
    let annotationClass: AnnotationClass
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var color: Color
    @State private var opacity: Double

    init(store: AnnotationStore, annotationClass: AnnotationClass) {
        self.store = store
        self.annotationClass = annotationClass
        _name = State(initialValue: annotationClass.name)
        _color = State(initialValue: annotationClass.color)
        _opacity = State(initialValue: annotationClass.opacity)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        store.classes.contains {
            $0.id != annotationClass.id
                && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        }
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && !isDuplicate
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Class name", text: $name)
                        .autocorrectionDisabled()
                }

                Section("Color") {
                    ColorPicker("Class color", selection: $color, supportsOpacity: false)
                }

                Section("Annotation Opacity") {
                    HStack(spacing: 12) {
                        Slider(value: $opacity, in: 0...1, step: 0.05)
                        Text("\(Int((opacity * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }

                    HStack(spacing: 10) {
                        Text("Preview")
                        Spacer()
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(color.opacity(opacity), lineWidth: 3)
                            .frame(width: 64, height: 28)
                    }
                }

                if isDuplicate {
                    Section {
                        Text("A class named \"\(trimmedName)\" already exists.")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Edit Class")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.updateClass(
                            id: annotationClass.id,
                            name: trimmedName,
                            color: color,
                            opacity: opacity
                        )
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
