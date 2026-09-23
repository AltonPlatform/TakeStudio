import AVFoundation
import CoreGraphics
import ImageIO
import UIKit
import UniformTypeIdentifiers

enum FilmstripFrameCache {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 320
        cache.totalCostLimit = 12 * 1024 * 1024
        return cache
    }()

    static func image(assetPath: String, timestamp: TimeInterval) -> CGImage? {
        cache.object(forKey: cacheKey(assetPath: assetPath, timestamp: timestamp))
    }

    static func nearestImage(assetPath: String, timestamp: TimeInterval) -> CGImage? {
        if let exact = image(assetPath: assetPath, timestamp: timestamp) { return exact }
        for step in 1...8 {
            let delta = TimeInterval(step) * 0.05
            if let image = image(assetPath: assetPath, timestamp: timestamp + delta) { return image }
            if let image = image(assetPath: assetPath, timestamp: max(0, timestamp - delta)) { return image }
        }
        return nil
    }

    static func store(_ image: CGImage, assetPath: String, timestamp: TimeInterval) {
        let cost = image.width * image.height * 4
        cache.setObject(image, forKey: cacheKey(assetPath: assetPath, timestamp: timestamp), cost: cost)
    }

    static func clear() {
        cache.removeAllObjects()
    }

    private static func cacheKey(assetPath: String, timestamp: TimeInterval) -> NSString {
        let bucket = Int((timestamp * 20).rounded())
        return "\(assetPath)#\(bucket)" as NSString
    }
}

enum FilmstripStripCache {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 8
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    static func image(for key: NSString) -> CGImage? {
        cache.object(forKey: key)
    }

    static func store(_ image: CGImage, for key: NSString) {
        let cost = image.width * image.height * 4
        cache.setObject(image, forKey: key, cost: cost)
    }

    static func clear() {
        cache.removeAllObjects()
    }

    static func key(
        clipID: UUID,
        pixelsPerSecond: CGFloat,
        slotSize: CGFloat,
        slotCount: Int,
        timeRange: CMTimeRange
    ) -> NSString {
        let ppsBucket = Int((pixelsPerSecond * 4).rounded())
        let startMs = Int((timeRange.start.seconds * 1000).rounded())
        let durationMs = Int((timeRange.duration.seconds * 1000).rounded())
        return "\(clipID.uuidString)#\(ppsBucket)#\(Int(slotSize))#\(slotCount)#\(startMs)#\(durationMs)" as NSString
    }

    static func invalidate(clipID: UUID) {
        // NSCache has no prefix eviction — clear all on trim; cheap at countLimit 8.
        clear()
    }
}

/// Shared extraction pool — one semaphore and generator cache for all clip cells.
final class FilmstripExtractionService: @unchecked Sendable {
    static let shared = FilmstripExtractionService()

    /// Single QoS for all work — mixing userInitiated waiters with utility holders
    /// caused priority inversions and UI freezes after Split (many new slot extracts).
    private let workQueue = DispatchQueue(label: "com.alton.editor.filmstrip", qos: .utility, attributes: .concurrent)
    private let semaphore = DispatchSemaphore(value: 3)
    private var generators: [String: AVAssetImageGenerator] = [:]
    private var generatorAccessOrder: [String] = []
    private let maxGenerators = 8
    private let lock = NSLock()
    private var isSuspended = false

    private init() {}

    func setSuspended(_ suspended: Bool) {
        lock.lock()
        isSuspended = suspended
        lock.unlock()
    }

    func extract(
        asset: AVURLAsset,
        assetPath: String,
        slotSize: CGFloat,
        timestamp: TimeInterval,
        isBackground: Bool,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) {
        if let cached = FilmstripFrameCache.image(assetPath: assetPath, timestamp: timestamp) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        lock.lock()
        let suspended = isSuspended
        lock.unlock()
        if suspended {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        // `isBackground` only affects whether we skip when the semaphore is saturated.
        workQueue.async { [self] in
            if isBackground, self.semaphore.wait(timeout: .now() + 0.01) == .timedOut {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            if !isBackground {
                self.semaphore.wait()
            }
            defer { self.semaphore.signal() }

            let generator = self.generator(for: asset, slotSize: slotSize)
            let image = TimelineFilmstrip.extractFrameSquare(
                asset: asset,
                generator: generator,
                at: timestamp
            )
            if let image {
                FilmstripFrameCache.store(image, assetPath: assetPath, timestamp: timestamp)
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    func clearOnMemoryWarning() {
        lock.lock()
        generators.removeAll()
        generatorAccessOrder.removeAll()
        lock.unlock()
        FilmstripFrameCache.clear()
        FilmstripStripCache.clear()
    }

    private func generator(for asset: AVURLAsset, slotSize: CGFloat) -> AVAssetImageGenerator {
        let key = "\(asset.url.path)#\(Int(slotSize))"
        lock.lock()
        defer { lock.unlock() }
        if let existing = generators[key] {
            touchGenerator(key)
            return existing
        }
        let generator = TimelineFilmstrip.makeGenerator(asset: asset, slotSize: slotSize)
        generators[key] = generator
        touchGenerator(key)
        while generators.count > maxGenerators, let oldest = generatorAccessOrder.first {
            generatorAccessOrder.removeFirst()
            generators.removeValue(forKey: oldest)
        }
        return generator
    }

    private func touchGenerator(_ key: String) {
        generatorAccessOrder.removeAll { $0 == key }
        generatorAccessOrder.append(key)
    }
}

enum TimelineFilmstrip {
    static let timestampChangeThreshold: TimeInterval = 0.1
    static let webPCompressionQuality: CGFloat = 0.72
    static let prefetchHysteresisSlots = 3
    static let maxSlotsForStripBake = 60

    static func slotCount(clipWidth: CGFloat, slotSize: CGFloat) -> Int {
        guard slotSize > 0 else { return 1 }
        return max(1, Int(floor(clipWidth / slotSize)))
    }

    static func secondsPerSlot(slotSize: CGFloat, pixelsPerSecond: CGFloat) -> TimeInterval {
        guard pixelsPerSecond > 0, slotSize > 0 else { return 0 }
        return TimeInterval(slotSize / pixelsPerSecond)
    }

    static func timestamp(
        timeRange: CMTimeRange,
        slotIndex: Int,
        slotSize: CGFloat,
        pixelsPerSecond: CGFloat
    ) -> TimeInterval {
        let secondsPerSlot = Self.secondsPerSlot(slotSize: slotSize, pixelsPerSecond: pixelsPerSecond)
        let raw = timeRange.start.seconds + (Double(slotIndex) + 0.5) * secondsPerSlot
        let end = timeRange.endTime.seconds
        return min(max(raw, timeRange.start.seconds), max(timeRange.start.seconds, end - 0.001))
    }

    static func slotIndexRange(
        clipXRange: ClosedRange<CGFloat>,
        slotSize: CGFloat,
        slotCount: Int
    ) -> ClosedRange<Int>? {
        guard slotSize > 0, slotCount > 0 else { return nil }
        let start = max(0, Int(floor(clipXRange.lowerBound / slotSize)))
        let end = min(slotCount - 1, Int(floor((clipXRange.upperBound - 0.001) / slotSize)))
        guard end >= start else { return nil }
        return start...end
    }

    static func extractionPixelSize(slotSize: CGFloat) -> CGSize {
        let scale = min(UIScreen.main.scale, 2)
        let pixels = max(1, Int(ceil(slotSize * scale)))
        return CGSize(width: pixels, height: pixels)
    }

    static func makeGenerator(asset: AVURLAsset, slotSize: CGFloat) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = extractionPixelSize(slotSize: slotSize)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        return generator
    }

    static func extractFrameSquare(
        asset: AVURLAsset,
        generator: AVAssetImageGenerator,
        at timestamp: TimeInterval
    ) -> CGImage? {
        guard let cgImage = extractRawFrame(asset: asset, generator: generator, at: timestamp) else {
            return nil
        }
        return centerCropToSquare(cgImage)
    }

    /// Stitches per-slot frames into one horizontal strip for instant scroll within a clip.
    static func bakeStrip(
        slots: [Int: FilmstripSlotState],
        slotCount: Int,
        slotSize: CGFloat
    ) -> CGImage? {
        guard slotCount > 0, slotCount <= maxSlotsForStripBake else { return nil }
        let pixelSlot = Int(ceil(extractionPixelSize(slotSize: slotSize).width))
        let width = pixelSlot * slotCount
        let height = pixelSlot
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        for index in 0..<slotCount {
            guard let slot = slots[index], let cgImage = slot.loadedFrame else {
                return nil
            }
            context.draw(
                cgImage,
                in: CGRect(x: index * pixelSlot, y: 0, width: pixelSlot, height: pixelSlot)
            )
        }
        return context.makeImage()
    }

    /// Extracts a frame and returns WebP payload (smaller than raw CGImage in flight).
    static func extractFrameWebP(
        asset: AVURLAsset,
        generator: AVAssetImageGenerator,
        at timestamp: TimeInterval
    ) -> Data? {
        guard let cgImage = extractRawFrame(asset: asset, generator: generator, at: timestamp) else {
            return nil
        }
        return encodeWebP(centerCropToSquare(cgImage))
    }

    /// Center-crops to a square so thumbnails fill the slot with no letterboxing.
    static func centerCropToSquare(_ image: CGImage) -> CGImage {
        let side = min(image.width, image.height)
        guard side > 0 else { return image }
        let x = (image.width - side) / 2
        let y = (image.height - side) / 2
        return image.cropping(to: CGRect(x: x, y: y, width: side, height: side)) ?? image
    }

    static func decodeWebP(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Private

    private static func extractRawFrame(
        asset: AVURLAsset,
        generator: AVAssetImageGenerator,
        at timestamp: TimeInterval
    ) -> CGImage? {
        let url = asset.url
        let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm"]
        if videoExtensions.contains(url.pathExtension.lowercased()) {
            let time = CMTime(seconds: timestamp, preferredTimescale: 600)
            let lock = NSLock()
            var image: CGImage?
            let done = DispatchSemaphore(value: 0)
            generator.generateCGImageAsynchronously(for: time) { cgImage, _, _ in
                lock.lock()
                image = cgImage
                lock.unlock()
                done.signal()
            }
            done.wait()
            lock.lock()
            defer { lock.unlock() }
            return image
        }
        let maxPixel = Int(max(extractionPixelSize(slotSize: 44).width, 1))
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encodeWebP(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        let webpType = UTType.webP.identifier as CFString
        if let destination = CGImageDestinationCreateWithData(data, webpType, 1, nil) {
            let properties = [kCGImageDestinationLossyCompressionQuality: webPCompressionQuality] as CFDictionary
            CGImageDestinationAddImage(destination, image, properties)
            if CGImageDestinationFinalize(destination) {
                return data as Data
            }
        }
        return encodeJPEGFallback(image)
    }

    private static func encodeJPEGFallback(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: webPCompressionQuality] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

final class FilmstripSlotState {
    let layer: CALayer
    var timestamp: TimeInterval = -1
    var requestToken: UInt64 = 0
    var loadedFrame: CGImage?

    init(index: Int, slotSize: CGFloat) {
        layer = CALayer()
        layer.frame = Self.frame(for: index, slotSize: slotSize)
        layer.contentsGravity = .resizeAspectFill
        layer.contentsScale = UIScreen.main.scale
        layer.masksToBounds = true
        layer.drawsAsynchronously = true
        layer.backgroundColor = UIColor(white: 0.12, alpha: 1).cgColor
        layer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull()
        ]
    }

    func setFrame(index: Int, slotSize: CGFloat) {
        layer.frame = Self.frame(for: index, slotSize: slotSize)
    }

    func clearContents() {
        loadedFrame = nil
        layer.contents = nil
        layer.backgroundColor = UIColor(white: 0.12, alpha: 1).cgColor
    }

    func applyFrame(_ cgImage: CGImage) {
        loadedFrame = cgImage
        layer.contents = cgImage
        layer.contentsScale = UIScreen.main.scale
        layer.contentsGravity = .resizeAspectFill
        layer.backgroundColor = nil
    }

    private static func frame(for index: Int, slotSize: CGFloat) -> CGRect {
        CGRect(
            x: CGFloat(index) * slotSize,
            y: 0,
            width: slotSize,
            height: slotSize
        )
    }
}
