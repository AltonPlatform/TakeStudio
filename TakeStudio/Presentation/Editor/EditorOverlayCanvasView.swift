import AVFoundation
import ImageIO
import SwiftUI
import UIKit

struct EditorOverlayCanvasView: View {
    @Bindable var viewModel: EditorViewModel
    var allowPlacement: Bool = true
    @State private var dragStartCenter: CGPoint?
    @State private var scaleStart: CGFloat?
    @State private var rotationStart: CGFloat?
    @State private var activeSnapGuides: OverlayAlignmentGuides = []
    @State private var isDraggingOverlay = false
    @State private var didSnapHapticX = false
    @State private var didSnapHapticY = false
    @State private var stickerImageCache: [String: UIImage] = [:]

    private static let stickerThumbnailMaxPixel = 256

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(viewModel.project.textOverlays) { overlay in
                    if isVisible(overlay.timeRange),
                       !(viewModel.isTextInputActive && viewModel.selectedTextID == overlay.id) {
                        overlayView(for: overlay, in: geometry.size)
                    }
                }
                ForEach(viewModel.project.stickerOverlays) { overlay in
                    if isVisible(overlay.timeRange) {
                        stickerView(for: overlay, in: geometry.size)
                    }
                }

                if isDraggingOverlay, !activeSnapGuides.isEmpty {
                    EditorOverlayAlignmentGuidesOverlay(
                        guides: activeSnapGuides,
                        canvasSize: geometry.size
                    )
                    .animation(.easeOut(duration: 0.12), value: activeSnapGuides)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                if allowPlacement,
                   viewModel.selectedTool == .text,
                   !viewModel.isTextInputActive,
                   viewModel.pendingTextPromptID == nil {
                    let normalized = normalizedPoint(from: location, size: geometry.size)
                    viewModel.addTextOverlay(at: normalized, openComposer: true)
                }
            }
        }
        .onChange(of: viewModel.project.stickerOverlays) { _, overlays in
            let livePaths = Set(overlays.compactMap { $0.imageURL?.path })
            stickerImageCache = stickerImageCache.filter { livePaths.contains($0.key) }
        }
    }

    private func isVisible(_ range: CMTimeRange) -> Bool {
        let time = viewModel.currentTime
        return time >= range.start.seconds && time <= range.endSeconds
    }

    private func normalizedPoint(from location: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: location.x / max(size.width, 1),
            y: 1 - location.y / max(size.height, 1)
        )
    }

    @ViewBuilder
    private func overlayView(for overlay: TextOverlay, in size: CGSize) -> some View {
        let isSelected = viewModel.selectedTextID == overlay.id
        let animated = previewAnimationState(for: overlay)
        let fontSize = overlay.style.fontSize * overlay.scale * animated.scale
        let textColor = (Color(hex: overlay.style.colorHex) ?? .white).opacity(overlay.opacity * animated.opacity)
        let position = CGPoint(
            x: animated.center.x * size.width,
            y: (1 - animated.center.y) * size.height
        )

        styledText(
            for: overlay,
            displayText: viewModel.displayText(for: overlay.id) ?? overlay.text,
            fontSize: fontSize,
            textColor: textColor
        )
            .gesture(overlayManipulationGesture(
                target: .text(overlay.id),
                center: overlay.normalizedCenter,
                scale: overlay.scale,
                rotation: overlay.rotation,
                canvasSize: size
            ))
            .onTapGesture {
                if viewModel.selectedTextID == overlay.id {
                    viewModel.requestTextPrompt(for: overlay.id)
                } else {
                    viewModel.selectTextOverlay(overlay.id)
                }
            }
            .rotationEffect(.radians(Double(overlay.rotation)))
            .position(position)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.yellow, lineWidth: 1)
                        .padding(-6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Button {
                        viewModel.deleteSelectedTextOverlay()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white, .red)
                    }
                    .offset(x: 12, y: -12)
                }
            }
    }

    @ViewBuilder
    private func styledText(
        for overlay: TextOverlay,
        displayText: String,
        fontSize: CGFloat,
        textColor: Color
    ) -> some View {
        let style = overlay.style
        Text(displayText)
            .font(previewFont(size: fontSize, weight: style.fontWeight, name: style.fontName))
            .foregroundStyle(textColor)
            .multilineTextAlignment(swiftTextAlignment(style.alignment))
            .padding(style.hasBackground ? 8 : 0)
            .background {
                if style.hasBackground {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(hex: style.backgroundColorHex) ?? Color.black.opacity(0.5))
                }
            }
            .shadow(
                color: style.hasShadow
                    ? (Color(hex: style.shadowColorHex) ?? .black).opacity(0.55)
                    : .clear,
                radius: style.hasShadow ? style.shadowRadius : 0,
                y: style.hasShadow ? 1 : 0
            )
            .overlay {
                if style.strokeWidth > 0 {
                    Text(displayText)
                        .font(previewFont(size: fontSize, weight: style.fontWeight, name: style.fontName))
                        .foregroundStyle(.clear)
                        .multilineTextAlignment(swiftTextAlignment(style.alignment))
                        .shadow(
                            color: Color(hex: style.strokeColorHex) ?? .black,
                            radius: 0,
                            x: style.strokeWidth * 0.35,
                            y: style.strokeWidth * 0.35
                        )
                        .allowsHitTesting(false)
                }
            }
    }

    private func swiftTextAlignment(_ alignment: NSTextAlignment) -> TextAlignment {
        switch alignment {
        case .left: return .leading
        case .right: return .trailing
        default: return .center
        }
    }

    private func previewFont(size: CGFloat, weight: UIFont.Weight, name: String?) -> Font {
        if let name, name != "System", UIFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: swiftFontWeight(weight))
    }

    @ViewBuilder
    private func stickerView(for overlay: StickerOverlay, in size: CGSize) -> some View {
        let isSelected = viewModel.selectedStickerID == overlay.id
        let cacheKey = overlay.imageURL?.path
        Group {
            if let cacheKey, let uiImage = stickerImageCache[cacheKey] {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72 * overlay.scale, height: 72 * overlay.scale)
            } else if overlay.imageURL != nil {
                ProgressView()
                    .frame(width: 72 * overlay.scale, height: 72 * overlay.scale)
            } else {
                Text(overlay.emoji ?? "😀")
                    .font(.system(size: 48 * overlay.scale))
            }
        }
        .opacity(overlay.opacity)
        .rotationEffect(.radians(Double(overlay.rotation)))
        .position(
            x: overlay.normalizedCenter.x * size.width,
            y: (1 - overlay.normalizedCenter.y) * size.height
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.yellow, lineWidth: 1)
                    .padding(-8)
            }
        }
        .gesture(overlayManipulationGesture(
            target: .sticker(overlay.id),
            center: overlay.normalizedCenter,
            scale: overlay.scale,
            rotation: overlay.rotation,
            canvasSize: size
        ))
        .onTapGesture {
            viewModel.endInlineTextEdit()
            viewModel.selectedStickerID = overlay.id
            viewModel.selectedTextID = nil
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Button {
                    viewModel.deleteSelectedStickerOverlay()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, .red)
                }
                .offset(x: 12, y: -12)
            }
        }
        .task(id: cacheKey) {
            guard let imageURL = overlay.imageURL else { return }
            let path = imageURL.path
            if stickerImageCache[path] != nil { return }
            let maxPixel = Self.stickerThumbnailMaxPixel
            let loaded = await Task.detached(priority: .userInitiated) {
                EditorOverlayCanvasView.loadDownsampledSticker(at: path, maxPixel: maxPixel)
            }.value
            if let loaded {
                stickerImageCache[path] = loaded
            }
        }
    }

    nonisolated private static func loadDownsampledSticker(at path: String, maxPixel: Int) -> UIImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(contentsOfFile: path)
        }
        return UIImage(cgImage: cgImage)
    }

    private enum OverlayTarget {
        case text(UUID)
        case sticker(UUID)
    }

    private func overlayManipulationGesture(
        target: OverlayTarget,
        center: CGPoint,
        scale: CGFloat,
        rotation: CGFloat,
        canvasSize: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStartCenter == nil {
                    dragStartCenter = center
                    isDraggingOverlay = true
                    didSnapHapticX = false
                    didSnapHapticY = false
                    selectTarget(target)
                    viewModel.beginGestureEdit("Move Overlay")
                }
                let start = dragStartCenter ?? center
                let rawCenter = CGPoint(
                    x: start.x + value.translation.width / canvasSize.width,
                    y: start.y - value.translation.height / canvasSize.height
                )
                let snap = OverlaySnapEngine.process(rawCenter)
                activeSnapGuides = snap.guides

                if snap.snappedX, !didSnapHapticX {
                    OverlaySnapHaptics.snapOccurred()
                    didSnapHapticX = true
                } else if !snap.snappedX {
                    didSnapHapticX = false
                }

                if snap.snappedY, !didSnapHapticY {
                    OverlaySnapHaptics.snapOccurred()
                    didSnapHapticY = true
                } else if !snap.snappedY {
                    didSnapHapticY = false
                }

                applyCenter(snap.point, to: target)
            }
            .onEnded { _ in
                dragStartCenter = nil
                isDraggingOverlay = false
                activeSnapGuides = []
                didSnapHapticX = false
                didSnapHapticY = false
                viewModel.commitOverlayGestureChange()
            }
            .simultaneously(with:
                MagnificationGesture()
                    .onChanged { value in
                        if scaleStart == nil {
                            guard abs(value - 1) > 0.01 else { return }
                            scaleStart = scale
                            viewModel.beginGestureEdit("Scale Overlay")
                        }
                        let start = scaleStart ?? scale
                        applyScale(max(0.3, min(start * value, 3)), to: target)
                    }
                    .onEnded { _ in
                        scaleStart = nil
                        viewModel.commitOverlayGestureChange()
                    }
            )
            .simultaneously(with:
                RotationGesture()
                    .onChanged { angle in
                        if rotationStart == nil {
                            guard abs(angle.radians) > 0.01 else { return }
                            rotationStart = rotation
                            viewModel.beginGestureEdit("Rotate Overlay")
                        }
                        let start = rotationStart ?? rotation
                        applyRotation(start + angle.radians, to: target)
                    }
                    .onEnded { _ in
                        rotationStart = nil
                        viewModel.commitOverlayGestureChange()
                    }
            )
    }

    private func selectTarget(_ target: OverlayTarget) {
        switch target {
        case .text(let id):
            viewModel.endInlineTextEdit()
            viewModel.selectedTextID = id
            viewModel.selectedStickerID = nil
        case .sticker(let id):
            viewModel.endInlineTextEdit()
            viewModel.selectedStickerID = id
            viewModel.selectedTextID = nil
        }
    }

    private func applyCenter(_ center: CGPoint, to target: OverlayTarget) {
        switch target {
        case .text(let id):
            guard var overlay = viewModel.project.textOverlays.first(where: { $0.id == id }) else { return }
            overlay.normalizedCenter = center
            viewModel.updateTextOverlay(overlay, recordHistory: false)
        case .sticker(let id):
            guard var overlay = viewModel.project.stickerOverlays.first(where: { $0.id == id }) else { return }
            overlay.normalizedCenter = center
            viewModel.updateStickerOverlay(overlay, recordHistory: false)
        }
    }

    private func applyScale(_ scale: CGFloat, to target: OverlayTarget) {
        switch target {
        case .text(let id):
            guard var overlay = viewModel.project.textOverlays.first(where: { $0.id == id }) else { return }
            overlay.scale = scale
            viewModel.updateTextOverlay(overlay, recordHistory: false)
        case .sticker(let id):
            guard var overlay = viewModel.project.stickerOverlays.first(where: { $0.id == id }) else { return }
            overlay.scale = scale
            viewModel.updateStickerOverlay(overlay, recordHistory: false)
        }
    }

    private func applyRotation(_ rotation: CGFloat, to target: OverlayTarget) {
        switch target {
        case .text(let id):
            guard var overlay = viewModel.project.textOverlays.first(where: { $0.id == id }) else { return }
            overlay.rotation = rotation
            viewModel.updateTextOverlay(overlay, recordHistory: false)
        case .sticker(let id):
            guard var overlay = viewModel.project.stickerOverlays.first(where: { $0.id == id }) else { return }
            overlay.rotation = rotation
            viewModel.updateStickerOverlay(overlay, recordHistory: false)
        }
    }

    private func swiftFontWeight(_ weight: UIFont.Weight) -> Font.Weight {
        switch weight {
        case .bold: return .bold
        case .heavy, .black: return .heavy
        case .semibold: return .semibold
        case .medium: return .medium
        case .light: return .light
        case .thin: return .thin
        default: return .regular
        }
    }

    private struct PreviewAnimationState {
        var center: CGPoint
        var opacity: CGFloat
        var scale: CGFloat
    }

    private func previewAnimationState(for overlay: TextOverlay) -> PreviewAnimationState {
        let time = viewModel.currentTime
        let start = overlay.timeRange.start.seconds
        let end = start + overlay.timeRange.duration.seconds

        switch overlay.animation {
        case .none, .typewriter:
            return PreviewAnimationState(center: overlay.normalizedCenter, opacity: 1, scale: 1)
        case .fade:
            let fadeDuration = min(0.3, overlay.timeRange.duration.seconds * 0.2)
            var opacity: CGFloat = 1
            if time < start + fadeDuration {
                opacity = CGFloat((time - start) / fadeDuration)
            } else if time > end - fadeDuration {
                opacity = CGFloat((end - time) / fadeDuration)
            }
            return PreviewAnimationState(center: overlay.normalizedCenter, opacity: max(0, min(1, opacity)), scale: 1)
        case .slide, .slideUp:
            let intro = min(0.35, overlay.timeRange.duration.seconds * 0.25)
            var center = overlay.normalizedCenter
            var opacity: CGFloat = 1
            if time < start + intro {
                let progress = CGFloat((time - start) / intro)
                center.y = overlay.normalizedCenter.y - (1 - progress) * 0.08
                opacity = progress
            } else if time > end - intro {
                let progress = CGFloat((end - time) / intro)
                center.y = overlay.normalizedCenter.y + (1 - progress) * 0.08
                opacity = progress
            }
            return PreviewAnimationState(center: center, opacity: max(0, min(1, opacity)), scale: 1)
        case .slideDown:
            let intro = min(0.35, overlay.timeRange.duration.seconds * 0.25)
            var center = overlay.normalizedCenter
            var opacity: CGFloat = 1
            if time < start + intro {
                let progress = CGFloat((time - start) / intro)
                center.y = overlay.normalizedCenter.y + (1 - progress) * 0.08
                opacity = progress
            } else if time > end - intro {
                let progress = CGFloat((end - time) / intro)
                center.y = overlay.normalizedCenter.y - (1 - progress) * 0.08
                opacity = progress
            }
            return PreviewAnimationState(center: center, opacity: max(0, min(1, opacity)), scale: 1)
        case .pop, .bounce, .scaleUp:
            let intro = min(0.35, overlay.timeRange.duration.seconds * 0.25)
            var scale: CGFloat = 1
            var opacity: CGFloat = 1
            if time < start + intro {
                let progress = CGFloat((time - start) / intro)
                let startScale: CGFloat = overlay.animation == .bounce ? 0.2 : (overlay.animation == .scaleUp ? 0.5 : 0.4)
                scale = startScale + (1 - startScale) * progress
                opacity = progress
            } else if time > end - min(0.25, overlay.timeRange.duration.seconds * 0.2) {
                let outro = min(0.25, overlay.timeRange.duration.seconds * 0.2)
                let progress = CGFloat((end - time) / outro)
                scale = 0.6 + 0.4 * progress
                opacity = progress
            }
            return PreviewAnimationState(center: overlay.normalizedCenter, opacity: max(0, min(1, opacity)), scale: scale)
        case .drift:
            let intro = min(0.4, overlay.timeRange.duration.seconds * 0.3)
            var center = overlay.normalizedCenter
            var opacity: CGFloat = 1
            if time < start + intro {
                let progress = CGFloat((time - start) / intro)
                center.x = overlay.normalizedCenter.x - (1 - progress) * 0.06
                opacity = progress
            }
            return PreviewAnimationState(center: center, opacity: max(0, min(1, opacity)), scale: 1)
        }
    }
}

struct EditorTransformPreviewOverlay: View {
    @Bindable var viewModel: EditorViewModel
    @State private var dragStartOffset: CGPoint?
    @State private var zoomStart: CGFloat = 1

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard viewModel.selectedTool == .transform else { return }
                        if dragStartOffset == nil {
                            dragStartOffset = viewModel.selectedClip?.framing.offset ?? .zero
                            viewModel.beginGestureEdit("Transform Clip")
                        }
                        let start = dragStartOffset ?? .zero
                        viewModel.setClipOffset(CGPoint(
                            x: start.x + value.translation.width / 400,
                            y: start.y - value.translation.height / 400
                        ))
                    }
                    .onEnded { _ in
                        dragStartOffset = nil
                        viewModel.commitClipTransformChange()
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { scale in
                        guard viewModel.selectedTool == .transform else { return }
                        if zoomStart == 1 {
                            zoomStart = viewModel.selectedClip?.framing.zoom ?? 1
                            viewModel.beginGestureEdit("Transform Clip")
                        }
                        viewModel.setClipZoom(zoomStart * scale)
                    }
                    .onEnded { _ in
                        zoomStart = 1
                        viewModel.commitClipTransformChange()
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
}
