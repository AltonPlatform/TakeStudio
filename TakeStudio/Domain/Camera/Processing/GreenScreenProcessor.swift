import AVFoundation
import CoreImage
import ImageIO
import UIKit
import Vision

final class GreenScreenProcessor {
    var isEnabled = false
    var mode: GreenScreenMode = .personSegmentation

    /// Hue tolerance around green (0.0–1.0). Higher = removes more green shades.
    var sensitivity: Double = 0.35

    /// Edge softness of the mask (0.0–1.0).
    var feather: Double = 0.5

    /// 1.0 for recording; lower values reduce preview compositing cost.
    var outputScale: CGFloat = 1.0

    private var backgroundImage: CIImage?
    private var backgroundCIColor: CIColor?
    private var player: AVPlayer?
    private var playerOutput: AVPlayerItemVideoOutput?
    private var playerItemObserver: (any NSObjectProtocol)?
    private var configuredBackgroundSource: BackgroundSource?
    private var configuredVideoURL: URL?
    private var cachedImageURL: URL?

    // MARK: - Render context & owned buffers (no pool reuse for cached frames)

    private var injectedContext: CIContext?
    private lazy var fallbackContext: CIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])

    private var renderContext: CIContext {
        injectedContext ?? fallbackContext
    }

    private let bufferLock = NSLock()
    private var bufferSize: CGSize = .zero
    /// Ping-pong: Vision writes the back buffer, process reads the front — no torn frames.
    private var maskBuffers: [CVPixelBuffer?] = [nil, nil]
    private var maskFrontIndex = 0
    private var backgroundBuffer: CVPixelBuffer?
    private var compositeBuffers: [CVPixelBuffer?] = [nil, nil]
    private var compositeFrontIndex = 0
    private var scratchCompositeBuffer: CVPixelBuffer?
    private var scratchMaskBuffer: CVPixelBuffer?

    // MARK: - Segmentation quality state

    private static let visionInputScale: CGFloat = 0.4
    private static let chromaInputScale: CGFloat = 0.5
    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()
    private static let deviceGray = CGColorSpaceCreateDeviceGray()
    /// Fixed temporal blend weight — no per-frame GPU→CPU motion probe.
    private static let temporalCurrentWeight: Float = 0.95
    private static let despillStrength: Float = 0.85
    private static let maskPixelFormat = kCVPixelFormatType_OneComponent32Float
    private static let chromaCubeDimension = 64
    private static let chromaCubeHueTolerance: Float = 0.12

    // MARK: - Reused CIFilter instances (single serial queue per processor)

    private lazy var blendFilter: CIFilter? = CIFilter(name: "CIBlendWithMask")
    private lazy var dissolveFilter: CIFilter? = CIFilter(name: "CIDissolveTransition")
    private lazy var gammaFilter: CIFilter? = CIFilter(name: "CIGammaAdjust")
    private lazy var morphMinFilter: CIFilter? = CIFilter(name: "CIMorphologyMinimum")
    private lazy var morphMaxFilter: CIFilter? = CIFilter(name: "CIMorphologyMaximum")
    private lazy var blurFilter: CIFilter? = CIFilter(name: "CIGaussianBlur")
    private lazy var colorCubeFilter: CIFilter? = CIFilter(name: "CIColorCube")
    private lazy var maxComponentFilter: CIFilter? = CIFilter(name: "CIMaximumComponent")

    private let stateLock = NSLock()

    private var hasMask = false
    private var maskGeneration = 0
    private var visionGeneration = 0

    private var cachedBackgroundExtent: CGRect = .zero
    private var cachedBackgroundIsVideo = false

    /// Live camera uses `.balanced` for mask quality; editor/export uses the same.
    var prefersFastSegmentation = false

    /// Camera preview: sync Vision (zero mask lag). Editor compositor: async Vision (real-time playback).
    var useSynchronousSegmentation = false

    private var isVisionInFlight = false
    private var pendingVisionImage: CIImage?
    private var pendingVisionExtent: CGRect?
    private var pendingVisionOrientation: CGImagePropertyOrientation = .up

    private let visionQueue = DispatchQueue(label: "com.alton.editor.vision", qos: .userInitiated)

    private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent32Float
        return request
    }()

    // MARK: - Public configuration

    func setRenderContext(_ context: CIContext) {
        injectedContext = context
    }

    func setPrefersFastSegmentation(_ fast: Bool) {
        prefersFastSegmentation = fast
        segmentationRequest.qualityLevel = fast ? .fast : .balanced
    }

    /// Applies effect parameters and reconfigures background only when `backgroundSource` changes.
    func configure(from effect: GreenScreenEffect) {
        let modeChanged = mode != effect.mode
        isEnabled = true
        mode = effect.mode
        sensitivity = effect.sensitivity
        feather = effect.feather

        if configuredBackgroundSource != effect.backgroundSource {
            configuredBackgroundSource = effect.backgroundSource
            applyBackgroundSource(effect.backgroundSource)
            reset()
        } else if modeChanged {
            reset()
        }
    }

    func releaseResources() {
        configuredBackgroundSource = nil
        configuredVideoURL = nil
        cachedImageURL = nil
        setBackgroundImage(nil)
        setBackgroundColor(nil)
        setBackgroundVideoURL(nil)
        reset()
    }

    deinit {
        if let playerItemObserver {
            NotificationCenter.default.removeObserver(playerItemObserver)
        }
        player?.pause()
        player = nil
        playerOutput = nil
    }

    // MARK: - Kernels (compiled once)

    private static let chromaKernel: CIColorKernel? = {
        let source = """
        kernel vec4 chromaKeyMask(__sample s, float hueCenter, float hueTolerance, float minSaturation) {
            vec3 rgb = s.rgb;
            float maxC = max(rgb.r, max(rgb.g, rgb.b));
            float minC = min(rgb.r, min(rgb.g, rgb.b));
            float delta = maxC - minC;
            float hue = 0.0;
            if (delta > 0.0) {
                if (maxC == rgb.g) {
                    hue = (rgb.b - rgb.r) / delta + 2.0;
                } else if (maxC == rgb.r) {
                    hue = (rgb.g - rgb.b) / delta;
                } else {
                    hue = (rgb.r - rgb.g) / delta + 4.0;
                }
                hue = hue / 6.0;
                if (hue < 0.0) hue += 1.0;
            }
            float sat = maxC > 0.0 ? delta / maxC : 0.0;
            float diff = abs(hue - hueCenter);
            if (diff > 0.5) diff = 1.0 - diff;
            bool isGreen = (diff < hueTolerance) && (sat > minSaturation);
            float alpha = isGreen ? 0.0 : 1.0;
            return vec4(alpha, alpha, alpha, 1.0);
        }
        """
        return CIColorKernel(source: source)
    }()

    private static let despillKernel: CIColorKernel? = {
        let source = """
        kernel vec4 greenDespill(__sample s, float strength) {
            float spillAmount = max(0.0, s.g - max(s.r, s.b));
            float g = s.g - spillAmount * strength;
            return vec4(s.r, g, s.b, s.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    private static let chromaCubeData: Data = {
        let size = chromaCubeDimension
        var cubeData = [Float](repeating: 0, count: size * size * size * 4)
        let hueTolerance = chromaCubeHueTolerance

        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let rf = Float(r) / Float(size - 1)
                    let gf = Float(g) / Float(size - 1)
                    let bf = Float(b) / Float(size - 1)

                    let maxC = max(rf, gf, bf)
                    let minC = min(rf, gf, bf)
                    let delta = maxC - minC
                    var hue: Float = 0
                    if delta > 0 {
                        if maxC == gf {
                            hue = (60 * ((bf - rf) / delta) + 120) / 360
                        } else if maxC == rf {
                            hue = (60 * ((gf - bf) / delta).truncatingRemainder(dividingBy: 6)) / 360
                        } else {
                            hue = (60 * ((rf - gf) / delta) + 240) / 360
                        }
                    }
                    if hue < 0 { hue += 1 }

                    let sat: Float = maxC > 0 ? delta / maxC : 0

                    var dist = abs(hue - 0.333)
                    if dist > 0.5 { dist = 1 - dist }

                    let isGreen = dist < hueTolerance && sat > 0.25
                    let alpha: Float = isGreen ? 0 : 1

                    let index = (b * size * size + g * size + r) * 4
                    cubeData[index + 0] = alpha
                    cubeData[index + 1] = alpha
                    cubeData[index + 2] = alpha
                    cubeData[index + 3] = 1
                }
            }
        }

        return Data(bytes: cubeData, count: cubeData.count * MemoryLayout<Float>.size)
    }()

    // MARK: - Background Setup

    func setBackgroundImage(_ image: UIImage?) {
        backgroundImage = image.flatMap { CIImage(image: $0) }
        backgroundCIColor = nil
        invalidateBackgroundCache()
    }

    func setBackgroundColor(_ color: CIColor?) {
        backgroundCIColor = color
        backgroundImage = nil
        invalidateBackgroundCache()
    }

    func setBackgroundVideoURL(_ url: URL?) {
        if url == configuredVideoURL, player != nil { return }

        if let playerItemObserver {
            NotificationCenter.default.removeObserver(playerItemObserver)
        }
        playerItemObserver = nil
        player?.pause()
        player = nil
        playerOutput = nil
        configuredVideoURL = url
        invalidateBackgroundCache()

        guard let url else { return }
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true
        newPlayer.actionAtItemEnd = .none
        playerItemObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak newPlayer] _ in
            newPlayer?.seek(to: .zero)
            newPlayer?.play()
        }
        player = newPlayer
        playerOutput = output
        newPlayer.play()
    }

    // MARK: - Main Process

    /// Sync Vision on the capture queue — mask matches this frame exactly.
    /// Returns a flattened CIImage in an owned buffer (releases the camera buffer immediately).
    func process(_ image: CIImage, orientation: CGImagePropertyOrientation = .up) -> CIImage {
        guard isEnabled else { return image }

        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return image }

        let workExtent = CGRect(origin: .zero, size: extent.size)
        ensureBuffers(for: workExtent)

        let normalizedImage = image
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            .cropped(to: workExtent)

        let feathered: CIImage?
        switch mode {
        case .personSegmentation:
            if useSynchronousSegmentation {
                feathered = updateSegmentationMaskSync(
                    image: normalizedImage,
                    targetExtent: workExtent,
                    orientation: orientation
                ) ?? displayMask()
            } else {
                scheduleVisionUpdate(image: normalizedImage, targetExtent: workExtent, orientation: orientation)
                feathered = displayMask()
            }
        case .chromaKey:
            feathered = chromaKeyDisplayMask(for: normalizedImage, extent: workExtent)
        }

        guard let feathered else {
            return image
        }

        let foregroundForBlend: CIImage
        if mode == .chromaKey {
            foregroundForBlend = applyDespill(to: normalizedImage, extent: workExtent) ?? normalizedImage
        } else {
            foregroundForBlend = normalizedImage
        }

        let background = currentBackground(for: workExtent) ?? solidBackground(for: workExtent)

        guard let blendFilter else { return image }
        blendFilter.setValue(foregroundForBlend, forKey: kCIInputImageKey)
        blendFilter.setValue(background, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(feathered, forKey: kCIInputMaskImageKey)

        guard
            let blendedGraph = blendFilter.outputImage,
            let flatOutput = renderToCompositeOutput(blendedGraph, extent: workExtent)
        else {
            return image
        }

        if extent.origin == .zero {
            return flatOutput
        }

        return flatOutput
            .transformed(by: CGAffineTransform(translationX: extent.origin.x, y: extent.origin.y))
            .cropped(to: extent)
    }

    func reset() {
        stateLock.lock()
        hasMask = false
        maskGeneration = 0
        visionGeneration += 1
        isVisionInFlight = false
        pendingVisionImage = nil
        pendingVisionExtent = nil
        pendingVisionOrientation = .up
        stateLock.unlock()
        invalidateBackgroundCache()
        releaseOwnedBuffers()
    }

    // MARK: - Owned buffer helpers

    private func releaseOwnedBuffers() {
        bufferLock.lock()
        bufferSize = .zero
        maskBuffers = [nil, nil]
        maskFrontIndex = 0
        backgroundBuffer = nil
        compositeBuffers = [nil, nil]
        compositeFrontIndex = 0
        scratchCompositeBuffer = nil
        scratchMaskBuffer = nil
        bufferLock.unlock()
    }

    private func ensureBuffers(for extent: CGRect) {
        let size = extent.size
        guard size.width > 0, size.height > 0 else { return }

        bufferLock.lock()
        if bufferSize == size {
            bufferLock.unlock()
            return
        }
        bufferSize = size
        maskBuffers = [nil, nil]
        maskFrontIndex = 0
        backgroundBuffer = nil
        compositeBuffers = [nil, nil]
        compositeFrontIndex = 0
        scratchCompositeBuffer = nil
        scratchMaskBuffer = nil
        bufferLock.unlock()

        stateLock.lock()
        hasMask = false
        maskGeneration = 0
        stateLock.unlock()
        invalidateBackgroundCache()
    }

    private static func createBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            attrs as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    private func ensureBuffer(
        _ slot: inout CVPixelBuffer?,
        width: Int,
        height: Int,
        format: OSType
    ) -> CVPixelBuffer? {
        if let existing = slot,
           CVPixelBufferGetWidth(existing) == width,
           CVPixelBufferGetHeight(existing) == height,
           CVPixelBufferGetPixelFormatType(existing) == format {
            return existing
        }
        slot = Self.createBuffer(width: width, height: height, format: format)
        return slot
    }

    private func render(_ image: CIImage, into buffer: CVPixelBuffer, extent: CGRect) {
        renderContext.render(
            image.cropped(to: extent),
            to: buffer,
            bounds: extent,
            colorSpace: Self.deviceRGB
        )
    }

    private func renderMask(_ image: CIImage, into buffer: CVPixelBuffer, extent: CGRect) {
        renderContext.render(
            image.cropped(to: extent),
            to: buffer,
            bounds: extent,
            colorSpace: Self.deviceGray
        )
    }

    private func renderToScratchComposite(_ image: CIImage, extent: CGRect) -> CIImage? {
        let width = Int(extent.width)
        let height = Int(extent.height)
        bufferLock.lock()
        guard let buffer = ensureBuffer(
            &scratchCompositeBuffer,
            width: width,
            height: height,
            format: kCVPixelFormatType_32BGRA
        ) else {
            bufferLock.unlock()
            return nil
        }
        render(image, into: buffer, extent: extent)
        let result = CIImage(cvPixelBuffer: buffer)
        bufferLock.unlock()
        return result
    }

    private func renderToScratchMask(_ image: CIImage, extent: CGRect) -> CIImage? {
        let width = Int(extent.width)
        let height = Int(extent.height)
        bufferLock.lock()
        guard let buffer = ensureBuffer(
            &scratchMaskBuffer,
            width: width,
            height: height,
            format: Self.maskPixelFormat
        ) else {
            bufferLock.unlock()
            return nil
        }
        renderMask(image, into: buffer, extent: extent)
        let result = CIImage(cvPixelBuffer: buffer)
        bufferLock.unlock()
        return result
    }

    private func renderToCompositeOutput(_ image: CIImage, extent: CGRect) -> CIImage? {
        let width = Int(extent.width)
        let height = Int(extent.height)
        bufferLock.lock()
        let backIndex = 1 - compositeFrontIndex
        guard let buffer = ensureBuffer(
            &compositeBuffers[backIndex],
            width: width,
            height: height,
            format: kCVPixelFormatType_32BGRA
        ) else {
            bufferLock.unlock()
            return nil
        }
        render(image, into: buffer, extent: extent)
        compositeFrontIndex = backIndex
        let result = CIImage(cvPixelBuffer: buffer)
        bufferLock.unlock()
        return result
    }

    private func publishMaskFrame(_ image: CIImage, extent: CGRect) {
        let width = Int(extent.width)
        let height = Int(extent.height)
        bufferLock.lock()
        let backIndex = 1 - maskFrontIndex
        if let buffer = ensureBuffer(
            &maskBuffers[backIndex],
            width: width,
            height: height,
            format: Self.maskPixelFormat
        ) {
            renderMask(image, into: buffer, extent: extent)
            maskFrontIndex = backIndex
        }
        bufferLock.unlock()
    }

    // MARK: - Background helpers

    private func applyBackgroundSource(_ source: BackgroundSource) {
        switch source {
        case .color(let hex):
            cachedImageURL = nil
            configuredVideoURL = nil
            setBackgroundVideoURL(nil)
            setBackgroundImage(nil)
            if let color = UIColor(hex: hex) {
                setBackgroundColor(CIColor(color: color))
            } else {
                setBackgroundColor(nil)
            }
        case .image(let url):
            configuredVideoURL = nil
            setBackgroundVideoURL(nil)
            setBackgroundColor(nil)
            if cachedImageURL != url {
                cachedImageURL = url
                if let data = try? Data(contentsOf: url),
                   let uiImage = DownsampledImage.make(data: data, maxPixelSize: 1920) {
                    setBackgroundImage(uiImage)
                } else {
                    setBackgroundImage(nil)
                }
            }
        case .videoURL(let url):
            cachedImageURL = nil
            setBackgroundColor(nil)
            setBackgroundImage(nil)
            setBackgroundVideoURL(url)
        }
    }

    private func invalidateBackgroundCache() {
        cachedBackgroundExtent = .zero
        cachedBackgroundIsVideo = false
    }

    private func currentBackground(for extent: CGRect) -> CIImage? {
        let isVideo = configuredVideoURL != nil

        if cachedBackgroundExtent == extent,
           backgroundBuffer != nil,
           (!isVideo || !cachedBackgroundIsVideo) {
            bufferLock.lock()
            let image = backgroundBuffer.map { CIImage(cvPixelBuffer: $0) }
            bufferLock.unlock()
            return image
        }

        let bgGraph: CIImage?
        if let color = backgroundCIColor {
            bgGraph = CIImage(color: color).cropped(to: extent)
        } else if let backgroundImage {
            bgGraph = aspectFillBackground(backgroundImage, to: extent)
        } else if let playerOutput,
                  let item = player?.currentItem,
                  item.status == .readyToPlay {
            let time = item.currentTime()
            if playerOutput.hasNewPixelBuffer(forItemTime: time),
               let pixelBuffer = playerOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                bgGraph = aspectFillBackground(CIImage(cvPixelBuffer: pixelBuffer), to: extent)
            } else if cachedBackgroundExtent == extent, let backgroundBuffer {
                return CIImage(cvPixelBuffer: backgroundBuffer)
            } else {
                bgGraph = nil
            }
        } else {
            bgGraph = nil
        }

        guard let bgGraph else { return nil }

        let width = Int(extent.width)
        let height = Int(extent.height)
        bufferLock.lock()
        guard let buffer = ensureBuffer(
            &backgroundBuffer,
            width: width,
            height: height,
            format: kCVPixelFormatType_32BGRA
        ) else {
            bufferLock.unlock()
            return nil
        }
        render(bgGraph, into: buffer, extent: extent)
        let flat = CIImage(cvPixelBuffer: buffer)
        bufferLock.unlock()

        cachedBackgroundExtent = extent
        cachedBackgroundIsVideo = isVideo
        return flat
    }

    private func aspectFillBackground(_ bg: CIImage, to extent: CGRect) -> CIImage {
        let scaleX = extent.width / max(bg.extent.width, 1)
        let scaleY = extent.height / max(bg.extent.height, 1)
        let scale = max(scaleX, scaleY)
        let scaled = bg.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = extent.midX - scaled.extent.midX
        let dy = extent.midY - scaled.extent.midY
        return scaled
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: extent)
    }

    private func solidBackground(for extent: CGRect) -> CIImage {
        if cachedBackgroundExtent == extent,
           let backgroundBuffer,
           backgroundCIColor == nil,
           backgroundImage == nil {
            return CIImage(cvPixelBuffer: backgroundBuffer)
        }

        let graph = CIImage(color: CIColor(red: 0.1, green: 0.15, blue: 0.35))
            .cropped(to: extent)

        let width = Int(extent.width)
        let height = Int(extent.height)
        bufferLock.lock()
        guard let buffer = ensureBuffer(
            &backgroundBuffer,
            width: width,
            height: height,
            format: kCVPixelFormatType_32BGRA
        ) else {
            bufferLock.unlock()
            return graph
        }
        render(graph, into: buffer, extent: extent)
        let flat = CIImage(cvPixelBuffer: buffer)
        bufferLock.unlock()

        cachedBackgroundExtent = extent
        cachedBackgroundIsVideo = false
        return flat
    }

    // MARK: - Vision (person segmentation)

    private func scheduleVisionUpdate(image: CIImage,
                                      targetExtent: CGRect,
                                      orientation: CGImagePropertyOrientation) {
        stateLock.lock()
        if isVisionInFlight {
            pendingVisionImage = image
            pendingVisionExtent = targetExtent
            pendingVisionOrientation = orientation
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        startVisionUpdate(image: image, targetExtent: targetExtent, orientation: orientation)
    }

    private func startVisionUpdate(image: CIImage,
                                   targetExtent: CGRect,
                                   orientation: CGImagePropertyOrientation) {
        stateLock.lock()
        isVisionInFlight = true
        let generation = visionGeneration
        stateLock.unlock()

        let visionImage = image.transformed(
            by: CGAffineTransform(scaleX: Self.visionInputScale, y: Self.visionInputScale)
        )

        visionQueue.async { [weak self] in
            guard let self else { return }
            defer { self.chainPendingVisionUpdate() }

            let handler = VNImageRequestHandler(ciImage: visionImage, orientation: orientation, options: [:])
            do {
                try handler.perform([self.segmentationRequest])
            } catch {
                return
            }

            guard let observation = self.segmentationRequest.results?.first else { return }

            let rawMask = CIImage(cvPixelBuffer: observation.pixelBuffer)
            guard rawMask.extent.width > 0, rawMask.extent.height > 0 else { return }

            let mask = self.scaleVisionMask(rawMask, to: targetExtent)

            self.stateLock.lock()
            let hasPrevious = self.hasMask
            self.stateLock.unlock()
            self.bufferLock.lock()
            let previous = hasPrevious ? self.maskBuffers[self.maskFrontIndex].map { CIImage(cvPixelBuffer: $0) } : nil
            self.bufferLock.unlock()

            let blended = self.adaptiveBlend(current: mask, previous: previous, extent: targetExtent)
            let refinedMask = self.refineSegmentationMask(blended, extent: targetExtent)

            self.stateLock.lock()
            guard generation == self.visionGeneration else {
                self.stateLock.unlock()
                return
            }
            self.publishMaskFrame(refinedMask, extent: targetExtent)
            self.hasMask = true
            self.maskGeneration += 1
            self.stateLock.unlock()
        }
    }

    private func chainPendingVisionUpdate() {
        stateLock.lock()
        let pendingImage = pendingVisionImage
        let pendingExtent = pendingVisionExtent
        let pendingOrientation = pendingVisionOrientation
        pendingVisionImage = nil
        pendingVisionExtent = nil
        pendingVisionOrientation = .up
        isVisionInFlight = false
        stateLock.unlock()

        guard let pendingImage, let pendingExtent else { return }
        startVisionUpdate(image: pendingImage, targetExtent: pendingExtent, orientation: pendingOrientation)
    }

    /// Runs Vision on the capture queue before compositing — zero mask lag vs the current frame.
    private func updateSegmentationMaskSync(image: CIImage,
                                            targetExtent: CGRect,
                                            orientation: CGImagePropertyOrientation) -> CIImage? {
        stateLock.lock()
        let generation = visionGeneration
        stateLock.unlock()

        let visionImage = image.transformed(
            by: CGAffineTransform(scaleX: Self.visionInputScale, y: Self.visionInputScale)
        )

        let handler = VNImageRequestHandler(ciImage: visionImage, orientation: orientation, options: [:])
        do {
            try handler.perform([segmentationRequest])
        } catch {
            return displayMask()
        }

        guard let observation = segmentationRequest.results?.first else {
            return displayMask()
        }

        let rawMask = CIImage(cvPixelBuffer: observation.pixelBuffer)
        guard rawMask.extent.width > 0, rawMask.extent.height > 0 else {
            return displayMask()
        }

        let mask = scaleVisionMask(rawMask, to: targetExtent)

        stateLock.lock()
        let hasPrevious = hasMask
        stateLock.unlock()
        bufferLock.lock()
        let previous = hasPrevious ? maskBuffers[maskFrontIndex].map { CIImage(cvPixelBuffer: $0) } : nil
        bufferLock.unlock()

        let blended = adaptiveBlend(current: mask, previous: previous, extent: targetExtent)
        let refinedMask = refineSegmentationMask(blended, extent: targetExtent)

        stateLock.lock()
        guard generation == visionGeneration else {
            stateLock.unlock()
            return displayMask()
        }
        publishMaskFrame(refinedMask, extent: targetExtent)
        hasMask = true
        maskGeneration += 1
        stateLock.unlock()

        return refinedMask
    }

    /// Light temporal blend — fixed weight, no GPU→CPU readback per frame.
    private func adaptiveBlend(current: CIImage, previous: CIImage?, extent: CGRect) -> CIImage {
        guard let previous, let dissolveFilter else { return current }

        dissolveFilter.setValue(previous, forKey: kCIInputImageKey)
        dissolveFilter.setValue(current, forKey: "inputTargetImage")
        dissolveFilter.setValue(Self.temporalCurrentWeight, forKey: kCIInputTimeKey)
        return dissolveFilter.outputImage?.cropped(to: extent) ?? current
    }

    private func displayMask() -> CIImage? {
        stateLock.lock()
        guard hasMask else {
            stateLock.unlock()
            return nil
        }
        stateLock.unlock()

        bufferLock.lock()
        let image = maskBuffers[maskFrontIndex].map { CIImage(cvPixelBuffer: $0).samplingLinear() }
        bufferLock.unlock()
        return image
    }

    // MARK: - Chroma Key

    private func chromaKeyDisplayMask(for image: CIImage, extent: CGRect) -> CIImage? {
        let smallExtent = CGRect(
            origin: .zero,
            size: CGSize(
                width: max(1, extent.width * Self.chromaInputScale),
                height: max(1, extent.height * Self.chromaInputScale)
            )
        )

        let smallImage = image
            .transformed(by: CGAffineTransform(scaleX: Self.chromaInputScale, y: Self.chromaInputScale))
            .cropped(to: smallExtent)

        guard let rawMask = chromaKeyMask(for: smallImage, extent: smallExtent) else { return nil }

        let blurRadius = (1 + feather * 2) * Self.chromaInputScale
        let featheredSmall = softChromaMaskEdges(rawMask, extent: smallExtent, blurRadius: blurRadius)

        let scaleUp = 1.0 / Self.chromaInputScale
        let upscaled = featheredSmall
            .transformed(by: CGAffineTransform(scaleX: scaleUp, y: scaleUp))
            .cropped(to: extent)

        return renderToScratchMask(upscaled, extent: extent)
    }

    private func chromaKeyMask(for image: CIImage, extent: CGRect) -> CIImage? {
        let greenHue: Float = 0.333
        let hueTolerance: Float = Float(0.05 + sensitivity * 0.20)
        let minSaturation: Float = 0.25

        if let kernel = Self.chromaKernel,
           let output = kernel.apply(
               extent: extent,
               roiCallback: { _, rect in rect },
               arguments: [image, greenHue, hueTolerance, minSaturation]
           ) {
            return output.cropped(to: extent)
        }

        return chromaKeyMaskColorCubeFallback(for: image, extent: extent, hueTolerance: Double(hueTolerance))
    }

    private func applyDespill(to image: CIImage, extent: CGRect) -> CIImage? {
        guard let kernel = Self.despillKernel,
              let output = kernel.apply(
                  extent: extent,
                  roiCallback: { _, rect in rect },
                  arguments: [image, Self.despillStrength]
              ) else {
            return image
        }
        return output.cropped(to: extent)
    }

    private func chromaKeyMaskColorCubeFallback(for image: CIImage,
                                                 extent: CGRect,
                                                 hueTolerance: Double) -> CIImage {
        _ = hueTolerance
        guard let colorCubeFilter, let maxComponentFilter else {
            return fullForegroundMask(for: extent)
        }

        let size = Self.chromaCubeDimension
        colorCubeFilter.setValue(size, forKey: "inputCubeDimension")
        colorCubeFilter.setValue(Self.chromaCubeData as NSData, forKey: "inputCubeData")
        colorCubeFilter.setValue(image, forKey: kCIInputImageKey)

        guard let mapped = colorCubeFilter.outputImage else {
            return fullForegroundMask(for: extent)
        }
        maxComponentFilter.setValue(mapped, forKey: kCIInputImageKey)
        return maxComponentFilter.outputImage?.cropped(to: extent) ?? fullForegroundMask(for: extent)
    }

    // MARK: - Mask utilities

    /// Upscales Vision float mask with linear sampling — preserves soft 0.0–1.0 alpha at edges.
    private func scaleVisionMask(_ rawMask: CIImage, to extent: CGRect) -> CIImage {
        let maskExtent = rawMask.extent
        guard maskExtent.width > 0, maskExtent.height > 0 else {
            return rawMask.cropped(to: extent)
        }

        let scaleX = extent.width / maskExtent.width
        let scaleY = extent.height / maskExtent.height
        return rawMask
            .samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: extent)
    }

    /// Person-segmentation edge refinement — suppress speckles, preserve Vision soft alpha at hair.
    private func refineSegmentationMask(_ rawMask: CIImage, extent: CGRect) -> CIImage {
        guard let gammaFilter, let morphMinFilter, let morphMaxFilter, let blurFilter else {
            return rawMask.cropped(to: extent)
        }

        gammaFilter.setValue(rawMask, forKey: kCIInputImageKey)
        gammaFilter.setValue(1.35, forKey: "inputPower")
        guard let confident = gammaFilter.outputImage?.cropped(to: extent) else {
            return rawMask.cropped(to: extent)
        }

        morphMinFilter.setValue(confident, forKey: kCIInputImageKey)
        morphMinFilter.setValue(1, forKey: "inputRadius")
        guard let eroded = morphMinFilter.outputImage?.cropped(to: extent) else {
            return confident
        }

        morphMaxFilter.setValue(eroded, forKey: kCIInputImageKey)
        morphMaxFilter.setValue(1, forKey: "inputRadius")
        guard let opened = morphMaxFilter.outputImage?.cropped(to: extent) else {
            return eroded
        }

        blurFilter.setValue(opened, forKey: kCIInputImageKey)
        blurFilter.setValue(1.0, forKey: kCIInputRadiusKey)
        return blurFilter.outputImage?.cropped(to: extent) ?? opened
    }

    private func softChromaMaskEdges(_ mask: CIImage, extent: CGRect, blurRadius: Double) -> CIImage {
        featherMask(mask, radius: blurRadius, extent: extent)
    }

    private func featherMask(_ mask: CIImage, radius: Double, extent: CGRect) -> CIImage {
        guard radius > 0, let blurFilter else { return mask }
        blurFilter.setValue(mask, forKey: kCIInputImageKey)
        blurFilter.setValue(radius, forKey: kCIInputRadiusKey)
        return blurFilter.outputImage?.cropped(to: extent) ?? mask
    }

    private func fullForegroundMask(for extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
            .cropped(to: extent)
    }
}

private extension UIColor {
    convenience init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
