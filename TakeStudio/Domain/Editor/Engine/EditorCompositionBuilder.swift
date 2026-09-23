import AVFoundation
import CoreImage
import UIKit

enum EditorCompositionError: LocalizedError {
    case noClips
    case buildFailed

    var errorDescription: String? {
        switch self {
        case .noClips: return "No video clips to compose."
        case .buildFailed: return "Failed to build video composition."
        }
    }
}

struct EditorCompositionResult {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition?
    let audioMix: AVAudioMix?
    let renderSize: CGSize
    let totalDuration: CMTime
    let clipRanges: [(clipID: UUID, compositionRange: CMTimeRange)]
    /// Maps embedded clip audio track IDs to their owning clip (for live `updateAudioMix`).
    let clipAudioTrackIDs: [CMPersistentTrackID: UUID]
}

private struct ClipPlacement {
    let clipID: UUID
    let trackID: CMPersistentTrackID
    let range: CMTimeRange
    let clip: VideoClip
    /// Orient + scale source frames into the portrait render canvas.
    let sourceTransform: CGAffineTransform
    let audioTrackID: CMPersistentTrackID?
}

final class EditorCompositionBuilder {
    /// Preview renders text/stickers/subtitles in SwiftUI; export bakes them into the compositor.
    /// - Parameter targetLongEdge: For `.export`, optional max(width, height) so transforms
    ///   are built for the final canvas (avoids post-hoc `renderSize` mutation in ExportEngine).
    func build(
        from project: EditorProject,
        quality: EditorBuildQuality = .export,
        bakeOverlays: Bool? = nil,
        targetLongEdge: CGFloat? = nil
    ) async throws -> EditorCompositionResult {
        let shouldBakeOverlays = bakeOverlays ?? (quality == .export)
        guard !project.clips.isEmpty else { throw EditorCompositionError.noClips }

        project.updateCompositionStartTimes()
        project.normalizeLayerOrder()

        let composition = AVMutableComposition()
        guard
            let videoTrack0 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let videoTrack1 = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw EditorCompositionError.buildFailed
        }

        let renderSize = standardRenderSize(
            for: project.aspectRatio,
            quality: quality,
            targetLongEdge: targetLongEdge
        )
        var placements: [ClipPlacement] = []
        var timelineEnd = CMTime.zero

        for (index, clip) in project.clips.enumerated() {
            let asset = EditorAVAssetCache.shared.asset(for: clip.sourceURL)
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else { continue }

            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }

            let sourceTrackRange = try await sourceVideo.load(.timeRange)
            guard let insertRange = clampedInsertRange(requested: clip.timeRange, source: sourceTrackRange),
                  insertRange.duration.seconds > 0.01 else { continue }

            let naturalSize = try await sourceVideo.load(.naturalSize)
            let preferredTransform = try await sourceVideo.load(.preferredTransform)
            let sourceTransform = portraitFitTransform(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                renderSize: renderSize
            )

            let targetTrack = index % 2 == 0 ? videoTrack0 : videoTrack1
            var insertAt = timelineEnd

            // Clamp transition so short clips / speed>1 never cause overlapping inserts on the same track.
            let clampedTransitionDuration: Double = {
                guard index > 0 else { return 0 }
                let previous = project.clips[index - 1]
                guard let transition = previous.transition, transition != .cut else { return 0 }
                let maxOverlap = min(previous.scaledDuration.seconds, insertRange.duration.seconds / max(clip.speed, 0.01))
                return min(max(previous.transitionDuration, 0), max(maxOverlap, 0))
            }()

            if clampedTransitionDuration > 0 {
                let half = CMTime(seconds: clampedTransitionDuration / 2, preferredTimescale: 600)
                insertAt = CMTimeSubtract(timelineEnd, half)
                // Never insert before the end of the previous segment on this same track.
                if let lastSameTrack = placements.last(where: { $0.trackID == targetTrack.trackID }) {
                    insertAt = CMTimeMaximum(insertAt, lastSameTrack.range.end)
                }
                // Persist clamped duration onto the previous (outgoing) placement.
                if !placements.isEmpty {
                    let prev = placements[placements.count - 1]
                    var prevClip = prev.clip
                    prevClip.transitionDuration = clampedTransitionDuration
                    placements[placements.count - 1] = ClipPlacement(
                        clipID: prev.clipID,
                        trackID: prev.trackID,
                        range: prev.range,
                        clip: prevClip,
                        sourceTransform: prev.sourceTransform,
                        audioTrackID: prev.audioTrackID
                    )
                }
            }

            try targetTrack.insertTimeRange(insertRange, of: sourceVideo, at: insertAt)

            var clipAudioTrackID: CMPersistentTrackID?
            if !clip.isMuted && !clip.hasDetachedAudio {
                // Only add an audio track after confirming source audio exists — empty tracks
                // would steal slots in positional audio-mix matching.
                if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
                   let audioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                   ) {
                    try? audioTrack.insertTimeRange(insertRange, of: sourceAudio, at: insertAt)
                    clipAudioTrackID = audioTrack.trackID
                }
            }

            // Keep source timescale when speed == 1 to avoid a trailing instruction gap.
            let scaledDuration: CMTime
            if abs(clip.speed - 1.0) < 0.001 {
                scaledDuration = insertRange.duration
            } else {
                scaledDuration = CMTime(
                    seconds: insertRange.duration.seconds / max(clip.speed, 0.01),
                    preferredTimescale: 600
                )
                let targetRange = CMTimeRange(start: insertAt, duration: insertRange.duration)
                targetTrack.scaleTimeRange(targetRange, toDuration: scaledDuration)
                if let clipAudioTrackID,
                   let audioTrack = composition.track(withTrackID: clipAudioTrackID) {
                    audioTrack.scaleTimeRange(targetRange, toDuration: scaledDuration)
                }
            }

            let placementRange = CMTimeRange(start: insertAt, duration: scaledDuration)
            placements.append(
                ClipPlacement(
                    clipID: clip.id,
                    trackID: targetTrack.trackID,
                    range: placementRange,
                    clip: clip,
                    sourceTransform: sourceTransform,
                    audioTrackID: clipAudioTrackID
                )
            )

            let clipEnd = CMTimeAdd(insertAt, scaledDuration)
            let outgoingClamped: Double = {
                guard let transition = clip.transition, transition != .cut, index < project.clips.count - 1 else { return 0 }
                let next = project.clips[index + 1]
                let nextScaled = next.scaledDuration.seconds
                let maxOverlap = min(scaledDuration.seconds, nextScaled)
                return min(max(clip.transitionDuration, 0), max(maxOverlap, 0))
            }()
            if outgoingClamped > 0 {
                timelineEnd = CMTimeSubtract(
                    clipEnd,
                    CMTime(seconds: outgoingClamped / 2, preferredTimescale: 600)
                )
                let last = placements[placements.count - 1]
                var lastClip = last.clip
                lastClip.transitionDuration = outgoingClamped
                placements[placements.count - 1] = ClipPlacement(
                    clipID: last.clipID,
                    trackID: last.trackID,
                    range: last.range,
                    clip: lastClip,
                    sourceTransform: last.sourceTransform,
                    audioTrackID: last.audioTrackID
                )
            } else {
                timelineEnd = clipEnd
            }
        }

        guard !placements.isEmpty, CMTimeCompare(timelineEnd, .zero) > 0 else {
            throw EditorCompositionError.buildFailed
        }

        for track in project.audioTracks {
            let asset = EditorAVAssetCache.shared.asset(for: track.sourceURL)
            guard
                let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
                let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
            else { continue }

            let sourceDuration = track.timeRange.duration
            var insertAt = track.startTime
            var remaining = timelineEnd
            if track.isLooping {
                while CMTimeCompare(remaining, .zero) > 0 {
                    let chunk = CMTimeMinimum(sourceDuration, remaining)
                    try audioTrack.insertTimeRange(
                        CMTimeRange(start: track.timeRange.start, duration: chunk),
                        of: sourceAudio,
                        at: insertAt
                    )
                    remaining = CMTimeSubtract(remaining, chunk)
                    insertAt = CMTimeAdd(insertAt, chunk)
                }
            } else {
                try audioTrack.insertTimeRange(track.timeRange, of: sourceAudio, at: track.startTime)
                // Detached clip audio must respect the source clip speed.
                if track.isDetachedFromVideo,
                   let clip = project.clips.first(where: {
                       $0.sourceURL == track.sourceURL && $0.hasDetachedAudio
                   }),
                   clip.speed != 1.0 {
                    let insertDuration = track.timeRange.duration
                    let scaled = CMTime(
                        seconds: insertDuration.seconds / max(clip.speed, 0.01),
                        preferredTimescale: 600
                    )
                    audioTrack.scaleTimeRange(
                        CMTimeRange(start: track.startTime, duration: insertDuration),
                        toDuration: scaled
                    )
                }
            }
        }

        if let voiceover = project.voiceoverTrack {
            for segment in voiceover.segments {
                let asset = EditorAVAssetCache.shared.asset(for: segment.fileURL)
                guard
                    let voiceTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
                    let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
                else { continue }
                let range = CMTimeRange(start: .zero, duration: segment.duration)
                try voiceTrack.insertTimeRange(range, of: sourceAudio, at: segment.startTime)
            }
        }

        let clipRanges = placements.map { ($0.clipID, $0.range) }
        let needsCustomCompositor = EditorProject.requiresCustomCompositor(for: project, bakeOverlays: shouldBakeOverlays)
        // Prefer actual track media end so instructions tile the full composition without a trailing hole.
        let finalDuration = CMTimeMaximum(timelineEnd, composition.duration)

        let videoComposition: AVMutableVideoComposition?
        if needsCustomCompositor {
            let compositorState = EditorCompositorState(
                clips: project.clips,
                clipRanges: clipRanges,
                globalFilterIDs: project.globalFilterIDs,
                globalColorAdjustments: project.globalColorAdjustments,
                textOverlays: project.textOverlays,
                stickerOverlays: project.stickerOverlays,
                subtitleTrack: project.subtitleTrack,
                layerOrder: project.layerOrder,
                renderSize: renderSize
            )
            EditorCompositorContext.setState(compositorState)

            videoComposition = makeCustomVideoComposition(
                placements: placements,
                totalDuration: finalDuration,
                renderSize: renderSize,
                compositorState: compositorState
            )
        } else {
            EditorCompositorContext.setState(nil)
            videoComposition = makePassthroughVideoComposition(
                composition: composition,
                placements: placements,
                totalDuration: finalDuration,
                renderSize: renderSize
            )
        }

        let clipAudioTrackIDs: [CMPersistentTrackID: UUID] = Dictionary(
            uniqueKeysWithValues: placements.compactMap { placement -> (CMPersistentTrackID, UUID)? in
                guard let audioTrackID = placement.audioTrackID else { return nil }
                return (audioTrackID, placement.clipID)
            }
        )
        let audioMix = makeAudioMix(
            composition: composition,
            project: project,
            clipAudioTrackIDs: clipAudioTrackIDs
        )

        return EditorCompositionResult(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            renderSize: renderSize,
            totalDuration: finalDuration,
            clipRanges: clipRanges,
            clipAudioTrackIDs: clipAudioTrackIDs
        )
    }

    private func makePassthroughVideoComposition(
        composition: AVMutableComposition,
        placements: [ClipPlacement],
        totalDuration: CMTime,
        renderSize: CGSize
    ) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let sorted = instructionBoundaries(placements: placements, totalDuration: totalDuration, includeOnlyFade: true)
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for index in 0..<(sorted.count - 1) {
            let start = sorted[index]
            let end = sorted[index + 1]
            guard CMTimeCompare(end, start) > 0 else { continue }

            let range = CMTimeRange(start: start, end: end)
            let midpoint = CMTimeAdd(start, CMTimeMultiplyByFloat64(range.duration, multiplier: 0.5))

            let active = placements.filter { CMTimeRangeContainsTime($0.range, time: midpoint) }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = range
            if active.isEmpty {
                // Prefer extending coverage with a silent layer from any track over an empty
                // instruction — empty layer lists make some AVPlayerItems fail after Split.
                if let fallback = placements.last,
                   let track = composition.track(withTrackID: fallback.trackID) {
                    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                    layer.setTransform(fallback.sourceTransform, at: .zero)
                    layer.setOpacity(0, at: range.start)
                    instruction.layerInstructions = [layer]
                } else {
                    instruction.layerInstructions = []
                }
            } else {
                instruction.layerInstructions = active.compactMap { placement in
                    guard let track = composition.track(withTrackID: placement.trackID) else { return nil }
                    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                    layer.setTransform(placement.sourceTransform, at: .zero)
                    applyFadeOpacityIfNeeded(
                        to: layer,
                        placement: placement,
                        placements: placements,
                        instructionRange: range,
                        midpoint: midpoint
                    )
                    return layer
                }
            }
            instructions.append(instruction)
        }

        videoComposition.instructions = instructions
        return videoComposition
    }

    /// Quantized CMTime boundaries. Uses `totalDuration.timescale` (composition media timescale)
    /// so the last instruction ends on the exact composition duration — hardcoding 600 after
    /// Split left a gap/overflow vs. source-timescale tracks and AVFoundation rejected the item.
    private func instructionBoundaries(
        placements: [ClipPlacement],
        totalDuration: CMTime,
        includeOnlyFade: Bool
    ) -> [CMTime] {
        let timescale: CMTimeScale = totalDuration.timescale > 0 ? totalDuration.timescale : 600
        var times = Set<CMTimeValue>()

        func insert(_ time: CMTime) {
            let quantized = CMTimeConvertScale(time, timescale: timescale, method: .default)
            guard quantized.isValid, !quantized.isIndefinite else { return }
            times.insert(quantized.value)
        }

        insert(.zero)
        insert(totalDuration)
        for placement in placements {
            insert(placement.range.start)
            insert(placement.range.end)
            if let transition = placement.clip.transition {
                let include = includeOnlyFade ? (transition == .fade) : (transition != .cut)
                if include {
                    let transitionStart = CMTimeSubtract(
                        placement.range.end,
                        CMTime(seconds: placement.clip.transitionDuration, preferredTimescale: timescale)
                    )
                    insert(CMTimeMaximum(placement.range.start, transitionStart))
                }
            }
        }

        var sorted = times.sorted().map { CMTime(value: $0, timescale: timescale) }
        // Force exact endpoints so instructions tile [0, composition.duration] with no hole.
        if !sorted.isEmpty {
            sorted[0] = .zero
            sorted[sorted.count - 1] = totalDuration
        }
        return sorted
    }

    private func applyFadeOpacityIfNeeded(
        to layer: AVMutableVideoCompositionLayerInstruction,
        placement: ClipPlacement,
        placements: [ClipPlacement],
        instructionRange: CMTimeRange,
        midpoint: CMTime
    ) {
        guard let index = placements.firstIndex(where: { $0.clipID == placement.clipID }) else {
            layer.setOpacity(1, at: instructionRange.start)
            return
        }

        // Outgoing clip fading out — only inside the transition window.
        if index + 1 < placements.count,
           (placements[index].clip.transition ?? .cut) == .fade {
            let outgoing = placements[index]
            let (transitionStart, transitionEnd) = transitionWindow(
                rangeEnd: outgoing.range.end,
                duration: outgoing.clip.transitionDuration
            )
            if midpoint >= transitionStart && midpoint < transitionEnd {
                let (from, to) = interpolatedOpacity(
                    from: 1, to: 0,
                    transitionStart: transitionStart,
                    transitionEnd: transitionEnd,
                    instructionRange: instructionRange
                )
                layer.setOpacityRamp(fromStartOpacity: from, toEndOpacity: to, timeRange: instructionRange)
                return
            }
        }

        // Incoming clip fading in (previous clip owns the fade) — only inside the window.
        if index > 0,
           (placements[index - 1].clip.transition ?? .cut) == .fade {
            let previous = placements[index - 1]
            let (transitionStart, transitionEnd) = transitionWindow(
                rangeEnd: previous.range.end,
                duration: previous.clip.transitionDuration
            )
            if midpoint >= transitionStart && midpoint < transitionEnd {
                let (from, to) = interpolatedOpacity(
                    from: 0, to: 1,
                    transitionStart: transitionStart,
                    transitionEnd: transitionEnd,
                    instructionRange: instructionRange
                )
                layer.setOpacityRamp(fromStartOpacity: from, toEndOpacity: to, timeRange: instructionRange)
                return
            }
        }

        layer.setOpacity(1, at: instructionRange.start)
    }

    private func transitionWindow(rangeEnd: CMTime, duration: Double) -> (CMTime, CMTime) {
        let timescale: CMTimeScale = rangeEnd.timescale > 0 ? rangeEnd.timescale : 600
        let start = CMTimeSubtract(rangeEnd, CMTime(seconds: duration, preferredTimescale: timescale))
        return (start, rangeEnd)
    }

    private func interpolatedOpacity(
        from startOpacity: Float,
        to endOpacity: Float,
        transitionStart: CMTime,
        transitionEnd: CMTime,
        instructionRange: CMTimeRange
    ) -> (Float, Float) {
        let window = CMTimeSubtract(transitionEnd, transitionStart).seconds
        guard window > 0 else { return (endOpacity, endOpacity) }
        let startProgress = min(max((instructionRange.start.seconds - transitionStart.seconds) / window, 0), 1)
        let endProgress = min(max((instructionRange.end.seconds - transitionStart.seconds) / window, 0), 1)
        let from = startOpacity + (endOpacity - startOpacity) * Float(startProgress)
        let to = startOpacity + (endOpacity - startOpacity) * Float(endProgress)
        return (from, to)
    }

    private func makeCustomVideoComposition(
        placements: [ClipPlacement],
        totalDuration: CMTime,
        renderSize: CGSize,
        compositorState: EditorCompositorState
    ) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.customVideoCompositorClass = EditorVideoCompositor.self

        let sorted = instructionBoundaries(placements: placements, totalDuration: totalDuration, includeOnlyFade: false)
        var instructions: [EditorCompositionInstruction] = []

        for index in 0..<(sorted.count - 1) {
            let start = sorted[index]
            let end = sorted[index + 1]
            guard CMTimeCompare(end, start) > 0 else { continue }

            let range = CMTimeRange(start: start, end: end)
            let midpoint = CMTimeAdd(start, CMTimeMultiplyByFloat64(range.duration, multiplier: 0.5))
            let active = placements.filter { placement in
                CMTimeRangeContainsTime(placement.range, time: midpoint)
            }

            let instruction = EditorCompositionInstruction()
            instruction.timeRange = range
            instruction.containsTweening = active.count > 1
            instruction.compositorState = compositorState

            let layersSource: [ClipPlacement]
            if active.isEmpty, let fallback = placements.last {
                layersSource = [fallback]
            } else {
                layersSource = active
            }
            instruction.requiredSourceTrackIDs = layersSource.map { NSNumber(value: $0.trackID) as NSValue }

            // `active` is chronological (outgoing, then incoming). The custom compositor
            // draws later layers over earlier ones AFTER reversing this list, so outgoing
            // ends up on top during the transition (required for fade/slide).
            instruction.layerInstructions = layersSource.map { placement in
                let opacity = transitionOpacity(
                    for: placement,
                    placements: placements,
                    at: midpoint,
                    renderSize: renderSize
                )
                return EditorLayerInstruction(
                    trackID: placement.trackID,
                    clipID: placement.clipID,
                    transform: transitionTransform(
                        for: placement,
                        at: midpoint,
                        renderSize: renderSize
                    ),
                    opacity: opacity
                )
            }

            instructions.append(instruction)
        }

        composition.instructions = instructions
        return composition
    }

    private func transitionOpacity(
        for placement: ClipPlacement,
        placements: [ClipPlacement],
        at time: CMTime,
        renderSize: CGSize
    ) -> Float {
        guard let index = placements.firstIndex(where: { $0.clipID == placement.clipID }) else {
            return 1
        }

        // Outgoing: this placement owns a non-cut transition into the next clip.
        if index + 1 < placements.count,
           let transition = placements[index].clip.transition,
           transition != .cut {
            let outgoing = placements[index]
            let (transitionStart, transitionEnd) = transitionWindow(
                rangeEnd: outgoing.range.end,
                duration: outgoing.clip.transitionDuration
            )
            if time >= transitionStart && time < transitionEnd {
                let progress = min(
                    max((time.seconds - transitionStart.seconds) / max(outgoing.clip.transitionDuration, 0.001), 0),
                    1
                )
                return Float(1 - progress)
            }
        }

        // Incoming: previous placement owns a transition into this clip.
        if index > 0,
           let transition = placements[index - 1].clip.transition,
           transition != .cut {
            let previous = placements[index - 1]
            let (transitionStart, transitionEnd) = transitionWindow(
                rangeEnd: previous.range.end,
                duration: previous.clip.transitionDuration
            )
            if time >= transitionStart && time < transitionEnd {
                let progress = min(
                    max((time.seconds - transitionStart.seconds) / max(previous.clip.transitionDuration, 0.001), 0),
                    1
                )
                return Float(progress)
            }
        }

        return 1
    }

    private func transitionTransform(
        for placement: ClipPlacement,
        at time: CMTime,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let base = placement.sourceTransform

        guard let transition = placement.clip.transition, transition != .cut else {
            return base
        }

        let (transitionStart, _) = transitionWindow(
            rangeEnd: placement.range.end,
            duration: placement.clip.transitionDuration
        )
        guard time >= transitionStart else { return base }

        let progress = min(
            max((time.seconds - transitionStart.seconds) / placement.clip.transitionDuration, 0),
            1
        )

        let effectTransform: CGAffineTransform
        switch transition {
        case .cut, .fade:
            effectTransform = .identity
        case .slideLeft:
            effectTransform = CGAffineTransform(translationX: -renderSize.width * progress, y: 0)
        case .slideRight:
            effectTransform = CGAffineTransform(translationX: renderSize.width * progress, y: 0)
        case .slideUp:
            effectTransform = CGAffineTransform(translationX: 0, y: renderSize.height * progress)
        case .slideDown:
            effectTransform = CGAffineTransform(translationX: 0, y: -renderSize.height * progress)
        case .zoomIn:
            let scale = 1 + CGFloat(progress) * 0.3
            effectTransform = CGAffineTransform(scaleX: scale, y: scale)
        case .zoomOut:
            let scale = 1 - CGFloat(progress) * 0.3
            effectTransform = CGAffineTransform(scaleX: scale, y: scale)
        }

        return base.concatenating(effectTransform)
    }

    func makeAudioMix(
        composition: AVComposition,
        project: EditorProject,
        clipAudioTrackIDs: [CMPersistentTrackID: UUID] = [:]
    ) -> AVAudioMix? {
        let audioTracks = composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return nil }

        let clipByID = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.id, $0) })
        let embeddedClips = project.clips.filter { !$0.isMuted && !$0.hasDetachedAudio }
        var inputParameters: [AVAudioMixInputParameters] = []
        var embeddedClipIndex = 0
        var projectAudioIndex = 0
        var voiceoverSegmentIndex = 0

        for track in audioTracks {
            let params = AVMutableAudioMixInputParameters(track: track)
            var volume: Float = 1.0
            var fadeIn = false
            var fadeOut = false
            var segmentStart = track.timeRange.start
            var trackDuration = track.timeRange.duration
            var clipForCrossfade: VideoClip?
            var clipPlacementStart: CMTime?
            var clipPlacementEnd: CMTime?

            if let clipID = clipAudioTrackIDs[track.trackID], let clip = clipByID[clipID] {
                volume = clip.isMuted ? 0 : clip.volume
                trackDuration = clip.scaledDuration
                clipForCrossfade = clip
                clipPlacementStart = clip.compositionStartTime
                clipPlacementEnd = CMTimeAdd(clip.compositionStartTime, clip.scaledDuration)
            } else if clipAudioTrackIDs.isEmpty, embeddedClipIndex < embeddedClips.count {
                let clip = embeddedClips[embeddedClipIndex]
                volume = clip.isMuted ? 0 : clip.volume
                trackDuration = clip.scaledDuration
                clipForCrossfade = clip
                clipPlacementStart = clip.compositionStartTime
                clipPlacementEnd = CMTimeAdd(clip.compositionStartTime, clip.scaledDuration)
                embeddedClipIndex += 1
            } else if projectAudioIndex < project.audioTracks.count {
                let audioTrack = project.audioTracks[projectAudioIndex]
                volume = audioTrack.volume
                fadeIn = audioTrack.isFadeIn
                fadeOut = audioTrack.isFadeOut
                segmentStart = audioTrack.startTime
                trackDuration = audioTrack.timeRange.duration
                projectAudioIndex += 1
            } else if let voiceover = project.voiceoverTrack,
                      voiceoverSegmentIndex < voiceover.segments.count {
                let segment = voiceover.segments[voiceoverSegmentIndex]
                volume = segment.volume
                segmentStart = segment.startTime
                trackDuration = segment.duration
                voiceoverSegmentIndex += 1
            }

            params.setVolume(volume, at: segmentStart)
            let oneSecond = CMTime(seconds: 1, preferredTimescale: 600)
            if fadeIn {
                params.setVolumeRamp(
                    fromStartVolume: 0,
                    toEndVolume: volume,
                    timeRange: CMTimeRange(start: segmentStart, duration: oneSecond)
                )
            }
            if fadeOut {
                let fadeStart = CMTimeMaximum(
                    segmentStart,
                    CMTimeSubtract(CMTimeAdd(segmentStart, trackDuration), oneSecond)
                )
                params.setVolumeRamp(
                    fromStartVolume: volume,
                    toEndVolume: 0,
                    timeRange: CMTimeRange(start: fadeStart, duration: oneSecond)
                )
            }

            // Crossfade clip audio across the full transition overlap.
            if let clip = clipForCrossfade,
               let start = clipPlacementStart,
               let end = clipPlacementEnd,
               let clipIndex = project.clips.firstIndex(where: { $0.id == clip.id }) {
                if clipIndex + 1 < project.clips.count,
                   let transition = clip.transition,
                   transition != .cut {
                    let fadeDuration = CMTime(seconds: clip.transitionDuration, preferredTimescale: 600)
                    let fadeStart = CMTimeSubtract(end, fadeDuration)
                    if CMTimeCompare(fadeStart, start) > 0 {
                        params.setVolumeRamp(
                            fromStartVolume: volume,
                            toEndVolume: 0,
                            timeRange: CMTimeRange(start: fadeStart, end: end)
                        )
                    }
                }
                if clipIndex > 0 {
                    let previous = project.clips[clipIndex - 1]
                    if let transition = previous.transition, transition != .cut {
                        let fadeDuration = CMTime(seconds: previous.transitionDuration, preferredTimescale: 600)
                        let fadeEnd = CMTimeAdd(start, fadeDuration)
                        params.setVolumeRamp(
                            fromStartVolume: 0,
                            toEndVolume: volume,
                            timeRange: CMTimeRange(start: start, end: fadeEnd)
                        )
                    }
                }
            }

            inputParameters.append(params)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = inputParameters
        return mix
    }

    private func clampedInsertRange(requested: CMTimeRange, source: CMTimeRange) -> CMTimeRange? {
        let start = CMTimeMaximum(requested.start, source.start)
        let end = CMTimeMinimum(requested.endTime, source.endTime)
        guard CMTimeCompare(end, start) > 0 else {
            return nil
        }
        return CMTimeRange(start: start, end: end)
    }

    private func transformedSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    private func standardRenderSize(
        for aspectRatio: AspectRatio,
        quality: EditorBuildQuality,
        targetLongEdge: CGFloat? = nil
    ) -> CGSize {
        let baseHeight: CGFloat = quality == .preview ? 1280 : 1920
        var width = baseHeight * aspectRatio.width / aspectRatio.height
        var height = baseHeight

        if quality == .export, let target = targetLongEdge, target > 0 {
            let currentLong = max(width, height)
            if abs(currentLong - target) > 0.5 {
                let scale = target / currentLong
                width *= scale
                height *= scale
            }
        }

        // HEVC requires even dimensions.
        func even(_ value: CGFloat) -> CGFloat {
            let rounded = Int(value.rounded())
            return CGFloat(max(2, rounded - (rounded % 2)))
        }
        return CGSize(width: even(width), height: even(height))
    }

    /// Maps a source track into the fixed portrait canvas (9:16) with aspect-fill.
    private func portraitFitTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        renderSize: CGSize
    ) -> CGAffineTransform {
        let orientedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedSize = CGSize(width: abs(orientedRect.width), height: abs(orientedRect.height))
        guard orientedSize.width > 0, orientedSize.height > 0 else { return .identity }

        var transform = preferredTransform.concatenating(
            CGAffineTransform(translationX: -orientedRect.origin.x, y: -orientedRect.origin.y)
        )

        let scale = max(renderSize.width / orientedSize.width, renderSize.height / orientedSize.height)
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))

        let scaledSize = CGSize(width: orientedSize.width * scale, height: orientedSize.height * scale)
        let tx = (renderSize.width - scaledSize.width) / 2
        let ty = (renderSize.height - scaledSize.height) / 2
        transform = transform.concatenating(CGAffineTransform(translationX: tx, y: ty))

        return transform
    }

    private func aspectAdjustedSize(_ source: CGSize, aspectRatio: AspectRatio) -> CGSize {
        let targetRatio = aspectRatio.width / aspectRatio.height
        let sourceRatio = source.width / source.height
        if sourceRatio > targetRatio {
            return CGSize(width: source.height * targetRatio, height: source.height)
        }
        return CGSize(width: source.width, height: source.width / targetRatio)
    }
}
