import PhotosUI
import SwiftUI
import UIKit

struct TextToolPanel: View {
    @Bindable var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var stickerTab: StickerTab = .emoji
    @State private var selectedStickerImageItem: PhotosPickerItem?

    private enum StickerTab: String, CaseIterable, Identifiable {
        case emoji
        case shapes
        case importImage

        var id: String { rawValue }

        var title: String {
            switch self {
            case .emoji: return "Emoji"
            case .shapes: return "Shapes"
            case .importImage: return "Import"
            }
        }
    }

    private let emojis = ["😀", "😂", "😍", "🔥", "👍", "🎉", "💯", "✨", "❤️", "😎", "🤩", "👏"]

    var body: some View {
        Form {
            Section {
                Button {
                    viewModel.addTextOverlay()
                    dismiss()
                } label: {
                    Label("Add Text", systemImage: "textformat")
                }

                Button {
                    viewModel.addTextOverlay(at: CGPoint(x: 0.5, y: 0.5))
                    dismiss()
                } label: {
                    Label("Add at Center", systemImage: "scope")
                }

                Text("The Text tool opens the on-video keyboard. Use this panel for stickers and style.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let selectedID = viewModel.selectedTextID,
               let index = viewModel.project.textOverlays.firstIndex(where: { $0.id == selectedID }) {
                Section("Selected Text") {
                    Button {
                        viewModel.requestTextPrompt(for: selectedID)
                        dismiss()
                    } label: {
                        Label("Edit on Video", systemImage: "character.cursor.ibeam")
                    }
                    TextOverlayEditor(overlay: Binding(
                        get: {
                            var overlay = viewModel.project.textOverlays[index]
                            overlay.text = viewModel.displayText(for: selectedID) ?? overlay.text
                            return overlay
                        },
                        set: { viewModel.updateTextOverlay($0) }
                    ))
                }
            }

            if let selectedID = viewModel.selectedStickerID,
               let index = viewModel.project.stickerOverlays.firstIndex(where: { $0.id == selectedID }) {
                Section("Selected Sticker") {
                    LabeledContent("Scale") {
                        Slider(
                            value: Binding(
                                get: { Double(viewModel.project.stickerOverlays[index].scale) },
                                set: {
                                    var overlay = viewModel.project.stickerOverlays[index]
                                    overlay.scale = CGFloat($0)
                                    viewModel.updateStickerOverlay(overlay)
                                }
                            ),
                            in: 0.3...3
                        )
                    }
                    LabeledContent("Opacity") {
                        Slider(
                            value: Binding(
                                get: { Double(viewModel.project.stickerOverlays[index].opacity) },
                                set: {
                                    var overlay = viewModel.project.stickerOverlays[index]
                                    overlay.opacity = CGFloat($0)
                                    viewModel.updateStickerOverlay(overlay)
                                }
                            ),
                            in: 0...1
                        )
                    }
                    Button(role: .destructive) {
                        viewModel.deleteSelectedStickerOverlay()
                    } label: {
                        Label("Delete Sticker", systemImage: "trash")
                    }
                }
            }

            Section("Stickers") {
                Picker("Type", selection: $stickerTab) {
                    ForEach(StickerTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                switch stickerTab {
                case .emoji:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                        ForEach(emojis, id: \.self) { emoji in
                            Button {
                                viewModel.addSticker(emoji)
                            } label: {
                                Text(emoji)
                                    .font(.title2)
                                    .frame(maxWidth: .infinity, minHeight: 40)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                case .shapes:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        ForEach(BundledStickerLibrary.StickerKind.allCases) { kind in
                            Button(kind.title) {
                                viewModel.addBundledSticker(kind)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                case .importImage:
                    PhotosPicker(selection: $selectedStickerImageItem, matching: .images) {
                        Label("Import PNG Sticker", systemImage: "photo")
                    }
                    .onChange(of: selectedStickerImageItem) { _, item in
                        guard let item else { return }
                        Task {
                            await viewModel.importStickerImage(from: item)
                            selectedStickerImageItem = nil
                        }
                    }
                }
            }
        }
        .onDisappear {
            viewModel.endInlineTextEdit()
        }
    }
}

struct TextOverlayEditor: View {
    @Binding var overlay: TextOverlay

    var body: some View {
        LabeledContent("Size") {
            Slider(value: Binding(
                get: { Double(overlay.style.fontSize) },
                set: { overlay.style.fontSize = CGFloat($0) }
            ), in: 14...72)
        }

        Picker("Font Weight", selection: Binding(
            get: { overlay.style.fontWeight },
            set: { overlay.style.fontWeight = $0 }
        )) {
            Text("Regular").tag(UIFont.Weight.regular)
            Text("Semibold").tag(UIFont.Weight.semibold)
            Text("Bold").tag(UIFont.Weight.bold)
            Text("Heavy").tag(UIFont.Weight.heavy)
        }

        Picker("Font", selection: Binding(
            get: { overlay.style.fontName ?? "System" },
            set: { overlay.style.fontName = $0 == "System" ? nil : $0 }
        )) {
            ForEach(OverlayRenderer.curatedFonts, id: \.self) { font in
                Text(font).tag(font)
            }
        }

        ColorPicker("Text Color", selection: hexColorBinding(
            get: { overlay.style.colorHex },
            set: { overlay.style.colorHex = $0 }
        ))

        Toggle("Background", isOn: $overlay.style.hasBackground)
        if overlay.style.hasBackground {
            ColorPicker("Background Color", selection: hexColorBinding(
                get: { overlay.style.backgroundColorHex },
                set: { overlay.style.backgroundColorHex = $0 }
            ))
        }

        Toggle("Shadow", isOn: $overlay.style.hasShadow)

        LabeledContent("Opacity") {
            Slider(value: Binding(
                get: { Double(overlay.opacity) },
                set: { overlay.opacity = CGFloat($0) }
            ), in: 0...1)
        }

        Picker("Animation", selection: Binding(
            get: { overlay.animation },
            set: { overlay.animation = $0 }
        )) {
            ForEach(TextAnimation.allCases) { animation in
                Text(animation.title).tag(animation)
            }
        }
    }

    private func hexColorBinding(get: @escaping () -> String, set: @escaping (String) -> Void) -> Binding<Color> {
        Binding(
            get: { Color(hex: get()) ?? .white },
            set: { color in
                set(color.toHexString())
            }
        )
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

    func toHexString() -> String {
        EditorColorHex.hexString(from: self)
    }
}
