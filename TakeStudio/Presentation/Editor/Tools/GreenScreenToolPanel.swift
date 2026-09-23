import PhotosUI
import SwiftUI
import UIKit

struct GreenScreenToolPanel: View {
    @Bindable var viewModel: EditorViewModel
    @State private var selectedImageItem: PhotosPickerItem?
    @State private var selectedVideoItem: PhotosPickerItem?

    private var clip: VideoClip? { viewModel.selectedClip }

    var body: some View {
        Group {
            if clip == nil {
                Text("Select a video clip to apply green screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                modePicker
                backgroundPicker
                if clip?.greenScreenEffect?.mode == .chromaKey {
                    sensitivitySlider
                }
                featherSlider
                removeButton
            }
        }
        .onChange(of: selectedImageItem) { _, item in
            guard let item else { return }
            Task {
                await importImageBackground(from: item)
                selectedImageItem = nil
            }
        }
        .onChange(of: selectedVideoItem) { _, item in
            guard let item else { return }
            Task {
                await importVideoBackground(from: item)
                selectedVideoItem = nil
            }
        }
        .onDisappear {
            viewModel.commitGreenScreenEffectChange()
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { clip?.greenScreenEffect?.mode ?? .personSegmentation },
            set: { mode in applyEffect { $0.mode = mode } }
        )) {
            Text("Auto Person").tag(GreenScreenMode.personSegmentation)
            Text("Chroma Key").tag(GreenScreenMode.chromaKey)
        }
    }

    private var backgroundPicker: some View {
        LabeledContent("Background") {
            HStack(spacing: 8) {
                ColorPicker("", selection: Binding(
                    get: { colorFromHex(clip?.greenScreenEffect?.backgroundSource) },
                    set: { newColor in
                        applyEffect {
                            $0.backgroundSource = .color(hex: EditorColorHex.hexString(from: newColor))
                        }
                    }
                ))
                .labelsHidden()

                PhotosPicker(selection: $selectedImageItem, matching: .images) {
                    Label("Image", systemImage: "photo")
                }

                PhotosPicker(selection: $selectedVideoItem, matching: .videos) {
                    Label("Video", systemImage: "film")
                }
            }
        }
    }

    private var sensitivitySlider: some View {
        LabeledContent("Sensitivity") {
            Slider(
                value: Binding(
                    get: { clip?.greenScreenEffect?.sensitivity ?? 0.35 },
                    set: { newValue in applyEffectPreview { $0.sensitivity = newValue } }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing {
                        viewModel.commitGreenScreenEffectChange()
                    }
                }
            )
        }
    }

    private var featherSlider: some View {
        LabeledContent("Feather") {
            Slider(
                value: Binding(
                    get: { clip?.greenScreenEffect?.feather ?? 0.5 },
                    set: { newValue in applyEffectPreview { $0.feather = newValue } }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing {
                        viewModel.commitGreenScreenEffectChange()
                    }
                }
            )
        }
    }

    private var removeButton: some View {
        Button(role: .destructive) {
            guard let clipID = clip?.id else { return }
            viewModel.setGreenScreenEffect(nil, for: clipID)
        } label: {
            Label("Remove Effect", systemImage: "trash")
        }
    }

    private func applyEffect(_ update: (inout GreenScreenEffect) -> Void) {
        guard let clipID = clip?.id else { return }
        var effect = clip?.greenScreenEffect ?? GreenScreenEffect()
        update(&effect)
        viewModel.setGreenScreenEffect(effect, for: clipID)
    }

    private func applyEffectPreview(_ update: (inout GreenScreenEffect) -> Void) {
        guard let clipID = clip?.id else { return }
        var effect = clip?.greenScreenEffect ?? GreenScreenEffect()
        update(&effect)
        viewModel.setGreenScreenEffect(effect, for: clipID, recordHistory: false)
    }

    private func importImageBackground(from item: PhotosPickerItem) async {
        guard let clipID = clip?.id else { return }
        guard let imported = try? await item.loadTransferable(type: ImportedImageFile.self) else { return }
        var effect = clip?.greenScreenEffect ?? GreenScreenEffect()
        effect.backgroundSource = .image(imported.url)
        viewModel.setGreenScreenEffect(effect, for: clipID)
    }

    private func importVideoBackground(from item: PhotosPickerItem) async {
        guard let clipID = clip?.id else { return }
        guard let imported = try? await item.loadTransferable(type: ImportedMovieFile.self) else { return }
        var effect = clip?.greenScreenEffect ?? GreenScreenEffect()
        effect.backgroundSource = .videoURL(imported.url)
        viewModel.setGreenScreenEffect(effect, for: clipID)
    }

    private func colorFromHex(_ source: BackgroundSource?) -> Color {
        guard case .color(let hex) = source else { return Color(red: 0.1, green: 0.15, blue: 0.35) }
        return Color(hex: hex) ?? Color(red: 0.1, green: 0.15, blue: 0.35)
    }
}

private extension Color {
    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
