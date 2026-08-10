//
//  ContentView.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/5.
//

import SwiftUI
import UniformTypeIdentifiers

enum PerClassScope: Identifiable {
    case all, current
    var id: Int { self == .all ? 0 : 1 }
}

struct ContentView: View {
    @State private var image: UIImage?
    @State private var imageBaseName: String = ""
    @AppStorage("authorInitials") private var authorInitials = ""
    @State private var showingSettings = false
    @State private var perClassBaseName = ""
    @State private var shareURL: URL?
    @State private var showingShare = false
    @State private var showImporter = false
    @State private var errorMessage: String?
    @State private var store = AnnotationStore()
    @State private var showingClassPanel = false
    @State private var showingAddClass = false
    @State private var showingExporter = false
    @State private var showingGeoJSONImporter = false
    @State private var showingUnsavedAlert = false
    @State private var showingFolderPicker = false
    @State private var pendingOpenAfterSave = false
    @State private var exportDocument: GeoJSONDocument?
    @State private var perClassScopeForSheet: PerClassScope?
    @State private var proceedToFolderAfterPrompt = false
    @State private var committedScope: PerClassScope = .all
    private func classNames(for scope: PerClassScope) -> [String] {
        switch scope {
        case .current:
            return [displayedClassName]
        case .all:
            // Only classes that actually have annotations will produce files,
            // so preview those rather than every defined class.
            let usedClassIDs = Set(store.annotations.map { $0.classID })
            var names = store.classes
                .filter { usedClassIDs.contains($0.id) }
                .map { $0.name }
            if usedClassIDs.contains(nil) {
                names.append("Unclassified")
            }
            return names
        }
    }
    private var activeClassName: String {
        store.classes.first { $0.id == store.activeClassID }?.name ?? "Class"
    }
    private var displayedClassName: String {
        store.classes.first { $0.id == store.displayedClassID }?.name ?? "Class"
    }
    
    private var exportFilename: String {
        let base = imageBaseName.isEmpty ? "annotations" : imageBaseName
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            .replacingOccurrences(of: "/", with: "-")
        let who = authorInitials.isEmpty ? "" : "_\(authorInitials)"
        return "\(base)\(who)_\(stamp)"
    }

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ZoomableImageView(image: image, store: store)
                } else {
                    ContentUnavailableView {
                        Label("No Image", systemImage: "photo.on.rectangle")
                    } description: {
                        Text(errorMessage ?? "Load a TIFF to begin annotating.")
                    } actions: {
                        Button("Load TIFF") { showImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .overlay {
                if showingFolderPicker {
                    FolderPicker(isPresented: $showingFolderPicker) { folder in
                        exportPerClass(to: folder)
                    }
                }
            }
            .toolbar {
                if image != nil {
                    ToolbarItem(placement: .bottomBar) {
                        HStack(spacing: 12) {
                            // Tool picker — constrained narrow.
                            Picker("Tool", selection: $store.activeTool) {
                                Image(systemName: "scribble").tag(AnnotationTool.freehand)
                                Image(systemName: "hexagon").tag(AnnotationTool.polygon)
                                Image(systemName: "hand.tap").tag(AnnotationTool.select)
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()                    // shrink to fit content, don't stretch
                            
                            if store.activeTool == .polygon {
                                Button {
                                    store.requestClosePolygon()
                                } label: {
                                    Label("Finish", systemImage: "checkmark.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }

                            Divider()
                            
                            Button {
                                showingClassPanel = true
                            } label: {
                                Label("Classes", systemImage: "list.bullet")
                            }
                            .labelStyle(.iconOnly)

                            Button {
                                showingClassPanel = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(uiImage: store.color(for: store.displayedClassID).swatch())
                                    Text(displayedClassName)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(minWidth: 120)
                            }
                            
                            Menu {
                                Button {
                                    shareAnnotations()
                                } label: {
                                    Label("Share / Save…", systemImage: "square.and.arrow.up")
                                }
                                Button {
                                    perClassBaseName = imageBaseName
                                    perClassScopeForSheet = .all
                                } label: {
                                    Label("Save all classes (one file each)", systemImage: "folder")
                                }
                                Button {
                                    perClassBaseName = imageBaseName
                                    perClassScopeForSheet = .current
                                } label: {
                                    Label("Save current class only", systemImage: "tag")
                                }
                                .disabled(store.displayedClassID == nil)
                            } label: {
                                Label("Save", systemImage: "square.and.arrow.down")
                            }
                            .labelStyle(.iconOnly)
                            .disabled(store.annotations.isEmpty)

                            Button {
                                showingGeoJSONImporter = true
                            } label: {
                                Label("Load", systemImage: "square.and.arrow.up")
                            }
                            .labelStyle(.iconOnly)

                            Spacer(minLength: 12)
                            
                            if store.selectedAnnotationID != nil {
                                Button(role: .destructive) {
                                    store.snapshot()
                                    store.deleteSelected()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .labelStyle(.iconOnly)
                            }

                            Button {
                                store.undo()
                            } label: {
                                Label("Undo", systemImage: "arrow.uturn.backward")
                            }
                            .labelStyle(.iconOnly)
                            .disabled(!store.canUndo)
                            
                            Button {
                                if store.hasUnsavedChanges {
                                    showingUnsavedAlert = true
                                } else {
                                    showImporter = true
                                }
                            } label: {
                                Label("Open Image", systemImage: "photo")
                            }
                            .labelStyle(.iconOnly)
                            
                            Button {
                                showingSettings = true
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                }
            }
            // GeoJSON export
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: imageBaseName.isEmpty ? "annotations" : imageBaseName
            ) { result in
                switch result {
                case .success:
                    store.hasUnsavedChanges = false      // saved — no longer dirty
                    if pendingOpenAfterSave {
                        pendingOpenAfterSave = false
                        showImporter = true
                    }
                case .failure(let error):
                    pendingOpenAfterSave = false
                    errorMessage = error.localizedDescription
                }
            }
            // GeoJSON import
            .fileImporter(
                isPresented: $showingGeoJSONImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    loadAnnotations(from: url)
                }
            }
            .onAppear {
                #if DEBUG
                if image == nil {
                    do {
                        image = try ImageLoader.loadFromBundle("test")
                        imageBaseName = "test"
                    }
                    catch { errorMessage = error.localizedDescription }
                }
                #endif
            }
            .sheet(isPresented: $showingAddClass) {
                AddClassView(store: store)
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.tiff, UTType(filenameExtension: "tif") ?? .image],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("Unsaved annotations", isPresented: $showingUnsavedAlert) {
            Button("Save…") {
                pendingOpenAfterSave = true
                exportAnnotations()
            }
            Button("Discard", role: .destructive) {
                showImporter = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Opening a new image will close the current one. Please make sure you saved your annotations.")
        }
        .sheet(isPresented: $showingShare) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .sheet(isPresented: $showingClassPanel) {
            ClassPanelView(store: store)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(authorInitials: $authorInitials)
        }
        .sheet(item: $perClassScopeForSheet, onDismiss: {
            if proceedToFolderAfterPrompt {
                proceedToFolderAfterPrompt = false
                showingFolderPicker = true
            }
        }) { scope in
            BaseNamePromptView(
                baseName: $perClassBaseName,
                scope: scope,
                classNames: classNames(for: scope),
                onProceed: {
                    committedScope = scope
                    proceedToFolderAfterPrompt = true
                }
            )
        }
        .onKeyPress(.delete) {
            if store.selectedAnnotationID != nil {
                store.snapshot()
                store.deleteSelected()
                return .handled
            }
            return .ignored
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                image = try ImageLoader.load(from: url)
                imageBaseName = url.deletingPathExtension().lastPathComponent
                // New image → annotations from the old image no longer apply.
                store.annotations.removeAll()
                store.selectedAnnotationID = nil
                store.editingVertexAnnotationID = nil
                store.clearHistory()
                store.hasUnsavedChanges = false
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
    
    func loadAnnotations(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try GeoJSONConverter.annotations(from: data, store: store)
            store.snapshot()                          // make the load undoable
            store.annotations.append(contentsOf: loaded)   // merge, don't replace
            store.selectedAnnotationID = nil
            store.hasUnsavedChanges = true            // merging is an unsaved change
        } catch {
            errorMessage = "Couldn't load annotations: \(error.localizedDescription)"
        }
    }
    
    func shareAnnotations() {
        do {
            let meta = GeoJSONConverter.metadata(author: authorInitials, imageName: imageBaseName)
            let data = try GeoJSONConverter.data(from: store.annotations, store: store, metadata: meta)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(exportFilename).json")
            try data.write(to: tmp)
            shareURL = tmp
            showingShare = true
            store.hasUnsavedChanges = false
        } catch {
            errorMessage = "Couldn't prepare annotations: \(error.localizedDescription)"
        }
    }
    
    // Save button action:
    func exportAnnotations() {
        do {
            let meta = GeoJSONConverter.metadata(author: authorInitials, imageName: imageBaseName)
            let data = try GeoJSONConverter.data(from: store.annotations, store: store, metadata: meta)
            exportDocument = GeoJSONDocument(data: data)
            showingExporter = true
        } catch {
            errorMessage = "Couldn't prepare the file: \(error.localizedDescription)"
        }
    }
    func exportPerClass(to folder: URL) {
        let didAccess = folder.startAccessingSecurityScopedResource()
        defer { if didAccess { folder.stopAccessingSecurityScopedResource() } }

        // Filter annotations by scope.
        let toExport: [Annotation]
        switch committedScope {
        case .all:     toExport = store.annotations
        case .current: toExport = store.annotations.filter { $0.classID == store.displayedClassID }
        }

        guard !toExport.isEmpty else {
            errorMessage = "No annotations to export for this selection."
            return
        }

        do {
            let meta = GeoJSONConverter.metadata(author: authorInitials, imageName: imageBaseName)
            let files = try GeoJSONConverter.dataPerClass(from: toExport,
                                                          store: store,
                                                          baseName: perClassBaseName,
                                                          metadata: meta)
            for (filename, data) in files {
                try data.write(to: folder.appendingPathComponent(filename))
            }
            store.hasUnsavedChanges = false
        } catch {
            errorMessage = "Couldn't export: \(error.localizedDescription)"
        }
    }
}
