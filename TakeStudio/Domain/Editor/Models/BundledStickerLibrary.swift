import UIKit

enum BundledStickerLibrary {
    enum StickerKind: String, CaseIterable, Identifiable {
        case circle
        case rectangle
        case arrow
        case star
        case heart
        case badge

        var id: String { rawValue }

        var title: String {
            rawValue.capitalized
        }
    }

    static func renderURL(for kind: StickerKind, color: UIColor = .white) -> URL? {
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            context.cgContext.clear(CGRect(origin: .zero, size: size))
            color.setFill()
            color.setStroke()

            switch kind {
            case .circle:
                UIBezierPath(ovalIn: CGRect(x: 28, y: 28, width: 200, height: 200)).fill()
            case .rectangle:
                UIBezierPath(roundedRect: CGRect(x: 36, y: 56, width: 184, height: 144), cornerRadius: 24).fill()
            case .arrow:
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 48, y: 128))
                path.addLine(to: CGPoint(x: 168, y: 128))
                path.addLine(to: CGPoint(x: 140, y: 96))
                path.move(to: CGPoint(x: 168, y: 128))
                path.addLine(to: CGPoint(x: 140, y: 160))
                path.lineWidth = 18
                path.lineCapStyle = .round
                path.stroke()
            case .star:
                drawStar(in: context.cgContext, center: CGPoint(x: 128, y: 128), radius: 96, color: color)
            case .heart:
                drawHeart(in: context.cgContext, center: CGPoint(x: 128, y: 138), size: 180, color: color)
            case .badge:
                let path = UIBezierPath(roundedRect: CGRect(x: 40, y: 72, width: 176, height: 112), cornerRadius: 28)
                path.fill()
                let text = "NEW"
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 42, weight: .heavy),
                    .foregroundColor: UIColor.black
                ]
                let textSize = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(
                    at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                    withAttributes: attributes
                )
            }
        }

        let url = TemporaryCaptureStore.directoryURL
            .appendingPathComponent("sticker-\(kind.rawValue)-\(UUID().uuidString).png")
        guard let data = image.pngData() else { return nil }
        try? data.write(to: url)
        return url
    }

    private static func drawStar(in context: CGContext, center: CGPoint, radius: CGFloat, color: UIColor) {
        let path = UIBezierPath()
        let points = 5
        let innerRadius = radius * 0.45
        for index in 0..<(points * 2) {
            let angle = (CGFloat(index) * .pi / CGFloat(points)) - .pi / 2
            let currentRadius = index.isMultiple(of: 2) ? radius : innerRadius
            let point = CGPoint(
                x: center.x + cos(angle) * currentRadius,
                y: center.y + sin(angle) * currentRadius
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.close()
        color.setFill()
        path.fill()
    }

    private static func drawHeart(in context: CGContext, center: CGPoint, size: CGFloat, color: UIColor) {
        let path = UIBezierPath()
        let width = size
        let height = size
        let top = center.y - height / 2
        path.move(to: CGPoint(x: center.x, y: top + height * 0.32))
        path.addCurve(
            to: CGPoint(x: center.x, y: top + height),
            controlPoint1: CGPoint(x: center.x - width * 0.55, y: top),
            controlPoint2: CGPoint(x: center.x - width * 0.55, y: top + height * 0.72)
        )
        path.addCurve(
            to: CGPoint(x: center.x, y: top + height * 0.32),
            controlPoint1: CGPoint(x: center.x + width * 0.55, y: top + height * 0.72),
            controlPoint2: CGPoint(x: center.x + width * 0.55, y: top)
        )
        path.close()
        color.setFill()
        path.fill()
    }
}
