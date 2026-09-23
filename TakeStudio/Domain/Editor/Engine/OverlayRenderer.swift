import AVFoundation
import CoreImage
import UIKit

enum OverlayRenderer {
    static let curatedFonts = [
        "System",
        "HelveticaNeue-Bold",
        "AvenirNext-DemiBold",
        "AvenirNext-Bold",
        "Georgia-Bold",
        "CourierNewPS-BoldMT",
        "SnellRoundhand-Bold",
        "Futura-Bold",
        "GillSans-Bold",
        "Impact",
        "AmericanTypewriter-Bold"
    ]

    private static let fontCache = NSCache<NSString, UIFont>()

    static func cachedFont(name: String?, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let key = "\(name ?? "System")|\(size)|\(weight.rawValue)" as NSString
        if let cached = fontCache.object(forKey: key) { return cached }
        let font = resolvedFont(name: name, size: size, weight: weight)
        fontCache.setObject(font, forKey: key)
        return font
    }

    static func clearFontCache() {
        fontCache.removeAllObjects()
    }

    static func renderText(_ overlay: TextOverlay, canvasSize: CGSize, currentTime: TimeInterval) -> CIImage? {
        let style = overlay.style
        let displayText = animatedText(overlay.text, animation: overlay.animation, timeRange: overlay.timeRange, currentTime: currentTime)
        guard !displayText.isEmpty else { return nil }

        let fontSize = style.fontSize * overlay.scale
        let font = cachedFont(name: style.fontName, size: fontSize, weight: style.fontWeight)
        let textColor = (UIColor(hex: style.colorHex) ?? .white).withAlphaComponent(style.opacity * overlay.opacity)

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: {
                let p = NSMutableParagraphStyle()
                p.alignment = style.alignment
                return p
            }()
        ]

        if style.strokeWidth > 0 {
            attributes[.strokeColor] = UIColor(hex: style.strokeColorHex) ?? .black
            attributes[.strokeWidth] = -style.strokeWidth
        } else if style.hasShadow {
            attributes[.strokeColor] = UIColor.black
            attributes[.strokeWidth] = -2.0
        }

        let textSize = (displayText as NSString).boundingRect(
            with: CGSize(width: canvasSize.width * 0.9, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        ).integral.size
        let padding: CGFloat = style.hasBackground ? 12 : 0
        let canvas = CGSize(width: max(textSize.width + padding * 2, 1), height: max(textSize.height + padding * 2, 1))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let image = renderer.image { context in
            if style.hasBackground {
                let bgColor = UIColor(hex: style.backgroundColorHex) ?? UIColor.black.withAlphaComponent(0.5)
                bgColor.setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: canvas), cornerRadius: 6).fill()
            }
            if style.hasShadow {
                let shadowColor = (UIColor(hex: style.shadowColorHex) ?? .black).cgColor
                context.cgContext.setShadow(
                    offset: CGSize(width: 0, height: 1),
                    blur: style.shadowRadius,
                    color: shadowColor
                )
            }
            (displayText as NSString).draw(
                in: CGRect(x: padding, y: padding, width: textSize.width, height: textSize.height),
                withAttributes: attributes
            )
        }
        guard let cgImage = image.cgImage else { return nil }

        let animationState = animationState(
            for: overlay.animation,
            timeRange: overlay.timeRange,
            currentTime: currentTime
        )

        return positionedImage(
            CIImage(cgImage: cgImage),
            normalizedCenter: animationState.center(for: overlay.normalizedCenter, canvasSize: canvasSize),
            canvasSize: canvasSize,
            rotation: overlay.rotation,
            opacity: animationState.opacity * overlay.opacity,
            scale: animationState.scale
        )
    }

    static func renderSticker(_ overlay: StickerOverlay, canvasSize: CGSize, currentTime: TimeInterval) -> CIImage? {
        let image: CIImage?
        if let imageURL = overlay.imageURL,
           let uiImage = UIImage(contentsOfFile: imageURL.path),
           let cgImage = uiImage.cgImage {
            image = CIImage(cgImage: cgImage)
        } else if let emoji = overlay.emoji {
            let fontSize = 72 * overlay.scale
            let font = UIFont.systemFont(ofSize: fontSize)
            let textSize = (emoji as NSString).size(withAttributes: [.font: font])
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: textSize, format: format)
            let rendered = renderer.image { _ in
                (emoji as NSString).draw(at: .zero, withAttributes: [.font: font])
            }
            guard let cgImage = rendered.cgImage else { return nil }
            image = CIImage(cgImage: cgImage)
        } else {
            return nil
        }

        guard let baseImage = image else { return nil }
        let scaled = baseImage.transformed(by: CGAffineTransform(scaleX: overlay.scale, y: overlay.scale))
        return positionedImage(
            scaled,
            normalizedCenter: overlay.normalizedCenter,
            canvasSize: canvasSize,
            rotation: overlay.rotation,
            opacity: overlay.opacity,
            scale: 1
        )
    }

    static func renderSubtitle(_ segment: SubtitleSegment, style: SubtitleStyle, canvasSize: CGSize, currentTime: TimeInterval) -> CIImage? {
        let effectiveStyle = segment.style ?? style
        let displayText: String
        if let words = segment.words, !words.isEmpty, effectiveStyle.hasBackground == false {
            displayText = words.filter { currentTime >= $0.timeRange.start.seconds && currentTime <= $0.timeRange.endSeconds }
                .map(\.text)
                .joined(separator: " ")
            if displayText.isEmpty { return nil }
        } else {
            displayText = segment.text
        }

        let overlay = TextOverlay(
            text: displayText,
            timeRange: segment.timeRange,
            style: effectiveStyle,
            normalizedCenter: effectiveStyle.position
        )
        return renderText(overlay, canvasSize: canvasSize, currentTime: currentTime)
    }

    private static func resolvedFont(name: String?, size: CGFloat, weight: UIFont.Weight) -> UIFont {
        if let name, name != "System", let font = UIFont(name: name, size: size) {
            return font
        }
        return UIFont.systemFont(ofSize: size, weight: weight)
    }

    private static func animatedText(_ text: String, animation: TextAnimation, timeRange: CMTimeRange, currentTime: TimeInterval) -> String {
        switch animation {
        case .none, .fade, .slide, .slideUp, .slideDown, .pop, .drift, .bounce, .scaleUp:
            return text
        case .typewriter:
            let start = timeRange.start.seconds
            let duration = max(timeRange.duration.seconds, 0.1)
            let progress = min(max((currentTime - start) / duration, 0), 1)
            let count = max(1, Int(Double(text.count) * progress))
            return String(text.prefix(count))
        }
    }

    private struct AnimationState {
        let opacity: CGFloat
        let scale: CGFloat
        let offset: CGPoint

        func center(for base: CGPoint, canvasSize: CGSize) -> CGPoint {
            CGPoint(
                x: base.x + offset.x / canvasSize.width,
                y: base.y + offset.y / canvasSize.height
            )
        }
    }

    private static func animationState(for animation: TextAnimation, timeRange: CMTimeRange, currentTime: TimeInterval) -> AnimationState {
        let start = timeRange.start.seconds
        let end = start + timeRange.duration.seconds
        let fadeDuration = min(0.3, timeRange.duration.seconds * 0.2)

        switch animation {
        case .none, .typewriter:
            return AnimationState(opacity: 1, scale: 1, offset: .zero)
        case .fade:
            var opacity: CGFloat = 1
            if currentTime < start + fadeDuration {
                opacity = CGFloat((currentTime - start) / fadeDuration)
            } else if currentTime > end - fadeDuration {
                opacity = CGFloat((end - currentTime) / fadeDuration)
            }
            return AnimationState(opacity: max(0, min(1, opacity)), scale: 1, offset: .zero)
        case .slide, .slideUp:
            let introDuration = min(0.35, timeRange.duration.seconds * 0.25)
            let outroDuration = min(0.35, timeRange.duration.seconds * 0.25)
            var offset = CGPoint.zero
            var opacity: CGFloat = 1
            if currentTime < start + introDuration {
                let progress = CGFloat((currentTime - start) / introDuration)
                offset.y = (1 - progress) * 80
                opacity = progress
            } else if currentTime > end - outroDuration {
                let progress = CGFloat((end - currentTime) / outroDuration)
                offset.y = (1 - progress) * -80
                opacity = progress
            }
            return AnimationState(opacity: max(0, min(1, opacity)), scale: 1, offset: offset)
        case .slideDown:
            let introDuration = min(0.35, timeRange.duration.seconds * 0.25)
            let outroDuration = min(0.35, timeRange.duration.seconds * 0.25)
            var offset = CGPoint.zero
            var opacity: CGFloat = 1
            if currentTime < start + introDuration {
                let progress = CGFloat((currentTime - start) / introDuration)
                offset.y = (1 - progress) * -80
                opacity = progress
            } else if currentTime > end - outroDuration {
                let progress = CGFloat((end - currentTime) / outroDuration)
                offset.y = (1 - progress) * 80
                opacity = progress
            }
            return AnimationState(opacity: max(0, min(1, opacity)), scale: 1, offset: offset)
        case .pop, .bounce, .scaleUp:
            let introDuration = min(0.35, timeRange.duration.seconds * 0.25)
            let outroDuration = min(0.25, timeRange.duration.seconds * 0.2)
            var scale: CGFloat = 1
            var opacity: CGFloat = 1
            if currentTime < start + introDuration {
                let progress = CGFloat((currentTime - start) / introDuration)
                let startScale: CGFloat = animation == .bounce ? 0.2 : (animation == .scaleUp ? 0.5 : 0.4)
                scale = startScale + (1 - startScale) * progress
                if animation == .bounce {
                    scale = startScale + (1.15 - startScale) * progress
                    if progress > 0.7 {
                        scale = 1.15 - (progress - 0.7) / 0.3 * 0.15
                    }
                }
                opacity = progress
            } else if currentTime > end - outroDuration {
                let progress = CGFloat((end - currentTime) / outroDuration)
                scale = 0.6 + 0.4 * progress
                opacity = progress
            }
            return AnimationState(opacity: max(0, min(1, opacity)), scale: scale, offset: .zero)
        case .drift:
            let introDuration = min(0.4, timeRange.duration.seconds * 0.3)
            var offset = CGPoint.zero
            var opacity: CGFloat = 1
            if currentTime < start + introDuration {
                let progress = CGFloat((currentTime - start) / introDuration)
                offset.x = (1 - progress) * -40
                opacity = progress
            }
            return AnimationState(opacity: max(0, min(1, opacity)), scale: 1, offset: offset)
        }
    }

    private static func positionedImage(
        _ image: CIImage,
        normalizedCenter: CGPoint,
        canvasSize: CGSize,
        rotation: CGFloat,
        opacity: CGFloat,
        scale: CGFloat = 1
    ) -> CIImage {
        let centerX = normalizedCenter.x * canvasSize.width
        let centerY = (1 - normalizedCenter.y) * canvasSize.height
        let extent = image.extent
        let transform = CGAffineTransform.identity
            .translatedBy(x: -extent.midX, y: -extent.midY)
            .scaledBy(x: scale, y: scale)
            .rotated(by: rotation)
            .translatedBy(x: centerX, y: centerY)
        var result = image.transformed(by: transform)
        if opacity < 1 {
            result = result.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
            ])
        }
        return result
    }
}

private extension UIColor {
    convenience init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        if cleaned.count == 8 {
            guard let value = UInt64(cleaned, radix: 16) else { return nil }
            self.init(
                red: CGFloat((value >> 24) & 0xFF) / 255,
                green: CGFloat((value >> 16) & 0xFF) / 255,
                blue: CGFloat((value >> 8) & 0xFF) / 255,
                alpha: CGFloat(value & 0xFF) / 255
            )
            return
        }
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
