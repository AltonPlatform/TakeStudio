import UIKit
import ImageIO
import UniformTypeIdentifiers

enum DownsampledImage {
    /// Creates a downsampled UIImage suitable for on-screen display without decoding full resolution.
    static func make(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return make(source: source, maxPixelSize: maxPixelSize)
    }

    static func make(contentsOfFile path: String, maxPixelSize: CGFloat) -> UIImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url, options as CFDictionary) else {
            return UIImage(contentsOfFile: path)
        }
        return make(source: source, maxPixelSize: maxPixelSize)
    }

    /// Downsamples and re-encodes as JPEG for upload / memory-bounded storage.
    static func jpegData(
        from data: Data,
        maxPixelSize: CGFloat,
        compressionQuality: CGFloat
    ) -> Data? {
        guard let image = make(data: data, maxPixelSize: maxPixelSize) else { return nil }
        return image.jpegData(compressionQuality: compressionQuality)
    }

    /// Downsamples and encodes as lossy WebP (server can copy when ≤ max dimension).
    static func webpData(
        from data: Data,
        maxPixelSize: CGFloat,
        compressionQuality: CGFloat
    ) -> Data? {
        guard let image = make(data: data, maxPixelSize: maxPixelSize),
              let cgImage = image.cgImage else { return nil }
        let out = NSMutableData()
        let type = UTType.webP.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else {
            return nil
        }
        let properties = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    /// Downsamples and re-encodes as PNG (preserves alpha).
    static func pngData(from data: Data, maxPixelSize: CGFloat) -> Data? {
        guard let image = make(data: data, maxPixelSize: maxPixelSize) else { return nil }
        return image.pngData()
    }

    /// Whether the image source has an alpha channel (ImageIO property and/or decoded CGImage).
    static func hasAlpha(data: Data) -> Bool {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return false
        }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool,
           hasAlpha {
            return true
        }
        // Fallback: decode a tiny thumbnail and inspect alphaInfo (covers WebP/PNG false-negatives).
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 32
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return false
        }
        return alphaInfoImpliesAlpha(cgImage.alphaInfo)
    }

    static func alphaInfoImpliesAlpha(_ info: CGImageAlphaInfo) -> Bool {
        switch info {
        case .premultipliedLast, .premultipliedFirst, .last, .first, .alphaOnly:
            return true
        case .none, .noneSkipLast, .noneSkipFirst:
            return false
        @unknown default:
            return false
        }
    }

    private static func make(source: CGImageSource, maxPixelSize: CGFloat) -> UIImage? {
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
