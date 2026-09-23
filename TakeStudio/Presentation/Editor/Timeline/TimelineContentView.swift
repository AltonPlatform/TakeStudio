import AVFoundation
import UIKit

protocol TimelineContentViewDelegate: AnyObject {
    func timelineContentDidSelectClip(_ clipID: UUID)
    func timelineContentDidBeginTrim(_ clipID: UUID)
    func timelineContentDidEndTrim(_ clipID: UUID)
    func timelineContentDidTrimPreview(clipID: UUID, timeRange: CMTimeRange)
    func timelineContentDidTrimCommit(clipID: UUID, timeRange: CMTimeRange)
    func timelineContentDidTrimCancel(clipID: UUID)
    func timelineContentDidToggleMute(clipID: UUID)
    func timelineContentDidTapTransition(_ clipID: UUID)
    func timelineContentDidSelectSubtitle(_ id: UUID)
    func timelineContentDidSelectText(_ id: UUID)
    func timelineContentDidSelectSticker(_ id: UUID)
    func timelineContentDidSelectAudio(_ id: UUID)
}

final class TimelineContentView: UIView {
    weak var delegate: TimelineContentViewDelegate?

    /// Ruler marker glyphs stay fixed-size; positions follow visual pixelsPerSecond during pinch.
    private let rulerView = TimelineRulerView()
    /// Only tracks are scaled via CALayer transform during active pinch.
    private let tracksContainer = UIView()
    private let reusePool = TimelineCellReusePool()
    private var activeCells: [String: UIView] = [:]
    private var snapshot = TimelineRenderSnapshot(
        clips: [],
        pixelsPerSecond: 60,
        contentWidth: 300,
        contentHeight: 100,
        rulerHeight: 20,
        trackSpacing: 6,
        trackRowHeight: 44,
        videoTrackContentHeight: 44,
        selectedClipID: nil,
        selectedSubtitleID: nil,
        selectedTextID: nil,
        selectedStickerID: nil,
        visibleVisualLayers: [.video],
        detachedTracks: [],
        musicTracks: [],
        sfxTracks: [],
        voiceoverSegments: [],
        subtitleSegments: [],
        textOverlays: [],
        stickerOverlays: [],
        clipLayouts: [],
        totalDuration: 0,
        draggingClipIndex: nil,
        clipDragTranslation: 0,
        rulerInterval: 5,
        rulerSubInterval: 1,
        isClipTrimming: false
    )

    private var waveformSamples: [String: [Float]] = [:]
    private var visibleRect: CGRect = .zero
    private var isPinchActive = false
    private var pinchPreviewPPS: CGFloat?

    private var effectivePixelsPerSecond: CGFloat {
        pinchPreviewPPS ?? snapshot.pixelsPerSecond
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addSubview(rulerView)
        addSubview(tracksContainer)
        tracksContainer.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// During pinch we only anchor scroll — never scale track layers (scaling stretches thumbnails).
    func beginPinch() {
        isPinchActive = true
    }

    func endPinch() {
        isPinchActive = false
        pinchPreviewPPS = nil
    }

    /// Live pinch preview: resize clip frames without re-extracting thumbnails.
    func applyPinchPreview(visualPixelsPerSecond: CGFloat, visibleRect: CGRect) {
        isPinchActive = true
        pinchPreviewPPS = visualPixelsPerSecond
        self.visibleRect = visibleRect

        let previewWidth = min(
            max(CGFloat(snapshot.totalDuration) * visualPixelsPerSecond, 1),
            EditorTimelineConstants.maxContentWidth
        )
        frame.size.width = previewWidth

        let rulerInterval = TimelineRenderSnapshot.rulerInterval(pixelsPerSecond: visualPixelsPerSecond)
        rulerView.frame = CGRect(x: 0, y: 0, width: previewWidth, height: snapshot.rulerHeight)
        rulerView.update(
            totalDuration: snapshot.totalDuration,
            pixelsPerSecond: visualPixelsPerSecond,
            rulerInterval: rulerInterval,
            rulerSubInterval: TimelineRenderSnapshot.rulerSubInterval(for: rulerInterval),
            width: previewWidth
        )

        tracksContainer.frame.size.width = previewWidth

        relayoutVisibleCells(refreshAfterZoom: false)
    }

    func update(
        snapshot: TimelineRenderSnapshot,
        visibleRect: CGRect,
        waveformSamples: [String: [Float]],
        refreshAfterZoom: Bool = false
    ) {
        self.snapshot = snapshot
        self.waveformSamples = waveformSamples
        self.visibleRect = visibleRect
        frame.size = CGSize(width: snapshot.contentWidth, height: snapshot.contentHeight)

        rulerView.frame = CGRect(x: 0, y: 0, width: snapshot.contentWidth, height: snapshot.rulerHeight)
        tracksContainer.frame = CGRect(
            x: 0,
            y: snapshot.rulerHeight,
            width: snapshot.contentWidth,
            height: snapshot.contentHeight - snapshot.rulerHeight
        )

        // Ruler markers reposition once here (gesture end / committed layout), never during pinch.
        if !isPinchActive {
            updateRuler(snapshot: snapshot)
        }

        if !isPinchActive {
            relayoutVisibleCells(refreshAfterZoom: refreshAfterZoom)
        }
    }

    private func updateRuler(snapshot: TimelineRenderSnapshot) {
        if snapshot.isClipTrimming {
            rulerView.setTrimPreviewActive(true)
            rulerView.update(
                totalDuration: snapshot.totalDuration,
                pixelsPerSecond: snapshot.pixelsPerSecond,
                rulerInterval: snapshot.rulerInterval,
                rulerSubInterval: snapshot.rulerSubInterval,
                width: snapshot.contentWidth
            )
        } else {
            rulerView.setTrimPreviewActive(false)
            rulerView.update(
                totalDuration: snapshot.totalDuration,
                pixelsPerSecond: snapshot.pixelsPerSecond,
                rulerInterval: snapshot.rulerInterval,
                rulerSubInterval: snapshot.rulerSubInterval,
                width: snapshot.contentWidth
            )
        }
    }

    private func relayoutVisibleCells(refreshAfterZoom: Bool) {
        let buffer = max(visibleRect.width, 320)
        let bufferedRect = CGRect(
            x: max(0, visibleRect.minX - buffer),
            y: 0,
            width: visibleRect.width + buffer * 2,
            height: snapshot.contentHeight - snapshot.rulerHeight
        )

        var neededIDs = Set<String>()

        layoutVideoTrack(
            in: bufferedRect,
            viewportRect: visibleRect,
            neededIDs: &neededIDs,
            refreshAfterZoom: refreshAfterZoom
        )
        layoutVisualLayers(in: bufferedRect, neededIDs: &neededIDs)
        layoutAudioTracks(in: bufferedRect, neededIDs: &neededIDs)

        recycleCells(notIn: neededIDs)
    }

    private func layoutVideoTrack(
        in rect: CGRect,
        viewportRect: CGRect,
        neededIDs: inout Set<String>,
        refreshAfterZoom: Bool
    ) {
        let yRange = snapshot.videoTrackVerticalRange()
        let trackOriginY = yRange.minY - snapshot.rulerHeight
        var x: CGFloat = 0

        let pps = effectivePixelsPerSecond
        let layoutOnly = pinchPreviewPPS != nil

        for (index, clip) in snapshot.clips.enumerated() {
            let width = max(CGFloat(clip.scaledDuration.seconds) * pps, 1)

            if index > 0 {
                let transitionID = "transition-\(clip.id)"
                let transitionRect = CGRect(
                    x: x - TimelineRenderSnapshot.transitionWidth / 2,
                    y: trackOriginY,
                    width: TimelineRenderSnapshot.transitionWidth,
                    height: snapshot.videoTrackContentHeight
                )
                if rect.intersects(transitionRect) {
                    neededIDs.insert(transitionID)
                    let cell = dequeueTransition(id: transitionID)
                    cell.frame.origin = transitionRect.origin
                    let prevClip = snapshot.clips[index - 1]
                    cell.configure(after: prevClip, height: snapshot.videoTrackContentHeight)
                    cell.onTap = { [weak self] in
                        self?.delegate?.timelineContentDidTapTransition(prevClip.id)
                    }
                }
            }
            let clipRect = CGRect(
                x: x,
                y: trackOriginY,
                width: width,
                height: snapshot.videoTrackContentHeight
            )
            if rect.intersects(clipRect) {
                let cellID = "video-\(clip.id)"
                neededIDs.insert(cellID)

                let cell = dequeueVideoClip(id: cellID)
                var frame = clipRect
                if snapshot.draggingClipIndex == index {
                    frame.origin.x += snapshot.clipDragTranslation
                }

                let waveform = waveformSamples[clip.sourceURL.path]
                let clipXRange = { (intersection: CGRect) -> ClosedRange<CGFloat>? in
                    guard width > 0, intersection.width > 0 else { return nil }
                    let lower = max(0, intersection.minX - clipRect.minX)
                    let upper = min(width, intersection.maxX - clipRect.minX)
                    guard upper > lower else { return nil }
                    return lower...upper
                }
                let prefetchClipXRange = clipXRange(clipRect.intersection(rect))
                let priorityClipXRange = clipXRange(clipRect.intersection(viewportRect))

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if cell.shouldPreserveLayoutFrame {
                    var preserved = cell.frame
                    preserved.origin = frame.origin
                    cell.frame = preserved
                } else {
                    cell.frame = frame
                }
                cell.configure(
                    clip: clip,
                    pixelsPerSecond: pps,
                    isSelected: snapshot.selectedClipID == clip.id,
                    isDragging: snapshot.draggingClipIndex == index,
                    waveformSamples: waveform,
                    prefetchClipXRange: prefetchClipXRange,
                    priorityClipXRange: priorityClipXRange,
                    refreshAfterZoom: refreshAfterZoom,
                    layoutOnly: layoutOnly
                )
                CATransaction.commit()
                cell.delegate = self
            }
            x += width
        }
    }

    private func layoutVisualLayers(in rect: CGRect, neededIDs: inout Set<String>) {
        let pps = effectivePixelsPerSecond
        for layer in snapshot.visibleVisualLayers where layer != .video {
            let y = snapshot.trackY(for: layer) - snapshot.rulerHeight
            switch layer {
            case .subtitles:
                for segment in snapshot.subtitleSegments {
                    let x = CGFloat(segment.timeRange.start.seconds) * pps
                    let width = max(CGFloat(segment.timeRange.duration.seconds) * pps, 40)
                    let segmentRect = CGRect(x: x, y: y + 8, width: width, height: 28)
                    guard rect.intersects(segmentRect) else { continue }
                    let cellID = "subtitle-\(segment.id)"
                    neededIDs.insert(cellID)
                    let cell = dequeueSegment(id: cellID)
                    cell.frame = segmentRect
                    let color: UIColor = snapshot.selectedSubtitleID == segment.id
                        ? .systemCyan.withAlphaComponent(0.7)
                        : .systemBlue.withAlphaComponent(0.55)
                    cell.configure(label: segment.text, width: width, color: color)
                    cell.onTap = { [weak self] in
                        self?.delegate?.timelineContentDidSelectSubtitle(segment.id)
                    }
                }
            case .textOverlays:
                for overlay in snapshot.textOverlays {
                    let x = CGFloat(overlay.timeRange.start.seconds) * pps
                    let width = max(CGFloat(overlay.timeRange.duration.seconds) * pps, 40)
                    let segmentRect = CGRect(x: x, y: y + 8, width: width, height: 28)
                    guard rect.intersects(segmentRect) else { continue }
                    let cellID = "text-\(overlay.id)"
                    neededIDs.insert(cellID)
                    let cell = dequeueSegment(id: cellID)
                    cell.frame = segmentRect
                    cell.configure(
                        label: overlay.text,
                        width: width,
                        color: .systemPurple.withAlphaComponent(0.55)
                    )
                    cell.onTap = { [weak self] in
                        self?.delegate?.timelineContentDidSelectText(overlay.id)
                    }
                }
            case .stickers:
                for overlay in snapshot.stickerOverlays {
                    let x = CGFloat(overlay.timeRange.start.seconds) * pps
                    let width = max(CGFloat(overlay.timeRange.duration.seconds) * pps, 40)
                    let segmentRect = CGRect(x: x, y: y + 8, width: width, height: 28)
                    guard rect.intersects(segmentRect) else { continue }
                    let cellID = "sticker-\(overlay.id)"
                    neededIDs.insert(cellID)
                    let cell = dequeueSegment(id: cellID)
                    cell.frame = segmentRect
                    cell.configure(
                        label: overlay.emoji ?? overlay.imageURL?.lastPathComponent ?? "Sticker",
                        width: width,
                        color: .systemOrange.withAlphaComponent(0.45)
                    )
                    cell.onTap = { [weak self] in
                        self?.delegate?.timelineContentDidSelectSticker(overlay.id)
                    }
                }
            case .video:
                break
            }
        }
    }

    private func layoutAudioTracks(in rect: CGRect, neededIDs: inout Set<String>) {
        let pps = effectivePixelsPerSecond
        var y = snapshot.audioTrackStartY() - snapshot.rulerHeight

        if let track = snapshot.detachedTracks.first {
            let x = CGFloat(track.startTime.seconds) * pps
            let width = max(CGFloat(track.timeRange.duration.seconds) * pps, 24)
            let trackRect = CGRect(x: x, y: y + 4, width: width, height: 36)
            if rect.intersects(trackRect) {
                let cellID = "audio-detached-\(track.id)"
                neededIDs.insert(cellID)
                let cell = dequeueSegment(id: cellID)
                cell.frame = trackRect
                cell.configure(label: track.title, width: width, color: .systemOrange.withAlphaComponent(0.55))
                let trackID = track.id
                cell.onTap = { [weak self] in
                    self?.delegate?.timelineContentDidSelectAudio(trackID)
                }
            }
            y += snapshot.trackRowHeight + snapshot.trackSpacing
        }

        if let track = snapshot.musicTracks.first {
            let x = CGFloat(track.startTime.seconds) * pps
            let width = max(CGFloat(track.timeRange.duration.seconds) * pps, 24)
            let trackRect = CGRect(x: x, y: y + 4, width: width, height: 36)
            if rect.intersects(trackRect) {
                let cellID = "audio-music-\(track.id)"
                neededIDs.insert(cellID)
                let cell = dequeueSegment(id: cellID)
                cell.frame = trackRect
                cell.configure(label: track.title, width: width, color: .systemGreen.withAlphaComponent(0.55))
                let trackID = track.id
                cell.onTap = { [weak self] in
                    self?.delegate?.timelineContentDidSelectAudio(trackID)
                }
            }
            y += snapshot.trackRowHeight + snapshot.trackSpacing
        }

        for track in snapshot.sfxTracks {
            let x = CGFloat(track.startTime.seconds) * pps
            let width = max(CGFloat(track.timeRange.duration.seconds) * pps, 24)
            let trackRect = CGRect(x: x, y: y + 4, width: width, height: 36)
            guard rect.intersects(trackRect) else {
                y += snapshot.trackRowHeight + snapshot.trackSpacing
                continue
            }
            let cellID = "audio-sfx-\(track.id)"
            neededIDs.insert(cellID)
            let cell = dequeueSegment(id: cellID)
            cell.frame = trackRect
            cell.configure(label: track.title, width: width, color: .systemPurple.withAlphaComponent(0.55))
            let trackID = track.id
            cell.onTap = { [weak self] in
                self?.delegate?.timelineContentDidSelectAudio(trackID)
            }
            y += snapshot.trackRowHeight + snapshot.trackSpacing
        }

        for segment in snapshot.voiceoverSegments {
            let x = CGFloat(segment.startTime.seconds) * pps
            let width = max(CGFloat(segment.duration.seconds) * pps, 24)
            let trackRect = CGRect(x: x, y: y + 4, width: width, height: 36)
            guard rect.intersects(trackRect) else { continue }
            let cellID = "voiceover-\(segment.id)"
            neededIDs.insert(cellID)
            let cell = dequeueSegment(id: cellID)
            cell.frame = trackRect
            cell.configure(label: "VO", width: width, color: .systemPink.withAlphaComponent(0.55))
        }
    }

    private func dequeueVideoClip(id: String) -> TimelineClipCell {
        if let existing = activeCells[id] as? TimelineClipCell {
            return existing
        }
        let cell = reusePool.dequeue(kind: TimelineCellKind.videoClip) { TimelineClipCell() } as! TimelineClipCell
        activeCells[id] = cell
        tracksContainer.addSubview(cell)
        return cell
    }

    private func dequeueTransition(id: String) -> TimelineTransitionCell {
        if let existing = activeCells[id] as? TimelineTransitionCell {
            return existing
        }
        let cell = reusePool.dequeue(kind: TimelineCellKind.transition) { TimelineTransitionCell() } as! TimelineTransitionCell
        activeCells[id] = cell
        tracksContainer.addSubview(cell)
        return cell
    }

    private func dequeueSegment(id: String) -> TimelineSegmentCell {
        if let existing = activeCells[id] as? TimelineSegmentCell {
            return existing
        }
        let cell = reusePool.dequeue(kind: TimelineCellKind.segment) { TimelineSegmentCell() } as! TimelineSegmentCell
        activeCells[id] = cell
        tracksContainer.addSubview(cell)
        return cell
    }

    /// Returns true when the touch targets a clip trim handle (scroll should defer).
    func shouldDeferScrollGestures(at contentPoint: CGPoint) -> Bool {
        for view in activeCells.values {
            guard let cell = view as? TimelineClipCell else { continue }
            if cell.containsTrimHandle(at: contentPoint) {
                return true
            }
        }
        return false
    }

    private func recycleCells(notIn neededIDs: Set<String>) {
        let staleIDs = activeCells.keys.filter { !neededIDs.contains($0) }
        for id in staleIDs {
            guard let cell = activeCells.removeValue(forKey: id) else { continue }
            if let clipCell = cell as? TimelineClipCell {
                clipCell.prepareForReuse()
                reusePool.recycle(clipCell, kind: TimelineCellKind.videoClip)
            } else if let transitionCell = cell as? TimelineTransitionCell {
                transitionCell.prepareForReuse()
                reusePool.recycle(transitionCell, kind: TimelineCellKind.transition)
            } else if let segmentCell = cell as? TimelineSegmentCell {
                segmentCell.prepareForReuse()
                reusePool.recycle(segmentCell, kind: TimelineCellKind.segment)
            }
        }
    }
}

extension TimelineContentView: TimelineClipCellDelegate {
    func clipCellDidSelect(_ clipID: UUID) {
        delegate?.timelineContentDidSelectClip(clipID)
    }

    func clipCellDidBeginTrim(_ clipID: UUID) {
        delegate?.timelineContentDidBeginTrim(clipID)
    }

    func clipCellDidEndTrim(_ clipID: UUID) {
        delegate?.timelineContentDidEndTrim(clipID)
    }

    func clipCellDidTrimPreview(_ clipID: UUID, timeRange: CMTimeRange) {
        delegate?.timelineContentDidTrimPreview(clipID: clipID, timeRange: timeRange)
    }

    func clipCellDidTrimCommit(_ clipID: UUID, timeRange: CMTimeRange) {
        delegate?.timelineContentDidTrimCommit(clipID: clipID, timeRange: timeRange)
    }

    func clipCellDidTrimCancel(_ clipID: UUID) {
        delegate?.timelineContentDidTrimCancel(clipID: clipID)
    }

    func clipCellDidToggleMute(_ clipID: UUID) {
        delegate?.timelineContentDidToggleMute(clipID: clipID)
    }

    func clipCellDidTapTransition(_ clipID: UUID) {
        delegate?.timelineContentDidTapTransition(clipID)
    }
}
