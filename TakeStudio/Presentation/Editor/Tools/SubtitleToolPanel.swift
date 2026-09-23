import SwiftUI

struct SubtitleToolPanel: View {
    @Bindable var viewModel: EditorViewModel
    @State private var subtitleDraft: String = ""
    @State private var draftSegmentID: UUID?

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await viewModel.generateSubtitles() }
                } label: {
                    if viewModel.isGeneratingSubtitles {
                        HStack {
                            ProgressView()
                            Text(viewModel.subtitleGenerationProgress ?? "Generating…")
                        }
                    } else {
                        Label("Auto Generate", systemImage: "captions.bubble")
                    }
                }
                .disabled(viewModel.isGeneratingSubtitles)
            }

            Section("Style") {
                ForEach(SubtitleStylePreset.allCases) { preset in
                    Button(preset.title) {
                        viewModel.applySubtitlePreset(preset)
                    }
                }
            }

            if let selectedID = viewModel.selectedSubtitleID,
               viewModel.project.subtitleTrack?.segments.contains(where: { $0.id == selectedID }) == true {
                Section("Selected Subtitle") {
                    TextField("Subtitle text", text: $subtitleDraft, axis: .vertical)
                        .onSubmit {
                            commitDraft(for: selectedID)
                        }
                }
            }
        }
        .onAppear {
            loadDraft(from: viewModel.selectedSubtitleID)
        }
        .onChange(of: viewModel.selectedSubtitleID) { _, newID in
            loadDraft(from: newID)
        }
        .onChange(of: subtitleDraft) { _, newText in
            guard let draftSegmentID else { return }
            viewModel.updateSubtitleText(draftSegmentID, newText)
        }
        .onDisappear {
            if let draftSegmentID {
                commitDraft(for: draftSegmentID)
            }
        }
    }

    private func loadDraft(from selectedID: UUID?) {
        guard let selectedID,
              let text = viewModel.project.subtitleTrack?.segments.first(where: { $0.id == selectedID })?.text
        else {
            draftSegmentID = nil
            subtitleDraft = ""
            return
        }
        draftSegmentID = selectedID
        if subtitleDraft != text {
            subtitleDraft = text
        }
    }

    private func commitDraft(for id: UUID) {
        guard var segment = viewModel.project.subtitleTrack?.segments.first(where: { $0.id == id }) else { return }
        segment.text = subtitleDraft
        viewModel.commitSubtitleSegment(segment)
    }
}
