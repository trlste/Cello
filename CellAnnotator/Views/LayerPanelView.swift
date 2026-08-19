//
//  LayerPanelView.swift
//  CellAnnotator
//

import SwiftUI

struct LayerPanelView: View {
    @Bindable var document: TIFFDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Image") {
                    LabeledContent("Dimensions", value: dimensionSummary)
                    LabeledContent("Bit depth", value: document.imageIndex.bitDepth.map { "\($0)-bit" } ?? "Unknown")
                    LabeledContent("Pyramid levels", value: "\(document.imageIndex.resolutions.count)")
                    if let pixelSize = pixelSizeSummary {
                        LabeledContent("Pixel size", value: pixelSize)
                    }
                    if document.imageIndex.sizeZ > 1 {
                        Picker("Z plane", selection: Binding(
                            get: { document.selectedZ },
                            set: { document.selectPlane(z: $0) }
                        )) {
                            ForEach(0..<document.imageIndex.sizeZ, id: \.self) { z in
                                Text("\(z + 1)").tag(z)
                            }
                        }
                    }
                    if document.imageIndex.sizeT > 1 {
                        Picker("Time point", selection: Binding(
                            get: { document.selectedTime },
                            set: { document.selectPlane(time: $0) }
                        )) {
                            ForEach(0..<document.imageIndex.sizeT, id: \.self) { time in
                                Text("\(time + 1)").tag(time)
                            }
                        }
                    }
                }

                Section("Channels") {
                    ForEach(document.channelSettings) { setting in
                        let index = setting.channelIndex
                        HStack(spacing: 12) {
                            Toggle(setting.name, isOn: binding(index, \.isVisible))

                            ColorPicker(
                                "Pseudocolor for \(setting.name)",
                                selection: Binding(
                                    get: { document.channelSettings[index].color.swiftUIColor },
                                    set: { newColor in
                                        document.updateChannelSettings(at: index) {
                                            $0.color = DisplayColor(newColor)
                                        }
                                    }
                                ),
                                supportsOpacity: false
                            )
                            .labelsHidden()
                        }
                    }
                }
            }
            .navigationTitle("Image Layers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Defaults") { document.resetLayerSettings() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var dimensionSummary: String {
        let index = document.imageIndex
        var value = "\(index.sizeX) × \(index.sizeY), C\(index.sizeC)"
        if index.sizeZ > 1 { value += ", Z\(index.sizeZ)" }
        if index.sizeT > 1 { value += ", T\(index.sizeT)" }
        return value
    }

    private var pixelSizeSummary: String? {
        let pixelSize = document.imageIndex.pixelSize
        guard let x = pixelSize.x else { return nil }
        let xUnit = pixelSize.unitX ?? "µm"
        if let y = pixelSize.y, abs(x - y) > 0.000_001 {
            return String(format: "%.4g × %.4g %@", x, y, pixelSize.unitY ?? xUnit)
        }
        return String(format: "%.4g %@", x, xUnit)
    }

    private func binding(
        _ index: Int,
        _ keyPath: WritableKeyPath<ChannelDisplaySettings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { document.channelSettings[index][keyPath: keyPath] },
            set: { value in
                document.updateChannelSettings(at: index) { $0[keyPath: keyPath] = value }
            }
        )
    }

}
