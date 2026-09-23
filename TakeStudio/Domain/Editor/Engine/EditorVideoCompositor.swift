@preconcurrency import AVFoundation
import CoreImage
import UIKit

final class EditorVideoCompositor: NSObject, AVVideoCompositing {
    private let renderContext = CIContext(options: [.useSoftwareRenderer: false])
    private let renderQueue = DispatchQueue(label: "com.alton.editor.videoCompositor", qos: .userInitiated)
    private let cancelLock = NSLock()
    private var _shouldCancelAllRequests = false
    private var shouldCancelAllRequests: Bool {
        get {
            cancelLock.lock()
            defer { cancelLock.unlock() }
            return _shouldCancelAllRequests
        }
        set {
            cancelLock.lock()
            _shouldCancelAllRequests = newValue
            cancelLock.unlock()
        }
    }
    private var greenScreenProcessors: [UUID: GreenScreenProcessor] = [:]
    private var lastGreenScreenEffect: [UUID: GreenScreenEffect] = [:]
    private let overlayImageCache: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    nonisolated var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferOpenGLESCompatibilityKey as String: true
        ]
    }

    nonisolated var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferOpenGLESCompatibilityKey as String: true
        ]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self else {
                asyncVideoCompositionRequest.finish(
                    with: NSError(
                        domain: "EditorVideoCompositor",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Compositor deallocated"]
                    )
                )
                return
            }
            if self.shouldCancelAllRequests {
                asyncVideoCompositionRequest.finishCancelledRequest()
                return
            }
            let result = self.compose(request: asyncVideoCompositionRequest)
            if let pixelBuffer = result {
                asyncVideoCompositionRequest.finish(withComposedVideoFrame: pixelBuffer)
            } else {
                EditorCompositorContext.recordComposeFailure()
                asyncVideoCompositionRequest.finish(with: NSError(domain: "EditorVideoCompositor", code: -1))
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Must not `renderQueue.sync` — AVFoundation may call cancel from a context that
        // already runs work on renderQueue (or while compose holds it), which deadlocks
        // the preview after Split/seek/replaceCurrentItem.
        shouldCancelAllRequests = true
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.greenScreenProcessors.values.forEach { $0.releaseResources() }
            self.greenScreenProcessors.removeAll()
            self.lastGreenScreenEffect.removeAll()
            self.overlayImageCache.removeAllObjects()
            self.shouldCancelAllRequests = false
        }
    }

    func releaseCachedResources() {
        renderQueue.async { [weak self] in
            guard let self else { return }
            self.greenScreenProcessors.values.forEach { $0.releaseResources() }
            self.greenScreenProcessors.removeAll()
            self.lastGreenScreenEffect.removeAll()
            self.overlayImageCache.removeAllObjects()
        }
    }

    private func compose(request: AVAsynchronousVideoCompositionRequest) -> CVPixelBuffer? {
        guard let instruction = request.videoCompositionInstruction as? EditorCompositionInstruction,
              let state = instruction.compositorState ?? EditorCompositorContext.state,
              let output = request.renderContext.newPixelBuffer() else {
            return nil
        }

        let time = request.compositionTime
        var composed = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(origin: .zero, size: state.renderSize))

        let renderRect = CGRect(origin: .zero, size: state.renderSize)

        // Builder comment: Incoming first, outgoing last so later layers paint on top.
        // `placements.filter` yields chronological [outgoing, incoming] — reverse so
        // outgoing (fading) composites over incoming. Opacity comes from builder as-is.
        let layers = instruction.layerInstructions.count > 1
            ? Array(instruction.layerInstructions.reversed())
            : instruction.layerInstructions

        for layer in layers {
            guard let pixelBuffer = request.sourceFrame(byTrackID: layer.trackID) else { continue }
            var image = ciImage(from: pixelBuffer)
            image = image.transformed(by: layer.transform)

            if let clip = state.clips.first(where: { $0.id == layer.clipID }) {
                image = FilterCompositor.applyGlobalAndClipFilters(
                    to: image,
                    globalFilterIDs: state.globalFilterIDs,
                    clipFilterIDs: clip.filterIDs
                )
                image = ColorAdjustmentCompositor.apply(
                    to: image,
                    global: state.globalColorAdjustments,
                    clip: clip.colorAdjustments
                )
                let framingTransform = clip.framing.asTransform(renderSize: state.renderSize)
                if framingTransform != .identity {
                    image = applyTransformAroundCenter(framingTransform, to: image, renderSize: state.renderSize)
                }
                if clip.transform != .identity {
                    image = applyTransformAroundCenter(clip.transform, to: image, renderSize: state.renderSize)
                }
                if let effect = clip.greenScreenEffect {
                    image = applyGreenScreen(effect: effect, to: image, clipID: clip.id)
                }
            }

            if layer.opacity < 1 {
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(layer.opacity))
                ])
            }

            composed = image.composited(over: composed)
        }

        composed = applyOverlays(to: composed, state: state, time: time)
        composed = composed.cropped(to: renderRect)

        renderContext.render(
            composed,
            to: output,
            bounds: renderRect,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return output
    }

    private func ciImage(from pixelBuffer: CVPixelBuffer) -> CIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        return image.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: height))
    }

    private func applyTransformAroundCenter(
        _ transform: CGAffineTransform,
        to image: CIImage,
        renderSize: CGSize
    ) -> CIImage {
        guard transform != .identity else { return image }
        return image.transformed(by: transform)
    }

    private func applyOverlays(to image: CIImage, state: EditorCompositorState, time: CMTime) -> CIImage {
        var result = image
        let timeSeconds = time.seconds
        let renderSize = state.renderSize

        let orderedLayers = state.layerOrder.filter { $0 != .video }
        for layer in orderedLayers {
            switch layer {
            case .textOverlays:
                for overlay in state.textOverlays where timeSeconds >= overlay.timeRange.start.seconds && timeSeconds <= overlay.timeRange.endSeconds {
                    let cacheKey = "text-\(overlay.id.uuidString)-\(overlay.text)-\(overlay.style.fontSize)-\(overlay.style.colorHex)"
                    if let overlayImage = cachedOverlayImage(key: cacheKey, render: {
                        OverlayRenderer.renderText(overlay, canvasSize: renderSize, currentTime: timeSeconds)
                    }) {
                        result = overlayImage.composited(over: result)
                    }
                }
            case .stickers:
                for overlay in state.stickerOverlays where timeSeconds >= overlay.timeRange.start.seconds && timeSeconds <= overlay.timeRange.endSeconds {
                    let cacheKey = "sticker-\(overlay.id.uuidString)-\(overlay.emoji ?? "")-\(overlay.imageURL?.lastPathComponent ?? "")-\(overlay.scale)"
                    if let overlayImage = cachedOverlayImage(key: cacheKey, render: {
                        OverlayRenderer.renderSticker(overlay, canvasSize: renderSize, currentTime: timeSeconds)
                    }) {
                        result = overlayImage.composited(over: result)
                    }
                }
            case .subtitles:
                if let subtitleTrack = state.subtitleTrack {
                    for segment in subtitleTrack.segments where timeSeconds >= segment.timeRange.start.seconds && timeSeconds <= segment.timeRange.endSeconds {
                        let cacheKey = "subtitle-\(segment.id.uuidString)-\(segment.text)-\(subtitleTrack.style.fontSize)-\(subtitleTrack.style.colorHex)"
                        if let overlayImage = cachedOverlayImage(key: cacheKey, render: {
                            OverlayRenderer.renderSubtitle(
                                segment,
                                style: subtitleTrack.style,
                                canvasSize: renderSize,
                                currentTime: timeSeconds
                            )
                        }) {
                            result = overlayImage.composited(over: result)
                        }
                    }
                }
            case .video:
                break
            }
        }
        return result
    }

    private func cachedOverlayImage(key: String, render: () -> CIImage?) -> CIImage? {
        let nsKey = key as NSString
        if let cached = overlayImageCache.object(forKey: nsKey) { return cached }
        guard let image = render() else { return nil }
        // Approximate cost for a canvas-sized BGRA buffer.
        let cost = Int(image.extent.width * image.extent.height * 4)
        overlayImageCache.setObject(image, forKey: nsKey, cost: max(cost, 1))
        return image
    }

    private func applyGreenScreen(effect: GreenScreenEffect, to image: CIImage, clipID: UUID) -> CIImage {
        let processor: GreenScreenProcessor
        if let existing = greenScreenProcessors[clipID] {
            processor = existing
        } else {
            let created = GreenScreenProcessor()
            created.setRenderContext(renderContext)
            created.setPrefersFastSegmentation(false)
            created.useSynchronousSegmentation = false
            processor = created
            greenScreenProcessors[clipID] = processor
        }

        if lastGreenScreenEffect[clipID] != effect {
            processor.configure(from: effect)
            lastGreenScreenEffect[clipID] = effect
        }

        processor.useSynchronousSegmentation = EditorCompositorContext.exportMode
        return processor.process(image)
    }
}
