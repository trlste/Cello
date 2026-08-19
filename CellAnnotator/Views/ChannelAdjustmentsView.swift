//
//  ChannelAdjustmentsView.swift
//  CellAnnotator
//

import SwiftUI

struct ChannelAdjustmentsView: View {
    @Bindable var document: TIFFDocument
    @Environment(\.dismiss) private var dismiss

    private var visibleSettings: [ChannelDisplaySettings] {
        document.channelSettings.filter(\.isVisible)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Only currently visible channels are listed. Each channel keeps its own adjustments when hidden.")
                        .foregroundStyle(.secondary)
                }

                if visibleSettings.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Visible Channels",
                            systemImage: "eye.slash",
                            description: Text("Use Layers to show a channel before adjusting it.")
                        )
                    }
                } else {
                    ForEach(visibleSettings) { setting in
                        let index = setting.channelIndex
                        Section(setting.name) {
                            valueSlider(
                                "Black point",
                                value: binding(index, \.blackPoint),
                                range: 0...max(0, setting.whitePoint - 0.001),
                                format: "%.3f"
                            )
                            valueSlider(
                                "White point",
                                value: binding(index, \.whitePoint),
                                range: min(1, setting.blackPoint + 0.001)...1,
                                format: "%.3f"
                            )
                            valueSlider(
                                "Gamma",
                                value: binding(index, \.gamma),
                                range: 0.1...3,
                                format: "%.2f"
                            )
                            valueSlider(
                                "Opacity",
                                value: binding(index, \.opacity),
                                range: 0...1,
                                format: "%.2f"
                            )
                        }
                    }
                }
            }
            .navigationTitle("Channel Adjustments")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset Shown") {
                        document.resetVisibleChannelAdjustments()
                    }
                    .disabled(visibleSettings.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func binding(
        _ index: Int,
        _ keyPath: WritableKeyPath<ChannelDisplaySettings, Double>
    ) -> Binding<Double> {
        Binding(
            get: { document.channelSettings[index][keyPath: keyPath] },
            set: { value in
                document.updateChannelSettings(at: index) { $0[keyPath: keyPath] = value }
            }
        )
    }

    @ViewBuilder
    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
