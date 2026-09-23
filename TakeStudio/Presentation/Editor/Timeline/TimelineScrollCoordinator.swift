import AVFoundation
import SwiftUI
import UIKit

struct TimelineClipLayout: Equatable {
    let index: Int
    let clipID: UUID
    let minX: CGFloat
    let maxX: CGFloat
    let minY: CGFloat
    let maxY: CGFloat
}

struct TimelineScrollSnapshot: Equatable {
    let renderSnapshot: TimelineRenderSnapshot
    let playbackTime: TimeInterval
    let totalDuration: TimeInterval
    let waveformSamples: [String: [Float]]
    /// Bumped after trim playback seek settles so the playhead can snap once without animation.
    let trimVisualSettleToken: UInt64
}

struct TimelineScrollCoordinator: UIViewRepresentable {
    let snapshot: TimelineScrollSnapshot
    @Binding var scrollOffset: CGFloat
    @Binding var pixelsPerSecond: CGFloat
    @Binding var draggingClipIndex: Int?
    @Binding var clipDragTranslation: CGFloat

    let onScroll: (CGFloat) -> Void
    let onClipDragEnded: (Int, Int) -> Void
    let onClipContextMenu: (UUID) -> Void
    let onSelectClip: (UUID) -> Void
    let onTrimBegin: () -> Void
    let onTrimPreview: (UUID, CMTimeRange) -> Void
    let onTrimCommit: (UUID, CMTimeRange) -> Void
    let onTrimCancel: () -> Void
    let onTrimEnd: () -> Void
    let onToggleMute: (UUID) -> Void
    let onTransitionTap: (UUID) -> Void
    let onSelectSubtitle: (UUID) -> Void
    let onSelectText: (UUID) -> Void
    let onSelectSticker: (UUID) -> Void
    let onSelectAudio: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.bounces = true
        scrollView.backgroundColor = .clear
        scrollView.indicatorStyle = .white
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true

        let contentView = TimelineContentView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.delegate = context.coordinator
        scrollView.addSubview(contentView)
        context.coordinator.contentView = contentView
        context.coordinator.scrollView = scrollView

        let heightConstraint = contentView.heightAnchor.constraint(equalToConstant: snapshot.renderSnapshot.contentHeight)
        let widthConstraint = contentView.widthAnchor.constraint(equalToConstant: max(snapshot.renderSnapshot.contentWidth, 1))
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            heightConstraint,
            widthConstraint
        ])
        context.coordinator.heightConstraint = heightConstraint
        context.coordinator.widthConstraint = widthConstraint

        let playhead = TimelinePlayheadOverlayView()
        playhead.translatesAutoresizingMaskIntoConstraints = false
        playhead.isUserInteractionEnabled = false
        scrollView.addSubview(playhead)
        NSLayoutConstraint.activate([
            playhead.topAnchor.constraint(equalTo: scrollView.frameLayoutGuide.topAnchor),
            playhead.bottomAnchor.constraint(equalTo: scrollView.frameLayoutGuide.bottomAnchor),
            playhead.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            playhead.widthAnchor.constraint(equalToConstant: 120)
        ])
        context.coordinator.playheadView = playhead

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        scrollView.addGestureRecognizer(pinch)

        let clipLongPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClipLongPress(_:))
        )
        clipLongPress.minimumPressDuration = 0.35
        clipLongPress.delegate = context.coordinator
        scrollView.addGestureRecognizer(clipLongPress)
        context.coordinator.clipLongPress = clipLongPress

        TimelineScrollRegistry.reset()
        TimelineScrollRegistry.sharedScrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        // Keep scroll/playhead locked for the whole VM trim freeze, not just the UIKit gesture.
        context.coordinator.isTrimmingClip = snapshot.renderSnapshot.isClipTrimming

        if !context.coordinator.isTrimmingClip {
            context.coordinator.playheadView?.update(
                currentTime: snapshot.playbackTime,
                totalDuration: snapshot.totalDuration
            )
        }

        if snapshot.trimVisualSettleToken != context.coordinator.lastTrimVisualSettleToken {
            context.coordinator.lastTrimVisualSettleToken = snapshot.trimVisualSettleToken
            context.coordinator.repositionPlayheadAfterTrimIfNeeded()
        }

        if context.coordinator.isPinchActive {
            TimelineScrollRegistry.sharedScrollView = scrollView
            return
        }

        let inset = scrollView.bounds.width / 2
        scrollView.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)

        guard let contentView = context.coordinator.contentView else {
            scrollView.contentSize = CGSize(
                width: max(snapshot.renderSnapshot.contentWidth, 1),
                height: snapshot.renderSnapshot.contentHeight
            )
            TimelineScrollRegistry.sharedScrollView = scrollView
            return
        }

        let width = max(snapshot.renderSnapshot.contentWidth, 1)
        let contentHeight = snapshot.renderSnapshot.contentHeight

        // Fast path FIRST: when only contentHeight changed (e.g. during resize drag),
        // skip the expensive cell relayout — but still sync scroll to the playhead.
        // Returning before playhead scroll sync freezes the montage while time advances.
        let current = snapshot.renderSnapshot
        let layoutUnchanged = context.coordinator.lastLayoutSnapshot.map {
            TimelineRenderSnapshot.layoutEqual(lhs: $0, rhs: current)
        } ?? false

        if layoutUnchanged {
            if let wc = context.coordinator.widthConstraint, wc.constant != width {
                wc.constant = width
            }
            if let hc = context.coordinator.heightConstraint, hc.constant != contentHeight {
                hc.constant = contentHeight
            }
            scrollView.contentSize = CGSize(width: width, height: contentHeight)

            // Content that layoutEqual ignores (waveform samples, overlay text) still needs a refresh.
            let waveformsChanged = context.coordinator.lastWaveformSamples != snapshot.waveformSamples
            let textChanged = context.coordinator.lastOverlayTextSignature
                != Self.overlayTextSignature(snapshot.renderSnapshot)
            if waveformsChanged || textChanged {
                let visibleRect = CGRect(
                    x: scrollView.contentOffset.x,
                    y: 0,
                    width: scrollView.bounds.width,
                    height: contentHeight
                )
                contentView.update(
                    snapshot: snapshot.renderSnapshot,
                    visibleRect: visibleRect,
                    waveformSamples: snapshot.waveformSamples,
                    refreshAfterZoom: false
                )
                context.coordinator.lastWaveformSamples = snapshot.waveformSamples
                context.coordinator.lastOverlayTextSignature = Self.overlayTextSignature(snapshot.renderSnapshot)
            }

            if scrollView.bounds.width > 0 {
                context.coordinator.didSetInitialOffset = true
            }

            if !context.coordinator.isTrimmingClip {
                syncScrollOffsetToPlayhead(
                    scrollView,
                    coordinator: context.coordinator,
                    inset: inset
                )
            }
            TimelineScrollRegistry.sharedScrollView = scrollView
            return
        }
        context.coordinator.lastLayoutSnapshot = current
        context.coordinator.lastWaveformSamples = snapshot.waveformSamples
        context.coordinator.lastOverlayTextSignature = Self.overlayTextSignature(snapshot.renderSnapshot)

        // Slow path: layout-affecting fields changed — full relayout.
        if let wc = context.coordinator.widthConstraint {
            wc.constant = width
        } else {
            let wc = contentView.widthAnchor.constraint(equalToConstant: width)
            wc.isActive = true
            context.coordinator.widthConstraint = wc
        }
        if let hc = context.coordinator.heightConstraint {
            hc.constant = contentHeight
        } else {
            let hc = contentView.heightAnchor.constraint(equalToConstant: contentHeight)
            hc.isActive = true
            context.coordinator.heightConstraint = hc
        }

        let visibleRect = CGRect(
            x: scrollView.contentOffset.x,
            y: 0,
            width: scrollView.bounds.width,
            height: contentHeight
        )
        let refreshAfterZoom = context.coordinator.shouldRefreshFilmstripAfterZoom
        context.coordinator.shouldRefreshFilmstripAfterZoom = false
        contentView.update(
            snapshot: snapshot.renderSnapshot,
            visibleRect: visibleRect,
            waveformSamples: snapshot.waveformSamples,
            refreshAfterZoom: refreshAfterZoom
        )

        scrollView.contentSize = CGSize(width: width, height: contentHeight)

        if context.coordinator.isTrimmingClip {
            if let frozenOffset = context.coordinator.frozenScrollOffset {
                context.coordinator.isProgrammaticScroll = true
                scrollView.contentOffset.x = frozenOffset
                context.coordinator.publishScrollOffset(frozenOffset)
                context.coordinator.isProgrammaticScroll = false
            }
        } else {
            clampScrollOffsetIfNeeded(scrollView, coordinator: context.coordinator)

            if !context.coordinator.didSetInitialOffset, scrollView.bounds.width > 0 {
                scrollView.contentOffset.x = -inset
                context.coordinator.didSetInitialOffset = true
            } else {
                syncScrollOffsetToPlayhead(
                    scrollView,
                    coordinator: context.coordinator,
                    inset: inset
                )
            }
        }

        TimelineScrollRegistry.sharedScrollView = scrollView
    }

    private static func overlayTextSignature(_ snapshot: TimelineRenderSnapshot) -> String {
        snapshot.textOverlays.map { "\($0.id.uuidString):\($0.text)" }.joined(separator: "|")
    }

    private func syncScrollOffsetToPlayhead(
        _ scrollView: UIScrollView,
        coordinator: Coordinator,
        inset: CGFloat
    ) {
        guard coordinator.activeClipIndex == nil,
              !coordinator.isUserDraggingScroll,
              !scrollView.isTracking,
              !scrollView.isDragging,
              !scrollView.isDecelerating,
              !coordinator.isPinchActive,
              !coordinator.isTrimmingClip else { return }

        let targetOffset = CGFloat(snapshot.playbackTime) * snapshot.renderSnapshot.pixelsPerSecond - inset
        guard abs(scrollView.contentOffset.x - targetOffset) > 0.5 else { return }

        // Coalesce: keep only the latest target and schedule at most one async hop.
        // Defer offset + binding writes out of SwiftUI's updateUIView pass —
        // synchronous contentOffset changes re-enter scrollViewDidScroll and
        // trigger "Modifying state during view update".
        coordinator.pendingTargetOffset = targetOffset
        guard !coordinator.pendingSyncScheduled else { return }
        coordinator.pendingSyncScheduled = true

        DispatchQueue.main.async {
            coordinator.pendingSyncScheduled = false
            let offset = coordinator.pendingTargetOffset
            coordinator.pendingTargetOffset = nil
            guard let offset else { return }
            guard !coordinator.isUserDraggingScroll,
                  !scrollView.isTracking,
                  !scrollView.isDragging,
                  !scrollView.isDecelerating,
                  !coordinator.isPinchActive,
                  !coordinator.isTrimmingClip else { return }
            coordinator.isProgrammaticScroll = true
            scrollView.contentOffset.x = offset
            coordinator.publishScrollOffset(offset)
            coordinator.isProgrammaticScroll = false
        }
    }

    private func clampScrollOffsetIfNeeded(_ scrollView: UIScrollView, coordinator: Coordinator) {
        let pps = snapshot.renderSnapshot.pixelsPerSecond
        guard pps > 0 else { return }

        let inset = scrollView.contentInset.left
        let maxOffset = max(
            CGFloat(snapshot.totalDuration) * pps - inset,
            -inset
        )
        let clampedOffset = min(max(scrollView.contentOffset.x, -inset), maxOffset)
        guard abs(clampedOffset - scrollView.contentOffset.x) > 0.5 else { return }

        coordinator.isProgrammaticScroll = true
        scrollView.contentOffset.x = clampedOffset
        coordinator.publishScrollOffset(clampedOffset)
        coordinator.isProgrammaticScroll = false

        let time = min(
            Double((clampedOffset + inset) / pps),
            snapshot.totalDuration
        )
        // Never call onScroll/seek synchronously from updateUIView.
        let scrollHandler = onScroll
        DispatchQueue.main.async {
            scrollHandler(max(0, time))
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate, TimelineContentViewDelegate {
        var parent: TimelineScrollCoordinator
        weak var contentView: TimelineContentView?
        weak var scrollView: UIScrollView?
        weak var playheadView: TimelinePlayheadOverlayView?
        var clipLongPress: UILongPressGestureRecognizer?
        var didSetInitialOffset = false
        var activeClipIndex: Int?
        /// Clip ID captured at long-press `.began` so `.ended` stays valid if layouts reorder.
        var activeClipID: UUID?
        var isUserDraggingScroll = false
        var isProgrammaticScroll = false
        var isPinchActive = false
        var isTrimmingClip = false
        var frozenScrollOffset: CGFloat?
        var shouldRefreshFilmstripAfterZoom = false
        var shouldRepositionPlayheadAfterTrim = false
        var lastTrimVisualSettleToken: UInt64 = 0
        /// Last snapshot whose layout-affecting fields were applied. When only `contentHeight`
        /// changes (e.g. resize), we skip the expensive `contentView.update()`.
        var lastLayoutSnapshot: TimelineRenderSnapshot?
        var lastWaveformSamples: [String: [Float]] = [:]
        var lastOverlayTextSignature: String = ""
        /// Stored Auto Layout constraints — updated via `.constant` instead of remove/re-add.
        var widthConstraint: NSLayoutConstraint?
        var heightConstraint: NSLayoutConstraint?
        /// Coalesced playhead→scroll sync (at most one pending main.async).
        var pendingTargetOffset: CGFloat?
        var pendingSyncScheduled = false
        /// Bumped on each pinch `.began` so stale momentum/async commits are ignored.
        var pinchGeneration: UInt64 = 0

        private var clipDragActive = false
        private var pressStartLocation: CGPoint = .zero
        private var pinchBasePPS: CGFloat = 1
        private var pinchFocalX: CGFloat = 0
        private var pinchAnchorContentX: CGFloat = 0
        private var pinchVisualScale: CGFloat = 1
        private var momentumDisplayLink: CADisplayLink?
        private var displayLinkTarget: DisplayLinkTarget?
        private var momentumStartScale: CGFloat = 1
        private var momentumTargetScale: CGFloat = 1
        private var momentumStartTime: CFTimeInterval = 0
        private var momentumPinchGeneration: UInt64 = 0
        private let momentumDuration: CFTimeInterval = 0.22
        private let scrollOwnerPinch = "timeline.pinch"
        private let scrollOwnerClipDrag = "timeline.clipDrag"
        private let scrollOwnerTrim = "timeline.trim"

        init(parent: TimelineScrollCoordinator) {
            self.parent = parent
        }

        func publishScrollOffset(_ offset: CGFloat) {
            DispatchQueue.main.async {
                self.parent.scrollOffset = offset
            }
        }

        deinit {
            momentumDisplayLink?.invalidate()
            momentumDisplayLink = nil
            displayLinkTarget = nil
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard !isTrimmingClip else { return }
            isUserDraggingScroll = true
            if activeClipIndex != nil, !clipDragActive {
                resetClipGesture()
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                isUserDraggingScroll = false
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            isUserDraggingScroll = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !clipDragActive else { return }
            guard !isTrimmingClip else { return }
            let offsetX = scrollView.contentOffset.x
            DispatchQueue.main.async { [weak self] in
                self?.parent.scrollOffset = offsetX
            }

            if !isPinchActive, let contentView {
                let visibleRect = CGRect(
                    x: scrollView.contentOffset.x,
                    y: 0,
                    width: scrollView.bounds.width,
                    height: parent.snapshot.renderSnapshot.contentHeight
                )
                contentView.update(
                    snapshot: parent.snapshot.renderSnapshot,
                    visibleRect: visibleRect,
                    waveformSamples: parent.snapshot.waveformSamples,
                    refreshAfterZoom: false
                )
            }

            guard !isProgrammaticScroll else { return }

            let pps = parent.snapshot.renderSnapshot.pixelsPerSecond
            guard pps > 0 else { return }

            let inset = scrollView.contentInset.left
            let maxOffset = max(
                CGFloat(parent.snapshot.totalDuration) * pps - inset,
                -inset
            )
            let clampedOffset = min(max(scrollView.contentOffset.x, -inset), maxOffset)
            if abs(clampedOffset - scrollView.contentOffset.x) > 0.5 {
                isProgrammaticScroll = true
                scrollView.contentOffset.x = clampedOffset
                isProgrammaticScroll = false
            }

            let centerX = clampedOffset + inset
            let time = min(
                Double(centerX / pps),
                parent.snapshot.totalDuration
            )
            let scrollHandler = parent.onScroll
            DispatchQueue.main.async {
                scrollHandler(max(0, time))
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let scrollView, let contentView else { return }

            switch gesture.state {
            case .began:
                pinchGeneration &+= 1
                isPinchActive = true
                contentView.beginPinch()
                // Cancel in-flight momentum and invalidate any stale commitZoom.
                momentumDisplayLink?.invalidate()
                momentumDisplayLink = nil
                displayLinkTarget = nil
                pinchBasePPS = parent.pixelsPerSecond
                pinchVisualScale = 1
                pinchFocalX = gesture.location(in: scrollView).x
                pinchAnchorContentX = (pinchFocalX + scrollView.contentOffset.x) / max(pinchVisualScale, 0.001)
                TimelineScrollRegistry.disableScroll(owner: scrollOwnerPinch)

            case .changed:
                let minScale = EditorTimelineConstants.minPixelsPerSecond / pinchBasePPS
                let maxScale = EditorTimelineConstants.maxPixelsPerSecond / pinchBasePPS
                let clampedScale = min(max(gesture.scale, minScale), maxScale)
                pinchVisualScale = clampedScale
                applyPinchPreview(
                    scale: clampedScale,
                    scrollView: scrollView,
                    contentView: contentView
                )

            case .ended, .cancelled, .failed:
                let minScale = EditorTimelineConstants.minPixelsPerSecond / pinchBasePPS
                let maxScale = EditorTimelineConstants.maxPixelsPerSecond / pinchBasePPS
                var clampedScale = min(max(gesture.scale, minScale), maxScale)

                let velocityBoost = gesture.velocity * 0.08
                clampedScale = min(max(clampedScale + velocityBoost, minScale), maxScale)

                if abs(velocityBoost) > 0.01 {
                    startMomentum(
                        from: clampedScale,
                        velocity: gesture.velocity,
                        minScale: minScale,
                        maxScale: maxScale,
                        scrollView: scrollView,
                        contentView: contentView,
                        generation: pinchGeneration
                    )
                } else {
                    commitZoom(
                        scale: clampedScale,
                        scrollView: scrollView,
                        contentView: contentView,
                        generation: pinchGeneration
                    )
                }

            default:
                break
            }
        }

        private func startMomentum(
            from startScale: CGFloat,
            velocity: CGFloat,
            minScale: CGFloat,
            maxScale: CGFloat,
            scrollView: UIScrollView,
            contentView: TimelineContentView,
            generation: UInt64
        ) {
            momentumStartScale = startScale
            momentumTargetScale = min(max(startScale + velocity * 0.12, minScale), maxScale)
            momentumStartTime = CACurrentMediaTime()
            momentumPinchGeneration = generation

            momentumDisplayLink?.invalidate()
            let target = DisplayLinkTarget()
            target.tickHandler = { [weak self] in
                self?.handleMomentumTick()
            }
            displayLinkTarget = target
            let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.step))
            link.add(to: .main, forMode: .common)
            momentumDisplayLink = link

            self.scrollView = scrollView
            self.contentView = contentView
        }

        private func handleMomentumTick() {
            guard let scrollView, let contentView else {
                momentumDisplayLink?.invalidate()
                momentumDisplayLink = nil
                displayLinkTarget = nil
                return
            }

            // Ignore ticks from a cancelled / superseded pinch.
            guard momentumPinchGeneration == pinchGeneration else {
                momentumDisplayLink?.invalidate()
                momentumDisplayLink = nil
                displayLinkTarget = nil
                return
            }

            let elapsed = CACurrentMediaTime() - momentumStartTime
            let progress = min(1, elapsed / momentumDuration)
            let eased = 1 - pow(1 - progress, 3)
            let currentScale = momentumStartScale + (momentumTargetScale - momentumStartScale) * CGFloat(eased)

            applyPinchPreview(
                scale: currentScale,
                scrollView: scrollView,
                contentView: contentView
            )

            if progress >= 1 {
                momentumDisplayLink?.invalidate()
                momentumDisplayLink = nil
                displayLinkTarget = nil
                commitZoom(
                    scale: momentumTargetScale,
                    scrollView: scrollView,
                    contentView: contentView,
                    generation: momentumPinchGeneration
                )
            }
        }

        private func applyPinchPreview(
            scale: CGFloat,
            scrollView: UIScrollView,
            contentView: TimelineContentView
        ) {
            let visualPPS = pinchBasePPS * scale
            let totalDuration = parent.snapshot.totalDuration
            let previewWidth = min(
                max(CGFloat(totalDuration) * visualPPS, 300),
                EditorTimelineConstants.maxContentWidth
            )

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            let newOffset = pinchAnchorContentX * scale - pinchFocalX
            scrollView.contentOffset.x = newOffset
            publishScrollOffset(newOffset)
            scrollView.contentSize = CGSize(
                width: previewWidth,
                height: parent.snapshot.renderSnapshot.contentHeight
            )

            // Keep the stored width constraint alive — removing it permanently breaks
            // later updateUIView constant writes (anonymous constraint would stick forever).
            if let wc = widthConstraint {
                wc.constant = previewWidth
            } else {
                let wc = contentView.widthAnchor.constraint(equalToConstant: previewWidth)
                wc.isActive = true
                widthConstraint = wc
            }

            let visibleRect = CGRect(
                x: scrollView.contentOffset.x,
                y: 0,
                width: scrollView.bounds.width,
                height: parent.snapshot.renderSnapshot.contentHeight
            )
            contentView.applyPinchPreview(
                visualPixelsPerSecond: visualPPS,
                visibleRect: visibleRect
            )

            CATransaction.commit()
        }

        private func commitZoom(
            scale: CGFloat,
            scrollView: UIScrollView,
            contentView: TimelineContentView,
            generation: UInt64
        ) {
            // Ignore stale commits after a newer pinch `.began`.
            guard generation == pinchGeneration else { return }

            let basePPS = pinchBasePPS
            let anchorX = pinchAnchorContentX
            let focalX = pinchFocalX
            let totalDuration = parent.snapshot.totalDuration

            // Compute finalPPS on main — no background hop (avoids racing a new pinch).
            var finalPPS = basePPS * scale
            if totalDuration > 0 {
                let required = CGFloat(totalDuration) * finalPPS
                if required > EditorTimelineConstants.maxContentWidth {
                    finalPPS = EditorTimelineConstants.maxContentWidth / CGFloat(totalDuration)
                }
            }
            finalPPS = min(
                max(finalPPS, EditorTimelineConstants.minPixelsPerSecond),
                EditorTimelineConstants.maxPixelsPerSecond
            )
            let committedScale = finalPPS / max(basePPS, 0.001)
            let newOffset = anchorX * committedScale - focalX

            guard generation == pinchGeneration else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            isPinchActive = false
            contentView.endPinch()
            TimelineScrollRegistry.enableScroll(owner: scrollOwnerPinch)
            shouldRefreshFilmstripAfterZoom = true
            parent.pixelsPerSecond = finalPPS
            isProgrammaticScroll = true
            scrollView.contentOffset.x = newOffset
            publishScrollOffset(newOffset)
            isProgrammaticScroll = false
            CATransaction.commit()
        }

        @objc func handleClipLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let contentView else { return }
            let location = gesture.location(in: contentView)

            switch gesture.state {
            case .began:
                guard let index = clipIndex(at: location) else { return }
                let layouts = parent.snapshot.renderSnapshot.clipLayouts
                guard index < layouts.count else { return }
                activeClipIndex = index
                activeClipID = layouts[index].clipID
                clipDragActive = false
                pressStartLocation = location
            case .changed:
                guard let index = activeClipIndex else { return }
                if !clipDragActive {
                    let moved = hypot(location.x - pressStartLocation.x, location.y - pressStartLocation.y)
                    if moved > 14 {
                        clipDragActive = true
                        TimelineScrollRegistry.disableScroll(owner: scrollOwnerClipDrag)
                        parent.draggingClipIndex = index
                        parent.clipDragTranslation = 0
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                }
                if clipDragActive {
                    parent.clipDragTranslation = location.x - pressStartLocation.x
                    parent.draggingClipIndex = index
                }
            case .ended, .cancelled, .failed:
                let layouts = parent.snapshot.renderSnapshot.clipLayouts
                if clipDragActive, let sourceIndex = activeClipIndex {
                    guard sourceIndex < layouts.count else {
                        resetClipGesture()
                        break
                    }
                    let layout = layouts[sourceIndex]
                    let centerX = layout.minX + (layout.maxX - layout.minX) / 2 + parent.clipDragTranslation
                    let destination = insertionIndex(forCenterX: centerX, excluding: sourceIndex)
                    parent.onClipDragEnded(sourceIndex, destination)
                } else if let clipID = activeClipID ?? activeClipIndex.flatMap({ index -> UUID? in
                    guard index < layouts.count else { return nil }
                    return layouts[index].clipID
                }) {
                    parent.onClipContextMenu(clipID)
                }
                resetClipGesture()
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let contentView, let scrollView else { return true }
            let point = touch.location(in: contentView)
            guard contentView.shouldDeferScrollGestures(at: point) else { return true }

            if gestureRecognizer === scrollView.panGestureRecognizer || gestureRecognizer === clipLongPress {
                return false
            }
            return true
        }

        private func resetClipGesture() {
            activeClipIndex = nil
            activeClipID = nil
            clipDragActive = false
            TimelineScrollRegistry.enableScroll(owner: scrollOwnerClipDrag)
            parent.draggingClipIndex = nil
            parent.clipDragTranslation = 0
        }

        private func clipIndex(at location: CGPoint) -> Int? {
            parent.snapshot.renderSnapshot.clipLayouts.first(where: {
                location.x >= $0.minX && location.x <= $0.maxX &&
                location.y >= $0.minY && location.y <= $0.maxY
            })?.index
        }

        private func insertionIndex(forCenterX centerX: CGFloat, excluding source: Int) -> Int {
            for layout in parent.snapshot.renderSnapshot.clipLayouts where layout.index != source {
                let mid = (layout.minX + layout.maxX) / 2
                if centerX < mid { return layout.index }
            }
            return parent.snapshot.renderSnapshot.clipLayouts.count
        }

        // MARK: - TimelineContentViewDelegate

        func timelineContentDidSelectClip(_ clipID: UUID) {
            parent.onSelectClip(clipID)
        }

        func timelineContentDidBeginTrim(_ clipID: UUID) {
            isTrimmingClip = true
            frozenScrollOffset = scrollView?.contentOffset.x
            shouldRepositionPlayheadAfterTrim = false
            TimelineScrollRegistry.disableScroll(owner: scrollOwnerTrim)
            clipLongPress?.isEnabled = false
            parent.onTrimBegin()
        }

        func timelineContentDidEndTrim(_ clipID: UUID) {
            isTrimmingClip = false
            frozenScrollOffset = nil
            shouldRepositionPlayheadAfterTrim = true
            TimelineScrollRegistry.enableScroll(owner: scrollOwnerTrim)
            clipLongPress?.isEnabled = true
            parent.onTrimEnd()
        }

        func repositionPlayheadAfterTrimIfNeeded() {
            guard shouldRepositionPlayheadAfterTrim,
                  let scrollView,
                  parent.snapshot.renderSnapshot.pixelsPerSecond > 0 else { return }
            shouldRepositionPlayheadAfterTrim = false

            let inset = scrollView.contentInset.left
            let targetOffset = CGFloat(parent.snapshot.playbackTime) * parent.snapshot.renderSnapshot.pixelsPerSecond - inset
            let maxOffset = max(
                CGFloat(parent.snapshot.totalDuration) * parent.snapshot.renderSnapshot.pixelsPerSecond - inset,
                -inset
            )
            let clampedOffset = min(max(targetOffset, -inset), maxOffset)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            isProgrammaticScroll = true
            scrollView.contentOffset.x = clampedOffset
            publishScrollOffset(clampedOffset)
            isProgrammaticScroll = false
            playheadView?.update(
                currentTime: parent.snapshot.playbackTime,
                totalDuration: parent.snapshot.totalDuration
            )
            CATransaction.commit()
        }

        func timelineContentDidTrimPreview(clipID: UUID, timeRange: CMTimeRange) {
            parent.onTrimPreview(clipID, timeRange)
        }

        func timelineContentDidTrimCommit(clipID: UUID, timeRange: CMTimeRange) {
            parent.onTrimCommit(clipID, timeRange)
        }

        func timelineContentDidTrimCancel(clipID: UUID) {
            parent.onTrimCancel()
        }

        func timelineContentDidToggleMute(clipID: UUID) {
            parent.onToggleMute(clipID)
        }

        func timelineContentDidTapTransition(_ clipID: UUID) {
            // Defer out of the UIKit gesture callback so presenting the sheet
            // doesn't stall the gesture gate / main-thread run loop.
            DispatchQueue.main.async {
                self.parent.onTransitionTap(clipID)
            }
        }

        func timelineContentDidSelectSubtitle(_ id: UUID) {
            parent.onSelectSubtitle(id)
        }

        func timelineContentDidSelectText(_ id: UUID) {
            parent.onSelectText(id)
        }

        func timelineContentDidSelectSticker(_ id: UUID) {
            parent.onSelectSticker(id)
        }

        func timelineContentDidSelectAudio(_ id: UUID) {
            parent.onSelectAudio(id)
        }
    }
}

enum TimelineScrollRegistry {
    static weak var sharedScrollView: UIScrollView?
    private static var scrollDisableOwners: Set<String> = []

    static func disableScroll(owner: String) {
        scrollDisableOwners.insert(owner)
        sharedScrollView?.isScrollEnabled = false
    }

    static func enableScroll(owner: String) {
        scrollDisableOwners.remove(owner)
        if scrollDisableOwners.isEmpty {
            sharedScrollView?.isScrollEnabled = true
        }
    }

    static func reset() {
        scrollDisableOwners.removeAll()
        sharedScrollView?.isScrollEnabled = true
    }
}

final class TimelinePlayheadOverlayView: UIView {
    private let lineView = UIView()
    private let triangleView = UIImageView()
    private let timeLabel = UILabel()
    private var lastDisplayedSecond = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        lineView.backgroundColor = .systemYellow
        lineView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lineView)

        let config = UIImage.SymbolConfiguration(pointSize: 7, weight: .bold)
        triangleView.image = UIImage(systemName: "triangle.fill", withConfiguration: config)?
            .withTintColor(.systemYellow, renderingMode: .alwaysOriginal)
        triangleView.transform = CGAffineTransform(rotationAngle: .pi)
        triangleView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(triangleView)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        timeLabel.textColor = .black
        timeLabel.backgroundColor = .systemYellow
        timeLabel.layer.cornerRadius = 10
        timeLabel.layer.masksToBounds = true
        timeLabel.textAlignment = .center
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeLabel)

        NSLayoutConstraint.activate([
            lineView.centerXAnchor.constraint(equalTo: centerXAnchor),
            lineView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            lineView.bottomAnchor.constraint(equalTo: bottomAnchor),
            lineView.widthAnchor.constraint(equalToConstant: 2),

            triangleView.centerXAnchor.constraint(equalTo: centerXAnchor),
            triangleView.topAnchor.constraint(equalTo: topAnchor),

            timeLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            timeLabel.topAnchor.constraint(equalTo: triangleView.bottomAnchor, constant: 2),
            timeLabel.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(currentTime: TimeInterval, totalDuration: TimeInterval) {
        let second = Int(currentTime.rounded())
        guard second != lastDisplayedSecond || timeLabel.text == nil else { return }
        lastDisplayedSecond = second
        timeLabel.text = "  \(formatTime(currentTime))  \(formatTime(totalDuration))  "
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Weak target for CADisplayLink to avoid retain cycles with Coordinator.
private final class DisplayLinkTarget: NSObject {
    var tickHandler: (() -> Void)?

    @objc func step() {
        tickHandler?()
    }
}
