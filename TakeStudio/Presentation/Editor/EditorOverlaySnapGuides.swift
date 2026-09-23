import CoreGraphics
import SwiftUI
import UIKit

struct OverlayAlignmentGuides: OptionSet, Equatable {
    let rawValue: Int

    static let verticalCenter = OverlayAlignmentGuides(rawValue: 1 << 0)
    static let horizontalCenter = OverlayAlignmentGuides(rawValue: 1 << 1)
}

struct OverlaySnapResult {
    var point: CGPoint
    var guides: OverlayAlignmentGuides
    var snappedX: Bool
    var snappedY: Bool
}

enum OverlaySnapEngine {
    private static let center: CGFloat = 0.5
    private static let snapThreshold: CGFloat = 0.028
    private static let guideThreshold: CGFloat = 0.07

    static func process(_ point: CGPoint) -> OverlaySnapResult {
        var result = point
        var guides: OverlayAlignmentGuides = []
        var snappedX = false
        var snappedY = false

        let deltaX = abs(point.x - center)
        let deltaY = abs(point.y - center)

        if deltaX < guideThreshold {
            guides.insert(.verticalCenter)
        }
        if deltaY < guideThreshold {
            guides.insert(.horizontalCenter)
        }

        if deltaX < snapThreshold {
            result.x = center
            guides.insert(.verticalCenter)
            snappedX = true
        }
        if deltaY < snapThreshold {
            result.y = center
            guides.insert(.horizontalCenter)
            snappedY = true
        }

        result.x = max(0.05, min(0.95, result.x))
        result.y = max(0.05, min(0.95, result.y))

        return OverlaySnapResult(point: result, guides: guides, snappedX: snappedX, snappedY: snappedY)
    }
}

struct EditorOverlayAlignmentGuidesOverlay: View {
    let guides: OverlayAlignmentGuides
    let canvasSize: CGSize

    var body: some View {
        ZStack {
            if guides.contains(.verticalCenter) {
                guideLine(isVertical: true)
            }
            if guides.contains(.horizontalCenter) {
                guideLine(isVertical: false)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    @ViewBuilder
    private func guideLine(isVertical: Bool) -> some View {
        let length = isVertical ? canvasSize.height : canvasSize.width
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

        Capsule(style: .continuous)
            .fill(Color.white.opacity(0.92))
            .frame(width: isVertical ? 1.5 : length, height: isVertical ? length : 1.5)
            .shadow(color: .black.opacity(0.45), radius: 1, x: 0, y: 0)
            .position(center)
    }
}

enum OverlaySnapHaptics {
    private static let generator = UIImpactFeedbackGenerator(style: .light)

    static func snapOccurred() {
        generator.prepare()
        generator.impactOccurred(intensity: 0.75)
    }
}
