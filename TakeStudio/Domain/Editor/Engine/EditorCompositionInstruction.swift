import AVFoundation
import CoreGraphics
import Foundation

/// Metadata carried through custom composition instructions for the editor compositor.
final class EditorCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange = .invalid
    var enablePostProcessing = true
    var containsTweening = false
    var requiredSourceTrackIDs: [NSValue]?
    var requiredSourceSampleDataTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    var layerInstructions: [EditorLayerInstruction] = []
    var compositionTimeStart: CMTime = .zero
    /// Per-instruction compositor state — avoids racing a global singleton.
    var compositorState: EditorCompositorState?
}

struct EditorLayerInstruction: Sendable {
    let trackID: CMPersistentTrackID
    let clipID: UUID
    var transform: CGAffineTransform = .identity
    var opacity: Float = 1
}

/// Thread-safe snapshot used by `EditorVideoCompositor` during rendering.
struct EditorCompositorState: @unchecked Sendable {
    let clips: [VideoClip]
    let clipRanges: [(clipID: UUID, compositionRange: CMTimeRange)]
    let globalFilterIDs: [String]
    let globalColorAdjustments: ColorAdjustments
    let textOverlays: [TextOverlay]
    let stickerOverlays: [StickerOverlay]
    let subtitleTrack: SubtitleTrack?
    let layerOrder: [VisualLayer]
    let renderSize: CGSize
}

enum EditorCompositorContext {
    private static let lock = NSLock()
    private static var _state: EditorCompositorState?
    private static var _exportMode = false
    private static var _composeFailureCount = 0

    static var state: EditorCompositorState? {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    static var exportMode: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _exportMode
        }
        set {
            lock.lock()
            _exportMode = newValue
            lock.unlock()
        }
    }

    static func setState(_ state: EditorCompositorState?) {
        lock.lock()
        _state = state
        lock.unlock()
    }

    static func recordComposeFailure() {
        lock.lock()
        _composeFailureCount += 1
        let count = _composeFailureCount
        lock.unlock()
        if count <= 5 || count % 30 == 0 {
            PipelineLogger.editor.error("compositor frame failed count=\(count)")
        }
    }
}
