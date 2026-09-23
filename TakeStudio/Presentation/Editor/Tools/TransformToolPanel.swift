import SwiftUI

struct TransformToolPanel: View {
    @Bindable var viewModel: EditorViewModel

    private var framing: ClipFraming {
        viewModel.selectedClip?.framing ?? .identity
    }

    var body: some View {
        Form {
            Section("Transform") {
                Button {
                    viewModel.rotateClip90()
                } label: {
                    Label("Rotate 90°", systemImage: "rotate.right")
                }

                Picker("Fit", selection: Binding(
                    get: { framing.fitMode },
                    set: { viewModel.setClipFit($0) }
                )) {
                    ForEach(ClipFitMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("Zoom") {
                    Slider(
                        value: Binding(
                            get: { Double(framing.zoom) },
                            set: { viewModel.setClipZoom(CGFloat($0)) }
                        ),
                        in: 0.5...3.0,
                        onEditingChanged: { editing in
                            if !editing {
                                viewModel.commitClipTransformChange()
                            }
                        }
                    )
                }

                Button("Reset Transform", role: .destructive) {
                    viewModel.resetClipTransform()
                }
            }

            Section {
                Text("Pinch to zoom and drag to pan on the preview while Transform is selected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
