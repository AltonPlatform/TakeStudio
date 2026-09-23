import AVFoundation
import CoreImage
import UIKit
import VideoToolbox

enum StillImageClipRenderer {
    static let defaultDuration: TimeInterval = 3
    static let defaultFrameRate: Int32 = 30

    enum KenBurnsStyle {
        case none
        case zoomIn
        case panRight
    }

    static func renderVideo(
        from imageURL: URL,
        duration: TimeInterval = defaultDuration,
        frameRate: Int32 = defaultFrameRate,
        kenBurns: KenBurnsStyle = .zoomIn
    ) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try renderVideoSync(
                from: imageURL,
                duration: duration,
                frameRate: frameRate,
                kenBurns: kenBurns
            )
        }.value
    }

    private static func renderVideoSync(
        from imageURL: URL,
        duration: TimeInterval,
        frameRate: Int32,
        kenBurns: KenBurnsStyle
    ) throws -> URL {
        guard let uiImage = UIImage(contentsOfFile: imageURL.path),
              let cgImage = uiImage.cgImage else {
            throw StillImageClipError.invalidImage
        }

        let outputURL = TemporaryCaptureStore.videoURL()
        let frameCount = max(Int(duration * Double(frameRate)), 1)
        let renderSize = CGSize(width: 1080, height: 1920)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_000_000,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(renderSize.width),
            kCVPixelBufferHeightKey as String: Int(renderSize.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.canAdd(input) else { throw StillImageClipError.writerFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? StillImageClipError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        let baseImage = CIImage(cgImage: cgImage)
        let fitted = fitImage(baseImage, to: renderSize)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }

            let progress = frameCount <= 1 ? 0 : CGFloat(frame) / CGFloat(frameCount - 1)
            let transform = kenBurnsTransform(style: kenBurns, progress: progress, renderSize: renderSize)
            let frameImage = fitted.transformed(by: transform).cropped(to: CGRect(origin: .zero, size: renderSize))

            guard let pool = adaptor.pixelBufferPool else { throw StillImageClipError.writerFailed }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else { throw StillImageClipError.writerFailed }

            ciContext.render(
                frameImage,
                to: pixelBuffer,
                bounds: CGRect(origin: .zero, size: renderSize),
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )

            let presentationTime = CMTime(value: CMTimeValue(frame), timescale: frameRate)
            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? StillImageClipError.writerFailed
            }
        }

        input.markAsFinished()
        let group = DispatchGroup()
        group.enter()
        writer.finishWriting {
            group.leave()
        }
        group.wait()

        guard writer.status == .completed else {
            throw writer.error ?? StillImageClipError.writerFailed
        }
        return outputURL
    }

    private static func fitImage(_ image: CIImage, to renderSize: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let scale = max(renderSize.width / extent.width, renderSize.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent
        let tx = (renderSize.width - scaledExtent.width) / 2 - scaledExtent.origin.x
        let ty = (renderSize.height - scaledExtent.height) / 2 - scaledExtent.origin.y
        return scaled.transformed(by: CGAffineTransform(translationX: tx, y: ty))
    }

    private static func kenBurnsTransform(
        style: KenBurnsStyle,
        progress: CGFloat,
        renderSize: CGSize
    ) -> CGAffineTransform {
        switch style {
        case .none:
            return .identity
        case .zoomIn:
            let scale = 1 + progress * 0.12
            let centerX = renderSize.width / 2
            let centerY = renderSize.height / 2
            return CGAffineTransform(translationX: centerX, y: centerY)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -centerX, y: -centerY)
        case .panRight:
            let panX = progress * renderSize.width * 0.08
            return CGAffineTransform(translationX: -panX, y: 0)
        }
    }
}

enum StillImageClipError: LocalizedError {
    case invalidImage
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Could not load image."
        case .writerFailed: return "Failed to create photo clip video."
        }
    }
}
