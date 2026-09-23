import SwiftUI

struct EffectsToolPanel: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        Form {
            Section("Green Screen") {
                GreenScreenToolPanel(viewModel: viewModel)
            }

            Section("Adjust") {
                Picker("Target", selection: $viewModel.colorAdjustTargetIsGlobal) {
                    Text("This Clip").tag(false)
                    Text("Whole Project").tag(true)
                }
                .pickerStyle(.segmented)

                ColorAdjustmentsEditor(
                    adjustments: activeAdjustmentsBinding,
                    onEditingChanged: { editing in
                        if !editing {
                            viewModel.commitColorAdjustmentChange()
                        }
                    }
                )

                Button("Reset Adjustments", role: .destructive) {
                    if viewModel.colorAdjustTargetIsGlobal {
                        viewModel.resetGlobalColorAdjustments()
                    } else {
                        viewModel.resetClipColorAdjustments()
                    }
                }
            }

            Section("Clip Filter") {
                Picker("Filter", selection: clipFilterBinding) {
                    Text("None").tag("")
                    ForEach(BuiltInCameraFilter.allFilters, id: \.id) { filter in
                        Text(filter.name).tag(filter.id)
                    }
                }
            }

            Section("Transition") {
                Picker("Transition", selection: Binding(
                    get: { viewModel.selectedClip?.transition ?? .cut },
                    set: { viewModel.setClipTransition($0) }
                )) {
                    ForEach(ClipTransition.allCases) { transition in
                        Text(transition.title).tag(transition)
                    }
                }
            }

            Section("Global Filter") {
                Picker("Filter", selection: globalFilterBinding) {
                    Text("None").tag("")
                    ForEach(BuiltInCameraFilter.allFilters, id: \.id) { filter in
                        Text(filter.name).tag(filter.id)
                    }
                }
            }
        }
        .onDisappear {
            viewModel.commitColorAdjustmentChange()
            viewModel.commitGreenScreenEffectChange()
        }
    }

    private var activeAdjustmentsBinding: Binding<ColorAdjustments> {
        Binding(
            get: {
                if viewModel.colorAdjustTargetIsGlobal {
                    return viewModel.project.globalColorAdjustments
                }
                return viewModel.selectedClip?.colorAdjustments ?? .identity
            },
            set: { newValue in
                if viewModel.colorAdjustTargetIsGlobal {
                    viewModel.setGlobalColorAdjustments(newValue)
                } else {
                    viewModel.setClipColorAdjustments(newValue)
                }
            }
        )
    }

    private var clipFilterBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedClip?.filterIDs.first ?? "" },
            set: { newValue in
                guard var clip = viewModel.selectedClip else { return }
                clip.filterIDs = newValue.isEmpty ? [] : [newValue]
                viewModel.selectedClip = clip
            }
        )
    }

    private var globalFilterBinding: Binding<String> {
        Binding(
            get: { viewModel.project.globalFilterIDs.first ?? "" },
            set: { newValue in
                viewModel.setGlobalFilter(newValue)
            }
        )
    }
}

private struct ColorAdjustmentsEditor: View {
    @Binding var adjustments: ColorAdjustments
    var onEditingChanged: (Bool) -> Void

    var body: some View {
        sliderRow("Brightness", value: $adjustments.brightness)
        sliderRow("Contrast", value: $adjustments.contrast)
        sliderRow("Saturation", value: $adjustments.saturation)
        sliderRow("Warmth", value: $adjustments.warmth)
        sliderRow("Exposure", value: $adjustments.exposure)
        sliderRow("Sharpness", value: $adjustments.sharpness)
        sliderRow("Vignette", value: $adjustments.vignette)
    }

    private func sliderRow(_ title: String, value: Binding<Float>) -> some View {
        LabeledContent(title) {
            Slider(
                value: value,
                in: -1...1,
                onEditingChanged: onEditingChanged
            )
        }
    }
}
