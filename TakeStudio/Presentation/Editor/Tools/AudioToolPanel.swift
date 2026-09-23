import AVFoundation
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

struct AudioToolPanel: View {
    @Bindable var viewModel: EditorViewModel
    @State private var showFileImporter = false
    @State private var previewPlayer: AVAudioPlayer?

    private var selectedTrack: AudioTrack? {
        guard let id = viewModel.selectedAudioTrackID else { return nil }
        return viewModel.project.audioTracks.first(where: { $0.id == id })
    }

    var body: some View {
        Form {
            Section {
                if let clipID = viewModel.selectedClipID, viewModel.selectedClip?.hasDetachedAudio == false {
                    Button {
                        viewModel.detachAudio(from: clipID)
                    } label: {
                        Label("Detach Audio", systemImage: "speaker.wave.2")
                    }
                }

                Button {
                    viewModel.pendingMusicPicker = true
                } label: {
                    Label("Add Music", systemImage: "music.note")
                }

                Button {
                    showFileImporter = true
                } label: {
                    Label("Import Audio", systemImage: "folder")
                }
            }

            Section("Clip Volume") {
                Slider(
                    value: Binding(
                        get: { viewModel.selectedClip?.volume ?? 1 },
                        set: { viewModel.setClipVolume($0) }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing {
                            viewModel.commitClipVolumeChange()
                        }
                    }
                )
            }

            if !viewModel.project.audioTracks.isEmpty {
                Section("Audio Tracks") {
                    ForEach(viewModel.project.audioTracks) { track in
                        Button {
                            viewModel.selectedAudioTrackID = track.id
                        } label: {
                            HStack {
                                Text(track.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if viewModel.selectedAudioTrackID == track.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.yellow)
                                }
                            }
                        }
                    }
                }
            }

            if let track = selectedTrack {
                Section(track.title) {
                    Toggle("Fade In", isOn: Binding(
                        get: { track.isFadeIn },
                        set: {
                            var updated = track
                            updated.isFadeIn = $0
                            viewModel.updateAudioTrack(updated)
                        }
                    ))
                    Toggle("Fade Out", isOn: Binding(
                        get: { track.isFadeOut },
                        set: {
                            var updated = track
                            updated.isFadeOut = $0
                            viewModel.updateAudioTrack(updated)
                        }
                    ))
                    Toggle("Loop", isOn: Binding(
                        get: { track.isLooping },
                        set: {
                            var updated = track
                            updated.isLooping = $0
                            viewModel.updateAudioTrack(updated)
                        }
                    ))
                    Slider(
                        value: Binding(
                            get: { track.volume },
                            set: { viewModel.setAudioTrackVolume(track.id, volume: $0) }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            if !editing {
                                viewModel.commitAudioTrackVolumeChange()
                            }
                        }
                    )
                }
            } else if !viewModel.project.audioTracks.isEmpty {
                Section {
                    Text("Select an audio track on the timeline or from the list above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sound Effects") {
                ForEach(SoundEffectCategory.allCases) { category in
                    if !SoundEffectLibrary.effects(in: category).isEmpty {
                        DisclosureGroup(category.title) {
                            ForEach(SoundEffectLibrary.effects(in: category)) { effect in
                                HStack {
                                    Text(effect.name)
                                    Spacer()
                                    Button {
                                        preview(effect)
                                    } label: {
                                        Image(systemName: "play.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    Button("Add") {
                                        Task { await viewModel.addSoundEffect(effect) }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
            }

            Section("Voiceover") {
                VoiceoverControlSection(viewModel: viewModel)
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.audio, .mpeg4Audio]) { result in
            guard case .success(let url) = result else { return }
            Task { await viewModel.importMusic(from: url, title: url.lastPathComponent) }
        }
        .onAppear {
            if viewModel.selectedAudioTrackID == nil,
               viewModel.project.audioTracks.count == 1,
               let only = viewModel.project.audioTracks.first {
                viewModel.selectedAudioTrackID = only.id
            }
        }
        .onDisappear {
            viewModel.commitClipVolumeChange()
            previewPlayer?.stop()
            previewPlayer = nil
        }
    }

    private func preview(_ effect: SoundEffect) {
        Task {
            do {
                let url = try SoundEffectAudioGenerator.url(for: effect)
                previewPlayer?.stop()
                previewPlayer = try AVAudioPlayer(contentsOf: url)
                previewPlayer?.play()
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

private struct VoiceoverControlSection: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(viewModel.voiceoverRecorder.levels, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.pink.gradient)
                    .frame(width: 3, height: CGFloat(level) * 24 + 4)
            }
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)

        Button {
            if viewModel.voiceoverRecorder.isRecording {
                viewModel.stopVoiceover()
            } else {
                Task { await viewModel.startVoiceover() }
            }
        } label: {
            Label(
                viewModel.voiceoverRecorder.isRecording ? "Stop Recording" : "Record Voiceover",
                systemImage: viewModel.voiceoverRecorder.isRecording ? "stop.circle.fill" : "mic.circle.fill"
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(viewModel.voiceoverRecorder.isRecording ? .red : .pink)
    }
}

struct MusicPickerView: UIViewControllerRepresentable {
    let onPick: (URL, String) -> Void
    var onCancel: (() -> Void)?

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: MPMediaPickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let onPick: (URL, String) -> Void
        let onCancel: (() -> Void)?

        init(onPick: @escaping (URL, String) -> Void, onCancel: (() -> Void)?) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func mediaPicker(_ mediaPicker: MPMediaPickerController, didPickMediaItems mediaItemCollection: MPMediaItemCollection) {
            guard
                let item = mediaItemCollection.items.first,
                let url = item.value(forProperty: MPMediaItemPropertyAssetURL) as? URL
            else {
                onCancel?()
                return
            }
            onPick(url, item.title ?? "Music")
        }

        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            onCancel?()
        }
    }
}
