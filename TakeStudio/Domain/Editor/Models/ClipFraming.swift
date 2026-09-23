import CoreGraphics
import Foundation

enum ClipFitMode: String, Equatable, Sendable, CaseIterable, Identifiable {
    case fill
    case fit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: return "Fill"
        case .fit: return "Fit"
        }
    }
}

struct ClipFraming: Equatable, Sendable {
    var zoom: CGFloat
    var offset: CGPoint
    var rotationQuarterTurns: Int
    var fitMode: ClipFitMode

    init(
        zoom: CGFloat = 1.0,
        offset: CGPoint = .zero,
        rotationQuarterTurns: Int = 0,
        fitMode: ClipFitMode = .fill
    ) {
        self.zoom = zoom
        self.offset = offset
        self.rotationQuarterTurns = rotationQuarterTurns
        self.fitMode = fitMode
    }

    static let identity = ClipFraming()

    var isIdentity: Bool {
        abs(zoom - 1.0) < 0.001
            && abs(offset.x) < 0.001
            && abs(offset.y) < 0.001
            && rotationQuarterTurns % 4 == 0
            && fitMode == .fill
    }

    func asTransform(renderSize: CGSize) -> CGAffineTransform {
        guard renderSize.width > 0, renderSize.height > 0 else { return .identity }

        let centerX = renderSize.width / 2
        let centerY = renderSize.height / 2
        let rotation = CGFloat(rotationQuarterTurns % 4) * (.pi / 2)
        let panX = offset.x * renderSize.width
        let panY = -offset.y * renderSize.height

        var transform = CGAffineTransform.identity
            .translatedBy(x: centerX, y: centerY)
            .rotated(by: rotation)
            .scaledBy(x: zoom, y: zoom)
            .translatedBy(x: panX, y: panY)
            .translatedBy(x: -centerX, y: -centerY)

        if fitMode == .fit {
            transform = transform.scaledBy(x: 0.88, y: 0.88)
        }

        return transform
    }
}
