import AVFoundation
import UIKit

protocol TimelineClipCellDelegate: AnyObject {
    func clipCellDidSelect(_ clipID: UUID)
    func clipCellDidBeginTrim(_ clipID: UUID)
    func clipCellDidEndTrim(_ clipID: UUID)
    func clipCellDidTrimPreview(_ clipID: UUID, timeRange: CMTimeRange)
    func clipCellDidTrimCommit(_ clipID: UUID, timeRange: CMTimeRange)
    func clipCellDidTrimCancel(_ clipID: UUID)
    func clipCellDidToggleMute(_ clipID: UUID)
    func clipCellDidTapTransition(_ clipID: UUID)
}

final class TimelineClipCell: UIView, UIGestureRecognizerDelegate {
    weak var delegate: TimelineClipCellDelegate?

    private let filmstripLayer = CALayer()
    private let filmstripContentLayer = CALayer()
    private let bakedStripDisplayLayer = CALayer()
    private let waveformClipLayer = CALayer()
    private let waveformContentLayer = CALayer()
    private let waveformLayer = TimelineWaveformLayer()
    private let borderLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let startTrimHandle = TimelineTrimHandleView(edge: .start)
    private let endTrimHandle = TimelineTrimHandleView(edge: .end)
    private let trimRecoverableTailLayer = CALayer()
    private let muteButton = UIButton(type: .system)
    private let audioRowContainer = UIView()

    private var clipID: UUID?
    private var clip: VideoClip?
    private var pixelsPerSecond: CGFloat = 60
    private var previewTimeRange: CMTimeRange?
    private var filmstripSlots: [Int: FilmstripSlotState] = [:]
    private var filmstripSession: UInt64 = 0
    private var prefetchClipXRange: ClosedRange<CGFloat>?
    private var priorityClipXRange: ClosedRange<CGFloat>?
    private var lastPixelsPerSecond: CGFloat = 0
    private var filmstripSlotSize: CGFloat = 44
    private var isUsingBakedStrip = false
    private var bakedStripKey: NSString?
    private var bakedStripLayoutWidth: CGFloat = 0
    private var isPinchLayoutPreview = false
    private var fullWaveformSamples: [Float] = []
    private var lastWaveformSamples: [Float] = []
    private var fullClipFillGeneration: UInt64 = 0
    private var inFlightSlotIndices = Set<Int>()
    private var lastConfiguredWidth: CGFloat = 0
    private var lastConfiguredSlotSize: CGFloat = 0
    private var lastConfiguredTimeRange: CMTimeRange?

    private var startTrimPan: UIPanGestureRecognizer?
    private var endTrimPan: UIPanGestureRecognizer?
    private var startEdgeTrimPan: UIPanGestureRecognizer?
    private var endEdgeTrimPan: UIPanGestureRecognizer?
    private weak var wiredScrollView: UIScrollView?
    private var trimAnchorRange: CMTimeRange?
    private var isTrimming = false
    private var suppressFilmstripConfigurePasses = 0
    /// Blocks a brief full-width clip snapshot from expanding the cell during rebuild/layout.
    private var filmstripWidthCeiling: CGFloat?
    /// Full filmstrip width captured at trim start — slots stay loaded at this width during drag.
    private var trimFilmstripBaseWidth: CGFloat?
    private let filmstripTrimMaskLayer = CAShapeLayer()
    private let waveformTrimMaskLayer = CAShapeLayer()

    private static let muteButtonWidth: CGFloat = 24
    private static let audioRowHeight: CGFloat = 28

    var shouldPreserveLayoutFrame: Bool { isTrimming }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        cancelAllExtractions()
    }

    private func setup() {
        clipsToBounds = true
        layer.cornerRadius = 4

        filmstripLayer.masksToBounds = true
        filmstripLayer.cornerRadius = 4
        filmstripTrimMaskLayer.fillColor = UIColor.white.cgColor
        filmstripTrimMaskLayer.actions = [
            "path": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        filmstripContentLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        filmstripContentLayer.masksToBounds = false
        filmstripContentLayer.actions = [
            "transform": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "sublayerTransform": NSNull()
        ]
        filmstripLayer.addSublayer(filmstripContentLayer)
        bakedStripDisplayLayer.masksToBounds = true
        bakedStripDisplayLayer.contentsGravity = .resizeAspectFill
        bakedStripDisplayLayer.contentsScale = UIScreen.main.scale
        bakedStripDisplayLayer.isHidden = true
        bakedStripDisplayLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull()
        ]
        layer.addSublayer(filmstripLayer)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.strokeColor = UIColor.white.withAlphaComponent(0.15).cgColor
        borderLayer.lineWidth = 1
        layer.addSublayer(borderLayer)

        selectionLayer.fillColor = UIColor.clear.cgColor
        selectionLayer.strokeColor = UIColor.systemYellow.cgColor
        selectionLayer.lineWidth = 2
        selectionLayer.isHidden = true
        layer.addSublayer(selectionLayer)

        audioRowContainer.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        audioRowContainer.isHidden = true
        addSubview(audioRowContainer)

        waveformClipLayer.masksToBounds = true
        waveformClipLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull()
        ]
        waveformContentLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        waveformContentLayer.masksToBounds = false
        waveformContentLayer.actions = [
            "transform": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        waveformTrimMaskLayer.fillColor = UIColor.white.cgColor
        waveformTrimMaskLayer.actions = [
            "path": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        waveformLayer.waveformColor = .systemTeal
        waveformLayer.waveformOpacity = 0.85
        waveformContentLayer.addSublayer(waveformLayer)
        waveformClipLayer.addSublayer(waveformContentLayer)
        audioRowContainer.layer.addSublayer(waveformClipLayer)

        muteButton.tintColor = .systemTeal
        muteButton.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)
        audioRowContainer.addSubview(muteButton)

        startTrimHandle.isHidden = true
        addSubview(startTrimHandle)

        endTrimHandle.isHidden = true
        addSubview(endTrimHandle)

        trimRecoverableTailLayer.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.18).cgColor
        trimRecoverableTailLayer.isHidden = true
        layer.insertSublayer(trimRecoverableTailLayer, above: filmstripLayer)

        let tap = UITapGestureRecognizer(target: self, action: #selector(cellTapped))
        addGestureRecognizer(tap)

        let startPan = UIPanGestureRecognizer(target: self, action: #selector(handleStartTrim(_:)))
        startPan.delegate = self
        startPan.maximumNumberOfTouches = 1
        startTrimHandle.addGestureRecognizer(startPan)
        startTrimPan = startPan

        let endPan = UIPanGestureRecognizer(target: self, action: #selector(handleEndTrim(_:)))
        endPan.delegate = self
        endPan.maximumNumberOfTouches = 1
        endTrimHandle.addGestureRecognizer(endPan)
        endTrimPan = endPan

        let startEdgePan = UIPanGestureRecognizer(target: self, action: #selector(handleStartTrim(_:)))
        startEdgePan.delegate = self
        startEdgePan.maximumNumberOfTouches = 1
        addGestureRecognizer(startEdgePan)
        startEdgeTrimPan = startEdgePan

        let endEdgePan = UIPanGestureRecognizer(target: self, action: #selector(handleEndTrim(_:)))
        endEdgePan.delegate = self
        endEdgePan.maximumNumberOfTouches = 1
        addGestureRecognizer(endEdgePan)
        endEdgeTrimPan = endEdgePan
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        wireTrimGesturesToScrollViewIfNeeded()
    }

    func containsTrimHandle(at pointInTracksContainer: CGPoint) -> Bool {
        guard let superview else { return false }
        let local = convert(pointInTracksContainer, from: superview)
        guard bounds.contains(local) else { return false }

        let hitWidth = TimelineTrimHandleView.hitWidth

        if !startTrimHandle.isHidden, startTrimHandle.frame.contains(local) {
            return true
        }
        if !endTrimHandle.isHidden, endTrimHandle.frame.contains(local) {
            return true
        }
        if local.x <= hitWidth || local.x >= bounds.width - hitWidth {
            return true
        }
        return false
    }

    private func wireTrimGesturesToScrollViewIfNeeded() {
        guard let scrollView = findEnclosingScrollView(), scrollView !== wiredScrollView else { return }
        wiredScrollView = scrollView
        let trimPans = [startTrimPan, endTrimPan, startEdgeTrimPan, endEdgeTrimPan].compactMap { $0 }
        for pan in trimPans {
            scrollView.panGestureRecognizer.require(toFail: pan)
        }
    }

    private func findEnclosingScrollView() -> UIScrollView? {
        var view: UIView? = superview
        while let current = view {
            if let scroll = current as? UIScrollView { return scroll }
            view = current.superview
        }
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        filmstripLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: filmstripSlotSize)

        let contentWidth = filmstripContentWidth
        filmstripContentLayer.bounds = CGRect(x: 0, y: 0, width: contentWidth, height: filmstripSlotSize)
        filmstripContentLayer.position = CGPoint(x: 0, y: filmstripSlotSize * 0.5)

        if isPinchLayoutPreview, contentWidth > 0 {
            let scaleX = bounds.width / contentWidth
            filmstripContentLayer.transform = CATransform3DMakeScale(scaleX, 1, 1)
        } else {
            filmstripContentLayer.transform = CATransform3DIdentity
        }

        if isTrimming, trimFilmstripBaseWidth != nil {
            let trimOffset = trimStartOffset(for: self.clip)
            applyTrimFilmstripMask(visibleWidth: bounds.width, trimStartOffset: trimOffset)
        } else if isUsingBakedStrip {
            bakedStripDisplayLayer.frame = CGRect(
                x: 0,
                y: 0,
                width: bakedStripLayoutWidth,
                height: filmstripSlotSize
            )
        } else {
            relayoutSlotFrames()
        }
        let borderInset = borderLayer.lineWidth * 0.5
        let borderRect = bounds.insetBy(dx: borderInset, dy: borderInset)
        borderLayer.path = UIBezierPath(roundedRect: borderRect, cornerRadius: 4).cgPath

        let selectionInset = selectionLayer.lineWidth * 0.5
        let selectionRect = bounds.insetBy(dx: selectionInset, dy: selectionInset)
        selectionLayer.path = UIBezierPath(roundedRect: selectionRect, cornerRadius: 4).cgPath

        if !audioRowContainer.isHidden {
            audioRowContainer.frame = CGRect(
                x: 0,
                y: filmstripSlotSize,
                width: bounds.width,
                height: Self.audioRowHeight
            )
            muteButton.frame = CGRect(x: 0, y: 0, width: Self.muteButtonWidth, height: Self.audioRowHeight)
            if isTrimming, trimFilmstripBaseWidth != nil {
                applyTrimWaveformMask(
                    visibleWidth: bounds.width,
                    trimStartOffset: trimStartOffset(for: self.clip)
                )
            } else {
                layoutWaveformNormally()
            }
        }

        let handleWidth = TimelineTrimHandleView.hitWidth
        let trimHeight = bounds.height
        startTrimHandle.frame = CGRect(x: 0, y: 0, width: handleWidth, height: trimHeight)
        endTrimHandle.frame = CGRect(x: bounds.width - handleWidth, y: 0, width: handleWidth, height: trimHeight)

        if let clip, clip.hasRecoverableTail, !endTrimHandle.isHidden {
            trimRecoverableTailLayer.isHidden = false
            trimRecoverableTailLayer.frame = CGRect(
                x: max(bounds.width - 5, 0),
                y: 0,
                width: 5,
                height: trimHeight
            )
            endTrimHandle.showsRecoverableHint = true
        } else {
            trimRecoverableTailLayer.isHidden = true
            endTrimHandle.showsRecoverableHint = false
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let location = gestureRecognizer.location(in: self)

        if gestureRecognizer === startEdgeTrimPan {
            return location.x <= TimelineTrimHandleView.hitWidth
        }
        if gestureRecognizer === endEdgeTrimPan {
            return location.x >= bounds.width - TimelineTrimHandleView.hitWidth
        }
        return true
    }

    func prepareForReuse() {
        cancelAllExtractions()
        invalidateBakedStrip()
        filmstripSlots.values.forEach { $0.clearContents() }
        removeAllSlotLayers()
        prefetchClipXRange = nil
        priorityClipXRange = nil
        lastPixelsPerSecond = 0
        filmstripSlotSize = 44
        isUsingBakedStrip = false
        bakedStripKey = nil
        bakedStripLayoutWidth = 0
        isPinchLayoutPreview = false
        fullWaveformSamples = []
        lastWaveformSamples = []
        waveformClipLayer.mask = nil
        waveformContentLayer.position = CGPoint(x: 0, y: Self.audioRowHeight * 0.5)
        bakedStripDisplayLayer.contents = nil
        bakedStripDisplayLayer.isHidden = true
        bakedStripDisplayLayer.removeFromSuperlayer()
        filmstripContentLayer.transform = CATransform3DIdentity
        fullClipFillGeneration = 0
        inFlightSlotIndices.removeAll()
        lastConfiguredWidth = 0
        lastConfiguredSlotSize = 0
        lastConfiguredTimeRange = nil
        clipID = nil
        clip = nil
        previewTimeRange = nil
        trimAnchorRange = nil
        isTrimming = false
        suppressFilmstripConfigurePasses = 0
        filmstripWidthCeiling = nil
        trimFilmstripBaseWidth = nil
        filmstripLayer.mask = nil
        filmstripContentLayer.position = CGPoint(x: 0, y: filmstripSlotSize * 0.5)
        trimRecoverableTailLayer.isHidden = true
        filmstripLayer.contents = nil
        waveformLayer.samples = []
        selectionLayer.isHidden = true
        startTrimHandle.isHidden = true
        endTrimHandle.isHidden = true
        audioRowContainer.isHidden = true
        layer.removeAllAnimations()
        transform = .identity
        alpha = 1
    }

    func configure(
        clip: VideoClip,
        pixelsPerSecond: CGFloat,
        isSelected: Bool,
        isDragging: Bool,
        waveformSamples: [Float]?,
        prefetchClipXRange: ClosedRange<CGFloat>?,
        priorityClipXRange: ClosedRange<CGFloat>? = nil,
        refreshAfterZoom: Bool = false,
        layoutOnly: Bool = false
    ) {
        let isSameClip = clip.id == clipID
        self.clip = clip
        self.clipID = clip.id
        self.pixelsPerSecond = pixelsPerSecond

        let incomingWidth: CGFloat = {
            if isTrimming, let previewTimeRange {
                return max(
                    CGFloat(previewTimeRange.duration.seconds / max(clip.speed, 0.01)) * pixelsPerSecond,
                    1
                )
            }
            return max(CGFloat(clip.scaledDuration.seconds) * pixelsPerSecond, 1)
        }()
        let width = clampedFilmstripWidth(incomingWidth)
        let showAudio = !clip.isMuted && !clip.hasDetachedAudio
        let height: CGFloat = showAudio ? 72 : 44
        let slotSize = showAudio ? 44 : height
        var newFrame = frame
        newFrame.size = CGSize(width: width, height: height)
        frame = newFrame

        updateAudioAndWaveform(showAudio: showAudio, clip: clip, waveformSamples: waveformSamples)

        if isTrimming {
            filmstripSlotSize = slotSize
            applyTrimVisualMask(visibleWidth: width, clip: clip)
            setNeedsLayout()
            return
        }

        if shouldSkipFilmstripReload(for: incomingWidth) {
            if suppressFilmstripConfigurePasses > 0 {
                suppressFilmstripConfigurePasses -= 1
            }
            applyFilmstripChromeOnly(
                width: width,
                slotSize: slotSize,
                isSelected: isSelected,
                prefetchClipXRange: prefetchClipXRange,
                priorityClipXRange: priorityClipXRange
            )
            return
        }

        if layoutOnly {
            isPinchLayoutPreview = true
            filmstripSlotSize = slotSize
            setNeedsLayout()
            return
        }

        isPinchLayoutPreview = false

        let isScrollOnlyUpdate = isSameClip
            && abs(pixelsPerSecond - self.pixelsPerSecond) < 0.001
            && abs(width - lastConfiguredWidth) < 0.5
            && abs(slotSize - lastConfiguredSlotSize) < 0.5
            && !refreshAfterZoom
            && !isDragging
            && !isTrimming
            && isSelected == !selectionLayer.isHidden
        if isScrollOnlyUpdate {
            self.prefetchClipXRange = prefetchClipXRange
            self.priorityClipXRange = priorityClipXRange ?? prefetchClipXRange
            guard let clip = self.clip else { return }
            updateFilmstrip(
                clip: clip,
                clipWidth: width,
                pixelsPerSecond: pixelsPerSecond,
                slotSize: slotSize,
                refreshAfterZoom: false,
                scheduleBackgroundFill: false
            )
            setNeedsLayout()
            return
        }

        let wasSelected = !selectionLayer.isHidden
        selectionLayer.isHidden = !isSelected
        startTrimHandle.isHidden = !isSelected
        endTrimHandle.isHidden = !isSelected
        if isSelected {
            bringSubviewToFront(startTrimHandle)
            bringSubviewToFront(endTrimHandle)
        }

        if isSelected != wasSelected {
            let animation = CABasicAnimation(keyPath: "strokeColor")
            animation.fromValue = wasSelected ? UIColor.systemYellow.cgColor : UIColor.clear.cgColor
            animation.toValue = isSelected ? UIColor.systemYellow.cgColor : UIColor.clear.cgColor
            animation.duration = 0.18
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            selectionLayer.add(animation, forKey: "selectionStroke")
        }

        if isDragging {
            applyDragAnimation()
        } else {
            layer.removeAnimation(forKey: "dragScale")
            transform = .identity
            alpha = 1
        }

        filmstripSlotSize = slotSize
        lastConfiguredWidth = width
        lastConfiguredSlotSize = slotSize
        self.prefetchClipXRange = prefetchClipXRange
        self.priorityClipXRange = priorityClipXRange ?? prefetchClipXRange
        updateFilmstrip(
            clip: clip,
            clipWidth: width,
            pixelsPerSecond: pixelsPerSecond,
            slotSize: filmstripSlotSize,
            refreshAfterZoom: refreshAfterZoom,
            scheduleBackgroundFill: true
        )
        setNeedsLayout()
    }

    func clearFilmstripFrameContents() {
        filmstripSlots.values.forEach { $0.clearContents() }
    }

    private func updateAudioAndWaveform(
        showAudio: Bool,
        clip: VideoClip,
        waveformSamples: [Float]?
    ) {
        audioRowContainer.isHidden = !showAudio
        guard showAudio else {
            fullWaveformSamples = []
            lastWaveformSamples = []
            return
        }
        muteButton.setImage(
            UIImage(systemName: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"),
            for: .normal
        )
        guard !isTrimming else { return }

        let incoming = waveformSamples ?? []
        if !incoming.isEmpty, incoming != fullWaveformSamples {
            fullWaveformSamples = incoming
        }
        let displaySamples = sliceWaveformSamples(
            fullWaveformSamples,
            timeRange: clip.timeRange,
            sourceTimeRange: clip.sourceTimeRange
        )
        if displaySamples != lastWaveformSamples {
            waveformLayer.samples = displaySamples
            lastWaveformSamples = displaySamples
        }
    }

    // MARK: - Filmstrip

    private var filmstripContentWidth: CGFloat {
        if isUsingBakedStrip, bakedStripLayoutWidth > 0 {
            return bakedStripLayoutWidth
        }
        if lastConfiguredWidth > 0 {
            return lastConfiguredWidth
        }
        return max(bounds.width, 1)
    }

    private func relayoutSlotFrames() {
        for (index, slot) in filmstripSlots {
            slot.setFrame(index: index, slotSize: filmstripSlotSize)
        }
    }

    private func updateFilmstrip(
        clip: VideoClip,
        clipWidth: CGFloat,
        pixelsPerSecond: CGFloat,
        slotSize: CGFloat,
        refreshAfterZoom: Bool,
        scheduleBackgroundFill: Bool,
        ignoreStripCache: Bool = false
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let slotCount = TimelineFilmstrip.slotCount(clipWidth: clipWidth, slotSize: slotSize)
        let zoomChanged = abs(pixelsPerSecond - lastPixelsPerSecond) > 0.001
        lastPixelsPerSecond = pixelsPerSecond
        let stripKey = FilmstripStripCache.key(
            clipID: clip.id,
            pixelsPerSecond: pixelsPerSecond,
            slotSize: slotSize,
            slotCount: slotCount,
            timeRange: clip.timeRange
        )

        // Split first half: same start, shorter duration — crop in place.
        // Unbaking / re-extracting is the "video track reloads from scratch" flicker.
        if !refreshAfterZoom,
           !zoomChanged,
           !ignoreStripCache,
           let previousRange = lastConfiguredTimeRange,
           CMTimeCompare(previousRange.start, clip.timeRange.start) == 0,
           CMTimeCompare(clip.timeRange.endTime, previousRange.endTime) < 0,
           lastConfiguredWidth > 0 {
            if isUsingBakedStrip {
                let sourceWidth = max(bakedStripLayoutWidth, lastConfiguredWidth)
                bakedStripLayoutWidth = clipWidth
                lastConfiguredWidth = clipWidth
                lastConfiguredTimeRange = clip.timeRange
                let fraction = sourceWidth > 0 ? clipWidth / sourceWidth : 1
                bakedStripDisplayLayer.contentsRect = CGRect(x: 0, y: 0, width: min(max(fraction, 0.01), 1), height: 1)
                bakedStripDisplayLayer.contentsGravity = .resize
                CATransaction.commit()
                setNeedsLayout()
                return
            }
            for index in filmstripSlots.keys where index >= slotCount {
                removeSlot(at: index)
            }
            lastConfiguredWidth = clipWidth
            lastConfiguredTimeRange = clip.timeRange
            CATransaction.commit()
            setNeedsLayout()
            return
        }
        lastConfiguredTimeRange = clip.timeRange

        if isUsingBakedStrip, abs(bakedStripLayoutWidth - clipWidth) > 0.5 {
            for index in filmstripSlots.keys where index >= slotCount {
                removeSlot(at: index)
            }
            unbakeToSlots()
        }

        if refreshAfterZoom {
            unbakeToSlots()
        }

        if !ignoreStripCache, let cachedStrip = FilmstripStripCache.image(for: stripKey) {
            applyBakedStrip(cachedStrip, key: stripKey)
            CATransaction.commit()
            return
        }

        if isUsingBakedStrip, bakedStripKey == stripKey {
            CATransaction.commit()
            return
        }

        for index in filmstripSlots.keys where index >= slotCount {
            removeSlot(at: index)
        }

        for index in 0..<slotCount {
            ensureSlot(at: index, slotSize: slotSize)
        }
        if !isUsingBakedStrip {
            relayoutSlotFrames()
        }

        let timeRange = clip.timeRange
        let assetPath = clip.asset.url.path
        let priorityIndices = priorityClipXRange.flatMap {
            TimelineFilmstrip.slotIndexRange(clipXRange: $0, slotSize: slotSize, slotCount: slotCount)
        }
        let viewportCenter = priorityClipXRange.map { ($0.lowerBound + $0.upperBound) * 0.5 } ?? 0
        var loadQueue: [(index: Int, isPriority: Bool, distance: CGFloat)] = []

        for index in 0..<slotCount {
            guard let slot = filmstripSlots[index] else { continue }

            let newTimestamp = TimelineFilmstrip.timestamp(
                timeRange: timeRange,
                slotIndex: index,
                slotSize: slotSize,
                pixelsPerSecond: pixelsPerSecond
            )
            let timestampDelta = abs(newTimestamp - slot.timestamp)
            let needsRefresh: Bool
            if slot.timestamp < 0 || slot.layer.contents == nil {
                needsRefresh = true
            } else if refreshAfterZoom {
                needsRefresh = timestampDelta > TimelineFilmstrip.timestampChangeThreshold
            } else if zoomChanged {
                needsRefresh = false
            } else {
                needsRefresh = timestampDelta > 0.001
            }

            if needsRefresh {
                slot.timestamp = newTimestamp
                if applyCachedFrame(to: slot, assetPath: assetPath, timestamp: newTimestamp) {
                    continue
                }
                let isPriority = priorityIndices?.contains(index) ?? false
                let slotCenter = CGFloat(index) * slotSize + slotSize * 0.5
                let distance = abs(slotCenter - viewportCenter)
                loadQueue.append((index, isPriority, distance))
            } else if abs(slot.timestamp - newTimestamp) > 0.001 {
                slot.timestamp = newTimestamp
            }
        }

        loadQueue.sort {
            if $0.isPriority != $1.isPriority { return $0.isPriority }
            return $0.distance < $1.distance
        }

        for item in loadQueue {
            guard let slot = filmstripSlots[item.index] else { continue }
            requestFrame(
                for: slot,
                at: item.index,
                clip: clip,
                timestamp: slot.timestamp,
                isBackground: !item.isPriority
            )
        }

        if scheduleBackgroundFill {
            scheduleFullClipBackgroundLoad(
                clip: clip,
                slotCount: slotCount,
                slotSize: slotSize,
                skipIndices: Set(loadQueue.map(\.index)),
                priorityClipXRange: priorityClipXRange
            )
        }

        CATransaction.commit()
    }

    private func scheduleFullClipBackgroundLoad(
        clip: VideoClip,
        slotCount: Int,
        slotSize: CGFloat,
        skipIndices: Set<Int>,
        priorityClipXRange: ClosedRange<CGFloat>?
    ) {
        fullClipFillGeneration &+= 1
        let generation = fullClipFillGeneration
        let timeRange = clip.timeRange
        let assetPath = clip.asset.url.path
        let hysteresis = TimelineFilmstrip.prefetchHysteresisSlots

        // Only prefetch viewport ± hysteresis — never the entire clip.
        let targetIndices: Set<Int>
        if let range = priorityClipXRange,
           let indices = TimelineFilmstrip.slotIndexRange(
                clipXRange: (range.lowerBound - CGFloat(hysteresis) * slotSize)...(range.upperBound + CGFloat(hysteresis) * slotSize),
                slotSize: slotSize,
                slotCount: slotCount
           ) {
            targetIndices = Set(indices)
        } else {
            targetIndices = Set(0..<min(slotCount, hysteresis * 2 + 1))
        }

        for index in targetIndices where !skipIndices.contains(index) {
            guard let slot = filmstripSlots[index] else { continue }
            guard slot.layer.contents == nil else { continue }

            let timestamp = TimelineFilmstrip.timestamp(
                timeRange: timeRange,
                slotIndex: index,
                slotSize: slotSize,
                pixelsPerSecond: pixelsPerSecond
            )
            if slot.timestamp < 0 {
                slot.timestamp = timestamp
            }
            if applyCachedFrame(to: slot, assetPath: assetPath, timestamp: slot.timestamp) {
                continue
            }
            requestFrame(
                for: slot,
                at: index,
                clip: clip,
                timestamp: slot.timestamp,
                isBackground: true,
                generation: generation
            )
        }
    }

    private func applyBakedStrip(_ image: CGImage, key: NSString) {
        filmstripLayer.backgroundColor = nil
        bakedStripLayoutWidth = lastConfiguredWidth
        filmstripSlots.values.forEach { $0.layer.isHidden = true }
        bakedStripDisplayLayer.contents = image
        bakedStripDisplayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        bakedStripDisplayLayer.contentsGravity = .resizeAspectFill
        bakedStripDisplayLayer.frame = CGRect(
            x: 0,
            y: 0,
            width: bakedStripLayoutWidth,
            height: filmstripSlotSize
        )
        if bakedStripDisplayLayer.superlayer == nil {
            filmstripContentLayer.addSublayer(bakedStripDisplayLayer)
        }
        bakedStripDisplayLayer.isHidden = false
        isUsingBakedStrip = true
        bakedStripKey = key
    }

    /// Hides baked overlay and reveals per-slot layers without clearing their frames.
    private func unbakeToSlots() {
        guard isUsingBakedStrip else { return }
        isUsingBakedStrip = false
        bakedStripKey = nil
        bakedStripLayoutWidth = 0
        bakedStripDisplayLayer.contents = nil
        bakedStripDisplayLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        bakedStripDisplayLayer.isHidden = true
        filmstripSlots.values.forEach { $0.layer.isHidden = false }
    }

    private func invalidateBakedStrip() {
        unbakeToSlots()
        bakedStripDisplayLayer.removeFromSuperlayer()
        fullClipFillGeneration &+= 1
    }

    private func removeSlot(at index: Int) {
        filmstripSlots[index]?.requestToken &+= 1
        inFlightSlotIndices.remove(index)
        if let slot = filmstripSlots.removeValue(forKey: index) {
            slot.layer.removeFromSuperlayer()
        }
    }

    private func removeAllSlotLayers() {
        filmstripSlots.values.forEach { $0.layer.removeFromSuperlayer() }
        filmstripSlots.removeAll()
    }

    private func tryBakeFullClipStrip(
        clip: VideoClip,
        slotCount: Int,
        slotSize: CGFloat,
        stripKey: NSString
    ) {
        guard !isUsingBakedStrip else { return }
        guard slotCount <= TimelineFilmstrip.maxSlotsForStripBake else { return }
        guard filmstripSlots.count == slotCount else { return }
        for index in 0..<slotCount where filmstripSlots[index]?.layer.contents == nil {
            return
        }
        guard let baked = TimelineFilmstrip.bakeStrip(
            slots: filmstripSlots,
            slotCount: slotCount,
            slotSize: slotSize
        ) else { return }

        FilmstripStripCache.store(baked, for: stripKey)
        applyBakedStrip(baked, key: stripKey)
    }

    private func ensureSlot(at index: Int, slotSize: CGFloat) {
        if filmstripSlots[index] == nil {
            let slot = FilmstripSlotState(index: index, slotSize: slotSize)
            filmstripContentLayer.addSublayer(slot.layer)
            filmstripSlots[index] = slot
        } else {
            filmstripSlots[index]?.layer.isHidden = isUsingBakedStrip
        }
    }

    @discardableResult
    private func applyCachedFrame(
        to slot: FilmstripSlotState,
        assetPath: String,
        timestamp: TimeInterval
    ) -> Bool {
        guard let cgImage = FilmstripFrameCache.image(assetPath: assetPath, timestamp: timestamp) else {
            return false
        }
        slot.applyFrame(cgImage)
        return true
    }

    private func requestFrame(
        for slot: FilmstripSlotState,
        at index: Int,
        clip: VideoClip,
        timestamp: TimeInterval,
        isBackground: Bool,
        generation: UInt64? = nil
    ) {
        guard slot.layer.contents == nil else { return }
        guard !inFlightSlotIndices.contains(index) else { return }

        let assetPath = clip.asset.url.path
        if applyCachedFrame(to: slot, assetPath: assetPath, timestamp: timestamp) {
            checkBakeAfterFrameLoad(clip: clip)
            return
        }

        cancelExtraction(for: slot.layer)
        inFlightSlotIndices.insert(index)
        filmstripSession &+= 1
        let token = filmstripSession
        slot.requestToken = token
        FilmstripExtractionService.shared.extract(
            asset: clip.asset,
            assetPath: assetPath,
            slotSize: filmstripSlotSize,
            timestamp: timestamp,
            isBackground: isBackground
        ) { [weak self] cgImage in
            guard let self else { return }
            guard slot.requestToken == token else { return }
            self.inFlightSlotIndices.remove(index)
            guard let current = self.filmstripSlots[index] else { return }
            guard current.layer === slot.layer else { return }
            if let generation, generation != self.fullClipFillGeneration { return }
            if let cgImage {
                slot.applyFrame(cgImage)
            }
            self.checkBakeAfterFrameLoad(clip: clip)
        }
    }

    private func checkBakeAfterFrameLoad(clip: VideoClip) {
        guard !isPinchLayoutPreview else { return }
        let slotCount = TimelineFilmstrip.slotCount(
            clipWidth: lastConfiguredWidth,
            slotSize: filmstripSlotSize
        )
        let stripKey = FilmstripStripCache.key(
            clipID: clip.id,
            pixelsPerSecond: pixelsPerSecond,
            slotSize: filmstripSlotSize,
            slotCount: slotCount,
            timeRange: clip.timeRange
        )
        tryBakeFullClipStrip(
            clip: clip,
            slotCount: slotCount,
            slotSize: filmstripSlotSize,
            stripKey: stripKey
        )
    }

    private func cancelExtraction(for layer: CALayer) {
        guard let index = filmstripSlots.first(where: { $0.value.layer === layer })?.key else { return }
        filmstripSlots[index]?.requestToken &+= 1
    }

    private func cancelAllExtractions() {
        filmstripSession &+= 1
        fullClipFillGeneration &+= 1
        inFlightSlotIndices.removeAll()
        filmstripSlots.values.forEach { $0.requestToken &+= 1 }
    }

    @objc private func handleMemoryWarning() {
        cancelAllExtractions()
        FilmstripExtractionService.shared.clearOnMemoryWarning()
        invalidateBakedStrip()
        removeAllSlotLayers()
    }

    private func applyDragAnimation() {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 1.05
        scale.duration = 0.28
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        layer.add(scale, forKey: "dragScale")
        alpha = 0.9
    }

    @objc private func cellTapped() {
        guard let clipID else { return }
        delegate?.clipCellDidSelect(clipID)
    }

    @objc private func muteTapped() {
        guard let clipID else { return }
        delegate?.clipCellDidToggleMute(clipID)
    }

    @objc private func handleStartTrim(_ gesture: UIPanGestureRecognizer) {
        guard let clip else { return }
        switch gesture.state {
        case .began:
            beginTrimSession(for: clip)
            trimAnchorRange = previewTimeRange ?? clip.timeRange
        case .changed:
            guard let anchor = trimAnchorRange,
                  let newRange = clip.startTrimmed(
                    timelineDelta: gesture.translation(in: self).x,
                    pixelsPerSecond: pixelsPerSecond,
                    anchor: anchor
                  ) else { return }
            applyTrimPreview(newRange, for: clip)
        case .ended:
            finishTrimSession(for: clip)
        case .cancelled, .failed:
            cancelTrimSession(for: clip)
        default:
            break
        }
    }

    @objc private func handleEndTrim(_ gesture: UIPanGestureRecognizer) {
        guard let clip else { return }
        switch gesture.state {
        case .began:
            beginTrimSession(for: clip)
            trimAnchorRange = previewTimeRange ?? clip.timeRange
        case .changed:
            guard let anchor = trimAnchorRange,
                  let newRange = clip.endTrimmed(
                    timelineDelta: gesture.translation(in: self).x,
                    pixelsPerSecond: pixelsPerSecond,
                    anchor: anchor
                  ) else { return }
            applyTrimPreview(newRange, for: clip)
        case .ended:
            finishTrimSession(for: clip)
        case .cancelled, .failed:
            cancelTrimSession(for: clip)
        default:
            break
        }
    }

    private func applyTrimPreview(_ newRange: CMTimeRange, for clip: VideoClip) {
        let previousPreview = previewTimeRange
        previewTimeRange = newRange
        var previewClip = clip
        previewClip.timeRange = newRange
        self.clip = previewClip

        let previewWidth = max(
            CGFloat(newRange.duration.seconds / max(clip.speed, 0.01)) * pixelsPerSecond,
            1
        )
        lastConfiguredWidth = previewWidth

        var previewFrame = frame
        previewFrame.size.width = previewWidth
        frame = previewFrame

        applyTrimVisualMask(visibleWidth: previewWidth, clip: previewClip)

        if previousPreview == nil || !CMTimeRangeEqual(previousPreview!, newRange) {
            delegate?.clipCellDidTrimPreview(clip.id, timeRange: newRange)
        }
        setNeedsLayout()
    }

    private func beginTrimSession(for clip: VideoClip) {
        isTrimming = true
        suppressFilmstripConfigurePasses = 0
        filmstripWidthCeiling = nil

        let anchorRange = trimAnchorRange ?? clip.timeRange
        trimFilmstripBaseWidth = max(
            CGFloat(anchorRange.duration.seconds / max(clip.speed, 0.01)) * pixelsPerSecond,
            1
        )

        if isUsingBakedStrip {
            unbakeToSlots()
        }
        ensureFilmstripLoadedForTrim(clip: clip, anchorRange: anchorRange)
        ensureWaveformLoadedForTrim(clip: clip, anchorRange: anchorRange)

        if selectionLayer.isHidden {
            delegate?.clipCellDidSelect(clip.id)
        }
        delegate?.clipCellDidBeginTrim(clip.id)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func finishTrimSession(for clip: VideoClip) {
        let committedRange = previewTimeRange ?? clip.timeRange
        previewTimeRange = nil
        trimAnchorRange = nil

        var trimmedClip = clip
        trimmedClip.timeRange = committedRange
        self.clip = trimmedClip

        let width = max(CGFloat(trimmedClip.scaledDuration.seconds) * pixelsPerSecond, 1)
        lastConfiguredWidth = width
        lastConfiguredSlotSize = filmstripSlotSize

        var trimmedFrame = frame
        trimmedFrame.size.width = width
        frame = trimmedFrame

        clearTrimVisualMask()
        suppressFilmstripConfigurePasses = 6
        filmstripWidthCeiling = width
        isTrimming = false

        reconcileFilmstripAfterTrim(clip: trimmedClip, width: width, slotSize: filmstripSlotSize)
        reconcileWaveformAfterTrim(clip: trimmedClip)

        delegate?.clipCellDidTrimCommit(clip.id, timeRange: committedRange)
        delegate?.clipCellDidEndTrim(clip.id)
        setNeedsLayout()
    }

    private func cancelTrimSession(for clip: VideoClip) {
        let originalRange = trimAnchorRange ?? clip.timeRange
        previewTimeRange = nil
        trimAnchorRange = nil

        var restoredClip = clip
        restoredClip.timeRange = originalRange
        self.clip = restoredClip

        let width = max(CGFloat(restoredClip.scaledDuration.seconds) * pixelsPerSecond, 1)
        lastConfiguredWidth = width
        lastConfiguredSlotSize = filmstripSlotSize

        var restoredFrame = frame
        restoredFrame.size.width = width
        frame = restoredFrame

        clearTrimVisualMask()
        suppressFilmstripConfigurePasses = 6
        filmstripWidthCeiling = width
        isTrimming = false

        reconcileFilmstripAfterTrim(clip: restoredClip, width: width, slotSize: filmstripSlotSize)
        reconcileWaveformAfterTrim(clip: restoredClip)

        delegate?.clipCellDidTrimCancel(clip.id)
        delegate?.clipCellDidEndTrim(clip.id)
        setNeedsLayout()
    }

    private func clampedFilmstripWidth(_ incomingWidth: CGFloat) -> CGFloat {
        guard let ceiling = filmstripWidthCeiling, incomingWidth > ceiling + 1 else {
            return incomingWidth
        }
        return ceiling
    }

    private func shouldSkipFilmstripReload(for incomingWidth: CGFloat) -> Bool {
        if isTrimming || suppressFilmstripConfigurePasses > 0 {
            return true
        }
        if let ceiling = filmstripWidthCeiling, incomingWidth > ceiling + 1 {
            return true
        }
        return false
    }

    private func applyFilmstripChromeOnly(
        width: CGFloat,
        slotSize: CGFloat,
        isSelected: Bool,
        prefetchClipXRange: ClosedRange<CGFloat>?,
        priorityClipXRange: ClosedRange<CGFloat>?
    ) {
        filmstripSlotSize = slotSize
        lastConfiguredWidth = width
        lastConfiguredSlotSize = slotSize
        self.prefetchClipXRange = prefetchClipXRange
        self.priorityClipXRange = priorityClipXRange ?? prefetchClipXRange
        selectionLayer.isHidden = !isSelected
        startTrimHandle.isHidden = !isSelected
        endTrimHandle.isHidden = !isSelected
        if isSelected {
            bringSubviewToFront(startTrimHandle)
            bringSubviewToFront(endTrimHandle)
        }
        if suppressFilmstripConfigurePasses == 0,
           let ceiling = filmstripWidthCeiling,
           abs(width - ceiling) < 0.5 {
            filmstripWidthCeiling = nil
        }
        setNeedsLayout()
    }

    private func trimStartOffset(for clip: VideoClip?) -> CGFloat {
        guard let clip, let anchor = trimAnchorRange else { return 0 }
        let previewStart = previewTimeRange?.start ?? clip.timeRange.start
        return max(
            CGFloat((previewStart.seconds - anchor.start.seconds) / max(clip.speed, 0.01)) * pixelsPerSecond,
            0
        )
    }

    private func applyTrimVisualMask(visibleWidth: CGFloat, clip: VideoClip) {
        let offset = trimStartOffset(for: clip)
        applyTrimFilmstripMask(visibleWidth: visibleWidth, trimStartOffset: offset)
        applyTrimWaveformMask(visibleWidth: visibleWidth, trimStartOffset: offset)
    }

    /// Zero-cost trim preview: shift existing slots and clip with a layer mask — no slot rebuild.
    private func applyTrimFilmstripMask(visibleWidth: CGFloat, trimStartOffset: CGFloat) {
        guard let baseWidth = trimFilmstripBaseWidth, baseWidth > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        filmstripLayer.frame = CGRect(x: 0, y: 0, width: visibleWidth, height: filmstripSlotSize)
        filmstripContentLayer.bounds = CGRect(x: 0, y: 0, width: baseWidth, height: filmstripSlotSize)
        filmstripContentLayer.position = CGPoint(
            x: -trimStartOffset,
            y: filmstripSlotSize * 0.5
        )
        filmstripContentLayer.transform = CATransform3DIdentity

        let maskRect = CGRect(x: 0, y: 0, width: visibleWidth, height: filmstripSlotSize)
        filmstripTrimMaskLayer.path = UIBezierPath(rect: maskRect).cgPath
        filmstripTrimMaskLayer.frame = maskRect
        filmstripLayer.mask = filmstripTrimMaskLayer

        CATransaction.commit()
    }

    private func applyTrimWaveformMask(visibleWidth: CGFloat, trimStartOffset: CGFloat) {
        guard !audioRowContainer.isHidden,
              let baseWidth = trimFilmstripBaseWidth,
              baseWidth > Self.muteButtonWidth else { return }

        let baseWaveWidth = baseWidth - Self.muteButtonWidth
        let visibleWaveWidth = max(visibleWidth - Self.muteButtonWidth, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        waveformClipLayer.frame = CGRect(
            x: Self.muteButtonWidth,
            y: 0,
            width: visibleWaveWidth,
            height: Self.audioRowHeight
        )
        waveformContentLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: baseWaveWidth,
            height: Self.audioRowHeight
        )
        waveformContentLayer.position = CGPoint(
            x: -trimStartOffset,
            y: Self.audioRowHeight * 0.5
        )
        waveformContentLayer.transform = CATransform3DIdentity
        waveformLayer.frame = CGRect(x: 0, y: 0, width: baseWaveWidth, height: Self.audioRowHeight)

        let maskRect = CGRect(x: 0, y: 0, width: visibleWaveWidth, height: Self.audioRowHeight)
        waveformTrimMaskLayer.path = UIBezierPath(rect: maskRect).cgPath
        waveformTrimMaskLayer.frame = maskRect
        waveformClipLayer.mask = waveformTrimMaskLayer

        CATransaction.commit()
    }

    private func layoutWaveformNormally() {
        let waveWidth = max(bounds.width - Self.muteButtonWidth, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        waveformClipLayer.mask = nil
        waveformClipLayer.frame = CGRect(
            x: Self.muteButtonWidth,
            y: 0,
            width: waveWidth,
            height: Self.audioRowHeight
        )
        waveformContentLayer.bounds = CGRect(x: 0, y: 0, width: waveWidth, height: Self.audioRowHeight)
        waveformContentLayer.position = CGPoint(x: 0, y: Self.audioRowHeight * 0.5)
        waveformContentLayer.transform = CATransform3DIdentity
        waveformLayer.frame = CGRect(x: 0, y: 0, width: waveWidth, height: Self.audioRowHeight)

        CATransaction.commit()
    }

    private func clearTrimVisualMask() {
        trimFilmstripBaseWidth = nil
        filmstripLayer.mask = nil
        filmstripContentLayer.position = CGPoint(x: 0, y: filmstripSlotSize * 0.5)
        filmstripContentLayer.transform = CATransform3DIdentity
        waveformClipLayer.mask = nil
        waveformContentLayer.position = CGPoint(x: 0, y: Self.audioRowHeight * 0.5)
        waveformContentLayer.transform = CATransform3DIdentity
    }

    private func sliceWaveformSamples(
        _ samples: [Float],
        timeRange: CMTimeRange,
        sourceTimeRange: CMTimeRange
    ) -> [Float] {
        guard samples.count > 1 else { return samples }

        let sourceDuration = sourceTimeRange.duration.seconds
        guard sourceDuration > 0 else { return samples }

        let startRatio = max(
            0,
            (timeRange.start.seconds - sourceTimeRange.start.seconds) / sourceDuration
        )
        let endRatio = min(
            1,
            (timeRange.endTime.seconds - sourceTimeRange.start.seconds) / sourceDuration
        )
        guard endRatio > startRatio else { return samples }

        let startIndex = Int(startRatio * Double(samples.count))
        let endIndex = max(startIndex + 1, Int(endRatio * Double(samples.count)))
        return Array(samples[startIndex..<min(endIndex, samples.count)])
    }

    private func ensureWaveformLoadedForTrim(clip: VideoClip, anchorRange: CMTimeRange) {
        guard !audioRowContainer.isHidden, let baseWidth = trimFilmstripBaseWidth else { return }

        let anchorSamples = sliceWaveformSamples(
            fullWaveformSamples,
            timeRange: anchorRange,
            sourceTimeRange: clip.sourceTimeRange
        )
        if anchorSamples != lastWaveformSamples {
            waveformLayer.samples = anchorSamples
            lastWaveformSamples = anchorSamples
        }

        let baseWaveWidth = baseWidth - Self.muteButtonWidth
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        waveformClipLayer.mask = nil
        waveformClipLayer.frame = CGRect(
            x: Self.muteButtonWidth,
            y: 0,
            width: baseWaveWidth,
            height: Self.audioRowHeight
        )
        waveformContentLayer.bounds = CGRect(x: 0, y: 0, width: baseWaveWidth, height: Self.audioRowHeight)
        waveformContentLayer.position = CGPoint(x: 0, y: Self.audioRowHeight * 0.5)
        waveformLayer.frame = CGRect(x: 0, y: 0, width: baseWaveWidth, height: Self.audioRowHeight)
        CATransaction.commit()
    }

    private func reconcileWaveformAfterTrim(clip: VideoClip) {
        let displaySamples = sliceWaveformSamples(
            fullWaveformSamples,
            timeRange: clip.timeRange,
            sourceTimeRange: clip.sourceTimeRange
        )
        if displaySamples != lastWaveformSamples {
            waveformLayer.samples = displaySamples
            lastWaveformSamples = displaySamples
        }
    }

    private func ensureFilmstripLoadedForTrim(clip: VideoClip, anchorRange: CMTimeRange) {
        guard let baseWidth = trimFilmstripBaseWidth else { return }

        var anchorClip = clip
        anchorClip.timeRange = anchorRange
        let slotCount = TimelineFilmstrip.slotCount(clipWidth: baseWidth, slotSize: filmstripSlotSize)
        let needsLoad = filmstripSlots.isEmpty
            || abs(lastConfiguredWidth - baseWidth) > 0.5
            || filmstripSlots.count < slotCount

        guard needsLoad else { return }

        lastConfiguredWidth = baseWidth
        updateFilmstrip(
            clip: anchorClip,
            clipWidth: baseWidth,
            pixelsPerSecond: pixelsPerSecond,
            slotSize: filmstripSlotSize,
            refreshAfterZoom: false,
            scheduleBackgroundFill: false
        )
    }

    private func reconcileFilmstripAfterTrim(clip: VideoClip, width: CGFloat, slotSize: CGFloat) {
        invalidateBakedStrip()
        lastConfiguredWidth = width
        updateFilmstrip(
            clip: clip,
            clipWidth: width,
            pixelsPerSecond: pixelsPerSecond,
            slotSize: slotSize,
            refreshAfterZoom: false,
            scheduleBackgroundFill: true,
            ignoreStripCache: true
        )
    }

}

private final class TimelineTrimHandleView: UIView {
    enum Edge { case start, end }

    static let hitWidth: CGFloat = 24

    var showsRecoverableHint = false {
        didSet { updateChrome() }
    }

    private let edge: Edge
    private let arrowView = UIImageView()

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        backgroundColor = .systemYellow

        let symbol = edge == .start ? "chevron.left" : "chevron.right"
        let config = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        arrowView.image = UIImage(systemName: symbol, withConfiguration: config)
        arrowView.tintColor = .black
        arrowView.contentMode = .scaleAspectFit
        addSubview(arrowView)
        updateChrome()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontalInset: CGFloat = 5
        let arrowHeight = min(bounds.height - 8, 20)
        arrowView.frame = CGRect(
            x: horizontalInset,
            y: (bounds.height - arrowHeight) * 0.5,
            width: bounds.width - horizontalInset * 2,
            height: arrowHeight
        )
        updateCornerMask()
    }

    private func updateCornerMask() {
        let radius: CGFloat = 4
        let corners: CACornerMask = edge == .start
            ? [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            : [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        layer.cornerRadius = radius
        layer.maskedCorners = corners
    }

    private func updateChrome() {
        backgroundColor = showsRecoverableHint
            ? UIColor.systemYellow.withAlphaComponent(0.85)
            : .systemYellow
    }
}

final class TimelineTransitionCell: UIView {
    private let iconView = UIImageView()
    var onTap: (() -> Void)?
    private var clipID: UUID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .center
        iconView.tintColor = UIColor.white.withAlphaComponent(0.45)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        layer.cornerRadius = 4
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func prepareForReuse() {
        onTap = nil
        clipID = nil
    }

    func configure(after clip: VideoClip, height: CGFloat) {
        clipID = clip.id
        frame.size = CGSize(width: TimelineRenderSnapshot.transitionWidth, height: height)
        let hasTransition = clip.transition != nil && clip.transition != .cut
        let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        iconView.image = UIImage(systemName: "hexagon", withConfiguration: config)
        iconView.tintColor = hasTransition ? .systemYellow : UIColor.white.withAlphaComponent(0.45)
        layer.borderColor = (hasTransition ? UIColor.systemYellow : UIColor.white.withAlphaComponent(0.25)).cgColor
    }

    @objc private func tapped() {
        onTap?()
    }
}

final class TimelineSegmentCell: UIView {
    private let label = UILabel()
    private let backgroundShape = CAShapeLayer()

    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundShape.fillColor = UIColor.systemOrange.withAlphaComponent(0.55).cgColor
        layer.addSublayer(backgroundShape)

        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = bounds.insetBy(dx: 0, dy: 4)
        backgroundShape.path = UIBezierPath(roundedRect: rect, cornerRadius: 4).cgPath
    }

    func prepareForReuse() {
        onTap = nil
        label.text = nil
        layer.removeAllAnimations()
        transform = .identity
        alpha = 1
    }

    func configure(label text: String, width: CGFloat, color: UIColor) {
        label.text = text
        frame.size = CGSize(width: max(width, 24), height: 36)
        backgroundShape.fillColor = color.cgColor
    }

    @objc private func tapped() {
        onTap?()
    }
}
