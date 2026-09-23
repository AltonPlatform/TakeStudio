import UIKit

protocol TextComposerCanvasDelegate: AnyObject {
    func canvasDidTapEmpty(_ canvas: TextComposerCanvasView)
    func canvas(_ canvas: TextComposerCanvasView, didSelectLayer id: UUID)
    func canvas(_ canvas: TextComposerCanvasView, didRequestEditLayer id: UUID)
    func canvas(_ canvas: TextComposerCanvasView, didUpdateTransform id: UUID, center: CGPoint, scale: CGFloat, rotation: CGFloat)
    func canvas(_ canvas: TextComposerCanvasView, didCommitTransform id: UUID)
    func canvas(_ canvas: TextComposerCanvasView, didDuplicateLayer id: UUID)
    func canvas(_ canvas: TextComposerCanvasView, didDeleteLayer id: UUID)
    func canvas(_ canvas: TextComposerCanvasView, didRequestAnimationFor id: UUID)
    func canvas(_ canvas: TextComposerCanvasView, didRequestTimingFor id: UUID)
    func canvasGesturesEnabled(_ canvas: TextComposerCanvasView) -> Bool
}

/// Canvas hosting inactive `UILabel` layers + selection handles. Shared `UITextView` lives in the VC.
final class TextComposerCanvasView: UIView, UIGestureRecognizerDelegate {
    weak var delegate: TextComposerCanvasDelegate?

    private let snapshotView = UIImageView()
    private let layersHost = UIView()
    private var layerViews: [UUID: TextLayerView] = [:]
    private var selectionOverlay = TextSelectionHandlesView()
    private var guideVertical = UIView()
    private var guideHorizontal = UIView()
    private var didSnapHapticX = false
    private var didSnapHapticY = false
    private var didSnapScaleHaptic = false

    var snapshotImage: UIImage? {
        get { snapshotView.image }
        set { snapshotView.image = newValue }
    }

    var canvasBounds: CGRect { snapshotView.bounds }

    var overlayHost: UIView { layersHost }

    func installEditingView(_ editingView: UIView) {
        if editingView.superview !== layersHost {
            layersHost.addSubview(editingView)
        }
        layersHost.bringSubviewToFront(editingView)
    }

    func positionEditingView(_ editingView: UIView, normalizedCenter: CGPoint, size: CGSize) {
        let host = layersHost.bounds.size
        guard host.width > 2, host.height > 2 else { return }
        editingView.bounds = CGRect(origin: .zero, size: size)
        editingView.center = CGPoint(
            x: normalizedCenter.x * host.width,
            y: (1 - normalizedCenter.y) * host.height
        )
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        backgroundColor = .black

        snapshotView.contentMode = .scaleAspectFill
        snapshotView.clipsToBounds = true
        snapshotView.backgroundColor = .black
        snapshotView.isUserInteractionEnabled = false
        snapshotView.translatesAutoresizingMaskIntoConstraints = false

        layersHost.translatesAutoresizingMaskIntoConstraints = false
        layersHost.clipsToBounds = true

        selectionOverlay.isUserInteractionEnabled = false
        selectionOverlay.isHidden = true

        guideVertical.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.85)
        guideHorizontal.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.85)
        guideVertical.isHidden = true
        guideHorizontal.isHidden = true
        guideVertical.translatesAutoresizingMaskIntoConstraints = false
        guideHorizontal.translatesAutoresizingMaskIntoConstraints = false

        addSubview(snapshotView)
        addSubview(layersHost)
        layersHost.addSubview(selectionOverlay)
        layersHost.addSubview(guideVertical)
        layersHost.addSubview(guideHorizontal)

        let snapshotWidth = snapshotView.widthAnchor.constraint(equalTo: widthAnchor)
        snapshotWidth.priority = .defaultLow

        NSLayoutConstraint.activate([
            snapshotView.centerXAnchor.constraint(equalTo: centerXAnchor),
            snapshotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            snapshotView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            snapshotView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor),
            snapshotView.widthAnchor.constraint(equalTo: snapshotView.heightAnchor, multiplier: 9.0 / 16.0),
            snapshotWidth,

            layersHost.leadingAnchor.constraint(equalTo: snapshotView.leadingAnchor),
            layersHost.trailingAnchor.constraint(equalTo: snapshotView.trailingAnchor),
            layersHost.topAnchor.constraint(equalTo: snapshotView.topAnchor),
            layersHost.bottomAnchor.constraint(equalTo: snapshotView.bottomAnchor),

            guideVertical.centerXAnchor.constraint(equalTo: layersHost.centerXAnchor),
            guideVertical.topAnchor.constraint(equalTo: layersHost.topAnchor),
            guideVertical.bottomAnchor.constraint(equalTo: layersHost.bottomAnchor),
            guideVertical.widthAnchor.constraint(equalToConstant: 1),

            guideHorizontal.centerYAnchor.constraint(equalTo: layersHost.centerYAnchor),
            guideHorizontal.leadingAnchor.constraint(equalTo: layersHost.leadingAnchor),
            guideHorizontal.trailingAnchor.constraint(equalTo: layersHost.trailingAnchor),
            guideHorizontal.heightAnchor.constraint(equalToConstant: 1)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleCanvasTap(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    func syncLayers(
        _ overlays: [TextOverlay],
        selectedID: UUID?,
        editingID: UUID?,
        gesturesEnabled: Bool
    ) {
        let ids = Set(overlays.map(\.id))
        for (id, view) in layerViews where !ids.contains(id) {
            view.removeFromSuperview()
            layerViews.removeValue(forKey: id)
        }

        let size = layersHost.bounds.size
        guard size.width > 2, size.height > 2 else { return }

        for overlay in overlays {
            let layerView: TextLayerView
            if let existing = layerViews[overlay.id] {
                layerView = existing
            } else {
                layerView = TextLayerView(overlayID: overlay.id)
                layerView.delegate = self
                layersHost.insertSubview(layerView, belowSubview: selectionOverlay)
                layerViews[overlay.id] = layerView
            }
            let isEditing = overlay.id == editingID
            layerView.isHidden = isEditing
            layerView.gesturesEnabled = gesturesEnabled && !isEditing
            layerView.apply(overlay: overlay, canvasSize: size)
        }

        if let selectedID, let selected = layerViews[selectedID], editingID != selectedID, gesturesEnabled {
            selectionOverlay.isHidden = false
            selectionOverlay.update(around: selected)
            layersHost.bringSubviewToFront(selectionOverlay)
        } else {
            selectionOverlay.isHidden = true
        }

        layersHost.bringSubviewToFront(guideVertical)
        layersHost.bringSubviewToFront(guideHorizontal)
        for subview in layersHost.subviews where subview is UITextView {
            layersHost.bringSubviewToFront(subview)
        }
    }

    func layerView(for id: UUID) -> TextLayerView? {
        layerViews[id]
    }

    func pointInCanvas(forNormalized center: CGPoint) -> CGPoint {
        let size = layersHost.bounds.size
        return CGPoint(x: center.x * size.width, y: (1 - center.y) * size.height)
    }

    func normalizedCenter(from point: CGPoint) -> CGPoint {
        let size = layersHost.bounds.size
        guard size.width > 1, size.height > 1 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: min(max(point.x / size.width, 0.05), 0.95),
            y: min(max(1 - point.y / size.height, 0.05), 0.95)
        )
    }

    @objc private func handleCanvasTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: layersHost)
        for (_, layerView) in layerViews where !layerView.isHidden {
            if layerView.frame.contains(location) { return }
        }
        delegate?.canvasDidTapEmpty(self)
    }

    func showGuides(_ guides: OverlayAlignmentGuides) {
        guideVertical.isHidden = !guides.contains(.verticalCenter)
        guideHorizontal.isHidden = !guides.contains(.horizontalCenter)
    }

    func clearGuides() {
        guideVertical.isHidden = true
        guideHorizontal.isHidden = true
        didSnapHapticX = false
        didSnapHapticY = false
    }
}

extension TextComposerCanvasView: TextLayerViewDelegate {
    func textLayerDidTap(_ view: TextLayerView) {
        if delegate?.canvasGesturesEnabled(self) == true {
            delegate?.canvas(self, didSelectLayer: view.overlayID)
        } else {
            delegate?.canvas(self, didRequestEditLayer: view.overlayID)
        }
    }

    func textLayerDidDoubleTap(_ view: TextLayerView) {
        delegate?.canvas(self, didRequestEditLayer: view.overlayID)
    }

    func textLayer(_ view: TextLayerView, didPanToNormalizedCenter center: CGPoint) {
        let snap = OverlaySnapEngine.process(center)
        showGuides(snap.guides)
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
        let size = layersHost.bounds.size
        view.center = CGPoint(x: snap.point.x * size.width, y: (1 - snap.point.y) * size.height)
        selectionOverlay.update(around: view)
        delegate?.canvas(
            self,
            didUpdateTransform: view.overlayID,
            center: snap.point,
            scale: view.currentScale,
            rotation: view.currentRotation
        )
    }

    func textLayerDidEndPan(_ view: TextLayerView) {
        clearGuides()
        delegate?.canvas(self, didCommitTransform: view.overlayID)
    }

    func textLayer(_ view: TextLayerView, didScale scale: CGFloat, rotation: CGFloat) {
        if abs(scale - 1) < 0.03, !didSnapScaleHaptic {
            OverlaySnapHaptics.snapOccurred()
            didSnapScaleHaptic = true
        } else if abs(scale - 1) >= 0.03 {
            didSnapScaleHaptic = false
        }
        selectionOverlay.update(around: view)
        delegate?.canvas(
            self,
            didUpdateTransform: view.overlayID,
            center: normalizedCenter(from: view.center),
            scale: scale,
            rotation: rotation
        )
    }

    func textLayerDidEndTransform(_ view: TextLayerView) {
        didSnapScaleHaptic = false
        delegate?.canvas(self, didCommitTransform: view.overlayID)
    }

    func textLayerDidLongPress(_ view: TextLayerView) {
        delegate?.canvas(self, didSelectLayer: view.overlayID)
        presentContextMenu(for: view)
    }

    private func presentContextMenu(for view: TextLayerView) {
        guard let root = window?.rootViewController ?? findViewController() else { return }
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Duplicate", style: .default) { [weak self] _ in
            guard let self else { return }
            self.delegate?.canvas(self, didDuplicateLayer: view.overlayID)
        })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.delegate?.canvas(self, didDeleteLayer: view.overlayID)
        })
        alert.addAction(UIAlertAction(title: "Animation", style: .default) { [weak self] _ in
            guard let self else { return }
            self.delegate?.canvas(self, didRequestAnimationFor: view.overlayID)
        })
        alert.addAction(UIAlertAction(title: "Timing", style: .default) { [weak self] _ in
            guard let self else { return }
            self.delegate?.canvas(self, didRequestTimingFor: view.overlayID)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = view.bounds
        }
        root.present(alert, animated: true)
    }

    private func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }
}

protocol TextLayerViewDelegate: AnyObject {
    func textLayerDidTap(_ view: TextLayerView)
    func textLayerDidDoubleTap(_ view: TextLayerView)
    func textLayer(_ view: TextLayerView, didPanToNormalizedCenter center: CGPoint)
    func textLayerDidEndPan(_ view: TextLayerView)
    func textLayer(_ view: TextLayerView, didScale scale: CGFloat, rotation: CGFloat)
    func textLayerDidEndTransform(_ view: TextLayerView)
    func textLayerDidLongPress(_ view: TextLayerView)
}

final class TextLayerView: UIView, UIGestureRecognizerDelegate {
    let overlayID: UUID
    weak var delegate: TextLayerViewDelegate?

    private let label = UILabel()
    private(set) var currentScale: CGFloat = 1
    private(set) var currentRotation: CGFloat = 0
    private var panStartCenter: CGPoint = .zero
    private var pinchStartScale: CGFloat = 1
    private var rotationStart: CGFloat = 0
    private var panGesture: UIPanGestureRecognizer!
    private var pinchGesture: UIPinchGestureRecognizer!
    private var rotateGesture: UIRotationGestureRecognizer!
    private var longPressGesture: UILongPressGestureRecognizer!

    var gesturesEnabled: Bool = true {
        didSet {
            panGesture.isEnabled = gesturesEnabled
            pinchGesture.isEnabled = gesturesEnabled
            rotateGesture.isEnabled = gesturesEnabled
            longPressGesture.isEnabled = gesturesEnabled
        }
    }

    init(overlayID: UUID) {
        self.overlayID = overlayID
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        label.numberOfLines = 0
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        addSubview(label)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
        addGestureRecognizer(doubleTap)

        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        addGestureRecognizer(panGesture)

        pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        addGestureRecognizer(pinchGesture)

        rotateGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        rotateGesture.delegate = self
        addGestureRecognizer(rotateGesture)

        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.45
        addGestureRecognizer(longPressGesture)
    }

    func apply(overlay: TextOverlay, canvasSize: CGSize) {
        // Frame-based. Avoid rewriting bounds/transform unless the overlay actually changed.
        let nextCenter = CGPoint(
            x: overlay.normalizedCenter.x * canvasSize.width,
            y: (1 - overlay.normalizedCenter.y) * canvasSize.height
        )
        let alreadyApplied =
            currentScale == overlay.scale
            && currentRotation == overlay.rotation
            && label.text == (overlay.text.isEmpty ? "Tap to type" : overlay.text)
            && abs(center.x - nextCenter.x) < 0.5
            && abs(center.y - nextCenter.y) < 0.5
        if alreadyApplied { return }

        currentScale = overlay.scale
        currentRotation = overlay.rotation
        let fontSize = overlay.style.fontSize * overlay.scale
        let font = OverlayRenderer.cachedFont(
            name: overlay.style.fontName,
            size: fontSize,
            weight: overlay.style.fontWeight
        )
        let color = (UIColor(hex: overlay.style.colorHex) ?? .white)
            .withAlphaComponent(overlay.opacity * overlay.style.opacity)
        let display = overlay.text.isEmpty ? "Tap to type" : overlay.text
        label.text = display
        label.font = font
        label.textColor = overlay.text.isEmpty ? color.withAlphaComponent(0.35) : color
        label.textAlignment = overlay.style.alignment
        label.layer.shadowOpacity = overlay.style.hasShadow ? 0.55 : 0
        label.layer.shadowRadius = overlay.style.shadowRadius
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        label.layer.shadowColor = (UIColor(hex: overlay.style.shadowColorHex) ?? .black).cgColor

        if overlay.style.hasBackground {
            backgroundColor = UIColor(hex: overlay.style.backgroundColorHex) ?? UIColor.black.withAlphaComponent(0.5)
            layer.cornerRadius = 6
            layoutMargins = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        } else {
            backgroundColor = .clear
            layer.cornerRadius = 0
            layoutMargins = .zero
        }

        let maxWidth = max(canvasSize.width - 24, 80)
        let fitted = label.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let padX = layoutMargins.left + layoutMargins.right
        let padY = layoutMargins.top + layoutMargins.bottom
        bounds = CGRect(x: 0, y: 0, width: fitted.width + padX, height: max(fitted.height + padY, 36))
        label.frame = bounds.inset(by: layoutMargins)

        center = CGPoint(
            x: overlay.normalizedCenter.x * canvasSize.width,
            y: (1 - overlay.normalizedCenter.y) * canvasSize.height
        )
        transform = CGAffineTransform(rotationAngle: overlay.rotation)
    }

    @objc private func handleTap() {
        delegate?.textLayerDidTap(self)
    }

    @objc private func handleDoubleTap() {
        delegate?.textLayerDidDoubleTap(self)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let canvas = superview else { return }
        switch gesture.state {
        case .began:
            panStartCenter = center
            delegate?.textLayerDidTap(self)
        case .changed:
            let translation = gesture.translation(in: canvas)
            let point = CGPoint(x: panStartCenter.x + translation.x, y: panStartCenter.y + translation.y)
            let normalized = CGPoint(
                x: point.x / max(canvas.bounds.width, 1),
                y: 1 - point.y / max(canvas.bounds.height, 1)
            )
            delegate?.textLayer(self, didPanToNormalizedCenter: normalized)
        case .ended, .cancelled:
            delegate?.textLayerDidEndPan(self)
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartScale = currentScale
            delegate?.textLayerDidTap(self)
        case .changed:
            currentScale = max(0.3, min(pinchStartScale * gesture.scale, 3))
            applyLiveTransform()
            delegate?.textLayer(self, didScale: currentScale, rotation: currentRotation)
        case .ended, .cancelled:
            delegate?.textLayerDidEndTransform(self)
        default:
            break
        }
    }

    @objc private func handleRotate(_ gesture: UIRotationGestureRecognizer) {
        switch gesture.state {
        case .began:
            rotationStart = currentRotation
            delegate?.textLayerDidTap(self)
        case .changed:
            currentRotation = rotationStart + gesture.rotation
            applyLiveTransform()
            delegate?.textLayer(self, didScale: currentScale, rotation: currentRotation)
        case .ended, .cancelled:
            delegate?.textLayerDidEndTransform(self)
        default:
            break
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        OverlaySnapHaptics.snapOccurred()
        delegate?.textLayerDidLongPress(self)
    }

    private func applyLiveTransform() {
        // Scale is baked into font size via model; rotation applied via transform.
        transform = CGAffineTransform(rotationAngle: currentRotation)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer === pinchGesture && otherGestureRecognizer === rotateGesture)
            || (gestureRecognizer === rotateGesture && otherGestureRecognizer === pinchGesture)
    }
}

final class TextSelectionHandlesView: UIView {
    private let border = CAShapeLayer()
    private let handles: [CALayer] = (0..<8).map { _ in
        let layer = CALayer()
        layer.backgroundColor = UIColor.systemBlue.cgColor
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 4
        layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        return layer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        border.fillColor = UIColor.clear.cgColor
        border.strokeColor = UIColor.systemBlue.cgColor
        border.lineWidth = 1.5
        layer.addSublayer(border)
        handles.forEach { layer.addSublayer($0) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(around target: UIView) {
        guard let host = superview else { return }
        let frame = target.convert(target.bounds, to: host).insetBy(dx: -6, dy: -6)
        self.frame = host.bounds
        let path = UIBezierPath(roundedRect: frame, cornerRadius: 4)
        border.path = path.cgPath

        let points: [CGPoint] = [
            CGPoint(x: frame.minX, y: frame.minY),
            CGPoint(x: frame.midX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.minY),
            CGPoint(x: frame.maxX, y: frame.midY),
            CGPoint(x: frame.maxX, y: frame.maxY),
            CGPoint(x: frame.midX, y: frame.maxY),
            CGPoint(x: frame.minX, y: frame.maxY),
            CGPoint(x: frame.minX, y: frame.midY)
        ]
        for (index, handle) in handles.enumerated() {
            handle.position = points[index]
        }
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
