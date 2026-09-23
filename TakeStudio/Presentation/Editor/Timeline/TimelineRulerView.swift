import UIKit

/// Ruler markers use fixed-size CALayers; positions follow `pixelsPerSecond` during live pinch preview.
final class TimelineRulerView: UIView {
    var totalDuration: TimeInterval = 0
    var pixelsPerSecond: CGFloat = 60
    var rulerInterval: TimeInterval = 5
    var rulerSubInterval: TimeInterval = 1

    private let markersContentLayer = CALayer()
    private let trimMaskLayer = CAShapeLayer()
    private var minorLayers: [CALayer] = []
    private var majorLayers: [CALayer] = []
    private var labelLayers: [CATextLayer] = []
    private var isTrimPreviewActive = false
    private var markersBuiltSignature: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false

        markersContentLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        markersContentLayer.masksToBounds = false
        markersContentLayer.actions = [
            "transform": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        layer.addSublayer(markersContentLayer)

        trimMaskLayer.fillColor = UIColor.white.cgColor
        trimMaskLayer.actions = [
            "path": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTrimPreviewActive(_ active: Bool) {
        if !active {
            isTrimPreviewActive = false
            layer.mask = nil
            markersContentLayer.position = CGPoint(x: 0, y: bounds.height * 0.5)
            markersContentLayer.transform = CATransform3DIdentity
        } else {
            isTrimPreviewActive = true
        }
    }

    func update(
        totalDuration: TimeInterval,
        pixelsPerSecond: CGFloat,
        rulerInterval: TimeInterval,
        rulerSubInterval: TimeInterval,
        width: CGFloat
    ) {
        self.totalDuration = totalDuration
        self.pixelsPerSecond = pixelsPerSecond
        self.rulerInterval = rulerInterval
        self.rulerSubInterval = rulerSubInterval

        if isTrimPreviewActive {
            ensureMarkersBuilt()
            applyTrimVisibleWidth(width)
            return
        }

        frame.size.width = width
        ensureMarkersBuilt()
    }

    /// During trim drag: only clip the already-built markers — no layer recreation.
    func applyTrimVisibleWidth(_ visibleWidth: CGFloat) {
        guard isTrimPreviewActive else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        frame.size.width = visibleWidth
        markersContentLayer.position = CGPoint(x: 0, y: bounds.height * 0.5)

        let maskRect = CGRect(x: 0, y: 0, width: visibleWidth, height: bounds.height)
        trimMaskLayer.path = UIBezierPath(rect: maskRect).cgPath
        trimMaskLayer.frame = maskRect
        layer.mask = trimMaskLayer

        CATransaction.commit()
    }

    private func ensureMarkersBuilt() {
        let signature = markersSignature
        guard markersBuiltSignature != signature else { return }
        rebuildMarkers()
        markersBuiltSignature = signature
    }

    private var markersSignature: String {
        let durationMs = Int((totalDuration * 1000).rounded())
        let ppsBucket = Int((pixelsPerSecond * 4).rounded())
        let intervalMs = Int((rulerInterval * 1000).rounded())
        let subMs = Int((rulerSubInterval * 1000).rounded())
        return "\(durationMs)#\(ppsBucket)#\(intervalMs)#\(subMs)"
    }

    private func rebuildMarkers() {
        minorLayers.forEach { $0.removeFromSuperlayer() }
        majorLayers.forEach { $0.removeFromSuperlayer() }
        labelLayers.forEach { $0.removeFromSuperlayer() }
        minorLayers.removeAll()
        majorLayers.removeAll()
        labelLayers.removeAll()

        let contentWidth = max(CGFloat(totalDuration) * pixelsPerSecond, 1)
        markersContentLayer.bounds = CGRect(x: 0, y: 0, width: contentWidth, height: bounds.height)
        markersContentLayer.position = CGPoint(x: 0, y: bounds.height * 0.5)

        guard totalDuration > 0 else {
            markersBuiltSignature = nil
            return
        }

        let secondary = UIColor.white.withAlphaComponent(0.45).cgColor
        let majorColor = UIColor.white.withAlphaComponent(0.75).cgColor

        let subTickCount = Int(floor(totalDuration / rulerSubInterval))
        for index in 0..<subTickCount {
            let time = Double(index) * rulerSubInterval
            let isMajor = abs(time.truncatingRemainder(dividingBy: rulerInterval)) < 0.001
                || abs(time.truncatingRemainder(dividingBy: rulerInterval) - rulerInterval) < 0.001
            if isMajor { continue }

            let layer = CALayer()
            layer.backgroundColor = secondary
            layer.cornerRadius = 1
            layer.frame = CGRect(x: CGFloat(time) * pixelsPerSecond, y: 2, width: 2, height: 2)
            layer.contentsScale = UIScreen.main.scale
            markersContentLayer.addSublayer(layer)
            minorLayers.append(layer)
        }

        let tickCount = Int(ceil(totalDuration / rulerInterval)) + 1
        for index in 0..<tickCount {
            let time = Double(index) * rulerInterval
            let x = CGFloat(time) * pixelsPerSecond

            let dot = CALayer()
            dot.backgroundColor = majorColor
            dot.cornerRadius = 1.5
            dot.frame = CGRect(x: x, y: 0, width: 3, height: 3)
            dot.contentsScale = UIScreen.main.scale
            markersContentLayer.addSublayer(dot)
            majorLayers.append(dot)

            let label = CATextLayer()
            label.string = "\(Int(time))s"
            label.font = UIFont.systemFont(ofSize: 9, weight: .medium)
            label.fontSize = 9
            label.foregroundColor = UIColor.white.withAlphaComponent(0.85).cgColor
            label.alignmentMode = .left
            label.contentsScale = UIScreen.main.scale
            label.frame = CGRect(x: x + 6, y: 6, width: 40, height: 12)
            markersContentLayer.addSublayer(label)
            labelLayers.append(label)
        }

        markersBuiltSignature = markersSignature
    }
}
