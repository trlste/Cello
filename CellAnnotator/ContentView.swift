//
//  ContentView.swift
//  CellAnnotator
//
//  Created by Triss Ren on 2026/8/5.
//

import SwiftUI
import UniformTypeIdentifiers

enum PerClassScope: Identifiable, Equatable {
    case all, current
    var id: Int { self == .all ? 0 : 1 }
}

struct ContentView: View {
    @State private var imageDocument: TIFFDocument?
    @State private var imageBaseName: String = ""
    @AppStorage("authorInitials") private var authorInitials = ""
    @AppStorage("freehandMaskSmoothing") private var freehandMaskSmoothing = 0.35
    @State private var showingSettings = false
    @State private var showingLayers = false
    @State private var showingChannelAdjustments = false
    @State private var showingMeasurementCalibration = false
    @State private var measurementCalibrationWasRequired = false
    @State private var perClassBaseName = ""
    @State private var shareItem: ShareItem?
    @State private var showImporter = false
    @State private var isLoadingImage = false
    @State private var showOpeningOverlay = false
    @State private var openingOverlayDelayTask: Task<Void, Never>?
    @State private var tileRenderStatus = TileRenderStatus.idle
    @State private var presentedTileRenderStatus = TileRenderStatus.idle
    @State private var tileIndicatorDelayTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var store = AnnotationStore()
    @State private var showingClassPanel = false
    @State private var showingAnnotationPicker = false
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
                if let imageDocument {
                    ZoomableImageView(
                        document: imageDocument,
                        store: store,
                        displaySettings: imageDocument.channelSettings,
                        displayRevision: imageDocument.displayRevision,
                        selectedZ: imageDocument.selectedZ,
                        selectedTime: imageDocument.selectedTime,
                        annotationDisplayRevision: store.annotationDisplayRevision,
                        annotationFocusRevision: store.annotationFocusRevision,
                        measurementCalibration: imageDocument.measurementCalibration,
                        freehandSmoothing: freehandMaskSmoothing,
                        renderStatus: $tileRenderStatus
                    )
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
                if showOpeningOverlay {
                    ZStack {
                        Color.black.opacity(0.22)
                            .ignoresSafeArea()
                        ProgressView("Opening TIFF…")
                            .padding(.horizontal, 24)
                            .padding(.vertical, 18)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .allowsHitTesting(true)
                }
                if !isLoadingImage, presentedTileRenderStatus.phase != .idle {
                    VStack {
                        HStack {
                            Spacer()
                            TileRenderIndicator(status: presentedTileRenderStatus)
                                .padding(12)
                        }
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .toolbar {
                if let imageDocument {
                    ToolbarItem(placement: .bottomBar) {
                        HStack(spacing: 12) {
                            // Tool picker — constrained narrow.
                            Picker("Tool", selection: $store.activeTool) {
                                Image(systemName: "scribble").tag(AnnotationTool.freehand)
                                Image(systemName: "hexagon").tag(AnnotationTool.polygon)
                                Image(systemName: "hand.tap").tag(AnnotationTool.select)
                                Image(systemName: "ruler").tag(AnnotationTool.measure)
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

                            if store.activeTool == .measure {
                                Button {
                                    measurementCalibrationWasRequired =
                                        imageDocument.measurementCalibration == nil
                                    showingMeasurementCalibration = true
                                } label: {
                                    Label("Measurement scale", systemImage: "ruler")
                                }
                                .labelStyle(.iconOnly)

                                if store.hasMeasurement {
                                    Button {
                                        store.clearMeasurement()
                                    } label: {
                                        Label("Clear ruler", systemImage: "xmark.circle")
                                    }
                                    .labelStyle(.iconOnly)
                                }
                            }

                            Divider()

                            Button {
                                showingLayers = true
                            } label: {
                                Label("Layers", systemImage: "square.3.layers.3d")
                            }
                            .labelStyle(.iconOnly)

                            Button {
                                showingChannelAdjustments = true
                            } label: {
                                Label("Adjust shown channels", systemImage: "slider.horizontal.3")
                            }
                            .labelStyle(.iconOnly)
                            
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

                            Button {
                                showingAnnotationPicker = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "list.number")
                                    if let label = store.label(for: store.selectedAnnotationID) {
                                        Text(label)
                                            .lineLimit(1)
                                            .frame(maxWidth: 100)
                                    }
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityLabel("Select annotation")
                            .disabled(store.annotations.isEmpty)
                            .popover(
                                isPresented: $showingAnnotationPicker,
                                arrowEdge: .bottom
                            ) {
                                AnnotationPickerView(store: store) { annotationID in
                                    store.selectAnnotation(annotationID)
                                    showingAnnotationPicker = false
                                }
                                .frame(width: 340, height: 420)
                                .presentationCompactAdaptation(.sheet)
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
                            .accessibilityLabel("Save annotations")
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
                if imageDocument == nil {
                    do {
                        imageDocument = try ImageLoader.loadFromBundle("test")
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
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url]) { completed in
                if completed {
                    store.hasUnsavedChanges = false
                }
            }
            .onDisappear {
                // The file only exists to back this share operation.
                try? FileManager.default.removeItem(at: item.url)
            }
        }
        .sheet(isPresented: $showingClassPanel) {
            ClassPanelView(store: store)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                authorInitials: $authorInitials,
                freehandSmoothing: $freehandMaskSmoothing
            )
        }
        .sheet(isPresented: $showingLayers) {
            if let imageDocument {
                LayerPanelView(document: imageDocument)
            }
        }
        .sheet(isPresented: $showingChannelAdjustments) {
            if let imageDocument {
                ChannelAdjustmentsView(document: imageDocument)
            }
        }
        .sheet(
            isPresented: $showingMeasurementCalibration,
            onDismiss: {
                if measurementCalibrationWasRequired,
                   imageDocument?.measurementCalibration == nil,
                   store.activeTool == .measure {
                    store.activeTool = .select
                }
                measurementCalibrationWasRequired = false
            }
        ) {
            if let imageDocument {
                MeasurementCalibrationView(document: imageDocument)
            }
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
        .onChange(of: tileRenderStatus.phase, initial: true) { _, phase in
            updateTileIndicator(for: phase)
        }
        .onChange(of: store.activeTool) { _, tool in
            guard tool == .measure,
                  let imageDocument,
                  imageDocument.measurementCalibration == nil else { return }
            measurementCalibrationWasRequired = true
            showingMeasurementCalibration = true
        }
        .onChange(of: tileRenderStatus) { _, status in
            if presentedTileRenderStatus.phase == status.phase,
               status.phase != .idle {
                presentedTileRenderStatus = status
            }
        }
        .animation(.easeInOut(duration: 0.15), value: presentedTileRenderStatus.phase)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isLoadingImage = true
            showOpeningOverlay = false
            tileRenderStatus = .idle
            presentedTileRenderStatus = .idle
            openingOverlayDelayTask?.cancel()
            openingOverlayDelayTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, isLoadingImage else { return }
                showOpeningOverlay = true
            }
            Task { @MainActor in
                defer {
                    openingOverlayDelayTask?.cancel()
                    openingOverlayDelayTask = nil
                    showOpeningOverlay = false
                    isLoadingImage = false
                }
                do {
                    let newDocument = try await ImageLoader.load(from: url)
                    imageDocument = newDocument
                    imageBaseName = url.deletingPathExtension().lastPathComponent
                    // New image → annotations from the old image no longer apply.
                    store.annotations.removeAll()
                    store.selectedAnnotationID = nil
                    store.editingVertexAnnotationID = nil
                    store.clearMeasurement()
                    store.clearHistory()
                    store.hasUnsavedChanges = false
                    errorMessage = nil
                    if store.activeTool == .measure,
                       newDocument.measurementCalibration == nil {
                        measurementCalibrationWasRequired = true
                        showingMeasurementCalibration = true
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func updateTileIndicator(for phase: TileRenderPhase) {
        tileIndicatorDelayTask?.cancel()
        tileIndicatorDelayTask = nil
        switch phase {
        case .idle:
            presentedTileRenderStatus = .idle
        case .failed:
            presentedTileRenderStatus = tileRenderStatus
        case .rendering:
            tileIndicatorDelayTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled,
                      tileRenderStatus.phase == .rendering else { return }
                presentedTileRenderStatus = tileRenderStatus
            }
        }
    }
    
    func loadAnnotations(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try GeoJSONConverter.annotations(from: data, store: store)
            store.snapshot()                          // make the load undoable
            store.add(contentsOf: loaded)             // merge, don't replace
            store.selectedAnnotationID = nil
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
            shareItem = ShareItem(url: tmp)
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

private struct AnnotationPickerView: View {
    let store: AnnotationStore
    let onSelect: (UUID) -> Void
    @State private var searchText = ""

    private var filteredAnnotations: [Annotation] {
        guard !searchText.isEmpty else { return store.annotations }
        return store.annotations.filter {
            store.label(for: $0).localizedStandardContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Annotations")
                    .font(.headline)
                Spacer()
                Text("\(store.annotations.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Cell 1, Nuclei 2…", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)

            Divider()

            Group {
                if filteredAnnotations.isEmpty {
                    ContentUnavailableView {
                        Label("No Matching Annotations", systemImage: "magnifyingglass")
                    } description: {
                        Text("Try a different annotation name.")
                    }
                } else {
                    List(filteredAnnotations) { annotation in
                        Button {
                            onSelect(annotation.id)
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(store.color(for: annotation.classID))
                                    .frame(width: 12, height: 12)
                                Text(store.label(for: annotation))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if annotation.id == store.selectedAnnotationID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
    }
}

private struct MeasurementCalibrationView: View {
    let document: TIFFDocument
    @Environment(\.dismiss) private var dismiss
    @State private var micronsPerPixel: String

    init(document: TIFFDocument) {
        self.document = document
        let current = document.measurementCalibration
        let initialValue: String
        if let current,
           abs(current.micronsPerPixelX - current.micronsPerPixelY) < 0.000_000_1 {
            initialValue = current.micronsPerPixelX.formatted(.number.precision(.fractionLength(0...6)))
        } else {
            initialValue = ""
        }
        _micronsPerPixel = State(initialValue: initialValue)
    }

    private var parsedScale: Double? {
        let normalized = micronsPerPixel.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                if let embedded = document.embeddedPixelCalibration {
                    Section("OME-TIFF scale") {
                        LabeledContent(
                            "Pixel size",
                            value: calibrationDescription(embedded)
                        )
                        Text("This scale was read automatically from PhysicalSizeX and PhysicalSizeY in the OME metadata.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if document.measurementCalibration?.source == .manual {
                            Button("Use OME-TIFF scale") {
                                document.restoreEmbeddedMeasurementCalibration()
                                dismiss()
                            }
                        }
                    }
                } else {
                    Section {
                        Text("This TIFF does not contain a usable OME physical pixel size. Enter the image scale to measure in micrometers.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Manual scale") {
                    HStack {
                        TextField("e.g. 0.25", text: $micronsPerPixel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("µm / pixel")
                            .foregroundStyle(.secondary)
                    }
                    Text("Magnification alone is not enough to convert pixels to micrometers; the physical pixel size is required. The manual value is applied to both X and Y.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Measurement Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let parsedScale else { return }
                        document.setManualMeasurementCalibration(micronsPerPixel: parsedScale)
                        dismiss()
                    }
                    .disabled(parsedScale == nil)
                }
            }
        }
    }

    private func calibrationDescription(_ calibration: PixelCalibration) -> String {
        let x = calibration.micronsPerPixelX.formatted(
            .number.precision(.fractionLength(0...6))
        )
        let y = calibration.micronsPerPixelY.formatted(
            .number.precision(.fractionLength(0...6))
        )
        return x == y ? "\(x) µm/pixel" : "\(x) × \(y) µm/pixel"
    }
}

private struct TileRenderIndicator: View {
    let status: TileRenderStatus

    var body: some View {
        HStack(spacing: 10) {
            if status.phase == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Some image tiles could not be rendered")
                        .font(.subheadline.weight(.semibold))
                    if let message = status.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rendering image…")
                        .font(.subheadline.weight(.medium))
                    Text("\(status.readyVisibleTiles) of \(status.requestedVisibleTiles) visible tiles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 5, y: 2)
        .accessibilityElement(children: .combine)
    }
}
