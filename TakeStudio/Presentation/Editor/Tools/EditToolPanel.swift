import SwiftUI

struct EditToolPanel: View {
    @Bindable var viewModel: EditorViewModel
    @State private var isReversing = false

    private let speedPresets: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0]

    var body: some View {
        Form {
            Section("Speed") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(speedPresets, id: \.self) { speed in
                            Button {
                                viewModel.setSpeed(speed)
                            } label: {
                                Text(speed == 1 ? "1×" : String(format: "%.2g×", speed))
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint((viewModel.selectedClip?.speed ?? 1) == speed ? .yellow : .primary)
                        }
                    }
                }
            }

            Section("Clip") {
                Button {
                    Task { await viewModel.splitClip(at: viewModel.currentTime) }
                } label: {
                    Label("Split", systemImage: "scissors")
                }

                Button {
                    Task {
                        isReversing = true
                        defer { isReversing = false }
                        await viewModel.reverseSelectedClip()
                    }
                } label: {
                    if isReversing {
                        HStack {
                            ProgressView()
                            Text("Reversing…")
                        }
                    } else {
                        Label("Reverse", systemImage: "arrow.uturn.backward")
                    }
                }
                .disabled(isReversing || viewModel.selectedClipID == nil)

                if let clipID = viewModel.selectedClipID {
                    Button(role: .destructive) {
                        viewModel.deleteClip(clipID)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            Section("Transform") {
                Button {
                    viewModel.rotateClip90()
                } label: {
                    Label("Rotate 90°", systemImage: "rotate.right")
                }

                Picker("Fit", selection: Binding(
                    get: { viewModel.selectedClip?.framing.fitMode ?? .fill },
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
                            get: { Double(viewModel.selectedClip?.framing.zoom ?? 1) },
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
        }
        .onDisappear {
            viewModel.commitClipTransformChange()
        }
    }
}
